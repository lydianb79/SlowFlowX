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

/// Renders (a section of) a song to a WAV file, optionally with the current speed and
/// transpose applied, using AVAudioEngine's offline manual-rendering mode (faster than real time).
enum AudioExporter {
    struct Options: Sendable {
        var start: Double            // seconds (source time)
        var end: Double              // seconds (source time)
        var rate: Float              // 1 = original speed
        var pitchSemitones: Int
        var bitDepth: Int            // 16 or 24
    }

    static func exportWAV(source: URL, destination: URL, options: Options,
                          progress: @escaping (Double) -> Void) throws {
        let file = try AVAudioFile(forReading: source)
        let format = file.processingFormat
        let sr = format.sampleRate

        let startFrame = AVAudioFramePosition(max(0, options.start) * sr)
        let endFrame = min(file.length, AVAudioFramePosition(options.end * sr))
        guard endFrame > startFrame else { throw ExportError.emptyRange }
        let sourceFrames = AVAudioFrameCount(endFrame - startFrame)

        let rate = min(max(options.rate, 0.25), 2)
        let processing = abs(rate - 1) > 0.0005 || options.pitchSemitones != 0

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        timePitch.rate = processing ? rate : 1
        timePitch.pitch = Float(options.pitchSemitones * 100)
        timePitch.overlap = 12
        timePitch.bypass = !processing

        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)

        let maxFrames: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: maxFrames)
        try engine.start()
        defer {
            player.stop()
            engine.stop()
        }

        player.scheduleSegment(file, startingFrame: startFrame, frameCount: sourceFrames, at: nil)
        player.play()

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sr,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVLinearPCMBitDepthKey: options.bitDepth == 16 ? 16 : 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        try? FileManager.default.removeItem(at: destination)
        let output = try AVAudioFile(forWriting: destination, settings: settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                            frameCapacity: engine.manualRenderingMaximumFrameCount) else {
            throw ExportError.renderFailed
        }

        let total = AVAudioFramePosition(Double(sourceFrames) / Double(processing ? rate : 1))
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
