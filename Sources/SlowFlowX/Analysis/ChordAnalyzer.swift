import Foundation
import Accelerate

enum AnalysisError: LocalizedError {
    case tooShort
    case fftSetup

    var errorDescription: String? {
        switch self {
        case .tooShort: return "The audio is too short to analyse."
        case .fftSetup: return "Could not initialise the FFT."
        }
    }
}

/// Chord recognition pipeline:
///   decode → STFT (Accelerate/vDSP) → chroma folding (Metal) → temporal smoothing
///   → chord-template cosine scoring (Metal) → HMM/Viterbi smoothing → segments.
/// Also estimates the musical key (Krumhansl–Schmuckler) and tempo (onset autocorrelation).
final class ChordAnalyzer {
    let sampleRate: Double = 22_050
    let fftSize = 8192
    let hop = 2048
    let minFreq: Double = 60
    let maxFreq: Double = 2100

    func analyze(url: URL, progress: @escaping (String, Double) -> Void) throws -> SongAnalysis {
        progress("Decoding audio", 0.02)
        let samples = try AudioLoader.loadMono(url: url, sampleRate: sampleRate)
        guard samples.count > fftSize * 2 else { throw AnalysisError.tooShort }
        let duration = Double(samples.count) / sampleRate

        progress("Rendering waveform", 0.08)
        let peaks = Self.peaks(samples, count: 2400)

        progress("Estimating tempo", 0.10)
        let bpm = Self.estimateTempo(samples, sampleRate: sampleRate)

        progress("Computing spectrum", 0.14)
        let spec = try spectrogram(samples) { p in progress("Computing spectrum", 0.14 + 0.46 * p) }
        let frames = spec.frames, bins = spec.bins

        // Map every FFT bin to a pitch class, weighted by how close it is to the semitone centre.
        var binPC = [Int32](repeating: -1, count: bins)
        var binW = [Float](repeating: 0, count: bins)
        for i in 0..<bins {
            let f = Double(i + spec.minBin) * sampleRate / Double(fftSize)
            guard f > 0 else { continue }
            let midi = 69 + 12 * log2(f / 440)
            let nearest = midi.rounded()
            let dev = abs(midi - nearest)
            binPC[i] = Int32(((Int(nearest) % 12) + 12) % 12)
            binW[i] = Float(cos(dev * .pi))      // 1 at the centre, 0 halfway between semitones
        }

        progress("Building chromagram on GPU", 0.62)
        var usedMetal = true
        var chroma: [Float]
        if let gpu = MetalCompute.foldChroma(mags: spec.mags, frames: frames, bins: bins, binPC: binPC, binWeight: binW) {
            chroma = gpu
        } else {
            usedMetal = false
            chroma = Self.cpuFold(mags: spec.mags, frames: frames, bins: bins, binPC: binPC, binW: binW)
        }

        progress("Smoothing harmony", 0.70)
        chroma = Self.smooth(chroma, frames: frames, radius: 4)

        // Frame energy (for "no chord" detection) and contrast enhancement.
        var energy = [Float](repeating: 0, count: frames)
        var keyProfile = [Float](repeating: 0, count: 12)
        for f in 0..<frames {
            var mn = Float.greatestFiniteMagnitude, mx: Float = 0, sum: Float = 0
            for p in 0..<12 {
                let v = chroma[f * 12 + p]
                mn = min(mn, v); mx = max(mx, v); sum += v
            }
            energy[f] = sum
            for p in 0..<12 {
                let v = chroma[f * 12 + p] - mn * 0.85
                chroma[f * 12 + p] = v
                if mx > 0 { keyProfile[p] += v / mx }
            }
        }

        progress("Matching chord templates on GPU", 0.76)
        let (templates, qualityOf, rootOf) = Self.chordTemplates()
        let tCount = qualityOf.count
        let scores: [Float]
        if let gpu = MetalCompute.scoreChords(chroma: chroma, frames: frames, templates: templates, templateCount: tCount) {
            scores = gpu
        } else {
            usedMetal = false
            scores = Self.cpuScore(chroma: chroma, frames: frames, templates: templates, templateCount: tCount)
        }

        progress("Decoding chord sequence", 0.86)
        let medianEnergy = Self.median(energy)
        let path = Self.viterbi(scores: scores, frames: frames, templateCount: tCount,
                                qualityOf: qualityOf, energy: energy, medianEnergy: medianEnergy)

        progress("Building chord chart", 0.94)
        let frameDur = Double(hop) / sampleRate
        let offset = Double(fftSize) / 2 / sampleRate
        var segments: [ChordSegment] = []
        var runStart = 0
        for f in 1...frames {
            if f == frames || path[f] != path[runStart] {
                let s = path[runStart]
                var conf: Float = 0
                if s < tCount {
                    for k in runStart..<f { conf += scores[k * tCount + s] }
                    conf /= Float(f - runStart)
                }
                let start = runStart == 0 ? 0 : Double(runStart) * frameDur + offset
                let end = f == frames ? duration : Double(f) * frameDur + offset
                segments.append(ChordSegment(
                    start: start, end: end,
                    root: s < tCount ? rootOf[s] : -1,
                    quality: s < tCount ? qualityOf[s] : .none,
                    confidence: conf))
                runStart = f
            }
        }
        segments = Self.cleanUp(segments, minDuration: 0.45)

        let key = Self.estimateKey(keyProfile)
        progress("Done", 1)
        return SongAnalysis(chords: segments, keyRoot: key.root, keyIsMinor: key.minor,
                            bpm: bpm, peaks: peaks, analyzedAt: Date(), usedMetal: usedMetal)
    }

    // MARK: - STFT

    private struct Spectrogram {
        let mags: [Float]
        let frames: Int
        let bins: Int
        let minBin: Int
    }

    private func spectrogram(_ x: [Float], progress: (Double) -> Void) throws -> Spectrogram {
        let n = fftSize, half = n / 2
        let log2n = vDSP_Length(log2(Double(n)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { throw AnalysisError.fftSetup }
        defer { vDSP_destroy_fftsetup(setup) }

        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        let minBin = max(1, Int(minFreq * Double(n) / sampleRate))
        let maxBin = min(half - 1, Int(maxFreq * Double(n) / sampleRate))
        let bins = maxBin - minBin + 1
        let frames = max(1, (x.count - n) / hop + 1)

        var mags = [Float](repeating: 0, count: frames * bins)
        var windowed = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: half)
        var im = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)

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
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        power.withUnsafeMutableBufferPointer { pp in
                            vDSP_zvmags(&split, 1, pp.baseAddress!, 1, vDSP_Length(half))
                        }
                    }
                }
                let rowBase = f * bins
                for b in 0..<bins { mags[rowBase + b] = sqrt(power[b + minBin]) }
                if f % 256 == 0 { progress(Double(f) / Double(frames)) }
            }
        }

        // Normalise so the GPU log-compression behaves the same regardless of loudness.
        let peak = vDSP.maximum(mags)
        if peak > 0 { mags = vDSP.multiply(1 / peak, mags) }
        return Spectrogram(mags: mags, frames: frames, bins: bins, minBin: minBin)
    }

    // MARK: - Templates

    /// Harmonic-aware chord templates. Each chord tone also contributes energy at its
    /// 3rd harmonic (+7 semitones) and 5th harmonic (+4 semitones), as real instruments do.
    private static func chordTemplates() -> ([Float], [ChordQuality], [Int]) {
        var templates: [Float] = []
        var qualities: [ChordQuality] = []
        var roots: [Int] = []
        for q in ChordQuality.detectable {
            for root in 0..<12 {
                var t = [Float](repeating: 0, count: 12)
                for (i, interval) in q.intervals.enumerated() {
                    let pc = (root + interval) % 12
                    let w: Float = (i == 0) ? 1.0 : (interval == 10 ? 0.75 : 0.9)
                    t[pc] += w
                    t[(pc + 7) % 12] += w * 0.33
                    t[(pc + 4) % 12] += w * 0.2
                }
                let norm = sqrt(t.reduce(0) { $0 + $1 * $1 })
                templates += t.map { $0 / norm }
                qualities.append(q)
                roots.append(root)
            }
        }
        return (templates, qualities, roots)
    }

    // MARK: - Viterbi

    private static func viterbi(scores: [Float], frames: Int, templateCount: Int, qualityOf: [ChordQuality],
                                energy: [Float], medianEnergy: Float) -> [Int] {
        let S = templateCount + 1                    // last state = "no chord"
        let noChord = templateCount
        let beta: Float = 18
        let logStay: Float = log(0.94)
        let logSwitch: Float = log(0.06 / Float(S - 1))
        let factor: [Float] = qualityOf.map { ($0 == .dominant7 || $0 == .minor7) ? 0.965 : 1.0 }

        func emission(_ t: Int, _ s: Int) -> Float {
            if s == noChord {
                let rel = medianEnergy > 0 ? energy[t] / medianEnergy : 1
                return beta * (rel < 0.12 ? 0.98 : 0.30)
            }
            return beta * scores[t * templateCount + s] * factor[s]
        }

        var delta = [Float](repeating: 0, count: S)
        var next = [Float](repeating: 0, count: S)
        var psi = [UInt8](repeating: 0, count: frames * S)
        for s in 0..<S { delta[s] = emission(0, s) }

        for t in 1..<max(frames, 1) {
            var maxV = -Float.greatestFiniteMagnitude, maxI = 0
            for s in 0..<S where delta[s] > maxV { maxV = delta[s]; maxI = s }
            let switchV = maxV + logSwitch
            for s in 0..<S {
                let stay = delta[s] + logStay
                if stay >= switchV {
                    next[s] = stay + emission(t, s) - maxV
                    psi[t * S + s] = UInt8(s)
                } else {
                    next[s] = switchV + emission(t, s) - maxV
                    psi[t * S + s] = UInt8(maxI)
                }
            }
            swap(&delta, &next)
        }

        var path = [Int](repeating: 0, count: frames)
        var best = 0
        for s in 1..<S where delta[s] > delta[best] { best = s }
        path[frames - 1] = best
        if frames > 1 {
            for t in stride(from: frames - 1, to: 0, by: -1) {
                path[t - 1] = Int(psi[t * S + path[t]])
            }
        }
        return path
    }

    // MARK: - Post-processing

    private static func cleanUp(_ input: [ChordSegment], minDuration: Double) -> [ChordSegment] {
        var out: [ChordSegment] = []
        for seg in input {
            if seg.duration < minDuration, var last = out.last {
                last.end = seg.end
                out[out.count - 1] = last
            } else {
                out.append(seg)
            }
        }
        // merge neighbours that ended up identical
        var merged: [ChordSegment] = []
        for seg in out {
            if var last = merged.last, last.root == seg.root, last.quality == seg.quality {
                let total = last.duration + seg.duration
                last.confidence = total > 0
                    ? (last.confidence * Float(last.duration) + seg.confidence * Float(seg.duration)) / Float(total)
                    : last.confidence
                last.end = seg.end
                merged[merged.count - 1] = last
            } else {
                merged.append(seg)
            }
        }
        return merged
    }

    // MARK: - Key

    private static func estimateKey(_ profile: [Float]) -> (root: Int, minor: Bool) {
        let major: [Float] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
        let minor: [Float] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
        func corr(_ a: [Float], _ b: [Float]) -> Float {
            let ma = a.reduce(0, +) / 12, mb = b.reduce(0, +) / 12
            var num: Float = 0, da: Float = 0, db: Float = 0
            for i in 0..<12 { num += (a[i] - ma) * (b[i] - mb); da += (a[i] - ma) * (a[i] - ma); db += (b[i] - mb) * (b[i] - mb) }
            return da > 0 && db > 0 ? num / sqrt(da * db) : 0
        }
        var best: (Int, Bool, Float) = (0, false, -2)
        for root in 0..<12 {
            let rotated = (0..<12).map { profile[($0 + root) % 12] }
            let cMaj = corr(rotated, major), cMin = corr(rotated, minor)
            if cMaj > best.2 { best = (root, false, cMaj) }
            if cMin > best.2 { best = (root, true, cMin) }
        }
        return (best.0, best.1)
    }

    // MARK: - Tempo

    static func estimateTempo(_ x: [Float], sampleRate: Double) -> Double {
        let det = OnsetDetector.detect(x, sampleRate: sampleRate, lowHz: 40, highHz: 8000)
        return tempo(fromFlux: det.flux, frameRate: det.frameRate)
    }

    /// Tempo from a spectral-flux onset envelope: autocorrelation scored over several metrical
    /// levels (beat, 2 beats, half beat, bar) so the estimate locks to the beat rather than
    /// the 8th-note or half-time pulse, with a mild prior around 120 BPM.
    static func tempo(fromFlux flux: [Float], frameRate fps: Double) -> Double {
        let n = flux.count
        guard n > 600 else { return 0 }
        let mean = flux.reduce(0, +) / Float(n)
        let f = flux.map { max(0, $0 - mean) }
        let maxLag = min(n - 1, Int(fps * 60 / 40 * 4) + 2)   // up to 4 beats at 40 BPM
        var ac = [Float](repeating: 0, count: maxLag + 1)
        f.withUnsafeBufferPointer { p in
            guard let base = p.baseAddress else { return }
            for lag in 1...maxLag {
                var s: Float = 0
                vDSP_dotpr(base, 1, base + lag, 1, &s, vDSP_Length(n - lag))
                ac[lag] = s / Float(n - lag)
            }
        }
        func acAt(_ lag: Double) -> Float {
            guard lag >= 1, lag < Double(maxLag) else { return 0 }
            let i = Int(lag), fr = Float(lag - Double(i))
            return ac[i] * (1 - fr) + ac[i + 1] * fr
        }
        var best = 0.0, bestScore: Float = -.greatestFiniteMagnitude
        var bpm = 60.0
        while bpm <= 200 {
            let lag = fps * 60 / bpm
            // balanced over metrical levels so neither half- nor double-time is favoured by default
            let score = acAt(lag) + 0.5 * acAt(2 * lag) + 0.25 * acAt(4 * lag) + 0.25 * acAt(lag / 2)
            let prior = Float(exp(-0.5 * pow(log2(bpm / 120) / 0.7, 2)))
            let v = score * prior
            if v > bestScore { bestScore = v; best = bpm }
            bpm += 0.5
        }
        return best
    }

    // MARK: - Helpers

    static func peaks(_ x: [Float], count: Int) -> [Float] {
        guard !x.isEmpty, count > 0 else { return [] }
        let bucket = max(1, x.count / count)
        let n = min(count, x.count / bucket)
        var out = [Float](repeating: 0, count: n)
        x.withUnsafeBufferPointer { p in
            guard let base = p.baseAddress else { return }
            for i in 0..<n {
                var m: Float = 0
                vDSP_maxmgv(base + i * bucket, 1, &m, vDSP_Length(bucket))
                out[i] = m
            }
        }
        let sorted = out.sorted()
        let ref = max(sorted[Int(Double(sorted.count - 1) * 0.985)], 1e-6)
        return out.map { min(1, pow($0 / ref, 0.85)) }
    }

    private static func smooth(_ chroma: [Float], frames: Int, radius: Int) -> [Float] {
        var out = [Float](repeating: 0, count: chroma.count)
        for f in 0..<frames {
            let lo = max(0, f - radius), hi = min(frames - 1, f + radius)
            let inv = 1 / Float(hi - lo + 1)
            for p in 0..<12 {
                var s: Float = 0
                for k in lo...hi { s += chroma[k * 12 + p] }
                out[f * 12 + p] = s * inv
            }
        }
        return out
    }

    private static func median(_ v: [Float]) -> Float {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s[s.count / 2]
    }

    private static func cpuFold(mags: [Float], frames: Int, bins: Int, binPC: [Int32], binW: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: frames * 12)
        for f in 0..<frames {
            for k in 0..<bins where binPC[k] >= 0 {
                out[f * 12 + Int(binPC[k])] += log(1 + 1000 * mags[f * bins + k]) * binW[k]
            }
        }
        return out
    }

    private static func cpuScore(chroma: [Float], frames: Int, templates: [Float], templateCount: Int) -> [Float] {
        var out = [Float](repeating: 0, count: frames * templateCount)
        for f in 0..<frames {
            var norm: Float = 0
            for i in 0..<12 { norm += chroma[f * 12 + i] * chroma[f * 12 + i] }
            norm = sqrt(norm)
            guard norm > 1e-9 else { continue }
            for t in 0..<templateCount {
                var d: Float = 0
                for i in 0..<12 { d += chroma[f * 12 + i] * templates[t * 12 + i] }
                out[f * templateCount + t] = d / norm
            }
        }
        return out
    }
}
