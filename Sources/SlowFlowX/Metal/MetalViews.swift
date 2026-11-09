import SwiftUI
import MetalKit

/// MTKView that lets mouse events fall through to SwiftUI gesture overlays.
final class PassthroughMTKView: MTKView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private func makeMetalView(delegate: MTKViewDelegate, clear: RGB) -> MTKView {
    let view = PassthroughMTKView(frame: .zero, device: MetalContext.shared?.device)
    configure(view, delegate: delegate, clear: clear)
    return view
}

private func configure(_ view: MTKView, delegate: MTKViewDelegate, clear: RGB) {
    view.colorPixelFormat = MetalContext.pixelFormat
    view.framebufferOnly = true
    view.enableSetNeedsDisplay = false
    view.isPaused = false
    view.preferredFramesPerSecond = 60
    view.clearColor = MTLClearColor(red: clear.r, green: clear.g, blue: clear.b, alpha: 1)
    view.delegate = delegate
    if let layer = view.layer as? CAMetalLayer {
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.isOpaque = true
    }
}

// MARK: - Waveform

private struct WaveUniforms {
    var waveColor: SIMD4<Float>
    var playedColor: SIMD4<Float>
    var playheadColor: SIMD4<Float>
    var bgColor: SIMD4<Float>
    var loopColor: SIMD4<Float>
    var size: SIMD2<Float>
    var progress: Float
    var loopA: Float
    var loopB: Float
    var peakCount: Float
    var scale: Float
    var hover: Float
    var viewStart: Float
    var viewEnd: Float
    var gridStep: Float
    var pad: Float = 0
}

/// Mouse / trackpad events reported by the waveform, in view coordinates (points, origin top-left).
struct WaveformEvents {
    var onHover: (CGFloat?) -> Void = { _ in }
    var onMouseDown: (CGFloat) -> Void = { _ in }
    var onDrag: (CGFloat, CGFloat) -> Void = { _, _ in }          // start x, current x
    var onMouseUp: (CGFloat, CGFloat, Bool) -> Void = { _, _, _ in } // start x, end x, didDrag
    var onScroll: (_ dx: CGFloat, _ dy: CGFloat, _ precise: Bool, _ zoomModifier: Bool, _ x: CGFloat) -> Void = { _, _, _, _, _ in }
    var onMagnify: (_ factor: CGFloat, _ x: CGFloat) -> Void = { _, _ in }
}

/// MTKView that handles clicks, drags, scroll-wheel/trackpad panning and pinch zoom itself.
final class InteractiveMTKView: MTKView {
    var events = WaveformEvents()
    private var dragStartX: CGFloat?
    private var didDrag = false
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    private func x(of event: NSEvent) -> CGFloat {
        min(max(convert(event.locationInWindow, from: nil).x, 0), bounds.width)
    }

    override func mouseMoved(with event: NSEvent) { events.onHover(x(of: event)) }
    override func mouseExited(with event: NSEvent) { events.onHover(nil) }

    override func mouseDown(with event: NSEvent) {
        let px = x(of: event)
        dragStartX = px
        didDrag = false
        events.onMouseDown(px)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartX else { return }
        let px = x(of: event)
        if abs(px - start) > 3 { didDrag = true }
        if didDrag { events.onDrag(start, px) }
        events.onHover(px)
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = dragStartX else { return }
        events.onMouseUp(start, x(of: event), didDrag)
        dragStartX = nil
        didDrag = false
    }

    override func scrollWheel(with event: NSEvent) {
        let zoomMod = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option)
        events.onScroll(event.scrollingDeltaX, event.scrollingDeltaY, event.hasPreciseScrollingDeltas, zoomMod, x(of: event))
    }

    override func magnify(with event: NSEvent) {
        events.onMagnify(1 + event.magnification, x(of: event))
    }
}

final class WaveformRenderer: NSObject, MTKViewDelegate {
    private(set) var peaksID: String = ""
    private var peaks: [Float] = []
    private var peaksBuffer: MTLBuffer?

    var progress: Float = 0
    var loopA: Float = -1
    var loopB: Float = -1
    var hover: Float = -1
    var viewStart: Float = 0
    var viewEnd: Float = 1
    var gridStep: Float = 0
    var theme: AppTheme = .midnight

    func setPeaks(_ p: [Float], id: String) {
        peaks = p
        peaksID = id
        peaksBuffer = nil
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let ctx = MetalContext.shared,
              let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cmd = ctx.queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }

        if peaksBuffer == nil {
            let data = peaks.isEmpty ? [Float(0)] : peaks
            peaksBuffer = ctx.device.makeBuffer(bytes: data, length: data.count * MemoryLayout<Float>.stride,
                                                options: .storageModeShared)
        }
        var u = WaveUniforms(
            waveColor: theme.subtext.simd(0.55),
            playedColor: theme.accent.simd(1),
            playheadColor: theme.accent2.simd(1),
            bgColor: theme.elevated.simd(1),
            loopColor: theme.accent2.simd(0.16),
            size: SIMD2<Float>(Float(view.drawableSize.width), Float(view.drawableSize.height)),
            progress: progress,
            loopA: loopA, loopB: loopB,
            peakCount: Float(peaks.count),
            scale: Float(view.window?.backingScaleFactor ?? 2),
            hover: hover,
            viewStart: viewStart, viewEnd: viewEnd,
            gridStep: gridStep)

        enc.setRenderPipelineState(ctx.wavePipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<WaveUniforms>.stride, index: 0)
        enc.setFragmentBuffer(peaksBuffer, offset: 0, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}

struct WaveformMetalView: NSViewRepresentable {
    var peaks: [Float]
    var peaksID: String
    var progress: Double
    var loopStart: Double?
    var loopEnd: Double?
    var hover: Double?
    var viewStart: Double = 0
    var viewEnd: Double = 1
    var gridStep: Double = 0
    var theme: AppTheme
    var events = WaveformEvents()

    func makeCoordinator() -> WaveformRenderer { WaveformRenderer() }

    func makeNSView(context: Context) -> MTKView {
        let view = InteractiveMTKView(frame: .zero, device: MetalContext.shared?.device)
        configure(view, delegate: context.coordinator, clear: theme.elevated)
        view.events = events
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        let r = context.coordinator
        if r.peaksID != peaksID { r.setPeaks(peaks, id: peaksID) }
        r.progress = Float(progress)
        r.loopA = Float(loopStart ?? -1)
        r.loopB = Float(loopEnd ?? -1)
        r.hover = Float(hover ?? -1)
        r.viewStart = Float(viewStart)
        r.viewEnd = Float(viewEnd)
        r.gridStep = Float(gridStep)
        r.theme = theme
        (view as? InteractiveMTKView)?.events = events
        view.clearColor = MTLClearColor(red: theme.elevated.r, green: theme.elevated.g, blue: theme.elevated.b, alpha: 1)
    }
}

// MARK: - Live spectrum

private struct SpecUniforms {
    var colorA: SIMD4<Float>
    var colorB: SIMD4<Float>
    var bgColor: SIMD4<Float>
    var size: SIMD2<Float>
    var bandCount: Float
    var scale: Float
}

final class SpectrumRenderer: NSObject, MTKViewDelegate {
    weak var tap: SpectrumTap?
    var isActive = false
    var theme: AppTheme = .midnight
    var background: RGB = AppTheme.midnight.surface
    private var display = [Float](repeating: 0, count: SpectrumTap.bandCount)

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let ctx = MetalContext.shared,
              let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cmd = ctx.queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }

        let target = (isActive ? tap?.snapshot() : nil) ?? [Float](repeating: 0, count: SpectrumTap.bandCount)
        for i in 0..<display.count {
            let t = i < target.count ? target[i] : 0
            if t > display[i] { display[i] += (t - display[i]) * 0.55 } else { display[i] = max(t, display[i] - 0.022) }
        }

        var u = SpecUniforms(
            colorA: theme.accent.simd(1),
            colorB: theme.accent2.simd(1),
            bgColor: background.simd(1),
            size: SIMD2<Float>(Float(view.drawableSize.width), Float(view.drawableSize.height)),
            bandCount: Float(display.count),
            scale: Float(view.window?.backingScaleFactor ?? 2))

        enc.setRenderPipelineState(ctx.spectrumPipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<SpecUniforms>.stride, index: 0)
        display.withUnsafeBytes { raw in
            enc.setFragmentBytes(raw.baseAddress!, length: raw.count, index: 1)
        }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}

struct SpectrumMetalView: NSViewRepresentable {
    var tap: SpectrumTap
    var isActive: Bool
    var theme: AppTheme

    func makeCoordinator() -> SpectrumRenderer { SpectrumRenderer() }

    func makeNSView(context: Context) -> MTKView {
        makeMetalView(delegate: context.coordinator, clear: theme.surface)
    }

    func updateNSView(_ view: MTKView, context: Context) {
        let r = context.coordinator
        r.tap = tap
        r.isActive = isActive
        r.theme = theme
        r.background = theme.surface
    }
}
