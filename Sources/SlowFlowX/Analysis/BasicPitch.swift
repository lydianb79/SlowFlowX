import Foundation
import CoreML
import Accelerate

/// Polyphonic, instrument-agnostic note transcription with Spotify's Basic Pitch model
/// (ICASSP 2022, Apache-2.0), run natively through Core ML — no Python needed.
///
/// This is a Swift port of `basic_pitch.inference` (windowing / unwrapping) and
/// `basic_pitch.note_creation.output_to_notes_polyphonic` (onset/frame decoding with the
/// "melodia trick"). Constants match the reference implementation so results are the same.
final class BasicPitch {
    struct Note {
        var start: Double
        var end: Double
        var midi: Int
        var amplitude: Float
    }

    struct Options {
        var onsetThreshold: Float = 0.5
        var frameThreshold: Float = 0.3
        var minNoteLengthMs: Double = 127.7
        var minFrequency: Double? = nil
        var maxFrequency: Double? = nil
        var inferOnsets = true
        var melodiaTrick = true
    }

    enum BPError: LocalizedError {
        case modelMissing, badOutput
        var errorDescription: String? {
            switch self {
            case .modelMissing: return "The note-transcription model (Basic Pitch) is missing from the app bundle."
            case .badOutput: return "The note-transcription model returned unexpected data."
            }
        }
    }

    // Model constants (basic_pitch/constants.py)
    static let sampleRate = 22_050.0
    static let fftHop = 256
    static let annotFrames = 172                       // ANNOTATIONS_FPS (86) * 2 s
    static let windowSamples = 22_050 * 2 - 256        // AUDIO_N_SAMPLES = 43 844
    static let overlapFrames = 30
    static let pitchBins = 88
    static let midiOffset = 21
    static let energyTolerance = 11
    static let alignmentOffset = 0.0018

    private let model: MLModel

    private init(model: MLModel) { self.model = model }

    // MARK: Loading

    private static let lock = NSLock()
    private static var cached: BasicPitch?

    /// Loads (and on first use compiles) the bundled model. Thread-safe.
    static func shared() throws -> BasicPitch {
        lock.lock(); defer { lock.unlock() }
        if let c = cached { return c }
        let url = try compiledModelURL()
        let config = MLModelConfiguration()
        config.computeUnits = .all
        let m = try MLModel(contentsOf: url, configuration: config)
        let bp = BasicPitch(model: m)
        cached = bp
        return bp
    }

    static var isAvailable: Bool { (try? locateModel()) != nil }

    private static func locateModel() throws -> URL {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let r = Bundle.main.resourceURL {
            candidates.append(r.appendingPathComponent("BasicPitch/nmp.mlmodelc"))
            candidates.append(r.appendingPathComponent("BasicPitch/nmp.mlpackage"))
        }
        // Development runs (`swift run`): look for the repository's Resources folder.
        var dir = Bundle.main.executableURL?.deletingLastPathComponent()
        for _ in 0..<6 {
            guard let d = dir else { break }
            candidates.append(d.appendingPathComponent("Resources/BasicPitch/nmp.mlpackage"))
            dir = d.deletingLastPathComponent()
        }
        candidates.append(URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Resources/BasicPitch/nmp.mlpackage"))
        guard let found = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else { throw BPError.modelMissing }
        return found
    }

    private static func compiledModelURL() throws -> URL {
        let src = try locateModel()
        if src.pathExtension == "mlmodelc" { return src }
        let fm = FileManager.default
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("SlowFlowX/Models", isDirectory: true)
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        let weights = src.appendingPathComponent("Data/com.apple.CoreML/weights/weight.bin")
        let size = (try? fm.attributesOfItem(atPath: weights.path)[.size] as? Int) ?? 0
        let dest = support.appendingPathComponent("BasicPitch-icassp2022-\(size).mlmodelc")
        if fm.fileExists(atPath: dest.path) { return dest }
        let compiled = try MLModel.compileModel(at: src)
        try? fm.removeItem(at: dest)
        do { try fm.moveItem(at: compiled, to: dest) } catch { try fm.copyItem(at: compiled, to: dest) }
        return dest
    }

    // MARK: Transcription

    /// - Parameter audio: mono samples at 22 050 Hz.
    func transcribe(_ audio: [Float], options: Options, progress: (Double) -> Void) throws -> [Note] {
        let (frames, onsets, n) = try runModel(audio, progress: progress)
        guard n > 2 else { return [] }
        return Self.decode(frames: frames, onsets: onsets, nFrames: n, options: options)
    }

    /// Runs the network over overlapping 2-second windows and stitches the outputs
    /// (`run_inference` + `unwrap_output`). Returns note and onset activations, row-major [frame][pitch].
    private func runModel(_ x: [Float], progress: (Double) -> Void) throws -> ([Float], [Float], Int) {
        let overlapLen = Self.overlapFrames * Self.fftHop
        let hopSize = Self.windowSamples - overlapLen
        let padded = [Float](repeating: 0, count: overlapLen / 2) + x
        let nOlap = Self.overlapFrames / 2
        let P = Self.pitchBins

        let input = try MLMultiArray(shape: [1, NSNumber(value: Self.windowSamples), 1], dataType: .float32)
        let inPtr = input.dataPointer.bindMemory(to: Float.self, capacity: Self.windowSamples)

        var notes: [Float] = [], onsets: [Float] = []
        let starts = Array(stride(from: 0, to: padded.count, by: hopSize))
        notes.reserveCapacity(starts.count * (Self.annotFrames - 2 * nOlap) * P)
        onsets.reserveCapacity(notes.capacity)

        for (k, i) in starts.enumerated() {
            let count = min(Self.windowSamples, padded.count - i)
            padded.withUnsafeBufferPointer { p in
                inPtr.update(from: p.baseAddress! + i, count: count)
            }
            if count < Self.windowSamples { (inPtr + count).update(repeating: 0, count: Self.windowSamples - count) }

            let provider = try MLDictionaryFeatureProvider(dictionary: ["input_2": MLFeatureValue(multiArray: input)])
            let out = try model.prediction(from: provider)
            guard let note = out.featureValue(for: "Identity_1")?.multiArrayValue,
                  let onset = out.featureValue(for: "Identity_2")?.multiArrayValue else { throw BPError.badOutput }
            try Self.appendRows(note, dropping: nOlap, to: &notes)
            try Self.appendRows(onset, dropping: nOlap, to: &onsets)
            progress(Double(k + 1) / Double(starts.count))
        }

        let framesPerWindow = Double(Self.annotFrames - Self.overlapFrames)
        let expected = Int(Double(x.count) / Double(hopSize) * framesPerWindow)
        let n = min(expected, notes.count / P, onsets.count / P)
        return (Array(notes.prefix(n * P)), Array(onsets.prefix(n * P)), n)
    }

    /// Appends rows [drop, T - drop) of a (…, T, 88) multi-array, whatever its element type and strides.
    private static func appendRows(_ a: MLMultiArray, dropping drop: Int, to out: inout [Float]) throws {
        let shape = a.shape.map(\.intValue), strides = a.strides.map(\.intValue)
        guard shape.count >= 2, shape[shape.count - 1] == pitchBins else { throw BPError.badOutput }
        let T = shape[shape.count - 2]
        let ts = strides[strides.count - 2], fs = strides[strides.count - 1]
        guard T > 2 * drop else { return }
        let span = (T - 1) * ts + (pitchBins - 1) * fs + 1
        switch a.dataType {
        case .float32:
            let p = a.dataPointer.bindMemory(to: Float.self, capacity: span)
            for t in drop..<(T - drop) { for f in 0..<pitchBins { out.append(p[t * ts + f * fs]) } }
        case .double:
            let p = a.dataPointer.bindMemory(to: Double.self, capacity: span)
            for t in drop..<(T - drop) { for f in 0..<pitchBins { out.append(Float(p[t * ts + f * fs])) } }
        default:
            // Float16 (bit-level conversion keeps this working on Intel Macs too).
            let p = a.dataPointer.bindMemory(to: UInt16.self, capacity: span)
            for t in drop..<(T - drop) { for f in 0..<pitchBins { out.append(halfToFloat(p[t * ts + f * fs])) } }
        }
    }

    private static func halfToFloat(_ h: UInt16) -> Float {
        let sign = UInt32(h & 0x8000) << 16
        var exp = UInt32((h >> 10) & 0x1F)
        var mant = UInt32(h & 0x3FF)
        if exp == 0 {
            if mant == 0 { return Float(bitPattern: sign) }
            while mant & 0x400 == 0 { mant <<= 1; exp &-= 1 }
            exp &+= 1; mant &= 0x3FF
        } else if exp == 31 {
            return Float(bitPattern: sign | 0x7F80_0000 | (mant << 13))
        }
        return Float(bitPattern: sign | ((exp &+ 112) << 23) | (mant << 13))
    }

    // MARK: Decoding (note_creation.output_to_notes_polyphonic)

    static func frameTime(_ f: Int) -> Double {
        let original = Double(f * fftHop) / sampleRate
        let windowOffset = Double(fftHop) / sampleRate * (Double(annotFrames) - Double(windowSamples) / Double(fftHop)) + alignmentOffset
        return original - windowOffset * Double(f / annotFrames)
    }

    static func decode(frames framesIn: [Float], onsets onsetsIn: [Float], nFrames n: Int, options o: Options) -> [Note] {
        let P = pitchBins
        var frames = framesIn, onsets = onsetsIn

        // constrain_frequency
        func midi(_ hz: Double) -> Double { 69 + 12 * log2(hz / 440) }
        let minIdx = o.minFrequency.map { max(0, Int((midi($0) - Double(midiOffset)).rounded())) } ?? 0
        let maxIdx = o.maxFrequency.map { min(P, Int((midi($0) - Double(midiOffset)).rounded())) } ?? P
        for t in 0..<n {
            for f in 0..<P where f < minIdx || f >= maxIdx {
                frames[t * P + f] = 0; onsets[t * P + f] = 0
            }
        }

        // get_infered_onsets (n_diff = 2)
        if o.inferOnsets {
            var diff = [Float](repeating: 0, count: n * P)
            var maxDiff: Float = 0
            for t in 2..<n {
                for f in 0..<P {
                    let cur = frames[t * P + f]
                    let d = max(0, min(cur - frames[(t - 1) * P + f], cur - frames[(t - 2) * P + f]))
                    diff[t * P + f] = d
                    maxDiff = max(maxDiff, d)
                }
            }
            let maxOnset = onsets.max() ?? 0
            if maxDiff > 0 {
                let s = maxOnset / maxDiff
                for i in 0..<(n * P) { onsets[i] = max(onsets[i], diff[i] * s) }
            }
        }

        // Peaks along time above the onset threshold, processed backwards in time.
        var peaks: [(t: Int, f: Int)] = []
        if n > 2 {
            for t in 1..<(n - 1) {
                for f in 0..<P {
                    let v = onsets[t * P + f]
                    if v >= o.onsetThreshold && v > onsets[(t - 1) * P + f] && v > onsets[(t + 1) * P + f] {
                        peaks.append((t, f))
                    }
                }
            }
        }
        peaks.reverse()

        let minLen = Int((o.minNoteLengthMs / 1000 * (sampleRate / Double(fftHop))).rounded())
        let tol = energyTolerance
        var remaining = frames
        var events: [(s: Int, e: Int, f: Int, amp: Float)] = []

        func meanAmp(_ s: Int, _ e: Int, _ f: Int) -> Float {
            guard e > s else { return 0 }
            var sum: Float = 0
            for t in s..<e { sum += frames[t * P + f] }
            return sum / Float(e - s)
        }
        func clearNeighbours(_ t: Int, _ f: Int) {
            remaining[t * P + f] = 0
            if f < P - 1 { remaining[t * P + f + 1] = 0 }
            if f > 0 { remaining[t * P + f - 1] = 0 }
        }

        for (start, f) in peaks {
            if start >= n - 1 { continue }
            var i = start + 1, k = 0
            while i < n - 1 && k < tol {
                if remaining[i * P + f] < o.frameThreshold { k += 1 } else { k = 0 }
                i += 1
            }
            i -= k
            if i - start <= minLen { continue }
            for t in start..<i { clearNeighbours(t, f) }
            events.append((start, i, f, meanAmp(start, i, f)))
        }

        if o.melodiaTrick {
            // Equivalent to repeatedly taking argmax(remaining): values only ever drop to zero,
            // so visiting candidates in descending order and skipping cleared ones is the same.
            var cands: [Int] = []
            for i in 0..<(n * P) where remaining[i] > o.frameThreshold { cands.append(i) }
            cands.sort { remaining[$0] > remaining[$1] }
            for idx in cands {
                guard remaining[idx] > o.frameThreshold else { continue }
                let mid = idx / P, f = idx % P
                remaining[idx] = 0

                var i = mid + 1, k = 0
                while i < n - 1 && k < tol {
                    if remaining[i * P + f] < o.frameThreshold { k += 1 } else { k = 0 }
                    clearNeighbours(i, f)
                    i += 1
                }
                let end = i - 1 - k

                i = mid - 1; k = 0
                while i > 0 && k < tol {
                    if remaining[i * P + f] < o.frameThreshold { k += 1 } else { k = 0 }
                    clearNeighbours(i, f)
                    i -= 1
                }
                let start = i + 1 + k
                if end - start <= minLen { continue }
                events.append((start, end, f, meanAmp(start, end, f)))
            }
        }

        return events.map {
            Note(start: max(0, frameTime($0.s)), end: frameTime(min($0.e, n - 1)), midi: $0.f + midiOffset, amplitude: $0.amp)
        }
        .sorted { $0.start != $1.start ? $0.start < $1.start : $0.midi < $1.midi }
    }
}

// MARK: - Per-part settings and clean-up

extension BasicPitch.Options {
    static func forPart(_ source: MelodySource) -> BasicPitch.Options {
        var o = BasicPitch.Options()
        switch source {
        case .vocal:
            o.minFrequency = 80; o.maxFrequency = 1200
            o.minNoteLengthMs = 100
        case .lead:
            o.minFrequency = 58; o.maxFrequency = 1600
            o.minNoteLengthMs = 58          // fast runs: 16ths at 200 BPM are 75 ms
        case .rhythm:
            o.minFrequency = 44; o.maxFrequency = 1100
            o.minNoteLengthMs = 58
        case .bass:
            o.minFrequency = 29; o.maxFrequency = 420
            o.minNoteLengthMs = 58
        }
        return o
    }
}

enum NoteCleanup {
    /// Turns raw model notes into a readable part: drops overtone "ghost" notes that ride on a
    /// stronger note, limits how many notes may sound together (one for voice and bass, two for
    /// lead, a chord for rhythm) and trims notes so a monophonic line never overlaps itself.
    static func clean(_ raw: [BasicPitch.Note], source: MelodySource) -> [MelodyNote] {
        guard !raw.isEmpty else { return [] }
        let maxPoly: Int
        switch source {
        case .vocal, .bass: maxPoly = 1
        case .lead: maxPoly = 2
        case .rhythm: maxPoly = 6
        }

        // 1. Overtone ghosts: a much weaker note an octave+fifth, two octaves, etc. above a
        //    note that sounds at the same time is almost always a harmonic, not a played note.
        let harmonicIntervals: Set<Int> = [12, 19, 24, 28, 31, 36]
        // Octaves are often really played on guitar (power chords), so they must be much weaker to go.
        func ratio(_ interval: Int) -> Float {
            guard interval == 12 else { return 0.75 }
            switch source {
            case .rhythm: return 0.45
            case .lead: return 0.6
            default: return 0.75
            }
        }
        var keep = [Bool](repeating: true, count: raw.count)
        var lo = 0
        for i in raw.indices {
            let a = raw[i]
            while lo < i && raw[lo].start < a.start - 6 { lo += 1 }       // notes are sorted by start
            var j = lo - 1
            while true {
                j += 1
                guard j < raw.count, raw[j].start < a.end else { break }
                guard j != i && keep[j] else { continue }
                let b = raw[j]
                let interval = a.midi - b.midi
                guard interval > 0, harmonicIntervals.contains(interval) else { continue }
                let overlap = min(a.end, b.end) - max(a.start, b.start)
                guard overlap > 0.6 * (a.end - a.start) else { continue }
                if a.amplitude < ratio(interval) * b.amplitude { keep[i] = false; break }
            }
        }
        var notes = raw.indices.filter { keep[$0] }.map { raw[$0] }

        // 2. Group notes that start together and keep the strongest `maxPoly`.
        var groups: [[BasicPitch.Note]] = []
        for n in notes {
            if let last = groups.last?.first, n.start - last.start <= 0.04 {
                groups[groups.count - 1].append(n)
            } else {
                groups.append([n])
            }
        }
        notes = []
        for var g in groups {
            if g.count > maxPoly {
                if source == .bass {
                    // the fundamental of a bass note is the lowest strong pitch
                    let strongest = g.map(\.amplitude).max() ?? 0
                    let low = g.filter { $0.amplitude >= 0.6 * strongest }.min { $0.midi < $1.midi }
                    g = low.map { [$0] } ?? [g[0]]
                } else {
                    g = Array(g.sorted { $0.amplitude > $1.amplitude }.prefix(maxPoly))
                }
            }
            notes += g.sorted { $0.midi < $1.midi }
        }

        // 3. Monophonic parts: a new note ends the previous one; drop leftovers that are swallowed.
        if maxPoly == 1 {
            var out: [BasicPitch.Note] = []
            for n in notes {
                if var last = out.last, n.start < last.end {
                    if n.start - last.start < 0.06 {
                        // practically simultaneous: keep the stronger one
                        if n.amplitude > last.amplitude { out[out.count - 1] = n }
                        continue
                    }
                    last.end = n.start
                    out[out.count - 1] = last
                }
                out.append(n)
            }
            notes = out
        }

        return notes.map { MelodyNote(start: $0.start, end: max($0.end, $0.start + 0.03), midi: $0.midi, confidence: min(1, $0.amplitude * 1.6)) }
            .sorted { $0.start != $1.start ? $0.start < $1.start : $0.midi < $1.midi }
    }
}
