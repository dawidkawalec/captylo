import AppKit
import SwiftUI
import SwiftData
import ServiceManagement

// MARK: - Glass with fallback (deployment target macOS 14)
struct GlassBackground<S: Shape>: ViewModifier {
    var shape: S
    var tint: Color? = nil
    var interactive = false
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.18), lineWidth: 0.5))
        }
    }
}
extension View {
    func vtGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassBackground(shape: shape, tint: tint, interactive: interactive))
    }
}

struct PillWidget: View {
    @Namespace private var ns
    @State var recording = false
    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform").frame(width: 28, height: 28)
                            .glassEffect(.regular.interactive(), in: .circle)
                            .glassEffectID("wave", in: ns)
                        if recording {
                            Text("00:03").monospacedDigit().padding(.horizontal, 10).frame(height: 28)
                                .glassEffect(.clear.tint(.red.opacity(0.25)), in: .capsule)
                                .glassEffectID("timer", in: ns)
                                .glassEffectTransition(.matchedGeometry)
                        }
                    }
                }
                Button("Stop") { recording.toggle() }.buttonStyle(.glassProminent)
                Button("Cancel") { }.buttonStyle(.glass)
            } else {
                HStack { Image(systemName: "waveform"); if recording { Text("00:03") } }
                    .padding(8).vtGlass(in: Capsule())
                Button("Stop") { recording.toggle() }.buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: - NSVisualEffectView wrapper (macOS 14/15 fallback when you need .hudWindow / behindWindow blur)
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material; v.blendingMode = blending; v.state = .active
        v.wantsLayer = true; v.layer?.cornerRadius = 22; v.layer?.masksToBounds = true
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material; v.blendingMode = blending }
}

// MARK: - Floating borderless non-activating panel
final class FloatingPanel: NSPanel {
    init<Content: View>(rootView: Content) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 220, height: 56),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating                     // or .statusBar to sit above full-screen apps' menus
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true                      // shadow follows the opaque pixels of the SwiftUI content
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        animationBehavior = .utilityWindow
        // Fixed transparent canvas; SwiftUI animates the pill inside it (no window-resize jank).
        // appearsActive=true: attempt to keep "active" glass rendering in a non-key panel (UNVERIFIED visually).
        let host = NSHostingView(rootView: rootView.environment(\.appearsActive, true).ignoresSafeArea())
        host.sizingOptions = []            // default is .standardBounds (min+intrinsic+max, updates window min/max)
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        contentView = host
    }
    override var canBecomeKey: Bool { true }   // allow text input; return false for a pure HUD
    override var canBecomeMain: Bool { false }
}

@MainActor
func showPanelBottomCenter(_ panel: NSPanel) {
    guard let screen = NSScreen.main else { return }
    let f = screen.visibleFrame
    let size = panel.frame.size
    panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.minY + 24))
    panel.orderFrontRegardless()      // shows without activating the app
}

@MainActor
func refreshShadow(_ panel: NSPanel) { panel.invalidateShadow() }  // call after the visible shape changes

// MARK: - Launch at login
@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) throws {
        if on {
            if SMAppService.mainApp.status == .enabled { return }
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }
    static func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

// MARK: - SwiftData with custom store URL
@Model
final class Transcription {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var text: String
    var enhancedText: String?
    var durationSeconds: Double
    var wordCount: Int
    var audioFileName: String?
    init(id: UUID = UUID(), createdAt: Date = .now, text: String, enhancedText: String? = nil, durationSeconds: Double, wordCount: Int, audioFileName: String? = nil) {
        self.id = id; self.createdAt = createdAt; self.text = text; self.enhancedText = enhancedText
        self.durationSeconds = durationSeconds; self.wordCount = wordCount; self.audioFileName = audioFileName
    }
}

enum Store {
    static func makeContainer(appSupportFolder: String = "VocaType2") throws -> ModelContainer {
        let base = URL.applicationSupportDirectory.appending(path: appSupportFolder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appending(path: "VocaType.store")
        let schema = Schema([Transcription.self])
        let config = ModelConfiguration("VocaType", schema: schema, url: url, allowsSave: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }
}
