import AppKit
import MetalKit
import SwiftUI

/// "Ciemny" / "Jasny": the brand's animated grain gradient (Brand Direction 01, React Bits
/// "Grainient" with the owner's parameters from `GlassTokens.Grainient`), drawn by a Metal
/// fragment shader (`Grainient.metal`) in an `MTKView`. The GPU does all the work; the view
/// animates only while its window is key in the active app and holds its last frame otherwise and
/// with Reduce Motion. Without Metal it falls back to a static gradient in the same colours.
@MainActor
struct GrainientBackdrop: View {
    var palette: GlassTokens.Grainient.Palette
    /// Black wash over the gradient (`GlassTokens.Scrim`), 0 = none.
    var scrim: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        ZStack {
            if GrainientRenderer.isSupported {
                GrainientMetalView(palette: palette, isAnimating: !reduceMotion && controlActiveState == .key)
            } else {
                GrainientFallback(palette: palette)
            }
            if scrim > 0 {
                Color.black.opacity(scrim)
            }
        }
    }
}

/// Static stand-in when the Mac has no Metal device (virtual machines).
@MainActor
private struct GrainientFallback: View {
    var palette: GlassTokens.Grainient.Palette

    var body: some View {
        LinearGradient(
            colors: [Color(hex: palette.color1), Color(hex: palette.color2), Color(hex: palette.color3)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Metal view

@MainActor
private struct GrainientMetalView: NSViewRepresentable {
    var palette: GlassTokens.Grainient.Palette
    var isAnimating: Bool

    func makeCoordinator() -> GrainientRenderer? {
        let renderer = GrainientRenderer.make()
        renderer?.palette = palette
        return renderer
    }

    func makeNSView(context: Context) -> GrainientMTKView {
        let view = GrainientMTKView(frame: .zero, device: context.coordinator?.device)
        view.delegate = context.coordinator
        view.framebufferOnly = true
        view.colorPixelFormat = .bgra8Unorm
        // Tag the output as sRGB, so the hex colours land on screen as they do in the browser.
        (view.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        view.clearColor = MTLClearColor(red: 0.13, green: 0.14, blue: 0.19, alpha: 1)
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = GlassTokens.Grainient.framesPerSecond
        view.isPaused = !isAnimating
        return view
    }

    func updateNSView(_ view: GrainientMTKView, context: Context) {
        context.coordinator?.isAnimating = isAnimating
        if let renderer = context.coordinator, renderer.palette != palette {
            renderer.palette = palette
            // A paused view shows the new colours right away; a running one on its next frame.
            if view.isPaused {
                view.draw()
            }
        }
        guard view.isPaused == isAnimating else { return }
        view.isPaused = !isAnimating
        if !isAnimating {
            // Hold a fresh still frame (also the first frame of a window that opens unfocused).
            view.draw()
        }
    }
}

/// Renders at `GlassTokens.Grainient.renderScale` of the backing scale: the field is soft, and
/// full Retina resolution would only cost power.
@MainActor
final class GrainientMTKView: MTKView {
    override func layout() {
        super.layout()
        autoResizeDrawable = false
        let backing = window?.backingScaleFactor ?? 2
        let scale = min(backing, GlassTokens.Grainient.renderScale)
        let size = CGSize(width: max(1, (bounds.width * scale).rounded()), height: max(1, (bounds.height * scale).rounded()))
        guard drawableSize != size else { return }
        drawableSize = size
        if isPaused {
            draw()
        }
    }
}

// MARK: - Renderer

/// Mirrors `GrainientUniforms` in `Grainient.metal` field by field (same order, same alignment).
private struct GrainientUniforms {
    var color1: SIMD4<Float>
    var color2: SIMD4<Float>
    var color3: SIMD4<Float>
    var resolution: SIMD2<Float>
    var centerOffset: SIMD2<Float>
    var time: Float
    var timeSpeed: Float
    var colorBalance: Float
    var warpStrength: Float
    var warpFrequency: Float
    var warpSpeed: Float
    var warpAmplitude: Float
    var blendAngle: Float
    var blendSoftness: Float
    var rotationAmount: Float
    var noiseScale: Float
    var grainAmount: Float
    var grainScale: Float
    var grainAnimated: Float
    var contrast: Float
    var gamma: Float
    var saturation: Float
    var zoom: Float
}

@MainActor
final class GrainientRenderer: NSObject, MTKViewDelegate {
    /// One pipeline for the whole app, built on first use.
    private static let shared: (device: MTLDevice, queue: MTLCommandQueue, pipeline: MTLRenderPipelineState)? = {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "grainientVertex"),
              let fragment = library.makeFunction(name: "grainientFragment")
        else {
            Log.app.error("Grainient: Metal is unavailable, using the static fallback")
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            return (device, queue, try device.makeRenderPipelineState(descriptor: descriptor))
        } catch {
            Log.app.error("Grainient pipeline failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }()

    static var isSupported: Bool { shared != nil }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    var isAnimating = false
    var palette: GlassTokens.Grainient.Palette = GlassTokens.Grainient.dark
    /// Shader time in seconds. Advances only while animating, so a paused window resumes where it
    /// stopped instead of jumping. Starts mid-cycle, where the colours are already mixed.
    private var elapsed: Double = GlassTokens.Grainient.startTime
    private var lastFrame: CFTimeInterval?

    /// nil without Metal (the view then shows `GrainientFallback`).
    static func make() -> GrainientRenderer? {
        guard let shared else { return nil }
        return GrainientRenderer(device: shared.device, queue: shared.queue, pipeline: shared.pipeline)
    }

    private init(device: MTLDevice, queue: MTLCommandQueue, pipeline: MTLRenderPipelineState) {
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        if isAnimating, let lastFrame {
            // Clamp gaps (a window that was hidden) so the motion never skips ahead.
            elapsed += min(now - lastFrame, 0.1)
        }
        lastFrame = isAnimating ? now : nil

        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        var uniforms = Self.uniforms(palette: palette, size: view.drawableSize, time: Float(elapsed))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<GrainientUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    private static func uniforms(palette: GlassTokens.Grainient.Palette, size: CGSize, time: Float) -> GrainientUniforms {
        typealias P = GlassTokens.Grainient
        return GrainientUniforms(
            color1: rgba(palette.color1),
            color2: rgba(palette.color2),
            color3: rgba(palette.color3),
            resolution: SIMD2(Float(size.width), Float(size.height)),
            centerOffset: SIMD2(Float(P.centerX), Float(P.centerY)),
            time: time,
            timeSpeed: Float(P.timeSpeed),
            colorBalance: Float(palette.colorBalance),
            warpStrength: Float(P.warpStrength),
            warpFrequency: Float(P.warpFrequency),
            warpSpeed: Float(P.warpSpeed),
            warpAmplitude: Float(P.warpAmplitude),
            blendAngle: Float(P.blendAngle),
            blendSoftness: Float(P.blendSoftness),
            rotationAmount: Float(P.rotationAmount),
            noiseScale: Float(P.noiseScale),
            grainAmount: Float(P.grainAmount),
            grainScale: Float(P.grainScale),
            grainAnimated: P.grainAnimated ? 1 : 0,
            contrast: Float(palette.contrast),
            gamma: Float(palette.gamma),
            saturation: Float(P.saturation),
            zoom: Float(P.zoom)
        )
    }

    /// 0xRRGGBB to sRGB components in 0...1, exactly like the web version's `hexToRgb`.
    private static func rgba(_ hex: UInt32) -> SIMD4<Float> {
        SIMD4(
            Float((hex >> 16) & 0xFF) / 255,
            Float((hex >> 8) & 0xFF) / 255,
            Float(hex & 0xFF) / 255,
            1
        )
    }
}
