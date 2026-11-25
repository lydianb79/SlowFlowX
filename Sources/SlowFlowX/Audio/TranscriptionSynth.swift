import Foundation
import AVFoundation

/// Renders a transcribed part to audio so it can be played next to the real recording:
/// plucked strings (Karplus–Strong) for guitar and bass, a soft flute-like tone for vocals.
/// The rendering covers the whole song at original pitch and tempo; speed and transpose are then
/// applied by the playback engine exactly as for the song, so the two always line up.
enum TranscriptionSynth {
    static let sampleRate = 44_100.0

    static func render(_ track: MelodyTrack, duration: Double, to url: URL) throws {
        let sr = sampleRate
        let total = Int(duration * sr) + 1
        var out = [Float](repeating: 0, count: total)

        let notes = track.usesStrums ? [] : track.notes
        let pluck = track.source != .vocal
        let isBass = track.source == .bass
        var rng = SystemRandomNumberGenerator()

        for n in notes {
            let start = Int(n.start * sr)
            guard start < total else { continue }
            let f = 440 * pow(2, Double(n.midi - 69) / 12)
            let noteLen = max(0.06, n.end - n.start)
            let release = 0.04
            let length = min(total - start, Int((noteLen + release) * sr))
            guard length > 8 else { continue }
            let gain = Float(0.18 + 0.22 * min(1, max(0, n.confidence))) * (isBass ? 1.3 : 1)
            let relStart = Int(noteLen * sr)
            let relLen = Double(release * sr)

            if pluck {
                // Karplus–Strong: a burst of noise circulating in a delay line one period long,
                // read with a fractional delay so the pitch is in tune.
                let period = sr / f
                let D = period - 0.5                         // the averaging filter adds half a sample
                let M = Int(D) + 4
                var buf = [Float](repeating: 0, count: M)
                // Decay so the note rings for its length but doesn't buzz forever.
                let ringSeconds = min(2.5, max(0.25, noteLen * 1.5))
                let decay = Float(pow(0.001, 1 / (ringSeconds * f)))
                var w = 0
                var lastY: Float = 0, noiseState: Float = 0
                for i in 0..<length {
                    var y: Float
                    if Double(i) < period {
                        let r = Float(Double(rng.next() % 20_000) / 10_000 - 1)
                        noiseState = isBass ? 0.6 * noiseState + 0.4 * r : 0.3 * noiseState + 0.7 * r
                        y = noiseState
                    } else {
                        let rp = Double(w) - D
                        let base = rp.rounded(.down)
                        let fr = Float(rp - base)
                        let i0 = ((Int(base) % M) + M) % M, i1 = (i0 + 1) % M
                        y = buf[i0] + (buf[i1] - buf[i0]) * fr
                    }
                    buf[w] = decay * 0.5 * (y + lastY)
                    lastY = y
                    w = (w + 1) % M
                    if i >= relStart { y *= Float(max(0, 1 - Double(i - relStart) / relLen)) }
                    out[start + i] += y * gain
                }
            } else {
                // Voice: sine + a little 2nd/3rd harmonic, soft attack.
                let w = 2 * Double.pi * f / sr
                let attack = 0.02 * sr
                for i in 0..<length {
                    let ph = w * Double(i)
                    var y = Float(sin(ph) + 0.25 * sin(2 * ph) + 0.1 * sin(3 * ph)) * 0.75
                    let env = min(1, Double(i) / attack)
                    y *= Float(env)
                    if i >= relStart { y *= Float(max(0, 1 - Double(i - relStart) / relLen)) }
                    out[start + i] += y * gain
                }
            }
        }

        // Normalise, with soft limiting for dense chords.
        let peak = out.reduce(0) { max($0, abs($1)) }
        if peak > 0 {
            let g = 0.8 / max(peak, 0.4)
            for i in out.indices { out[i] = tanh(out[i] * g * 1.2) / 1.2 }
        }

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = AVAudioFrameCount(total)
        out.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: total)
        }
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}
