import AppKit
import SwiftUI

/// "Gradient": a slow animated dusk sky in the brand palette (night, navy, indigo, violet,
/// orchid, rose, peach, horizon glow), dark enough for white type, under a light scrim and a
/// vignette.
///
/// Three compositions of the sky (`AuroraSky`: a 4 x 4 `MeshGradient` on macOS 15+, soft
/// drifting glows on macOS 14) are rendered once into small bitmaps, then Core Animation
/// cross-fades and drifts them (`AuroraLayerView`) over one `GlassTokens.Aurora.period`. The
/// motion runs in the render server, so the app does no work per frame (a SwiftUI
/// `TimelineView` cost about 6 % CPU whatever its frame rate). It animates only while its window
/// is key in the active app and holds a still frame otherwise and with Reduce Motion.
@MainActor
struct AuroraBackdrop: View {
    var scrim: Double
    var vignette: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                AuroraLayerView(
                    frames: AuroraFrames.shared,
                    isAnimating: !reduceMotion && controlActiveState == .key,
                    isStill: reduceMotion
                )

                // Darker under the titles, a touch darker at the bottom.
                LinearGradient(
                    stops: [
                        .init(color: Color.black.opacity(min(scrim * 1.8, 0.8)), location: 0),
                        .init(color: Color.black.opacity(scrim), location: 0.22),
                        .init(color: Color.black.opacity(scrim * 0.6), location: 0.6),
                        .init(color: Color.black.opacity(scrim * 1.1), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                if vignette {
                    RadialGradient(
                        colors: [.clear, Color.black.opacity(0.9 * scrim)],
                        center: .center,
                        startRadius: min(proxy.size.width, proxy.size.height) * 0.35,
                        endRadius: max(proxy.size.width, proxy.size.height) * 0.8
                    )
                }
            }
        }
    }
}

// MARK: - Frames

/// The three sky compositions the layers blend between, rendered once for the whole app.
@MainActor
final class AuroraFrames {
    static let shared = AuroraFrames()

    /// Bitmap size of one composition: a smooth gradient scales up without visible loss.
    static let pixelSize = CGSize(width: 480, height: 320)
    /// Phases of `AuroraSky` the three layers show (the first is the still frame).
    static let phases: [Double] = [0.18, 0.51, 0.84]

    let images: [CGImage]

    private init() {
        images = Self.phases.compactMap { phase in
            let renderer = ImageRenderer(
                content: AuroraSky(phase: phase)
                    .frame(width: Self.pixelSize.width, height: Self.pixelSize.height)
            )
            renderer.scale = 1
            return renderer.cgImage
        }
    }
}

// MARK: - Layers

/// Core Animation host of the sky: the first composition as the base, the other two fading in
/// and out above it in turn, each layer slowly drifting and breathing on its own cycle.
@MainActor
private struct AuroraLayerView: NSViewRepresentable {
    var frames: AuroraFrames
    var isAnimating: Bool
    var isStill: Bool

    func makeNSView(context: Context) -> AuroraLayerHostView {
        let view = AuroraLayerHostView(images: frames.images)
        view.update(isAnimating: isAnimating, isStill: isStill)
        return view
    }

    func updateNSView(_ nsView: AuroraLayerHostView, context: Context) {
        nsView.update(isAnimating: isAnimating, isStill: isStill)
    }
}

final class AuroraLayerHostView: NSView {
    /// The layers overscan the view so the drift never shows an edge (kept small: the warm
    /// horizon sits in the bottom band of the compositions).
    private static let overscan: CGFloat = 0.05

    private let skyLayers: [CALayer]
    private var hasAnimations = false
    private var isStill = false

    init(images: [CGImage]) {
        skyLayers = images.map { image in
            let layer = CALayer()
            layer.contents = image
            layer.contentsGravity = .resize
            layer.minificationFilter = .linear
            layer.magnificationFilter = .linear
            return layer
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(GlassColor.night).cgColor
        layer?.masksToBounds = true
        for (index, sky) in skyLayers.enumerated() {
            sky.opacity = index == 0 ? 1 : 0
            layer?.addSublayer(sky)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let inset = -max(bounds.width, bounds.height) * Self.overscan
        for sky in skyLayers {
            sky.frame = bounds.insetBy(dx: inset, dy: inset)
        }
        CATransaction.commit()
    }

    func update(isAnimating: Bool, isStill: Bool) {
        guard let root = layer else { return }
        if isStill != self.isStill || !hasAnimations {
            self.isStill = isStill
            isStill ? removeAnimations() : addAnimations()
        }
        guard !isStill else { return }
        if isAnimating, root.speed == 0 {
            // Resume where it stopped.
            let paused = root.timeOffset
            root.speed = 1
            root.timeOffset = 0
            root.beginTime = 0
            root.beginTime = root.convertTime(CACurrentMediaTime(), from: nil) - paused
        } else if !isAnimating, root.speed != 0 {
            let now = root.convertTime(CACurrentMediaTime(), from: nil)
            root.speed = 0
            root.timeOffset = now
        }
    }

    private func removeAnimations() {
        hasAnimations = true
        for (index, sky) in skyLayers.enumerated() {
            sky.removeAllAnimations()
            sky.opacity = index == 0 ? 1 : 0
        }
    }

    private func addAnimations() {
        hasAnimations = true
        let period = GlassTokens.Aurora.period
        for (index, sky) in skyLayers.enumerated() {
            sky.removeAllAnimations()

            // Cross-fade: the second and third compositions take over in turn, then give the
            // sky back to the first.
            if index > 0 {
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = index == 1 ? [0, 1, 0, 0] : [0, 0, 1, 0]
                fade.keyTimes = [0, 0.33, 0.66, 1]
                fade.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 3)
                fade.duration = period
                fade.repeatCount = .infinity
                sky.add(fade, forKey: "fade")
            }

            // Drift: a slow ellipse per layer, at periods that never line up.
            let drift = CAKeyframeAnimation(keyPath: "transform.translation")
            let radius = CGSize(width: 30 + 10 * Double(index), height: 18 + 6 * Double(index))
            drift.values = (0...12).map { step in
                let angle = Double(step) / 12 * 2 * .pi + Double(index) * 2.1
                return NSValue(size: CGSize(width: radius.width * cos(angle), height: radius.height * sin(angle)))
            }
            drift.duration = period * (1.3 + 0.37 * Double(index))
            drift.repeatCount = .infinity
            drift.calculationMode = .cubic
            sky.add(drift, forKey: "drift")

            // Breathing scale.
            let breathe = CABasicAnimation(keyPath: "transform.scale")
            breathe.fromValue = 1.0
            breathe.toValue = 1.06 + 0.02 * Double(index)
            breathe.duration = period * (0.7 + 0.23 * Double(index))
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            sky.add(breathe, forKey: "breathe")
        }
    }
}

// MARK: - Palette

/// Brand colours of the aurora (`branding/palette.json`), as RGB for mixing.
enum AuroraPalette {
    typealias RGB = SIMD3<Double>

    static let night = RGB(20, 22, 46) / 255
    static let duskNavy = RGB(35, 40, 90) / 255
    static let indigo = RGB(58, 57, 147) / 255
    static let violet = RGB(111, 107, 216) / 255
    static let orchid = RGB(162, 119, 204) / 255
    static let rose = RGB(224, 132, 159) / 255
    static let peach = RGB(245, 154, 100) / 255
    static let horizonGlow = RGB(255, 180, 106) / 255

    /// `color` pulled toward night: 0 = night, 1 = the full colour.
    static func dim(_ color: RGB, _ amount: Double) -> RGB {
        night + (color - night) * amount
    }

    static func color(_ rgb: RGB) -> Color {
        Color(.sRGB, red: rgb.x, green: rgb.y, blue: rgb.z, opacity: 1)
    }
}

// MARK: - Sky

/// One composition of the sky at `phase` (0..<1 around the loop).
@MainActor
private struct AuroraSky: View {
    var phase: Double

    var body: some View {
        if #available(macOS 15.0, *), !GlassTokens.forcesFallback {
            AuroraMesh(phase: phase)
        } else {
            AuroraGlows(phase: phase)
        }
    }
}

@available(macOS 15.0, *)
@MainActor
private struct AuroraMesh: View {
    var phase: Double

    private typealias P = AuroraPalette

    /// Two dusk skies the mesh mixes between, rows top to bottom: night above, violet in the
    /// middle, a dimmed warm horizon low in the window, glows moving from right to left.
    private static let skyA: [P.RGB] = [
        P.night, P.duskNavy, P.night, P.night,
        P.duskNavy, P.dim(P.indigo, 0.85), P.dim(P.violet, 0.6), P.night,
        P.dim(P.indigo, 0.5), P.dim(P.orchid, 0.55), P.dim(P.indigo, 0.7), P.dim(P.rose, 0.6),
        P.night, P.dim(P.rose, 0.65), P.dim(P.peach, 0.62), P.dim(P.orchid, 0.45),
    ]

    private static let skyB: [P.RGB] = [
        P.night, P.night, P.duskNavy, P.night,
        P.dim(P.indigo, 0.6), P.dim(P.violet, 0.6), P.dim(P.indigo, 0.8), P.duskNavy,
        P.dim(P.rose, 0.6), P.dim(P.indigo, 0.6), P.dim(P.orchid, 0.6), P.dim(P.indigo, 0.45),
        P.dim(P.horizonGlow, 0.55), P.dim(P.orchid, 0.5), P.dim(P.rose, 0.6), P.night,
    ]

    var body: some View {
        MeshGradient(
            width: 4,
            height: 4,
            points: Self.points(phase: phase),
            colors: Self.colors(phase: phase),
            smoothsColors: true
        )
    }

    /// Corners stay put, edge points slide along their edge, the four inner points orbit.
    private static func points(phase: Double) -> [SIMD2<Float>] {
        let angle = phase * 2 * .pi
        var points: [SIMD2<Float>] = []
        points.reserveCapacity(16)
        for row in 0..<4 {
            for column in 0..<4 {
                var x = Double(column) / 3
                var y = Double(row) / 3
                let seed = Double(row * 4 + column)
                let isEdgeX = column == 0 || column == 3
                let isEdgeY = row == 0 || row == 3
                switch (isEdgeX, isEdgeY) {
                case (true, true):
                    break
                case (false, true):
                    x += 0.07 * sin(angle + seed * 1.3)
                case (true, false):
                    y += 0.07 * cos(angle + seed * 0.9)
                case (false, false):
                    x += 0.11 * sin(angle + seed * 1.7)
                    y += 0.09 * cos(angle * 2 + seed * 1.1)
                }
                points.append(SIMD2(Float(x), Float(y)))
            }
        }
        return points
    }

    private static func colors(phase: Double) -> [Color] {
        let angle = phase * 2 * .pi
        return (0..<16).map { index in
            let mix = 0.5 + 0.5 * sin(angle + Double(index) * 0.55)
            return P.color(skyA[index] + (skyB[index] - skyA[index]) * mix)
        }
    }
}

/// macOS 14 has no `MeshGradient`: four large soft radial glows over a night base.
@MainActor
private struct AuroraGlows: View {
    var phase: Double

    private typealias P = AuroraPalette

    private struct Glow {
        var color: P.RGB
        var opacity: Double
        /// Resting centre (unit square) and drift radius.
        var center: CGPoint
        var drift: CGSize
        var size: Double
        var turns: Double
        var offset: Double
    }

    private static let glows: [Glow] = [
        Glow(color: P.indigo, opacity: 0.85, center: CGPoint(x: 0.25, y: 0.35), drift: CGSize(width: 0.12, height: 0.08), size: 1.1, turns: 1, offset: 0),
        Glow(color: P.violet, opacity: 0.45, center: CGPoint(x: 0.75, y: 0.45), drift: CGSize(width: 0.10, height: 0.10), size: 0.9, turns: 1, offset: 2.1),
        Glow(color: P.rose, opacity: 0.38, center: CGPoint(x: 0.3, y: 0.95), drift: CGSize(width: 0.14, height: 0.05), size: 0.9, turns: 1, offset: 4.2),
        Glow(color: P.peach, opacity: 0.30, center: CGPoint(x: 0.8, y: 1.0), drift: CGSize(width: 0.10, height: 0.05), size: 0.8, turns: 2, offset: 1.0),
    ]

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let extent = max(size.width, size.height)
            ZStack {
                LinearGradient(
                    colors: [P.color(P.night), P.color(P.duskNavy)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                ForEach(Self.glows.indices, id: \.self) { index in
                    let glow = Self.glows[index]
                    let angle = phase * 2 * .pi * glow.turns + glow.offset
                    let diameter = extent * glow.size
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [P.color(glow.color).opacity(glow.opacity), P.color(glow.color).opacity(0)],
                                center: .center,
                                startRadius: 0,
                                endRadius: diameter / 2
                            )
                        )
                        .frame(width: diameter, height: diameter)
                        .position(
                            x: size.width * (glow.center.x + glow.drift.width * sin(angle)),
                            y: size.height * (glow.center.y + glow.drift.height * cos(angle))
                        )
                }
            }
        }
        .clipped()
    }
}
