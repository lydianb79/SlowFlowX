import Foundation
import AVFoundation
import Accelerate

enum StemError: LocalizedError {
    case demucsMissing
    case demucsFailed(String)
    case noOutput
    case unsupported

    var errorDescription: String? {
        switch self {
        case .demucsMissing:
            return "Demucs was not found. Install it with:\n\(StemSeparator.installCommand)\n\n(or use the built-in quick separation)."
        case .demucsFailed(let msg):
            return "Demucs reported an error:\n\(msg)"
        case .noOutput:
            return "Separation finished but no stem files were produced."
        case .unsupported:
            return "This audio file can't be separated."
        }
    }
}

/// Splits a song into stems, either with Demucs (AI, best quality) or with a built-in
/// spectral separator (stereo-centre extraction + harmonic/percussive separation, Metal-accelerated).
enum StemSeparator {

    static var demucsURL: URL? { ToolLocator.find("demucs") }

    /// Python 3.12 + torch/torchaudio 2.8: newer Pythons lack wheels for some dependencies, and
    /// torchaudio ≥ 2.9 routes saving through TorchCodec, which breaks Demucs' WAV output.
    /// numpy and soundfile are listed explicitly: Demucs imports numpy without declaring it (torch 2.8 no
    /// longer pulls it in), and torchaudio 2.8 needs soundfile as a reliable WAV backend.
    static let installCommand = #"brew install uv && uv tool install --force --python 3.12 demucs --with "torch==2.8.*" --with "torchaudio==2.8.*" --with numpy --with soundfile"#

    // MARK: - Installing Demucs

    enum InstallError: LocalizedError {
        case homebrewMissing
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .homebrewMissing:
                return "Homebrew was not found. Install it from https://brew.sh, then try again."
            case .failed(let step):
                return "Installation failed during: \(step). See the log for details."
            }
        }
    }

    /// Installs Demucs the reliable way: Homebrew → uv → Demucs on Python 3.12 with torch/torchaudio 2.8.
    /// `log` receives every output line.
    static func installDemucs(log: @escaping @Sendable (String) -> Void) async throws {
        let env = ToolLocator.environment
        var uv = ToolLocator.find("uv")
        if uv == nil {
            guard let brew = ToolLocator.find("brew") else { throw InstallError.homebrewMissing }
            log("$ brew install uv")
            let r = try await ProcessRunner.run(brew, ["install", "uv"], environment: env,
                                                onStdoutLine: log, onStderrLine: log)
            guard r.status == 0 else { throw InstallError.failed("brew install uv") }
            uv = ToolLocator.find("uv")
        }
        guard let uv else { throw InstallError.failed("locating uv") }

        let args = ["tool", "install", "--force", "--python", "3.12", "demucs",
                    "--with", "torch==2.8.*", "--with", "torchaudio==2.8.*",
                    "--with", "numpy", "--with", "soundfile"]
        log("$ uv " + args.joined(separator: " "))
        let r = try await ProcessRunner.run(uv, args, environment: env, onStdoutLine: log, onStderrLine: log)
        guard r.status == 0 else { throw InstallError.failed("uv tool install demucs") }

        guard let demucs = ToolLocator.find("demucs") else { throw InstallError.failed("locating demucs") }
        log("$ self-test: import numpy, soundfile, torch, torchaudio, demucs")
        let check = await checkDemucs()
        guard check.ok else {
            log(check.message)
            throw InstallError.failed("demucs self-test")
        }
        log("✓ Demucs is installed and working: \(demucs.path)")
    }

    /// Verifies that Demucs can actually run — not just that its launcher exists — by importing
    /// everything a separation needs with Demucs' own Python interpreter.
    static func checkDemucs() async -> (ok: Bool, message: String) {
        guard let demucs = demucsURL else { return (false, "Demucs is not installed.") }
        var exe = demucs
        var args = ["--help"]
        if let handle = try? FileHandle(forReadingFrom: demucs) {
            let head = (try? handle.read(upToCount: 512)) ?? Data()
            try? handle.close()
            if let text = String(data: head, encoding: .utf8), text.hasPrefix("#!"),
               let line = text.dropFirst(2).split(separator: "\n").first {
                let interpreter = line.trimmingCharacters(in: .whitespaces)
                if !interpreter.contains(" "), FileManager.default.isExecutableFile(atPath: interpreter) {
                    exe = URL(fileURLWithPath: interpreter)
                    args = ["-c", "import numpy, soundfile, torch, torchaudio, demucs.separate"]
                }
            }
        }
        do {
            let r = try await ProcessRunner.run(exe, args, environment: ToolLocator.environment)
            if r.status == 0 { return (true, "") }
            let lines = r.stderr.split(separator: "\n").map(String.init)
            let last = lines.last(where: { $0.contains("Error") }) ?? lines.last ?? "exit code \(r.status)"
            return (false, last)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: - Demucs

    static func separateWithDemucs(input: URL, songID: String, model: DemucsModel,
                                   progress: @escaping @Sendable (Double) -> Void) async throws -> StemSet {
        guard let demucs = demucsURL else { throw StemError.demucsMissing }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("slowflowx-stems-\(songID)-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // Decode to WAV ourselves so Demucs never depends on its own decoder setup.
        let wav = work.appendingPathComponent("input.wav")
        try AudioFileTools.writeWAV(from: input, to: wav)
        progress(0.02)

        var env = ToolLocator.environment
        env["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
        let models = model == .fineTuned ? 4.0 : 1.0
        let pctRegex = try NSRegularExpression(pattern: #"(\d{1,3})%\|"#)

        func run(device: String) async throws -> ProcessResult {
            let state = ProgressState()
            let args = ["-n", model.rawValue, "-d", device, "-o", work.appendingPathComponent("out").path, wav.path]
            return try await ProcessRunner.run(demucs, args, environment: env, onStderrLine: { line in
                let ns = line as NSString
                guard let m = pctRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                      let pct = Double(ns.substring(with: m.range(at: 1))) else { return }
                let overall = state.update(pct) / models
                progress(0.03 + 0.95 * min(1, overall))
            })
        }

        #if arch(arm64)
        var result = try await run(device: "mps")
        if result.status != 0 { result = try await run(device: "cpu") }   // MPS can fail on some setups
        #else
        let result = try await run(device: "cpu")
        #endif
        guard result.status == 0 else {
            var tail = result.stderr.split(separator: "\n").suffix(5).joined(separator: "\n")
            if tail.isEmpty { tail = "exit code \(result.status)" }
            if result.stderr.localizedCaseInsensitiveContains("torchcodec") {
                tail += "\n\nYour torchaudio is 2.9 or newer, which needs TorchCodec. Reinstall Demucs with torch/torchaudio 2.8:\n" + installCommand
            }
            throw StemError.demucsFailed(tail)
        }

        let produced = work.appendingPathComponent("out").appendingPathComponent(model.rawValue).appendingPathComponent("input")
        let dest = LibraryPaths.stems(songID)
        clear(dest)
        var files: [String: String] = [:]
        for kind in StemKind.allCases {
            let src = produced.appendingPathComponent("\(kind.rawValue).wav")
            guard fm.fileExists(atPath: src.path) else { continue }
            let name = "\(kind.rawValue).wav"
            try? fm.removeItem(at: dest.appendingPathComponent(name))
            try fm.moveItem(at: src, to: dest.appendingPathComponent(name))
            files[kind.rawValue] = name
        }
        guard !files.isEmpty else { throw StemError.noOutput }
        progress(1)
        return StemSet(engine: .demucs, model: model.rawValue, files: files, createdAt: Date())
    }

    /// Tracks tqdm progress across multiple bars (bag-of-models runs several).
    private final class ProgressState: @unchecked Sendable {
        private var bar = 0
        private var last = 0.0
        private let lock = NSLock()
        func update(_ pct: Double) -> Double {
            lock.lock(); defer { lock.unlock() }
            if pct + 50 < last { bar += 1 }
            last = pct
            return Double(bar) + pct / 100
        }
    }

    static func clear(_ dir: URL) {
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: f)
        }
    }

    // MARK: - Built-in separator

    /// Quick 4-stem separation (vocals, drums, bass, other).
    /// * drums  = percussive part (median filtering across frequency)
    /// * bass   = harmonic part below ~200 Hz
    /// * vocals = harmonic, centre-panned part in the vocal range
    /// * other  = everything else
    /// Works best on stereo mixes with centred vocals.
    static func separateBuiltin(input: URL, songID: String, progress: @escaping (Double) -> Void) throws -> StemSet {
        let file = try AVAudioFile(forReading: input)
        let sr = file.processingFormat.sampleRate
        let (L, R) = try AudioFileTools.readStereo(file)
        let N = L.count
        guard N > 8192 else { throw StemError.unsupported }

        let n = 4096, hop = 1024, half = n / 2
        let log2n: vDSP_Length = 12
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { throw AnalysisError.fftSetup }
        defer { vDSP_destroy_fftsetup(setup) }
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        let outScale: Float = 1 / (2 * Float(n) * 1.5)       // zrip round-trip (2n) × Hann² overlap at 75 % (1.5)

        // Pad by n on both sides so the edges reconstruct perfectly.
        let padded = N + 2 * n
        let frames = (padded - n) / hop + 1
        func sample(_ x: [Float], _ i: Int) -> Float { let j = i - n; return (j >= 0 && j < N) ? x[j] : 0 }

        // Per-bin static weights.
        var bassW = [Float](repeating: 0, count: half)
        var vocalBand = [Float](repeating: 0, count: half)
        for k in 0..<half {
            let f = Float(Double(k) * sr / Double(n))
            bassW[k] = min(1, max(0, (220 - f) / 100))
            vocalBand[k] = min(1, max(0, (f - 120) / 80)) * min(1, max(0, (11_000 - f) / 3000))
        }

        // Output files
        let kinds: [StemKind] = [.vocals, .drums, .bass, .other]
        let dest = LibraryPaths.stems(songID)
        clear(dest)
        var outFiles: [AVAudioFile] = []
        for k in kinds {
            outFiles.append(try AudioFileTools.makeWAVWriter(url: dest.appendingPathComponent("\(k.rawValue).wav"),
                                                             sampleRate: sr, channels: 2, bitDepth: 16))
        }
        let S = kinds.count

        let core = 256, halo = 12
        // accumulators: [stem][channel] covering core*hop + n samples
        let accLen = core * hop + n
        var acc = [[[Float]]](repeating: [[Float]](repeating: [Float](repeating: 0, count: accLen), count: 2), count: S)
        var accStart = 0          // padded-sample index of acc[.][.][0]
        var written = 0           // original samples written so far

        var frameBuf = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
        var tmpRe = [Float](repeating: 0, count: half), tmpIm = [Float](repeating: 0, count: half)
        var timeOut = [Float](repeating: 0, count: n)
        var masks = [[Float]](repeating: [Float](repeating: 0, count: half), count: 4)

        func forward(_ x: [Float], frame f: Int, into reOut: inout [Float], _ imOut: inout [Float]) {
            for i in 0..<n { frameBuf[i] = sample(x, f * hop + i) * window[i] }
            reOut.withUnsafeMutableBufferPointer { rp in
                imOut.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frameBuf.withUnsafeBufferPointer { fp in
                        fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }
        }

        func inverse(_ reIn: inout [Float], _ imIn: inout [Float]) {
            reIn.withUnsafeMutableBufferPointer { rp in
                imIn.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                    timeOut.withUnsafeMutableBufferPointer { tp in
                        tp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                            vDSP_ztoc(&split, 1, cp, 2, vDSP_Length(half))
                        }
                    }
                }
            }
        }

        var chunkStart = 0
        while chunkStart < frames {
            let chunkEnd = min(frames, chunkStart + core)
            let a = max(0, chunkStart - halo), b = min(frames, chunkEnd + halo)
            let m = b - a

            // STFT of both channels for the chunk (+ halo)
            var specLr = [Float](repeating: 0, count: m * half), specLi = specLr
            var specRr = specLr, specRi = specLr
            var mag = specLr
            for (row, f) in (a..<b).enumerated() {
                forward(L, frame: f, into: &re, &im)
                forward(R, frame: f, into: &tmpRe, &tmpIm)
                let base = row * half
                for k in 0..<half {
                    specLr[base + k] = re[k]; specLi[base + k] = im[k]
                    specRr[base + k] = tmpRe[k]; specRi[base + k] = tmpIm[k]
                    let ml = sqrt(re[k] * re[k] + im[k] * im[k])
                    let mr = sqrt(tmpRe[k] * tmpRe[k] + tmpIm[k] * tmpIm[k])
                    mag[base + k] = 0.5 * (ml + mr)
                }
            }

            // Harmonic (median over time) and percussive (median over frequency) envelopes
            let harm = MetalCompute.medianFilter(mag, frames: m, bins: half, alongTime: true, radius: 12)
                ?? cpuMedian(mag, frames: m, bins: half, alongTime: true, radius: 4)
            let perc = MetalCompute.medianFilter(mag, frames: m, bins: half, alongTime: false, radius: 12)
                ?? cpuMedian(mag, frames: m, bins: half, alongTime: false, radius: 4)

            for f in chunkStart..<chunkEnd {
                let row = f - a
                let base = row * half
                // 1) masks for this frame (computed once, shared by both channels)
                for k in 0..<half {
                    let h2 = harm[base + k] * harm[base + k]
                    let p2 = perc[base + k] * perc[base + k]
                    // three-way split with a separation margin (β = 2):
                    // steady tones → harmonic, broadband hits → percussive, the rest (vibrato,
                    // sliding voices, noise) → residual
                    let mh = h2 / (h2 + 4 * p2 + 1e-12)
                    let mp = p2 / (p2 + 4 * h2 + 1e-12)
                    let mr = max(0, 1 - mh - mp)

                    let lr = specLr[base + k], li = specLi[base + k]
                    let rr = specRr[base + k], ri = specRi[base + k]
                    let cross = lr * rr + li * ri
                    let energy = lr * lr + li * li + rr * rr + ri * ri
                    let psi = max(0, min(1, 2 * cross / (energy + 1e-12)))
                    let center = psi * psi * psi * psi

                    let mDrums = mp
                    let mBass = (mh + mr) * bassW[k]
                    let mVocal = (mr + 0.6 * mh) * (1 - bassW[k]) * center * vocalBand[k]
                    masks[0][k] = mVocal
                    masks[1][k] = mDrums
                    masks[2][k] = mBass
                    masks[3][k] = max(0, 1 - mVocal - mDrums - mBass)
                }
                // 2) apply masks and resynthesise every stem / channel
                for s in 0..<S {
                    for ch in 0..<2 {
                        for k in 0..<half {
                            let mask = masks[s][k]
                            tmpRe[k] = (ch == 0 ? specLr[base + k] : specRr[base + k]) * mask
                            tmpIm[k] = (ch == 0 ? specLi[base + k] : specRi[base + k]) * mask
                        }
                        inverse(&tmpRe, &tmpIm)
                        let offset = f * hop - accStart
                        for i in 0..<n {
                            acc[s][ch][offset + i] += timeOut[i] * window[i] * outScale
                        }
                    }
                }
            }

            // Samples before chunkEnd*hop are complete → write them.
            let readyEnd = chunkEnd == frames ? accStart + accLen : chunkEnd * hop
            let readyCount = readyEnd - accStart
            var origFrom = accStart - n, origTo = readyEnd - n
            origFrom = max(origFrom, written); origTo = min(origTo, N)
            if origTo > origFrom {
                let count = origTo - origFrom
                let localStart = origFrom + n - accStart
                for s in 0..<S {
                    guard let buf = AVAudioPCMBuffer(pcmFormat: outFiles[s].processingFormat, frameCapacity: AVAudioFrameCount(count)),
                          let chData = buf.floatChannelData else { continue }
                    buf.frameLength = AVAudioFrameCount(count)
                    for ch in 0..<2 {
                        acc[s][ch].withUnsafeBufferPointer { src in
                            chData[ch].update(from: src.baseAddress! + localStart, count: count)
                        }
                    }
                    try outFiles[s].write(from: buf)
                }
                written = origTo
            }
            // carry the tail
            let carry = accLen - readyCount
            for s in 0..<S {
                for ch in 0..<2 {
                    if carry > 0 {
                        let tail = Array(acc[s][ch][readyCount..<accLen])
                        for i in 0..<accLen { acc[s][ch][i] = i < carry ? tail[i] : 0 }
                    } else {
                        for i in 0..<accLen { acc[s][ch][i] = 0 }
                    }
                }
            }
            accStart = readyEnd
            chunkStart = chunkEnd
            progress(Double(chunkStart) / Double(frames))
        }

        var files: [String: String] = [:]
        for k in kinds { files[k.rawValue] = "\(k.rawValue).wav" }
        return StemSet(engine: .builtin, model: "builtin-hpss", files: files, createdAt: Date())
    }

    private static func cpuMedian(_ x: [Float], frames: Int, bins: Int, alongTime: Bool, radius: Int) -> [Float] {
        var out = [Float](repeating: 0, count: x.count)
        var window = [Float](repeating: 0, count: 2 * radius + 1)
        for f in 0..<frames {
            for b in 0..<bins {
                for k in -radius...radius {
                    let ff = alongTime ? min(frames - 1, max(0, f + k)) : f
                    let bb = alongTime ? b : min(bins - 1, max(0, b + k))
                    window[k + radius] = x[ff * bins + bb]
                }
                window.sort()
                out[f * bins + b] = window[radius]
            }
        }
        return out
    }
}

// MARK: - Audio file helpers

enum AudioFileTools {
    /// Reads any file as two Float channels (mono is duplicated).
    static func readStereo(_ file: AVAudioFile) throws -> ([Float], [Float]) {
        let format = file.processingFormat
        let total = Int(file.length)
        var L = [Float](), R = [Float]()
        L.reserveCapacity(total); R.reserveCapacity(total)
        let cap: AVAudioFrameCount = 65_536
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { throw StemError.unsupported }
        file.framePosition = 0
        while file.framePosition < file.length {
            try file.read(into: buf, frameCount: cap)
            let n = Int(buf.frameLength)
            guard n > 0, let ch = buf.floatChannelData else { break }
            L.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: n))
            let right = format.channelCount > 1 ? ch[1] : ch[0]
            R.append(contentsOf: UnsafeBufferPointer(start: right, count: n))
        }
        return (L, R)
    }

    static func makeWAVWriter(url: URL, sampleRate: Double, channels: Int, bitDepth: Int) throws -> AVAudioFile {
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: bitDepth,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        return try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// Converts any readable file to a 16-bit WAV with the same rate/channels.
    static func writeWAV(from input: URL, to output: URL) throws {
        let src = try AVAudioFile(forReading: input)
        let format = src.processingFormat
        let dst = try makeWAVWriter(url: output, sampleRate: format.sampleRate,
                                    channels: Int(format.channelCount), bitDepth: 16)
        let cap: AVAudioFrameCount = 65_536
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { throw StemError.unsupported }
        while src.framePosition < src.length {
            try src.read(into: buf, frameCount: cap)
            if buf.frameLength == 0 { break }
            try dst.write(from: buf)
        }
    }
}
