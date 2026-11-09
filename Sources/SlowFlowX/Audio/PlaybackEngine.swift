import AVFoundation
import Observation

/// Audio playback with independent speed and pitch control, playing either the original mix or a set
/// of separated stems in sample-accurate sync (each stem can be muted, soloed or re-balanced).
///
/// Graph:  player(s) → submix → AVAudioUnitTimePitch → mainMixer → output
/// The time-pitch unit performs a phase-vocoder time-stretch, so `rate` slows the music down without
/// changing its pitch (and `pitch` transposes without changing tempo).
@Observable
final class PlaybackEngine {
    private struct Source {
        let key: String            // "mix" or StemKind.rawValue
        let player: AVAudioPlayerNode
        let file: AVAudioFile
        var sampleRate: Double { file.processingFormat.sampleRate }
    }

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let submix = AVAudioMixerNode()
    @ObservationIgnored private let timePitch = AVAudioUnitTimePitch()
    @ObservationIgnored private var sources: [Source] = []
    @ObservationIgnored private var segmentStartTime: Double = 0
    @ObservationIgnored private var isScheduled = false
    @ObservationIgnored private var scheduleToken = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var configObserver: NSObjectProtocol?
    @ObservationIgnored let spectrum = SpectrumTap()

    private(set) var isPlaying = false
    private(set) var isLoaded = false
    private(set) var duration: Double = 0
    private(set) var currentTime: Double = 0
    private(set) var rate: Float = 1
    private(set) var pitchSemitones: Int = 0
    private(set) var volume: Float = 0.9
    private(set) var loopEnabled = false
    private(set) var loopStart: Double?
    private(set) var loopEnd: Double?

    /// Stems currently loaded (empty when playing the original mix).
    private(set) var stemKinds: [StemKind] = []
    private(set) var mix: [StemKind: StemMixState] = [:]
    var usingStems: Bool { !stemKinds.isEmpty }

    init() {
        engine.attach(submix)
        engine.attach(timePitch)
        timePitch.overlap = 12
        submix.outputVolume = volume
        let tap = spectrum
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, _ in
            tap.process(buffer)
        }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                self?.handleConfigurationChange()
            }
    }

    deinit {
        timer?.invalidate()
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.stop()
    }

    // MARK: Loading

    /// Plays the original mix.
    func load(url: URL) throws {
        try load(tracks: [("mix", url)])
        stemKinds = []
        mix = [:]
    }

    /// Plays separated stems in sync. Keeps the position/loop when switching from the mix.
    func loadStems(_ stems: [(StemKind, URL)], keepPosition: Bool = true) throws {
        guard !stems.isEmpty else { return }
        let t = currentTime, wasPlaying = isPlaying
        let a = loopStart, b = loopEnd, looping = loopEnabled
        try load(tracks: stems.map { ($0.0.rawValue, $0.1) })
        stemKinds = stems.map(\.0)
        var newMix: [StemKind: StemMixState] = [:]
        for k in stemKinds { newMix[k] = mix[k] ?? StemMixState() }
        mix = newMix
        applyMix()
        if keepPosition {
            loopStart = a; loopEnd = b; loopEnabled = looping
            seek(to: t)
            if wasPlaying { play() }
        }
    }

    /// Switches back from stems to the original mix, keeping the position.
    func switchToMix(url: URL) throws {
        let t = currentTime, wasPlaying = isPlaying
        let a = loopStart, b = loopEnd, looping = loopEnabled
        try load(url: url)
        loopStart = a; loopEnd = b; loopEnabled = looping
        seek(to: t)
        if wasPlaying { play() }
    }

    private func load(tracks: [(String, URL)]) throws {
        stopInternal()
        engine.stop()
        for s in sources {
            engine.disconnectNodeOutput(s.player)
            engine.detach(s.player)
        }
        sources = []
        engine.disconnectNodeOutput(submix)
        engine.disconnectNodeOutput(timePitch)

        var newSources: [Source] = []
        for (key, url) in tracks {
            let f = try AVAudioFile(forReading: url)
            let p = AVAudioPlayerNode()
            engine.attach(p)
            engine.connect(p, to: submix, format: f.processingFormat)
            newSources.append(Source(key: key, player: p, file: f))
        }
        sources = newSources
        guard let first = sources.first else { return }

        let sr = first.sampleRate
        guard let busFormat = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2) else { return }
        engine.connect(submix, to: timePitch, format: busFormat)
        engine.connect(timePitch, to: engine.mainMixerNode, format: busFormat)

        duration = sources.map { Double($0.file.length) / $0.sampleRate }.max() ?? 0
        currentTime = 0
        segmentStartTime = 0
        isScheduled = false
        loopStart = nil; loopEnd = nil; loopEnabled = false
        engine.prepare()
        try engine.start()
        isLoaded = true
    }

    func unload() {
        stopInternal()
        engine.stop()
        for s in sources {
            engine.disconnectNodeOutput(s.player)
            engine.detach(s.player)
        }
        sources = []
        stemKinds = []
        mix = [:]
        isLoaded = false
        duration = 0
        currentTime = 0
        spectrum.reset()
    }

    // MARK: Stem mixer

    func toggleMute(_ k: StemKind) { mix[k, default: StemMixState()].muted.toggle(); applyMix() }

    func toggleSolo(_ k: StemKind) { mix[k, default: StemMixState()].solo.toggle(); applyMix() }

    func setStemVolume(_ k: StemKind, _ v: Float) {
        mix[k, default: StemMixState()].volume = min(max(v, 0), 1.5)
        applyMix()
    }

    /// Only this stem audible ("practise along with just the bass").
    func soloOnly(_ k: StemKind) {
        for key in stemKinds { mix[key, default: StemMixState()].solo = (key == k); mix[key]?.muted = false }
        applyMix()
    }

    /// Everything except this stem ("play along / karaoke").
    func muteOnly(_ k: StemKind) {
        for key in stemKinds { mix[key, default: StemMixState()].muted = (key == k); mix[key]?.solo = false }
        applyMix()
    }

    func resetMix() {
        for key in stemKinds { mix[key] = StemMixState() }
        applyMix()
    }

    func effectiveGain(_ k: StemKind) -> Float {
        guard let s = mix[k] else { return 1 }
        let anySolo = mix.values.contains { $0.solo }
        if anySolo { return s.solo ? s.volume : 0 }
        return s.muted ? 0 : s.volume
    }

    /// Current per-stem gains (for exporting exactly what you hear).
    var currentGains: [StemKind: Float] {
        var g: [StemKind: Float] = [:]
        for k in stemKinds { g[k] = effectiveGain(k) }
        return g
    }

    private func applyMix() {
        for s in sources {
            if let k = StemKind(rawValue: s.key) { s.player.volume = effectiveGain(k) } else { s.player.volume = 1 }
        }
    }

    // MARK: Transport

    func play() {
        guard !sources.isEmpty else { return }
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            NSLog("SlowFlowX: engine start failed: \(error)")
            return
        }
        if currentTime >= duration - 0.05 { currentTime = 0; isScheduled = false }
        if !isScheduled { schedule(from: currentTime) }
        startAllInSync()
        isPlaying = true
        startTimer()
    }

    func pause() {
        guard isPlaying else { return }
        updateTime()
        for s in sources { s.player.pause() }
        isPlaying = false
        stopTimer()
    }

    func togglePlayPause() { isPlaying ? pause() : play() }

    func seek(to time: Double) {
        guard !sources.isEmpty else { return }
        let t = max(0, min(time, duration))
        let wasPlaying = isPlaying
        schedule(from: t)
        currentTime = t
        if wasPlaying { startAllInSync() }
    }

    func skip(by seconds: Double) { seek(to: currentTime + seconds) }

    // MARK: Speed / pitch / volume

    func setRate(_ r: Float) {
        rate = min(max(r, 0.25), 2.0)
        timePitch.rate = rate
    }

    func setPitch(semitones: Int) {
        pitchSemitones = min(max(semitones, -12), 12)
        timePitch.pitch = Float(pitchSemitones * 100)
    }

    func setVolume(_ v: Float) {
        volume = min(max(v, 0), 1)
        submix.outputVolume = volume
    }

    // MARK: Looping

    func setLoopStartHere() {
        loopStart = currentTime
        if let b = loopEnd, b <= currentTime + 0.1 { loopEnd = nil; loopEnabled = false }
    }

    func setLoopEndHere() {
        let a = loopStart ?? 0
        guard currentTime > a + 0.1 else { return }
        loopStart = a
        loopEnd = currentTime
        loopEnabled = true
    }

    func setLoop(start: Double, end: Double) {
        guard end > start + 0.1 else { return }
        loopStart = start
        loopEnd = end
        loopEnabled = true
        if currentTime < start || currentTime > end { seek(to: start) }
    }

    func toggleLoop() {
        guard loopStart != nil, loopEnd != nil else { return }
        loopEnabled.toggle()
    }

    func clearLoop() {
        loopStart = nil; loopEnd = nil; loopEnabled = false
    }

    // MARK: Internals

    /// Starts every player at the same host time so stems stay sample-aligned.
    private func startAllInSync() {
        guard !sources.isEmpty else { return }
        if sources.count == 1 {
            sources[0].player.play()
            return
        }
        let start = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.06))
        for s in sources { s.player.play(at: start) }
    }

    private func schedule(from time: Double) {
        scheduleToken &+= 1
        let token = scheduleToken
        for s in sources { s.player.stop() }
        segmentStartTime = max(0, min(time, duration))
        var any = false
        for (i, s) in sources.enumerated() {
            let startFrame = AVAudioFramePosition(segmentStartTime * s.sampleRate)
            let remaining = s.file.length - startFrame
            guard remaining > 0 else { continue }
            any = true
            let isReference = i == 0
            s.player.scheduleSegment(s.file, startingFrame: startFrame, frameCount: AVAudioFrameCount(remaining),
                                     at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard isReference else { return }
                DispatchQueue.main.async {
                    guard let self, self.scheduleToken == token else { return }
                    self.playbackReachedEnd()
                }
            }
        }
        isScheduled = any
    }

    private func playbackReachedEnd() {
        if loopEnabled, let a = loopStart {
            seek(to: a)
            return
        }
        for s in sources { s.player.stop() }
        isScheduled = false
        isPlaying = false
        currentTime = duration
        stopTimer()
    }

    private func updateTime() {
        guard isPlaying, let ref = sources.first?.player,
              let nodeTime = ref.lastRenderTime, nodeTime.isSampleTimeValid,
              let pt = ref.playerTime(forNodeTime: nodeTime) else { return }
        let t = segmentStartTime + max(0, Double(pt.sampleTime)) / pt.sampleRate
        currentTime = max(0, min(t, duration))
        if loopEnabled, let a = loopStart, let b = loopEnd, b > a, currentTime >= b {
            seek(to: a)
        }
    }

    private func startTimer() {
        stopTimer()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.updateTime()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func stopInternal() {
        scheduleToken &+= 1
        for s in sources { s.player.stop() }
        isScheduled = false
        isPlaying = false
        stopTimer()
    }

    private func handleConfigurationChange() {
        let wasPlaying = isPlaying
        let t = currentTime
        stopInternal()
        currentTime = t
        if wasPlaying { play() }
    }
}
