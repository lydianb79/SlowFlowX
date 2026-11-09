import Foundation

// MARK: - Chords

enum ChordQuality: String, Codable, CaseIterable {
    case major, minor, dominant7, minor7, none

    var suffix: String {
        switch self {
        case .major: return ""
        case .minor: return "m"
        case .dominant7: return "7"
        case .minor7: return "m7"
        case .none: return ""
        }
    }

    /// Chord tones as semitone offsets from the root.
    var intervals: [Int] {
        switch self {
        case .major: return [0, 4, 7]
        case .minor: return [0, 3, 7]
        case .dominant7: return [0, 4, 7, 10]
        case .minor7: return [0, 3, 7, 10]
        case .none: return []
        }
    }

    /// Qualities used by the analyser (order matters: template index = qualityIndex * 12 + root).
    static let detectable: [ChordQuality] = [.major, .minor, .dominant7, .minor7]
}

enum ChordNaming {
    static let names = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]

    static func noteName(_ pc: Int) -> String { names[((pc % 12) + 12) % 12] }

    static func name(root: Int, quality: ChordQuality, transpose: Int = 0) -> String {
        guard root >= 0, quality != .none else { return "N.C." }
        return noteName(root + transpose) + quality.suffix
    }
}

struct ChordSegment: Codable, Hashable, Identifiable {
    var start: Double
    var end: Double
    var root: Int            // 0...11, -1 = no chord
    var quality: ChordQuality
    var confidence: Float

    var id: Double { start }
    var duration: Double { end - start }
    var isChord: Bool { root >= 0 && quality != .none }

    func name(transpose: Int = 0) -> String {
        ChordNaming.name(root: root, quality: quality, transpose: transpose)
    }

    func pitchClasses(transpose: Int = 0) -> [Int] {
        guard isChord else { return [] }
        return quality.intervals.map { (($0 + root + transpose) % 12 + 12) % 12 }
    }
}

struct SongAnalysis: Codable, Hashable {
    var chords: [ChordSegment]
    var keyRoot: Int
    var keyIsMinor: Bool
    var bpm: Double
    var peaks: [Float]
    var analyzedAt: Date
    var usedMetal: Bool

    func keyName(transpose: Int = 0) -> String {
        ChordNaming.noteName(keyRoot + transpose) + (keyIsMinor ? " minor" : " major")
    }

    /// Index of the chord active at `time` (binary search).
    func chordIndex(at time: Double) -> Int? {
        guard !chords.isEmpty else { return nil }
        var lo = 0, hi = chords.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if chords[mid].start <= time { lo = mid } else { hi = mid - 1 }
        }
        return chords[lo].start <= time + 0.0001 ? lo : nil
    }

    var uniqueChordCount: Int {
        Set(chords.filter(\.isChord).map { "\($0.root)-\($0.quality.rawValue)" }).count
    }
}

// MARK: - Lyrics

enum LyricsSource: String, Codable {
    case synced, plain, transcription, instrumental, notFound

    var label: String {
        switch self {
        case .synced: return "Synced · LRCLIB"
        case .plain: return "Unsynced · LRCLIB"
        case .transcription: return "Auto-transcribed"
        case .instrumental: return "Instrumental"
        case .notFound: return "Not found"
        }
    }
}

struct LyricLine: Codable, Hashable, Identifiable {
    var id: Int
    var time: Double?
    var text: String
}

struct Lyrics: Codable, Hashable {
    var lines: [LyricLine]
    var source: LyricsSource
    var matchedArtist: String?
    var matchedTitle: String?

    var isSynced: Bool { source == .synced || source == .transcription }

    func lineIndex(at time: Double) -> Int? {
        guard isSynced else { return nil }
        var result: Int?
        for (i, line) in lines.enumerated() {
            guard let t = line.time else { continue }
            if t <= time + 0.05 { result = i } else { break }
        }
        return result
    }
}

// MARK: - Song

struct Song: Identifiable, Codable, Hashable {
    var id: String               // YouTube video id
    var title: String
    var artist: String?
    var track: String?
    var uploader: String?
    var duration: Double
    var thumbnailURL: URL?
    var sourceURL: String
    var audioFileName: String
    var addedAt: Date
    var analysis: SongAnalysis?
    var lyrics: Lyrics?

    var audioURL: URL { LibraryPaths.audio.appendingPathComponent(audioFileName) }
    var displayArtist: String { artist ?? uploader ?? "Unknown artist" }
    var displayTitle: String { track ?? title }
}

// MARK: - Persistence

enum LibraryPaths {
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SlowFlowX", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static var audio: URL {
        let dir = root.appendingPathComponent("Audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var libraryFile: URL { root.appendingPathComponent("library.json") }
}

enum LibraryStore {
    static func load() -> [Song] {
        guard let data = try? Data(contentsOf: LibraryPaths.libraryFile) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Song].self, from: data)) ?? []
    }

    static func save(_ songs: [Song]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(songs) else { return }
        try? data.write(to: LibraryPaths.libraryFile, options: .atomic)
    }
}

// MARK: - Helpers

func formatTime(_ t: Double) -> String {
    guard t.isFinite, t >= 0 else { return "0:00" }
    let total = Int(t.rounded(.down))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}
