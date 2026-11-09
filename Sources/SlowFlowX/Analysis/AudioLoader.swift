import AVFoundation

enum AudioLoader {
    /// Decodes any AVFoundation-readable file into a mono Float32 signal at `sampleRate`.
    static func loadMono(url: URL, sampleRate: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                            channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw NSError(domain: "SlowFlowX", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported audio format"])
        }
        converter.downmix = true

        let inCapacity: AVAudioFrameCount = 32_768
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: inCapacity) else { return [] }

        var output: [Float] = []
        output.reserveCapacity(Int(Double(file.length) * sampleRate / inFormat.sampleRate) + 4096)
        var reachedEnd = false

        while true {
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 32_768) else { break }
            var convError: NSError?
            let status = converter.convert(to: outBuffer, error: &convError) { _, outStatus in
                if reachedEnd { outStatus.pointee = .endOfStream; return nil }
                do {
                    try file.read(into: inBuffer, frameCount: inCapacity)
                } catch {
                    reachedEnd = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if inBuffer.frameLength == 0 {
                    reachedEnd = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return inBuffer
            }
            if let convError { throw convError }
            if outBuffer.frameLength > 0, let ch = outBuffer.floatChannelData {
                output.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(outBuffer.frameLength)))
            }
            if status == .endOfStream || status == .error { break }
            if reachedEnd && outBuffer.frameLength == 0 { break }
        }
        return output
    }
}
