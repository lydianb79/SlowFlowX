import Metal
import MetalKit

/// Shared Metal device, queue and pipelines (render + compute).
final class MetalContext {
    static let shared: MetalContext? = MetalContext()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let wavePipeline: MTLRenderPipelineState
    let spectrumPipeline: MTLRenderPipelineState
    let foldPipeline: MTLComputePipelineState
    let scorePipeline: MTLComputePipelineState

    static let pixelFormat: MTLPixelFormat = .bgra8Unorm

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        do {
            let library = try device.makeLibrary(source: MetalShaders.source, options: nil)
            guard let vfn = library.makeFunction(name: "fullscreen_vertex"),
                  let waveFn = library.makeFunction(name: "waveform_fragment"),
                  let specFn = library.makeFunction(name: "spectrum_fragment"),
                  let foldFn = library.makeFunction(name: "fold_chroma"),
                  let scoreFn = library.makeFunction(name: "score_chords") else { return nil }

            func renderPipeline(_ fragment: MTLFunction) throws -> MTLRenderPipelineState {
                let desc = MTLRenderPipelineDescriptor()
                desc.vertexFunction = vfn
                desc.fragmentFunction = fragment
                desc.colorAttachments[0].pixelFormat = MetalContext.pixelFormat
                return try device.makeRenderPipelineState(descriptor: desc)
            }
            wavePipeline = try renderPipeline(waveFn)
            spectrumPipeline = try renderPipeline(specFn)
            foldPipeline = try device.makeComputePipelineState(function: foldFn)
            scorePipeline = try device.makeComputePipelineState(function: scoreFn)
        } catch {
            NSLog("SlowFlowX: Metal setup failed: \(error)")
            return nil
        }
    }
}

/// GPU implementations of the heavy, embarrassingly-parallel analysis steps.
enum MetalCompute {

    static func foldChroma(mags: [Float], frames: Int, bins: Int, binPC: [Int32], binWeight: [Float]) -> [Float]? {
        guard let ctx = MetalContext.shared, frames > 0, bins > 0 else { return nil }
        let d = ctx.device
        guard let magBuf = d.makeBuffer(bytes: mags, length: mags.count * 4, options: .storageModeShared),
              let pcBuf = d.makeBuffer(bytes: binPC, length: binPC.count * 4, options: .storageModeShared),
              let wBuf = d.makeBuffer(bytes: binWeight, length: binWeight.count * 4, options: .storageModeShared),
              let outBuf = d.makeBuffer(length: frames * 12 * 4, options: .storageModeShared),
              let cmd = ctx.queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { return nil }

        var dims = SIMD2<UInt32>(UInt32(frames), UInt32(bins))
        enc.setComputePipelineState(ctx.foldPipeline)
        enc.setBuffer(magBuf, offset: 0, index: 0)
        enc.setBuffer(pcBuf, offset: 0, index: 1)
        enc.setBuffer(wBuf, offset: 0, index: 2)
        enc.setBuffer(outBuf, offset: 0, index: 3)
        enc.setBytes(&dims, length: MemoryLayout<SIMD2<UInt32>>.size, index: 4)
        let tg = MTLSize(width: 64, height: 1, depth: 1)
        let groups = MTLSize(width: (frames + 63) / 64, height: 12, depth: 1)
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        guard cmd.status == .completed else { return nil }

        let ptr = outBuf.contents().bindMemory(to: Float.self, capacity: frames * 12)
        return Array(UnsafeBufferPointer(start: ptr, count: frames * 12))
    }

    static func scoreChords(chroma: [Float], frames: Int, templates: [Float], templateCount: Int) -> [Float]? {
        guard let ctx = MetalContext.shared, frames > 0, templateCount > 0 else { return nil }
        let d = ctx.device
        guard let cBuf = d.makeBuffer(bytes: chroma, length: chroma.count * 4, options: .storageModeShared),
              let tBuf = d.makeBuffer(bytes: templates, length: templates.count * 4, options: .storageModeShared),
              let outBuf = d.makeBuffer(length: frames * templateCount * 4, options: .storageModeShared),
              let cmd = ctx.queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { return nil }

        var dims = SIMD2<UInt32>(UInt32(frames), UInt32(templateCount))
        enc.setComputePipelineState(ctx.scorePipeline)
        enc.setBuffer(cBuf, offset: 0, index: 0)
        enc.setBuffer(tBuf, offset: 0, index: 1)
        enc.setBuffer(outBuf, offset: 0, index: 2)
        enc.setBytes(&dims, length: MemoryLayout<SIMD2<UInt32>>.size, index: 3)
        let tg = MTLSize(width: 64, height: 1, depth: 1)
        let groups = MTLSize(width: (frames + 63) / 64, height: templateCount, depth: 1)
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        guard cmd.status == .completed else { return nil }

        let ptr = outBuf.contents().bindMemory(to: Float.self, capacity: frames * templateCount)
        return Array(UnsafeBufferPointer(start: ptr, count: frames * templateCount))
    }
}
