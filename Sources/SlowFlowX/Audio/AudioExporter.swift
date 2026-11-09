import AVFoundation

enum ExportError: LocalizedError {
    case emptyRange
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .emptyRange: return "The selected range is empty."
        case .renderFailed: return "The audio engine failed while rendering the export."
        }
    }
}

/// Renders (a section of) a song — the original file or any mix of stems — to a WAV file,
/// optionally with the current speed and transpose applied, using AVAudioEngine's offline
/// manual-rendering mode (faster than real time).
enum AudioExporter {
    struct Options: Sendable {
        var start: Double            // seconds (source time)
        var end: Double              // seconds (source time)
        var rate: Float              // 1 = original speed
        var pitchSemitones: Int
        var bitDepth: Int            // 16 or 24
    }

    /// Convenience for a single source at unity gain.
    static func exportWAV(source: URL, destination: URL, options: Options,
                          progress: @escaping (Double) -> Void) throws {
        try exportWAV(sources: [(source, 1)], destination: destination, options: options, progress: progress)
    }

    /// Mixes all `sources` (file, gain) — e.g. selected stems — into one WAV.
    static func exportWAV(sources: [(URL, Float)], destination: URL, options: Options,
                          progress: @escaping (Double) -> Void) throws {
        guard !sources.isEmpty else { throw ExportError.emptyRange }
        let files = try sources.map { try AVAudioFile(forReading: $0.0) }
        let sr = files[0].processingFormat.sampleRate
        guard let busFormat = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2) else { throw ExportError.renderFailed }

        let longest = files.map { Double($0.length) / $0.processingFormat.sampleRate }.max() ?? 0
        let startT = max(0, options.start)
        let endT = min(options.end, longest)
        guard endT > startT else { throw ExportError.emptyRange }

        let rate = min(max(options.rate, 0.25), 2)
        let processing = abs(rate - 1) > 0.0005 || options.pitchSemitones != 0

        let engine = AVAudioEngine()
        let submix = AVAudioMixerNode()
        let timePitch = AVAudioUnitTimePitch()
        timePitch.rate = processing ? rate : 1
        timePitch.pitch = Float(options.pitchSemitones * 100)
        timePitch.overlap = 12
        timePitch.bypass = !processing
        engine.attach(submix)
        engine.attach(timePitch)

        var players: [AVAudioPlayerNode] = []
        for (i, f) in files.enumerated() {
            let p = AVAudioPlayerNode()
            engine.attach(p)
            engine.connect(p, to: submix, format: f.processingFormat)
            p.volume = sources[i].1
            players.append(p)
        }
        engine.connect(submix, to: timePitch, format: busFormat)
        engine.connect(timePitch, to: engine.mainMixerNode, format: busFormat)

        let maxFrames: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: busFormat, maximumFrameCount: maxFrames)
        try engine.start()
        defer {
            players.forEach { $0.stop() }
            engine.stop()
        }

        for (p, f) in zip(players, files) {
            let fsr = f.processingFormat.sampleRate
            let s = AVAudioFramePosition(startT * fsr)
            let e = min(f.length, AVAudioFramePosition(endT * fsr))
            if e > s { p.scheduleSegment(f, startingFrame: s, frameCount: AVAudioFrameCount(e - s), at: nil) }
            p.play()
        }

        let output = try AudioFileTools.makeWAVWriter(url: destination, sampleRate: sr, channels: 2,
                                                      bitDepth: options.bitDepth == 16 ? 16 : 24)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                            frameCapacity: engine.manualRenderingMaximumFrameCount) else {
            throw ExportError.renderFailed
        }

        let sourceFrames = (endT - startT) * sr
        let total = AVAudioFramePosition(sourceFrames / Double(processing ? rate : 1))
        var written: AVAudioFramePosition = 0
        var stalls = 0
        var iteration = 0

        while written < total {
            if Task.isCancelled { throw CancellationError() }
            let n = AVAudioFrameCount(min(AVAudioFramePosition(buffer.frameCapacity), total - written))
            let status = try engine.renderOffline(n, to: buffer)
            switch status {
            case .success:
                try output.write(from: buffer)
                written += AVAudioFramePosition(buffer.frameLength)
                stalls = 0
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                stalls += 1
                if stalls > 1000 { throw ExportError.renderFailed }
            case .error:
                throw ExportError.renderFailed
            @unknown default:
                throw ExportError.renderFailed
            }
            iteration += 1
            if iteration % 32 == 0 { progress(Double(written) / Double(total)) }
        }
        progress(1)
    }

    static func suggestedFileName(title: String, rate: Float, pitch: Int, isSection: Bool) -> String {
        var name = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if abs(rate - 1) > 0.0005 { name += " (\(Int((rate * 100).rounded()))%)" }
        if pitch != 0 { name += String(format: " (%+d st)", pitch) }
        if isSection { name += " [section]" }
        return name + ".wav"
    }
}
