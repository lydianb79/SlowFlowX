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
    var demucs: URL?
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
    /// Stem-separation progress keyed by song id.
    var stemStatus: [String: AnalysisStatus] = [:]
    /// Play separated stems (when available) instead of the original mix.
    private(set) var playStems: Bool = UserDefaults.standard.object(forKey: "playStems") as? Bool ?? true

    @ObservationIgnored let player = PlaybackEngine()
    @ObservationIgnored private let downloader = YouTubeDownloader()
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var exportWork: Task<Void, Error>?
    @ObservationIgnored private var peaksLoading: Set<String> = []
    @ObservationIgnored private var stemTasks: [String: Task<Void, Never>] = [:]

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
        tools = ToolStatus(ytdlp: ToolLocator.find("yt-dlp"), ffmpeg: ToolLocator.find("ffmpeg"),
                           demucs: ToolLocator.find("demucs"))
    }

    // MARK: Selection

    func select(_ id: String?) {
        guard id != selectedID else { return }
        selectedID = id
        guard let song = selectedSong else { player.unload(); return }
        do {
            try player.load(url: song.audioURL)
            if playStems, song.stems != nil { loadStemsIntoPlayer(song) }
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
        let url = song.stems?.url(.vocals, songID: id)
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? song.audioURL
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
        // Transcribe from the isolated stem when one exists (much more accurate than the full mix).
        let stemKind = song.stems?.bestStem(for: source)
        let url = stemKind.flatMap { song.stems?.url($0, songID: id) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? song.audioURL
        let usedStem = url == song.audioURL ? nil : stemKind?.rawValue
        Task {
            do {
                var track = try await Task.detached(priority: .userInitiated) {
                    try MelodyAnalyzer().analyze(url: url, source: source) { stage, p in
                        Task { @MainActor in
                            if self.melodyStatus[key] != nil {
                                self.melodyStatus[key] = AnalysisStatus(stage: stage, progress: p)
                            }
                        }
                    }
                }.value
                track.stemUsed = usedStem
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

    // MARK: Stems

    func separateStems(_ id: String, engine: StemEngine) {
        guard let song = songs.first(where: { $0.id == id }), stemStatus[id] == nil else { return }
        refreshTools()
        if engine == .demucs && tools.demucs == nil {
            show("Demucs not installed", StemError.demucsMissing.errorDescription ?? "")
            return
        }
        stemStatus[id] = AnalysisStatus(stage: engine == .demucs ? "Starting Demucs…" : "Separating", progress: 0)
        let input = song.audioURL
        let model = DemucsModel.current
        let task = Task {
            do {
                let set: StemSet
                switch engine {
                case .demucs:
                    set = try await StemSeparator.separateWithDemucs(input: input, songID: id, model: model) { p in
                        Task { @MainActor in
                            if self.stemStatus[id] != nil {
                                self.stemStatus[id] = AnalysisStatus(stage: "Separating with Demucs (\(model.rawValue))", progress: p)
                            }
                        }
                    }
                case .builtin:
                    set = try await Task.detached(priority: .userInitiated) {
                        try StemSeparator.separateBuiltin(input: input, songID: id) { p in
                            Task { @MainActor in
                                if self.stemStatus[id] != nil {
                                    self.stemStatus[id] = AnalysisStatus(stage: "Separating (built-in, Metal)", progress: p)
                                }
                            }
                        }
                    }.value
                }
                try Task.checkCancellation()
                update(id) { $0.stems = set }
                if selectedID == id, playStems, let s = songs.first(where: { $0.id == id }) { loadStemsIntoPlayer(s) }
            } catch is CancellationError {
                // cancelled by the user
            } catch {
                show("Stem separation failed", error.localizedDescription)
            }
            stemStatus[id] = nil
            stemTasks[id] = nil
        }
        stemTasks[id] = task
    }

    func cancelStemSeparation(_ id: String) {
        stemTasks[id]?.cancel()
        stemTasks[id] = nil
        stemStatus[id] = nil
    }

    func deleteStems(_ id: String) {
        guard let song = songs.first(where: { $0.id == id }) else { return }
        if selectedID == id && player.usingStems { try? player.switchToMix(url: song.audioURL) }
        StemSeparator.clear(LibraryPaths.stems(id))
        update(id) { $0.stems = nil }
    }

    func setPlayStems(_ on: Bool) {
        playStems = on
        UserDefaults.standard.set(on, forKey: "playStems")
        guard let song = selectedSong else { return }
        if on, song.stems != nil {
            loadStemsIntoPlayer(song)
        } else if !on, player.usingStems {
            do { try player.switchToMix(url: song.audioURL) } catch { show("Couldn't open audio", error.localizedDescription) }
        }
    }

    private func loadStemsIntoPlayer(_ song: Song) {
        guard let set = song.stems else { return }
        let tracks: [(StemKind, URL)] = set.kinds.compactMap { k in
            guard let u = set.url(k, songID: song.id), FileManager.default.fileExists(atPath: u.path) else { return nil }
            return (k, u)
        }
        guard !tracks.isEmpty else { return }
        do { try player.loadStems(tracks) } catch { show("Couldn't open stems", error.localizedDescription) }
    }

    // MARK: Export

    enum ExportAudio {
        case original
        /// Stems mixed into one file with the given gains.
        case stemMix([StemKind: Float])
        /// One file per stem.
        case separateStems([StemKind])
    }

    func exportWAV(songID: String, useSelection: Bool, applyProcessing: Bool, bitDepth: Int, audio: ExportAudio = .original) {
        guard let song = songs.first(where: { $0.id == songID }), activity == nil else { return }
        var start = 0.0
        var end = player.duration > 0 ? player.duration : song.duration
        let isSection = useSelection && player.loopStart != nil && player.loopEnd != nil
        if isSection, let a = player.loopStart, let b = player.loopEnd, b > a { start = a; end = b }
        let rate: Float = applyProcessing ? player.rate : 1
        let pitch = applyProcessing ? player.pitchSemitones : 0
        let options = AudioExporter.Options(start: start, end: end, rate: rate, pitchSemitones: pitch, bitDepth: bitDepth)
        let baseName = AudioExporter.suggestedFileName(title: song.displayTitle, rate: rate, pitch: pitch, isSection: isSection)
            .replacingOccurrences(of: ".wav", with: "")

        // Build the list of output files: (destination, [(source, gain)])
        var jobs: [(URL, [(URL, Float)])] = []
        var revealURL: URL?
        switch audio {
        case .original:
            let panel = NSSavePanel()
            panel.title = "Export WAV"
            panel.allowedContentTypes = [.wav]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = baseName + ".wav"
            guard panel.runModal() == .OK, let dest = panel.url else { return }
            jobs = [(dest, [(song.audioURL, 1)])]
            revealURL = dest

        case .stemMix(let gains):
            guard let set = song.stems else { return }
            let srcs: [(URL, Float)] = gains.compactMap { k, g in
                guard g > 0, let u = set.url(k, songID: song.id) else { return nil }
                return (u, g)
            }
            guard !srcs.isEmpty else { show("Nothing to export", "All selected stems are muted."); return }
            let label = gains.filter { $0.value > 0 }.keys.sorted { $0.rawValue < $1.rawValue }.map(\.label).joined(separator: "+")
            let panel = NSSavePanel()
            panel.title = "Export Stem Mix"
            panel.allowedContentTypes = [.wav]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = "\(baseName) [\(label)].wav"
            guard panel.runModal() == .OK, let dest = panel.url else { return }
            jobs = [(dest, srcs)]
            revealURL = dest

        case .separateStems(let kinds):
            guard let set = song.stems, !kinds.isEmpty else { return }
            let panel = NSOpenPanel()
            panel.title = "Choose a folder for the stems"
            panel.prompt = "Export Here"
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            for k in kinds {
                guard let u = set.url(k, songID: song.id) else { continue }
                jobs.append((folder.appendingPathComponent("\(baseName) - \(k.label).wav"), [(u, 1)]))
            }
            revealURL = jobs.first?.0
        }
        guard !jobs.isEmpty else { return }

        activity = Activity(title: "Exporting WAV", detail: jobs.count == 1 ? jobs[0].0.lastPathComponent : "\(jobs.count) files", progress: 0)
        let jobList = jobs
        let work = Task.detached(priority: .userInitiated) {
            for (i, job) in jobList.enumerated() {
                try AudioExporter.exportWAV(sources: job.1, destination: job.0, options: options) { p in
                    let overall = (Double(i) + p) / Double(jobList.count)
                    Task { @MainActor in
                        if self.activity?.title == "Exporting WAV" { self.activity?.progress = overall }
                    }
                }
            }
        }
        exportWork = work
        Task {
            do {
                try await work.value
                activity = nil
                if let revealURL { NSWorkspace.shared.activateFileViewerSelecting(jobList.map(\.0).isEmpty ? [revealURL] : jobList.map(\.0)) }
            } catch is CancellationError {
                activity = nil
                for j in jobList { try? FileManager.default.removeItem(at: j.0) }
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
        try? FileManager.default.removeItem(at: LibraryPaths.stems(id))
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
