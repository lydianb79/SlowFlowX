import Foundation

/// Gives plain (unsynced) lyrics approximate line times so they can scroll with the song.
/// Lines are spread over the time the singer is actually singing: taken from the vocals stem
/// when it exists (sections without vocals are skipped), otherwise over the body of the song.
enum LyricsTiming {
    static func estimate(_ lyrics: Lyrics, duration: Double, vocalsURL: URL?) -> Lyrics {
        guard lyrics.source == .plain, !lyrics.lines.isEmpty, duration > 10 else { return lyrics }

        // Active singing time as (start, end) spans.
        var spans: [(Double, Double)] = []
        if let url = vocalsURL, let act = try? activity(url: url) { spans = act }
        if spans.isEmpty { spans = [(duration * 0.06, duration * 0.94)] }
        let total = spans.reduce(0) { $0 + ($1.1 - $1.0) }
        guard total > 1 else { return lyrics }

        // Each line gets singing time in proportion to its length; blank lines mark a short break.
        let weights = lyrics.lines.map { line -> Double in
            let t = line.text.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? 3 : Double(max(6, t.count))
        }
        let sum = weights.reduce(0, +)

        func time(atActive a: Double) -> Double {
            var left = a
            for (s, e) in spans {
                if left <= e - s { return s + left }
                left -= e - s
            }
            return spans.last?.1 ?? duration
        }

        var out = lyrics
        var acc = 0.0
        for i in out.lines.indices {
            out.lines[i].time = time(atActive: acc / sum * total)
            acc += weights[i]
        }
        out.estimated = true
        return out
    }

    /// Where the vocals stem has sound: 0.25 s RMS frames, smoothed, gated relative to the loud parts.
    private static func activity(url: URL) throws -> [(Double, Double)] {
        let sr = 8_000.0
        let x = try AudioLoader.loadMono(url: url, sampleRate: sr)
        let hop = Int(sr * 0.25)
        guard x.count > hop * 8 else { return [] }
        var rms: [Float] = []
        var i = 0
        while i + hop <= x.count {
            var s: Float = 0
            for j in i..<(i + hop) { s += x[j] * x[j] }
            rms.append((s / Float(hop)).squareRoot())
            i += hop
        }
        // smooth over ~1 s so short breaths don't split phrases
        let k = 2
        let smooth = rms.indices.map { idx -> Float in
            let lo = max(0, idx - k), hi = min(rms.count - 1, idx + k)
            return rms[lo...hi].reduce(0, +) / Float(hi - lo + 1)
        }
        let sorted = smooth.sorted()
        let loud = sorted[Int(Double(sorted.count - 1) * 0.9)]
        guard loud > 1e-4 else { return [] }
        let gate = loud * 0.18

        var spans: [(Double, Double)] = []
        var start: Int?
        for (idx, v) in smooth.enumerated() {
            if v >= gate { if start == nil { start = idx } }
            else if let s = start { spans.append((Double(s) * 0.25, Double(idx) * 0.25)); start = nil }
        }
        if let s = start { spans.append((Double(s) * 0.25, Double(smooth.count) * 0.25)) }
        // ignore blips shorter than 1.5 s, merge gaps shorter than 2 s
        spans = spans.filter { $0.1 - $0.0 >= 1.5 }
        var merged: [(Double, Double)] = []
        for sp in spans {
            if let last = merged.last, sp.0 - last.1 < 2 { merged[merged.count - 1].1 = sp.1 } else { merged.append(sp) }
        }
        return merged
    }
}
