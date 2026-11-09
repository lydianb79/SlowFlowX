import Foundation
import Accelerate

/// Predominant-melody transcription:
///   STFT (vDSP) → harmonic-summation pitch salience (Metal) → Viterbi pitch tracking with
///   voicing detection → semitone note segmentation.
/// Works on full mixes; accuracy is best when the chosen part (voice, lead, bass) is prominent.
final class MelodyAnalyzer {
    let sampleRate: Double = 22_050
    let fftSize = 4096
    let hop = 256
    let centsPerBin: Double = 20
    let maxFreq: Double = 4200
    let chunkFrames = 2048

    /// - Parameters:
    ///   - url: audio to transcribe (ideally the isolated stem)
    ///   - rhythmURL: audio used for the beat grid — drums stem or full mix. Isolated vocals/guitar
    ///     make poor tempo references, so the beat is taken from here when given.
    ///   - tempoHint: tempo of the whole song (from the chord analysis), used when available
    func analyze(url: URL, source: MelodySource, rhythmURL: URL? = nil, tempoHint: Double? = nil,
                 progress: @escaping (String, Double) -> Void) throws -> MelodyTrack {
        progress("Decoding audio", 0.02)
        let x = try AudioLoader.loadMono(url: url, sampleRate: sampleRate)
        guard x.count > fftSize * 2 else { throw AnalysisError.tooShort }

        if source.isRhythm { return analyzeRhythm(x, rhythmURL: rhythmURL, tempoHint: tempoHint, progress: progress) }

        // Candidate fundamentals on a 20-cent grid.
        let range = source.frequencyRange
        let nCand = Int((1200 * log2(range.upperBound / range.lowerBound) / centsPerBin).rounded(.down)) + 1
        let candidates: [Float] = (0..<nCand).map { Float(range.lowerBound * pow(2, Double($0) * centsPerBin / 1200)) }

        let n = fftSize, half = n / 2
        let binHz = sampleRate / Double(n)
        let bins = min(half - 1, Int(maxFreq / binHz) + 2)
        let frames = max(1, (x.count - n) / hop + 1)

        let log2n = vDSP_Length(log2(Double(n)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { throw AnalysisError.fftSetup }
        defer { vDSP_destroy_fftsetup(setup) }
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)

        var salience = [Float](repeating: 0, count: frames * nCand)
        var energy = [Float](repeating: 0, count: frames)
        var usedMetal = true

        var windowed = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: half)
        var im = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)
        let scale = 1 / Float(n)

        progress("Computing pitch salience on GPU", 0.08)
        var chunkStart = 0
        while chunkStart < frames {
            let count = min(chunkFrames, frames - chunkStart)
            var mags = [Float](repeating: 0, count: count * bins)
            x.withUnsafeBufferPointer { xp in
                guard let base = xp.baseAddress else { return }
                for k in 0..<count {
                    let f = chunkStart + k
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
                    var e: Float = 0
                    let row = k * bins
                    for b in 0..<bins {
                        let m = sqrt(power[b]) * scale
                        e += m
                        mags[row + b] = log(1 + 200 * m)     // log-compressed magnitude
                    }
                    energy[f] = e
                }
            }

            let chunkSal: [Float]
            if let gpu = MetalCompute.melodySalience(mags: mags, frames: count, bins: bins, candidates: candidates,
                                                     harmonics: source.harmonics, binHz: Float(binHz), maxFreq: Float(maxFreq)) {
                chunkSal = gpu
            } else {
                usedMetal = false
                chunkSal = Self.cpuSalience(mags: mags, frames: count, bins: bins, candidates: candidates,
                                            harmonics: source.harmonics, binHz: Float(binHz), maxFreq: Float(maxFreq))
            }
            for i in 0..<chunkSal.count { salience[chunkStart * nCand + i] = chunkSal[i] }
            chunkStart += count
            progress("Computing pitch salience on GPU", 0.08 + 0.62 * Double(chunkStart) / Double(frames))
        }

        progress("Tracking pitch", 0.72)
        let path = track(salience: salience, frames: frames, candidates: nCand, energy: energy)

        progress("Segmenting notes", 0.92)
        let frameTime = Double(hop) / sampleRate
        let offset = Double(n) / 2 / sampleRate
        var midiTrack = [Double?](repeating: nil, count: frames)
        var frameConf = [Float](repeating: 0, count: frames)
        let norm = Self.percentile((0..<frames).map { (f: Int) -> Float in
            var m: Float = 0
            for c in 0..<nCand { m = max(m, salience[f * nCand + c]) }
            return m
        }, 0.95)
        for f in 0..<frames {
            if let c = path[f] {
                midiTrack[f] = 69 + 12 * log2(Double(candidates[c]) / 440)
                frameConf[f] = norm > 0 ? min(1, salience[f * nCand + c] / norm) : 0
            }
        }
        var notes = Self.segment(midiTrack, confidence: frameConf, frameTime: frameTime, offset: offset)

        progress("Detecting note attacks", 0.95)
        let band = source.onsetBand
        let onsetResult = OnsetDetector.detect(x, sampleRate: sampleRate, lowHz: band.lowerBound, highHz: band.upperBound)
        notes = refine(notes, onsets: onsetResult.onsets.map(\.time), salience: salience, candidates: candidates,
                       frames: frames, frameTime: frameTime, offset: offset, plucked: source.isPlucked)

        progress("Finding the beat", 0.98)
        let (tempo, beatOffset) = beatGrid(fallback: x, rhythmURL: rhythmURL, tempoHint: tempoHint)

        progress("Done", 1)
        return MelodyTrack(source: source, notes: notes, analyzedAt: Date(), usedMetal: usedMetal,
                           bpm: tempo, beatOffset: beatOffset, strums: nil)
    }

    // MARK: - Note-length refinement

    /// Splits notes at re-attacks, snaps starts to detected attacks and, for plucked parts,
    /// ends each note when its pitch dies away.
    private func refine(_ notes: [MelodyNote], onsets: [Double], salience: [Float], candidates: [Float],
                        frames: Int, frameTime: Double, offset: Double, plucked: Bool) -> [MelodyNote] {
        guard !notes.isEmpty else { return notes }
        let C = candidates.count
        let midiLow = 69 + 12 * log2(Double(candidates[0]) / 440)
        let binsPerSemitone = 100 / centsPerBin

        func frame(_ t: Double) -> Int { min(frames - 1, max(0, Int(((t - offset) / frameTime).rounded()))) }
        func pitchSalience(_ f: Int, midi: Int) -> Float {
            let c = Int(((Double(midi) - midiLow) * binsPerSemitone).rounded())
            var m: Float = 0
            for k in max(0, c - 2)...min(C - 1, max(0, c + 2)) { m = max(m, salience[f * C + k]) }
            return m
        }
        func nearestOnset(_ t: Double) -> Double? {
            var lo = 0, hi = onsets.count
            while lo < hi { let mid = (lo + hi) / 2; if onsets[mid] < t { lo = mid + 1 } else { hi = mid } }
            var best: Double?
            for i in [lo - 1, lo] where i >= 0 && i < onsets.count {
                if best == nil || abs(onsets[i] - t) < abs(best! - t) { best = onsets[i] }
            }
            return best
        }

        var out: [MelodyNote] = []
        for n in notes {
            // 1) split at re-attacks inside the note
            var cuts = onsets.filter { $0 > n.start + 0.07 && $0 < n.end - 0.07 }
            cuts.insert(n.start, at: 0)
            cuts.append(n.end)
            for k in 0..<(cuts.count - 1) {
                var start = cuts[k]
                var end = cuts[k + 1]
                // 2) snap the first piece's start to a nearby attack
                if k == 0, let o = nearestOnset(start), abs(o - start) < 0.05, o < end - 0.05 { start = o }
                // 3) plucked parts: end when the pitch has decayed
                if plucked {
                    let f0 = frame(start), f1 = frame(end)
                    if f1 > f0 + 2 {
                        var peak: Float = 0, peakF = f0
                        for f in f0...f1 {
                            let v = pitchSalience(f, midi: n.midi)
                            if v > peak { peak = v; peakF = f }
                        }
                        if peak > 0 {
                            for f in peakF...f1 where pitchSalience(f, midi: n.midi) < peak * 0.3 {
                                let t = Double(f) * frameTime + offset
                                if t - start >= 0.06 { end = min(end, t) }
                                break
                            }
                        }
                    }
                }
                if end - start >= 0.06 {
                    out.append(MelodyNote(start: start, end: end, midi: n.midi, confidence: n.confidence))
                }
            }
        }
        out.sort { $0.start < $1.start }
        // keep it monophonic: never overlap the next note
        for i in out.indices.dropLast() where out[i].end > out[i + 1].start {
            out[i].end = max(out[i].start + 0.03, out[i + 1].start)
        }
        return Self.fixOctaveErrors(out)
    }

    /// Pitch trackers sometimes lock onto the octave above/below for a moment. A short note that sits
    /// about an octave away from both neighbours (while they are close to each other) is folded back.
    static func fixOctaveErrors(_ notes: [MelodyNote]) -> [MelodyNote] {
        guard notes.count >= 3 else { return notes }
        var out = notes
        for i in 1..<(out.count - 1) {
            let a = out[i - 1].midi, b = out[i].midi, c = out[i + 1].midi
            guard out[i].duration < 0.35, abs(a - c) <= 5 else { continue }
            let avg = Double(a + c) / 2
            let dist = abs(Double(b) - avg)
            if dist >= 9 {
                if abs(Double(b - 12) - avg) <= 4 { out[i].midi = b - 12 }
                else if abs(Double(b + 12) - avg) <= 4 { out[i].midi = b + 12 }
            }
        }
        // merge neighbours that became the same pitch with (almost) no gap
        var merged: [MelodyNote] = []
        for n in out {
            if var last = merged.last, last.midi == n.midi, n.start - last.end < 0.03 {
                last.end = n.end
                merged[merged.count - 1] = last
            } else {
                merged.append(n)
            }
        }
        return merged
    }

    // MARK: - Rhythm part (strums)

    /// Tempo and first-beat offset from the rhythm reference (drums stem / full mix).
    private func beatGrid(fallback x: [Float], rhythmURL: URL?, tempoHint: Double?) -> (Double, Double) {
        var audio = x
        if let r = rhythmURL, let y = try? AudioLoader.loadMono(url: r, sampleRate: sampleRate), y.count > fftSize * 2 {
            audio = y
        }
        let hint = tempoHint ?? 0
        let estimated = hint > 30 ? hint : ChordAnalyzer.estimateTempo(audio, sampleRate: sampleRate)
        let tempo = estimated > 30 ? estimated : 120
        let det = OnsetDetector.detect(audio, sampleRate: sampleRate, lowHz: 40, highHz: 8000)
        return (tempo, OnsetDetector.beatOffset(det, bpm: tempo))
    }

    private func analyzeRhythm(_ x: [Float], rhythmURL: URL?, tempoHint: Double?,
                               progress: @escaping (String, Double) -> Void) -> MelodyTrack {
        progress("Detecting strums", 0.3)
        let det = OnsetDetector.detect(x, sampleRate: sampleRate, lowHz: 150, highHz: 6000)
        progress("Finding the beat", 0.7)
        let (tempo, offset) = beatGrid(fallback: x, rhythmURL: rhythmURL, tempoHint: tempoHint)
        let grid = RhythmGrid(bpm: tempo, offset: offset)

        let hits = det.onsets.filter { $0.strength > 0.15 }
        let steps = hits.map { Int(grid.stepPosition($0.time).rounded()) }
        // 16th-note feel if a fair share of strums fall on odd 16ths
        let odd = steps.filter { abs($0) % 2 == 1 }.count
        let sixteenthFeel = Double(odd) / Double(max(1, steps.count)) > 0.18

        progress("Assigning strum directions", 0.9)
        var strums: [Strum] = []
        for (i, h) in hits.enumerated() {
            let g = ((steps[i] % 16) + 16) % 16
            // Classic strumming: the hand moves down on the beat and up in between.
            let down = sixteenthFeel ? (g % 2 == 0) : (g % 4 == 0)
            let nextStart = i + 1 < hits.count ? hits[i + 1].time : h.time + 2 * grid.beat
            let end = min(nextStart, h.time + 2 * grid.beat)
            strums.append(Strum(start: h.time, end: end, down: down, strength: h.strength))
        }
        progress("Done", 1)
        return MelodyTrack(source: .rhythm, notes: [], analyzedAt: Date(), usedMetal: false,
                           bpm: tempo, beatOffset: grid.offset, strums: strums)
    }

    // MARK: - Viterbi pitch tracking

    /// Returns the candidate index per frame, or nil when unvoiced.
    private func track(salience: [Float], frames: Int, candidates C: Int, energy: [Float]) -> [Int?] {
        var maxPerFrame = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
            var m: Float = 0
            for c in 0..<C { m = max(m, salience[f * C + c]) }
            maxPerFrame[f] = m
        }
        let norm = max(Self.percentile(maxPerFrame, 0.95), 1e-6)
        let energyFloor = Self.percentile(energy, 0.10) * 1.5
        let voicingThreshold: Float = 0.42

        let beta: Float = 10
        let stepCost: Float = 0.08          // per 20-cent bin of glide
        let jumpCost: Float = 2.0           // any larger interval
        let voicingCost: Float = 1.6        // switching voiced <-> unvoiced
        let W = 8                           // ±160 cents of continuous glide

        let U = C                           // unvoiced state index
        var delta = [Float](repeating: 0, count: C + 1)
        var next = [Float](repeating: 0, count: C + 1)
        var psi = [Int16](repeating: 0, count: frames * (C + 1))

        func emission(_ f: Int, _ c: Int) -> Float {
            if c == U {
                return beta * (energy[f] < energyFloor ? 1.0 : voicingThreshold)
            }
            return beta * (salience[f * C + c] / norm)
        }

        for c in 0...C { delta[c] = emission(0, c) }

        do {
            for f in 1..<max(frames, 1) {
                var maxV = -Float.greatestFiniteMagnitude, maxI = 0
                for c in 0..<C where delta[c] > maxV { maxV = delta[c]; maxI = c }
                let unv = delta[U]
                let base = f * (C + 1)
                for c in 0..<C {
                    var best = maxV - jumpCost, bestI = maxI
                    let lo = max(0, c - W), hi = min(C - 1, c + W)
                    for p in lo...hi {
                        let v = delta[p] - stepCost * Float(abs(p - c))
                        if v > best { best = v; bestI = p }
                    }
                    if unv - voicingCost > best { best = unv - voicingCost; bestI = U }
                    next[c] = best + emission(f, c)
                    psi[base + c] = Int16(bestI)
                }
                // unvoiced
                if unv >= maxV - voicingCost {
                    next[U] = unv + emission(f, U); psi[base + U] = Int16(U)
                } else {
                    next[U] = maxV - voicingCost + emission(f, U); psi[base + U] = Int16(maxI)
                }
                let m = next.max() ?? 0
                for c in 0...C { delta[c] = next[c] - m }
            }
        }

        var state = delta.indices.max { delta[$0] < delta[$1] } ?? U
        var path = [Int?](repeating: nil, count: frames)
        for f in stride(from: frames - 1, through: 0, by: -1) {
            path[f] = state == U ? nil : state
            if f > 0 { state = Int(psi[f * (C + 1) + state]) }
        }
        return path
    }

    // MARK: - Note segmentation

    private struct Run { var midi: Int?; var start: Int; var end: Int; var conf: Float }

    static func segment(_ track: [Double?], confidence: [Float], frameTime: Double, offset: Double) -> [MelodyNote] {
        // 1) quantise to semitones with hysteresis
        var q = [Int?](repeating: nil, count: track.count)
        var prev: Int?
        for (i, m) in track.enumerated() {
            guard let m else { prev = nil; continue }
            if let p = prev, abs(m - Double(p)) < 0.7 { q[i] = p } else { q[i] = Int(m.rounded()); prev = q[i] }
        }
        // 2) run-length
        var runs: [Run] = []
        for (i, v) in q.enumerated() {
            if var last = runs.last, last.midi == v {
                last.end = i + 1
                last.conf += confidence[i]
                runs[runs.count - 1] = last
            } else {
                runs.append(Run(midi: v, start: i, end: i + 1, conf: confidence[i]))
            }
        }
        // 3) drop very short voiced blips
        let minBlip = max(2, Int(0.05 / frameTime))
        for i in runs.indices where runs[i].midi != nil && runs[i].end - runs[i].start < minBlip {
            runs[i].midi = nil
        }
        // 4) merge same-pitch runs separated by short gaps
        let maxGap = max(1, Int(0.045 / frameTime))
        var merged: [Run] = []
        for r in runs {
            guard r.midi != nil else { merged.append(r); continue }
            if merged.count >= 2, let gap = merged.last, gap.midi == nil, gap.end - gap.start <= maxGap,
               merged[merged.count - 2].midi == r.midi {
                merged.removeLast()
                merged[merged.count - 1].end = r.end
                merged[merged.count - 1].conf += r.conf
            } else if let last = merged.last, last.midi == r.midi {
                merged[merged.count - 1].end = r.end
                merged[merged.count - 1].conf += r.conf
            } else {
                merged.append(r)
            }
        }
        // 5) emit notes
        let minNote = 0.08
        var notes: [MelodyNote] = []
        for r in merged {
            guard let m = r.midi else { continue }
            let start = Double(r.start) * frameTime + offset
            let end = Double(r.end) * frameTime + offset
            guard end - start >= minNote else { continue }
            notes.append(MelodyNote(start: start, end: end, midi: m, confidence: r.conf / Float(r.end - r.start)))
        }
        return notes
    }

    // MARK: - Helpers

    static func percentile(_ v: [Float], _ p: Double) -> Float {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s[min(s.count - 1, max(0, Int(Double(s.count - 1) * p)))]
    }

    static func cpuSalience(mags: [Float], frames: Int, bins: Int, candidates: [Float], harmonics: Int,
                            binHz: Float, maxFreq: Float) -> [Float] {
        let C = candidates.count
        var out = [Float](repeating: 0, count: frames * C)
        for f in 0..<frames {
            let row = f * bins
            for c in 0..<C {
                let f0 = candidates[c]
                var s: Float = 0, w: Float = 1
                for h in 1...harmonics {
                    let fh = f0 * Float(h)
                    if fh >= maxFreq { break }
                    let b = fh / binHz
                    let b0 = Int(b)
                    if b0 + 1 >= bins { break }
                    let fr = b - Float(b0)
                    var m = mags[row + b0] * (1 - fr) + mags[row + b0 + 1] * fr
                    m = max(m, max(mags[row + b0], mags[row + b0 + 1]) * 0.9)
                    var between: Float = 0
                    if h > 1 {
                        let bh = (fh - 0.5 * f0) / binHz
                        let bh0 = Int(bh)
                        if bh0 + 1 < bins {
                            let fh2 = bh - Float(bh0)
                            between = mags[row + bh0] * (1 - fh2) + mags[row + bh0 + 1] * fh2
                        }
                    }
                    s += w * (m - 0.5 * between)
                    w *= 0.8
                }
                out[f * C + c] = max(s, 0)
            }
        }
        return out
    }
}
