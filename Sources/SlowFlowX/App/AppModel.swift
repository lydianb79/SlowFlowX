import SwiftUI
import AppKit
import Observation
import UniformTypeIdentifiers

struct Activity: Equatable {
    var title: String
    var detail: String
    var progress: Double?
}

struct AnalysisStatus: Equatable {
    var stage: String
    var progress: Double
}

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct ToolStatus {
    var ytdlp: URL?
    var ffmpeg: URL?
}

@MainActor
@Observable
final class AppModel {
    var songs: [Song] = []
    private(set) var selectedID: String?
    var urlText = ""
    var activity: Activity?
    var analysisStatus: [String: AnalysisStatus] = [:]
    var lyricsLoading: Set<String> = []
    var alert: AppAlert?
    var tools = ToolStatus()
    /// High-resolution waveform peaks (100 per second) for the zoomable waveform, computed on demand.
    var detailPeaks: [String: [Float]] = [:]
    var showExportSheet = false
    /// Progress of melody transcriptions, keyed by "songID|source".
    var melodyStatus: [String: AnalysisStatus] = [:]

    @ObservationIgnored let player = PlaybackEngine()
    @ObservationIgnored private let downloader = YouTubeDownloader()
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var exportWork: Task<Void, Error>?
    @ObservationIgnored private var peaksLoading: Set<String> = []

    init() {
        songs = LibraryStore.load().filter { FileManager.default.fileExists(atPath: $0.audioURL.path) }
        refreshTools()
    }

    var selectedSong: Song? {
        guard let selectedID else { return nil }
        return songs.first { $0.id == selectedID }
    }

    var transpose: Int { player.pitchSemitones }

    func refreshTools() {
        tools = ToolStatus(ytdlp: ToolLocator.find("yt-dlp"), ffmpeg: ToolLocator.find("ffmpeg"))
    }

    // MARK: Selection

    func select(_ id: String?) {
        guard id != selectedID else { return }
        selectedID = id
        guard let song = selectedSong else { player.unload(); return }
        do {
            try player.load(url: song.audioURL)
        } catch {
            show("Couldn't open audio", error.localizedDescription)
        }
        if song.analysis == nil { analyze(song.id) }
        if song.lyrics == nil { fetchLyrics(song.id) }
        loadDetailPeaks(song.id)
    }

    private func loadDetailPeaks(_ id: String) {
        guard detailPeaks[id] == nil, !peaksLoading.contains(id),
              let song = songs.first(where: { $0.id == id }) else { return }
        peaksLoading.insert(id)
        let url = song.audioURL
        Task {
            let peaks = await Task.detached(priority: .utility) { () -> [Float] in
                let sr = 8000.0
                guard let samples = try? AudioLoader.loadMono(url: url, sampleRate: sr), !samples.isEmpty else { return [] }
                let count = max(1, Int(Double(samples.count) / sr * 100))
                return ChordAnalyzer.peaks(samples, count: count)
            }.value
            if !peaks.isEmpty { detailPeaks[id] = peaks }
            peaksLoading.remove(id)
        }
    }

    // MARK: Import

    func importFromURL() {
        let text = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard YouTubeDownloader.isValidYouTubeURL(text) else {
            show("Invalid link", "Paste a YouTube video link, e.g. https://www.youtube.com/watch?v=…")
            return
        }
        guard activity == nil else { return }
        importTask = Task { await runImport(text) }
    }

    func cancelImport() {
        importTask?.cancel()
        importTask = nil
        exportWork?.cancel()
        activity = nil
    }

    private func runImport(_ url: String) async {
        refreshTools()
        activity = Activity(title: "Fetching video info…", detail: url, progress: nil)
        do {
            let meta = try await downloader.metadata(for: url)
            if let existing = songs.first(where: { $0.id == meta.id }),
               FileManager.default.fileExists(atPath: existing.audioURL.path) {
                activity = nil
                urlText = ""
                select(existing.id)
                return
            }

            activity = Activity(title: "Downloading audio", detail: meta.title, progress: 0)
            let fileURL = try await downloader.downloadAudio(url: url, id: meta.id, to: LibraryPaths.audio) { p in
                Task { @MainActor in self.activity?.progress = p }
            }
            try Task.checkCancellation()

            let song = Song(
                id: meta.id, title: meta.title, artist: meta.artist, track: meta.track, uploader: meta.uploader,
                duration: meta.duration, thumbnailURL: meta.thumbnail, sourceURL: url,
                audioFileName: fileURL.lastPathComponent, addedAt: Date(), analysis: nil, lyrics: nil)
            songs.removeAll { $0.id == song.id }
            songs.insert(song, at: 0)
            save()
            activity = nil
            urlText = ""
            if selectedID == song.id { selectedID = nil }
            select(song.id)
        } catch is CancellationError {
            activity = nil
        } catch {
            activity = nil
            show("Download failed", error.localizedDescription)
        }
    }

    // MARK: Analysis

    func analyze(_ id: String) {
        guard let song = songs.first(where: { $0.id == id }), analysisStatus[id] == nil else { return }
        analysisStatus[id] = AnalysisStatus(stage: "Preparing", progress: 0)
        let url = song.audioURL
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try ChordAnalyzer().analyze(url: url) { stage, p in
                        Task { @MainActor in
                            if self.analysisStatus[id] != nil {
                                self.analysisStatus[id] = AnalysisStatus(stage: stage, progress: p)
                            }
                        }
                    }
                }.value
                update(id) { $0.analysis = result }
            } catch {
                show("Analysis failed", error.localizedDescription)
            }
            analysisStatus[id] = nil
        }
    }

    // MARK: Lyrics

    func fetchLyrics(_ id: String, artist: String? = nil, title: String? = nil) {
        guard let song = songs.first(where: { $0.id == id }), !lyricsLoading.contains(id) else { return }
        var query = LyricsService.query(for: song)
        if let artist { query.artist = artist.isEmpty ? nil : artist }
        if let title, !title.isEmpty { query.title = title }
        lyricsLoading.insert(id)
        Task {
            var lyrics: Lyrics?
            do {
                lyrics = try await LyricsService.fetchOnline(query)
            } catch {
                NSLog("SlowFlowX: lyrics lookup failed: \(error)")
            }
            update(id) { $0.lyrics = lyrics ?? Lyrics(lines: [], source: .notFound, matchedArtist: nil, matchedTitle: nil) }
            lyricsLoading.remove(id)
        }
    }

    func transcribeLyrics(_ id: String) {
        guard let song = songs.first(where: { $0.id == id }), !lyricsLoading.contains(id) else { return }
        lyricsLoading.insert(id)
        let url = song.audioURL
        Task {
            do {
                let lyrics = try await LyricsService.transcribe(url: url)
                update(id) { $0.lyrics = lyrics }
            } catch {
                show("Transcription failed", error.localizedDescription)
            }
            lyricsLoading.remove(id)
        }
    }

    // MARK: Melody / riff transcription

    static func melodyKey(_ id: String, _ source: MelodySource) -> String { id + "|" + source.rawValue }

    func analyzeMelody(_ id: String, source: MelodySource) {
        let key = Self.melodyKey(id, source)
        guard let song = songs.first(where: { $0.id == id }), melodyStatus[key] == nil else { return }
        melodyStatus[key] = AnalysisStatus(stage: "Preparing", progress: 0)
        let url = song.audioURL
        Task {
            do {
                let track = try await Task.detached(priority: .userInitiated) {
                    try MelodyAnalyzer().analyze(url: url, source: source) { stage, p in
                        Task { @MainActor in
                            if self.melodyStatus[key] != nil {
                                self.melodyStatus[key] = AnalysisStatus(stage: stage, progress: p)
                            }
                        }
                    }
                }.value
                update(id) { song in
                    var m = song.melodies ?? [:]
                    m[source.rawValue] = track
                    song.melodies = m
                }
            } catch {
                show("Transcription failed", error.localizedDescription)
            }
            melodyStatus[key] = nil
        }
    }

    func exportMIDI(_ id: String, source: MelodySource) {
        guard let song = songs.first(where: { $0.id == id }), let track = song.melodies?[source.rawValue] else { return }
        let panel = NSSavePanel()
        panel.title = "Export MIDI"
        panel.allowedContentTypes = [UTType(filenameExtension: "mid") ?? .data]
        panel.nameFieldStringValue = "\(song.displayTitle) - \(source.shortLabel).mid"
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let data = MelodyExport.midiFile(track: track, chords: song.analysis?.chords ?? [], title: song.displayTitle,
                                         fallbackBPM: song.analysis?.bpm ?? 0, transpose: player.pitchSemitones,
                                         resolution: Self.quantizeResolution)
        do {
            try data.write(to: url, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            show("Export failed", error.localizedDescription)
        }
    }

    func asciiTab(_ id: String, source: MelodySource) -> String? {
        guard let song = songs.first(where: { $0.id == id }), let track = song.melodies?[source.rawValue] else { return nil }
        return MelodyExport.asciiTab(track: track, chords: song.analysis?.chords ?? [],
                                     title: "\(song.displayTitle) – \(song.displayArtist)",
                                     fallbackBPM: song.analysis?.bpm ?? 0, transpose: player.pitchSemitones,
                                     resolution: Self.quantizeResolution)
    }

    /// Grid snapping chosen in the Tab & Notes panel: 0 = off, 1 = 16ths, 2 = 8ths.
    static var quantizeResolution: Int { UserDefaults.standard.integer(forKey: "melodyQuantize") }

    /// Adjust the detected tempo of a part (e.g. halve or double when the guess is off).
    func setMelodyTempo(_ id: String, source: MelodySource, bpm: Double) {
        let clamped = min(max(bpm, 40), 240)
        update(id) { song in
            guard var t = song.melodies?[source.rawValue] else { return }
            t.bpm = clamped
            song.melodies?[source.rawValue] = t
        }
    }

    /// Move the beat grid so the beat falls at `time`.
    func alignBeat(_ id: String, source: MelodySource, at time: Double) {
        update(id) { song in
            guard var t = song.melodies?[source.rawValue] else { return }
            let grid = t.grid(fallbackBPM: song.analysis?.bpm ?? 0)
            var off = time.truncatingRemainder(dividingBy: grid.beat)
            if off < 0 { off += grid.beat }
            t.beatOffset = off
            song.melodies?[source.rawValue] = t
        }
    }

    func copyASCIITab(_ id: String, source: MelodySource) {
        guard let text = asciiTab(id, source: source) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func saveASCIITab(_ id: String, source: MelodySource) {
        guard let song = songs.first(where: { $0.id == id }), let text = asciiTab(id, source: source) else { return }
        let panel = NSSavePanel()
        panel.title = "Save Tab"
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(song.displayTitle) - \(source.shortLabel) tab.txt"
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            show("Save failed", error.localizedDescription)
        }
    }

    // MARK: Export

    func exportWAV(songID: String, useSelection: Bool, applyProcessing: Bool, bitDepth: Int) {
        guard let song = songs.first(where: { $0.id == songID }), activity == nil else { return }
        var start = 0.0
        var end = player.duration > 0 ? player.duration : song.duration
        let isSection = useSelection && player.loopStart != nil && player.loopEnd != nil
        if isSection, let a = player.loopStart, let b = player.loopEnd, b > a { start = a; end = b }
        let rate: Float = applyProcessing ? player.rate : 1
        let pitch = applyProcessing ? player.pitchSemitones : 0

        let panel = NSSavePanel()
        panel.title = "Export WAV"
        panel.allowedContentTypes = [.wav]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = AudioExporter.suggestedFileName(
            title: song.displayTitle, rate: rate, pitch: pitch, isSection: isSection)
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let options = AudioExporter.Options(start: start, end: end, rate: rate, pitchSemitones: pitch, bitDepth: bitDepth)
        let source = song.audioURL
        activity = Activity(title: "Exporting WAV", detail: destination.lastPathComponent, progress: 0)
        let work = Task.detached(priority: .userInitiated) {
            try AudioExporter.exportWAV(source: source, destination: destination, options: options) { p in
                Task { @MainActor in
                    if self.activity?.title == "Exporting WAV" { self.activity?.progress = p }
                }
            }
        }
        exportWork = work
        Task {
            do {
                try await work.value
                activity = nil
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch is CancellationError {
                activity = nil
                try? FileManager.default.removeItem(at: destination)
            } catch {
                activity = nil
                show("Export failed", error.localizedDescription)
            }
            exportWork = nil
        }
    }

    // MARK: Library management

    func delete(_ id: String) {
        guard let song = songs.first(where: { $0.id == id }) else { return }
        if selectedID == id { select(nil) }
        try? FileManager.default.removeItem(at: song.audioURL)
        songs.removeAll { $0.id == id }
        save()
    }

    func revealInFinder(_ id: String) {
        guard let song = songs.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([song.audioURL])
    }

    func openSource(_ id: String) {
        guard let song = songs.first(where: { $0.id == id }), let url = URL(string: song.sourceURL) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Helpers

    func show(_ title: String, _ message: String) {
        alert = AppAlert(title: title, message: message)
    }

    private func update(_ id: String, _ body: (inout Song) -> Void) {
        guard let i = songs.firstIndex(where: { $0.id == id }) else { return }
        body(&songs[i])
        save()
    }

    private func save() { LibraryStore.save(songs) }
}
