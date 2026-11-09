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
    /// nil = not checked yet / checking, true = self-test passed, false = broken or missing
    var demucsOK: Bool?
    var demucsProblem: String?

    /// Demucs is installed AND its self-test passed.
    var demucsReady: Bool { demucs != nil && demucsOK == true }
    /// The launcher exists but Demucs can't run (e.g. a missing Python module).
    var demucsBroken: Bool { demucs != nil && demucsOK == false }
    var demucsChecking: Bool { demucs != nil && demucsOK == nil }
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
    /// Demucs installer state
    var showDemucsInstaller = false
    private(set) var demucsInstalling = false
    private(set) var demucsInstallLog = ""
    private(set) var demucsInstallError: String?
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

    /// Re-locates the command-line tools. Demucs is also self-tested (in the background) the first time,
    /// whenever its location changes, or when `recheckDemucs` is true.
    func refreshTools(recheckDemucs: Bool = false) {
        let demucs = ToolLocator.find("demucs")
        let needsCheck = recheckDemucs || demucs != tools.demucs || tools.demucsOK == nil
        var t = ToolStatus(ytdlp: ToolLocator.find("yt-dlp"), ffmpeg: ToolLocator.find("ffmpeg"), demucs: demucs)
        if demucs == nil {
            t.demucsOK = false
        } else if !needsCheck {
            t.demucsOK = tools.demucsOK
            t.demucsProblem = tools.demucsProblem
        }
        tools = t
        guard demucs != nil, needsCheck else { return }
        Task {
            let result = await StemSeparator.checkDemucs()
            guard tools.demucs == demucs else { return }
            tools.demucsOK = result.ok
            tools.demucsProblem = result.ok ? nil : result.message
        }
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
        // Beat grid reference: drums stem if available, otherwise the full mix (never an isolated
        // vocal/guitar stem, which has no reliable pulse).
        let rhythmURL = song.stems?.url(.drums, songID: id)
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? song.audioURL
        let tempoHint = song.analysis?.bpm
        Task {
            do {
                var track = try await Task.detached(priority: .userInitiated) {
                    try MelodyAnalyzer().analyze(url: url, source: source, rhythmURL: rhythmURL, tempoHint: tempoHint) { stage, p in
                        Task { @MainActor in
                            if self.melodyStatus[key] != nil {
                                self.melodyStatus[key] = AnalysisStatus(stage: stage, progress: p)
                            }
                        }
                    }
                }.value
                track.stemUsed = usedStem
                track.version = MelodyTrack.currentVersion
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

    /// Exports place notes on the 16th-note grid, like the sheet-style tab view.
    static var quantizeResolution: Int { 1 }

    /// Adjust the detected tempo of a part (e.g. halve or double when the guess is off).
    /// Tempo is a property of the song: changing it updates the song and every transcribed part.
    func setMelodyTempo(_ id: String, source: MelodySource, bpm: Double) {
        setSongTempo(id, bpm: bpm, offset: nil)
    }

    func setSongTempo(_ id: String, bpm: Double, offset: Double?, userSet: Bool = true) {
        let clamped = min(max(bpm, 40), 240)
        update(id) { song in
            if var a = song.analysis {
                a.bpm = clamped
                if userSet { a.tempoLocked = true }
                a.beatOffset = offset ?? a.beatOffset
                song.analysis = a
            }
            guard var m = song.melodies else { return }
            for k in Array(m.keys) {
                guard var t = m[k] else { continue }
                if t.isOutdated { t.version = MelodyTrack.currentVersion }
                t.bpm = clamped
                if let offset { t.beatOffset = offset } else if t.beatOffset == nil { t.beatOffset = 0 }
                m[k] = t
            }
            song.melodies = m
        }
    }

    /// Move the beat grid (all parts) so a beat falls at `time`.
    func alignBeat(_ id: String, source: MelodySource, at time: Double) {
        guard let song = songs.first(where: { $0.id == id }) else { return }
        let bpm = song.melodies?[source.rawValue]?.grid(fallbackBPM: song.analysis?.bpm ?? 0).bpm
            ?? song.analysis?.bpm ?? 120
        let beat = 60 / bpm
        var off = time.truncatingRemainder(dividingBy: beat)
        if off < 0 { off += beat }
        setSongTempo(id, bpm: bpm, offset: off)
    }

    // MARK: Tap tempo

    @ObservationIgnored private var tapTimes: [Double] = []
    @ObservationIgnored private var tapWall: [Date] = []
    private(set) var tapCount = 0

    /// Tap along with the beat while the song plays (works at any playback speed — taps are
    /// measured in song time). After 4+ taps the song tempo and beat position are set.
    func tapTempo(_ id: String) {
        let now = Date()
        if let last = tapWall.last, now.timeIntervalSince(last) > 2.5 {
            tapTimes.removeAll(); tapWall.removeAll()
        }
        tapTimes.append(player.currentTime)
        tapWall.append(now)
        if tapTimes.count > 16 { tapTimes.removeFirst(); tapWall.removeFirst() }
        tapCount = tapTimes.count
        guard tapTimes.count >= 4 else { return }
        let intervals = zip(tapTimes.dropFirst(), tapTimes).map { $0 - $1 }.filter { $0 > 0.2 && $0 < 2 }
        guard intervals.count >= 3 else { return }
        let sorted = intervals.sorted()
        let beat = sorted[sorted.count / 2]
        let bpm = (60 / beat * 2).rounded() / 2          // nearest 0.5 BPM
        let b = 60 / bpm
        // circular mean of tap phases → beat offset
        var sx = 0.0, sy = 0.0
        for t in tapTimes {
            let ph = t.truncatingRemainder(dividingBy: b) / b * 2 * .pi
            sx += cos(ph); sy += sin(ph)
        }
        var phase = atan2(sy, sx) / (2 * .pi) * b
        if phase < 0 { phase += b }
        setSongTempo(id, bpm: bpm, offset: phase)
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
        if engine == .demucs && !tools.demucsReady {
            // Missing, broken or still being checked: open the installer, which can repair it.
            showDemucsInstaller = true
            if tools.demucsChecking { refreshTools(recheckDemucs: true) }
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
                retempoFromDrums(id)
                if selectedID == id, playStems, let s = songs.first(where: { $0.id == id }) { loadStemsIntoPlayer(s) }
            } catch is CancellationError {
                // cancelled by the user
            } catch {
                if engine == .demucs {
                    // Re-test Demucs; if it's broken the Stems bar switches to "Repair Demucs".
                    tools.demucsOK = nil
                    refreshTools(recheckDemucs: true)
                    show("Stem separation failed",
                         error.localizedDescription + "\n\nIf Demucs itself is broken, use “Repair Demucs” in the Stems bar (or Settings › Tools).")
                } else {
                    show("Stem separation failed", error.localizedDescription)
                }
            }
            stemStatus[id] = nil
            stemTasks[id] = nil
        }
        stemTasks[id] = task
    }

    func installDemucs() {
        guard !demucsInstalling else { return }
        demucsInstalling = true
        demucsInstallError = nil
        demucsInstallLog = ""
        Task {
            do {
                try await StemSeparator.installDemucs { line in
                    Task { @MainActor in
                        self.demucsInstallLog += line + "\n"
                        if self.demucsInstallLog.count > 60_000 {
                            self.demucsInstallLog = String(self.demucsInstallLog.suffix(40_000))
                        }
                    }
                }
            } catch {
                demucsInstallError = error.localizedDescription
            }
            tools.demucsOK = nil
            refreshTools(recheckDemucs: true)
            demucsInstalling = false
        }
    }

    /// The drums stem gives a much cleaner pulse than the full mix: re-detect tempo and bar position
    /// from it (unless the user already set the tempo by hand).
    func retempoFromDrums(_ id: String, force: Bool = false) {
        guard let song = songs.first(where: { $0.id == id }),
              force || song.analysis?.tempoLocked != true,
              let drums = song.stems?.url(.drums, songID: id),
              FileManager.default.fileExists(atPath: drums.path) else { return }
        Task {
            let result = await Task.detached(priority: .utility) { () -> (Double, Double)? in
                guard let x = try? AudioLoader.loadMono(url: drums, sampleRate: 22_050) else { return nil }
                let det = OnsetDetector.detect(x, sampleRate: 22_050, lowHz: 40, highHz: 10_000)
                let bpm = ChordAnalyzer.tempo(fromFlux: det.flux, frameRate: det.frameRate)
                guard bpm > 30 else { return nil }
                return (bpm, OnsetDetector.beatOffset(det, bpm: bpm))
            }.value
            if let r = result { setSongTempo(id, bpm: r.0, offset: r.1, userSet: force) }
        }
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
