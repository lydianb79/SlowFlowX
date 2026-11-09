import Foundation
import Speech

struct LyricsQuery: Hashable {
    var artist: String?
    var title: String
    var duration: Double
}

enum LyricsError: LocalizedError {
    case speechNotAuthorized
    case speechUnavailable
    case nothingRecognized

    var errorDescription: String? {
        switch self {
        case .speechNotAuthorized:
            return "Speech recognition permission was denied. Enable it in System Settings › Privacy & Security › Speech Recognition."
        case .speechUnavailable:
            return "Speech recognition isn't available for this language on this Mac."
        case .nothingRecognized:
            return "No vocals could be recognised in this recording."
        }
    }
}

/// Lyrics come from two places at runtime:
///  1. LRCLIB (https://lrclib.net), a free, open database of time-synced lyrics.
///  2. Apple's on-device speech recogniser as a best-effort fallback.
enum LyricsService {

    // MARK: Query building

    static func query(for song: Song) -> LyricsQuery {
        if let track = song.track, !track.isEmpty {
            return LyricsQuery(artist: song.artist ?? song.uploader, title: track, duration: song.duration)
        }
        let cleaned = cleanTitle(song.title)
        for sep in [" - ", " – ", " — ", " | ", " ~ "] {
            if let r = cleaned.range(of: sep) {
                let a = cleaned[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
                let t = cleaned[r.upperBound...].trimmingCharacters(in: .whitespaces)
                if !a.isEmpty, !t.isEmpty { return LyricsQuery(artist: a, title: t, duration: song.duration) }
            }
        }
        return LyricsQuery(artist: song.artist ?? song.uploader, title: cleaned, duration: song.duration)
    }

    static func cleanTitle(_ s: String) -> String {
        var t = s
        let noise = #"[\(\[\{][^\)\]\}]*(official|video|audio|lyric|visuali[sz]er|\bhd\b|\bhq\b|4k|remaster|\bmv\b|m/v|clip|explicit)[^\)\]\}]*[\)\]\}]"#
        t = t.replacingOccurrences(of: noise, with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"\s+(ft\.?|feat\.?|featuring)\s+[^\-–—\(\[]*"#, with: " ", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—|")))
    }

    // MARK: LRCLIB

    private struct LRCLibItem: Decodable {
        let id: Int
        let trackName: String?
        let artistName: String?
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    static func fetchOnline(_ q: LyricsQuery) async throws -> Lyrics? {
        var candidates: [LRCLibItem] = []
        if let artist = q.artist, !artist.isEmpty {
            candidates = try await search(["track_name": q.title, "artist_name": artist])
        }
        if candidates.isEmpty {
            let full = [q.artist, q.title].compactMap { $0 }.joined(separator: " ")
            candidates = try await search(["q": full])
        }
        if candidates.isEmpty, q.artist != nil {
            candidates = try await search(["q": q.title])
        }
        guard let best = pickBest(candidates, duration: q.duration) else { return nil }

        if best.instrumental == true {
            return Lyrics(lines: [], source: .instrumental, matchedArtist: best.artistName, matchedTitle: best.trackName)
        }
        if let synced = best.syncedLyrics, !synced.isEmpty {
            let lines = parseLRC(synced)
            if !lines.isEmpty {
                return Lyrics(lines: lines, source: .synced, matchedArtist: best.artistName, matchedTitle: best.trackName)
            }
        }
        if let plain = best.plainLyrics, !plain.isEmpty {
            let lines = plain.components(separatedBy: .newlines).enumerated()
                .map { LyricLine(id: $0.offset, time: nil, text: $0.element) }
            return Lyrics(lines: lines, source: .plain, matchedArtist: best.artistName, matchedTitle: best.trackName)
        }
        return nil
    }

    private static func search(_ params: [String: String]) async throws -> [LRCLibItem] {
        var comps = URLComponents(string: "https://lrclib.net/api/search")!
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = comps.url else { return [] }
        var req = URLRequest(url: url)
        req.setValue("SlowFlowX/1.0 (macOS music practice app)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return (try? JSONDecoder().decode([LRCLibItem].self, from: data)) ?? []
    }

    private static func pickBest(_ items: [LRCLibItem], duration: Double) -> LRCLibItem? {
        func score(_ i: LRCLibItem) -> Double {
            let diff = (duration > 0 && (i.duration ?? 0) > 0) ? abs((i.duration ?? 0) - duration) : 10
            let syncPenalty: Double = (i.syncedLyrics?.isEmpty == false) ? 0 : 15
            return diff + syncPenalty
        }
        let plausible = items.filter { item in
            guard duration > 0, let d = item.duration, d > 0 else { return true }
            return abs(d - duration) <= 25
        }
        return plausible.min { score($0) < score($1) }
    }

    static func parseLRC(_ s: String) -> [LyricLine] {
        guard let regex = try? NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2}(?:[\.:]\d{1,3})?)\]"#) else { return [] }
        var entries: [(Double, String)] = []
        for raw in s.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let matches = regex.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let text = ns.substring(from: last.range.location + last.range.length).trimmingCharacters(in: .whitespaces)
            for m in matches {
                let minutes = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: m.range(at: 2)).replacingOccurrences(of: ":", with: ".")) ?? 0
                entries.append((minutes * 60 + seconds, text))
            }
        }
        entries.sort { $0.0 < $1.0 }
        return entries.enumerated().map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }

    // MARK: On-device transcription

    private final class Once: @unchecked Sendable {
        private var done = false
        private let lock = NSLock()
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }

    private static var activeTask: SFSpeechRecognitionTask?

    static func transcribe(url: URL, localeIdentifier: String = "en-US") async throws -> Lyrics {
        let status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard status == .authorized else { throw LyricsError.speechNotAuthorized }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else { throw LyricsError.speechUnavailable }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        let result: SFSpeechRecognitionResult = try await withCheckedThrowingContinuation { cont in
            let once = Once()
            activeTask = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    if once.claim() { cont.resume(returning: result) }
                } else if let error {
                    if once.claim() { cont.resume(throwing: error) }
                }
            }
        }
        activeTask = nil

        // Group recognised words into lines using pauses and a max word count.
        var lines: [LyricLine] = []
        var words: [String] = []
        var lineStart: Double = 0
        var lastEnd: Double = 0
        for seg in result.bestTranscription.segments {
            let gap = seg.timestamp - lastEnd
            if !words.isEmpty && (gap > 0.8 || words.count >= 9) {
                lines.append(LyricLine(id: lines.count, time: lineStart, text: words.joined(separator: " ")))
                words.removeAll()
            }
            if words.isEmpty { lineStart = seg.timestamp }
            words.append(seg.substring)
            lastEnd = seg.timestamp + seg.duration
        }
        if !words.isEmpty { lines.append(LyricLine(id: lines.count, time: lineStart, text: words.joined(separator: " "))) }
        guard !lines.isEmpty else { throw LyricsError.nothingRecognized }
        return Lyrics(lines: lines, source: .transcription, matchedArtist: nil, matchedTitle: nil)
    }
}
