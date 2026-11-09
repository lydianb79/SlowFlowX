import AVFoundation
import Observation

/// Audio playback with independent speed and pitch control.
/// AVAudioUnitTimePitch performs a phase-vocoder time-stretch, so changing `rate`
/// slows the music down without changing its pitch (and `pitch` transposes without changing tempo).
@Observable
final class PlaybackEngine {
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let player = AVAudioPlayerNode()
    @ObservationIgnored private let timePitch = AVAudioUnitTimePitch()
    @ObservationIgnored private var file: AVAudioFile?
    @ObservationIgnored private var sampleRate: Double = 44_100
    @ObservationIgnored private var lengthFrames: AVAudioFramePosition = 0
    @ObservationIgnored private var segmentStartFrame: AVAudioFramePosition = 0
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

    init() {
        engine.attach(player)
        engine.attach(timePitch)
        timePitch.overlap = 12          // a bit smoother than the default 8
        player.volume = volume
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

    func load(url: URL) throws {
        stopInternal()
        engine.stop()
        let f = try AVAudioFile(forReading: url)
        file = f
        sampleRate = f.processingFormat.sampleRate
        lengthFrames = f.length
        duration = Double(f.length) / sampleRate
        currentTime = 0
        segmentStartFrame = 0
        isScheduled = false
        loopStart = nil; loopEnd = nil; loopEnabled = false

        engine.disconnectNodeOutput(player)
        engine.disconnectNodeOutput(timePitch)
        engine.connect(player, to: timePitch, format: f.processingFormat)
        engine.connect(timePitch, to: engine.mainMixerNode, format: f.processingFormat)
        engine.prepare()
        try engine.start()
        isLoaded = true
    }

    func unload() {
        stopInternal()
        engine.stop()
        file = nil
        isLoaded = false
        duration = 0
        currentTime = 0
        spectrum.reset()
    }

    // MARK: Transport

    func play() {
        guard file != nil else { return }
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            NSLog("SlowFlowX: engine start failed: \(error)")
            return
        }
        if currentTime >= duration - 0.05 { currentTime = 0; isScheduled = false }
        if !isScheduled { schedule(from: frame(for: currentTime)) }
        player.play()
        isPlaying = true
        startTimer()
    }

    func pause() {
        guard isPlaying else { return }
        updateTime()
        player.pause()
        isPlaying = false
        stopTimer()
    }

    func togglePlayPause() { isPlaying ? pause() : play() }

    func seek(to time: Double) {
        guard file != nil else { return }
        let t = max(0, min(time, duration))
        let wasPlaying = isPlaying
        schedule(from: frame(for: t))
        currentTime = t
        if wasPlaying { player.play() }
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
        player.volume = volume
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

    private func frame(for time: Double) -> AVAudioFramePosition {
        AVAudioFramePosition(time * sampleRate)
    }

    private func schedule(from start: AVAudioFramePosition) {
        guard let file else { return }
        scheduleToken &+= 1
        let token = scheduleToken
        player.stop()
        let s = max(0, min(start, lengthFrames))
        segmentStartFrame = s
        let remaining = lengthFrames - s
        guard remaining > 0 else { isScheduled = false; return }
        player.scheduleSegment(file, startingFrame: s, frameCount: AVAudioFrameCount(remaining), at: nil,
                               completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.scheduleToken == token else { return }
                self.playbackReachedEnd()
            }
        }
        isScheduled = true
    }

    private func playbackReachedEnd() {
        if loopEnabled, let a = loopStart {
            seek(to: a)
            return
        }
        player.stop()
        isScheduled = false
        isPlaying = false
        currentTime = duration
        stopTimer()
    }

    private func updateTime() {
        guard isPlaying,
              let nodeTime = player.lastRenderTime, nodeTime.isSampleTimeValid,
              let pt = player.playerTime(forNodeTime: nodeTime) else { return }
        let t = Double(segmentStartFrame) / sampleRate + Double(pt.sampleTime) / pt.sampleRate
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
        player.stop()
        isScheduled = false
        isPlaying = false
        stopTimer()
    }

    private func handleConfigurationChange() {
        // Output device changed (e.g. headphones unplugged): the engine stopped itself.
        let wasPlaying = isPlaying
        let t = currentTime
        stopInternal()
        currentTime = t
        if wasPlaying { play() }
    }
}
