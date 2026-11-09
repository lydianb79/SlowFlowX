import Foundation
import Accelerate

/// Note-attack (onset) detection with band-limited spectral flux, plus beat-phase estimation.
enum OnsetDetector {
    struct Onset {
        let time: Double
        let strength: Float     // 0...1 (normalised flux peak)
    }

    struct Result {
        let onsets: [Onset]
        let flux: [Float]       // normalised onset envelope
        let frameRate: Double   // flux frames per second
        let timeOffset: Double  // time of flux frame 0
    }

    static func detect(_ x: [Float], sampleRate: Double, lowHz: Double, highHz: Double,
                       sensitivity: Float = 1.0) -> Result {
        let n = 2048, half = n / 2, hop = 256
        let frames = max(0, (x.count - n) / hop + 1)
        let frameRate = sampleRate / Double(hop)
        let timeOffset = Double(n) / 2 / sampleRate - Double(hop) / 2 / sampleRate
        guard frames > 8,
              let setup = vDSP_create_fftsetup(11, FFTRadix(kFFTRadix2)) else {
            return Result(onsets: [], flux: [], frameRate: frameRate, timeOffset: timeOffset)
        }
        defer { vDSP_destroy_fftsetup(setup) }

        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        let binHz = sampleRate / Double(n)
        let b0 = max(1, Int(lowHz / binHz)), b1 = min(half - 1, Int(highHz / binHz))
        let bandBins = max(1, b1 - b0 + 1)

        var windowed = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: half)
        var im = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)
        var prev = [Float](repeating: 0, count: bandBins)
        var cur = [Float](repeating: 0, count: bandBins)
        var flux = [Float](repeating: 0, count: frames)

        x.withUnsafeBufferPointer { xp in
            guard let base = xp.baseAddress else { return }
            for f in 0..<frames {
                vDSP_vmul(base + f * hop, 1, window, 1, &windowed, 1, vDSP_Length(n))
                re.withUnsafeMutableBufferPointer { rp in
                    im.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        windowed.withUnsafeBufferPointer { wp in
                            wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                                vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                            }
                        }
                        vDSP_fft_zrip(setup, &split, 1, 11, FFTDirection(FFT_FORWARD))
                        power.withUnsafeMutableBufferPointer { pp in
                            vDSP_zvmags(&split, 1, pp.baseAddress!, 1, vDSP_Length(half))
                        }
                    }
                }
                var sum: Float = 0
                for k in 0..<bandBins {
                    let v = log(1 + 100 * sqrt(power[b0 + k]) / Float(n))
                    cur[k] = v
                    if f > 0 { sum += max(0, v - prev[k]) }
                }
                flux[f] = sum
                swap(&prev, &cur)
            }
        }

        // normalise
        let sorted = flux.sorted()
        let ref = max(sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.99))], 1e-6)
        flux = flux.map { min(1, $0 / ref) }

        // adaptive threshold + peak picking
        var onsets: [Onset] = []
        let w = 10, localMax = 3
        let minGap = Int(0.07 * frameRate)
        var last = -minGap
        for t in 1..<(frames - 1) {
            let v = flux[t]
            let lo = max(0, t - w), hi = min(frames - 1, t + w)
            var mean: Float = 0
            for k in lo...hi { mean += flux[k] }
            mean /= Float(hi - lo + 1)
            let threshold = (mean * 1.35 + 0.07) / sensitivity
            guard v > threshold, t - last >= minGap else { continue }
            var isPeak = true
            for k in max(0, t - localMax)...min(frames - 1, t + localMax) where k != t && flux[k] > v { isPeak = false; break }
            guard isPeak else { continue }
            onsets.append(Onset(time: Double(t) / frameRate + timeOffset, strength: v))
            last = t
        }
        return Result(onsets: onsets, flux: flux, frameRate: frameRate, timeOffset: timeOffset)
    }

    /// Time (seconds, 0 ≤ offset < beat) of the first beat, found by aligning a beat comb to the onset envelope.
    static func beatOffset(_ r: Result, bpm: Double) -> Double {
        guard bpm > 30, !r.flux.isEmpty else { return 0 }
        let period = r.frameRate * 60 / bpm
        let steps = max(1, Int(period.rounded(.down)))
        var bestPhase = 0, bestScore: Float = -1
        for phase in 0..<steps {
            var score: Float = 0
            var pos = Double(phase)
            while Int(pos) < r.flux.count {
                score += r.flux[Int(pos)]
                // off-beats count a little so 8th-note grooves still lock to the beat
                let off = Int(pos + period / 2)
                if off < r.flux.count { score += 0.25 * r.flux[off] }
                pos += period
            }
            if score > bestScore { bestScore = score; bestPhase = phase }
        }
        let beat = 60 / bpm
        var offset = Double(bestPhase) / r.frameRate + r.timeOffset
        offset = offset.truncatingRemainder(dividingBy: beat)
        if offset < 0 { offset += beat }
        return offset
    }
}
