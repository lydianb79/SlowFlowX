import Accelerate
import AVFoundation

/// Receives buffers from an AVAudioEngine tap and produces log-spaced band levels (0...1)
/// for the real-time Metal spectrum view.
final class SpectrumTap: @unchecked Sendable {
    static let bandCount = 48

    private let lock = NSLock()
    private var levels = [Float](repeating: 0, count: SpectrumTap.bandCount)
    private let n = 2048
    private let log2n: vDSP_Length = 11
    private let setup: FFTSetup
    private let window: [Float]

    init() {
        setup = vDSP_create_fftsetup(11, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: 2048, isHalfWindow: false)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        let half = n / 2
        let m = min(count, n)
        let chCount = Int(buffer.format.channelCount)

        var frame = [Float](repeating: 0, count: n)
        for c in 0..<chCount {
            let p = channels[c]
            for i in 0..<m { frame[i] += p[i] }
        }
        if chCount > 1 { frame = vDSP.multiply(1 / Float(chCount), frame) }
        frame = vDSP.multiply(frame, window)

        var re = [Float](repeating: 0, count: half)
        var im = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBufferPointer { fp in
                    fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                power.withUnsafeMutableBufferPointer { pp in
                    vDSP_zvmags(&split, 1, pp.baseAddress!, 1, vDSP_Length(half))
                }
            }
        }

        let sr = buffer.format.sampleRate
        let fMin = 40.0, fMax = min(16_000.0, sr / 2)
        let norm = Float(n * n)
        var out = [Float](repeating: 0, count: Self.bandCount)
        for b in 0..<Self.bandCount {
            let lo = fMin * pow(fMax / fMin, Double(b) / Double(Self.bandCount))
            let hi = fMin * pow(fMax / fMin, Double(b + 1) / Double(Self.bandCount))
            var k0 = Int(lo * Double(n) / sr), k1 = Int(hi * Double(n) / sr)
            k0 = max(1, min(k0, half - 1)); k1 = max(k0 + 1, min(k1, half))
            var sum: Float = 0
            for k in k0..<k1 { sum += power[k] }
            let p = sum / Float(k1 - k0) / norm
            let db = 10 * log10(p + 1e-12)
            // tilt so high bands are visible (music spectra fall ~3 dB/oct)
            let tilt = Float(b) / Float(Self.bandCount) * 18
            out[b] = max(0, min(1, (db + tilt + 78) / 62))
        }
        lock.lock(); levels = out; lock.unlock()
    }

    func snapshot() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return levels
    }

    func reset() {
        lock.lock(); levels = [Float](repeating: 0, count: Self.bandCount); lock.unlock()
    }
}
