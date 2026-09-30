# VocaType 2.0 - platform research (macOS 26.5 / Xcode 26.6 / Swift 6.3.3)

Environment verified on this Mac: Xcode 26.6 (17F113), Swift 6.3.3, SDK MacOSX26.5.sdk, macOS 26.5.2 (25F84), arm64.
XcodeGen is NOT installed (`brew install xcodegen` gives 2.46.0, the latest release). A standalone copy was downloaded
for testing into `scratchpad/port-notes/probe/xcg/xcodegen/bin/xcodegen`.
No code-signing identities in the keychain (`security find-identity -v -p codesigning` shows 0), so builds are ad-hoc.

Sources: signatures below were copied from the SDK `.swiftinterface` / ObjC headers (the most authoritative source),
plus Apple doc JSON (`developer.apple.com/tutorials/data/documentation/...json`) and a few community reports (linked).

Legend: [RUN] executed on this Mac, [TC] typechecked with `swiftc -swift-version 6`, [BUILD] built with xcodebuild, [DOC] from docs only.

Probe files you can reuse (all in `scratchpad/port-notes/probe/`):
- `app/Samples.swift` - glass + fallback modifier, pill widget, NSVisualEffectView wrapper, FloatingPanel, LaunchAtLogin, SwiftData store. [TC, deployment target 14.0]
- `LiveTranscriber.swift` - live mic -> SpeechAnalyzer + DictationTranscriber, Swift 6 clean. [TC, target 26.0]
- `fileprobe.swift` - file transcription, Polish. [RUN]
- `sd/main.swift` - SwiftData with custom URL. [RUN]
- `xcg/VTProbe/project.yml` - XcodeGen spec (SPM + entitlements + Info.plist + assets + hardened runtime + ad-hoc). [BUILD]

---

## 1. Liquid Glass in SwiftUI (macOS 26)

All in `SwiftUICore` (re-exported by `import SwiftUI`). Everything is `@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, *)`, `@available(visionOS, unavailable)`.

### Exact signatures (SDK 26.5)

```swift
// View modifier
nonisolated public func glassEffect(_ glass: Glass = .regular,
                                    in shape: some Shape = DefaultGlassEffectShape()) -> some View
public struct DefaultGlassEffectShape: Shape { public init() }   // = Capsule by default per docs

// Glass value
public struct Glass: Equatable, Sendable {
    public static var regular: Glass { get }
    public static var clear: Glass { get }
    public static var identity: Glass { get }      // "no glass", handy for toggling without changing view identity
    public func tint(_ color: Color?) -> Glass
    public func interactive(_ isEnabled: Bool = true) -> Glass
}

// Container (blends / morphs child glass shapes, better perf)
@MainActor public struct GlassEffectContainer<Content: View>: View {
    public init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content)
}

// Morphing / identity
nonisolated public func glassEffectID(_ id: (some Hashable & Sendable)?, in namespace: Namespace.ID) -> some View
@MainActor public func glassEffectUnion(id: (some Hashable & Sendable)?, namespace: Namespace.ID) -> some View
@MainActor public func glassEffectTransition(_ transition: GlassEffectTransition) -> some View
public struct GlassEffectTransition: Sendable {
    public static var matchedGeometry: GlassEffectTransition { get }   // default for shapes within container spacing
    public static var materialize: GlassEffectTransition { get }       // for shapes farther apart than spacing
    public static var identity: GlassEffectTransition { get }
}

// Button styles (in SwiftUI module)
extension PrimitiveButtonStyle where Self == GlassButtonStyle { static var glass: GlassButtonStyle }
extension PrimitiveButtonStyle where Self == GlassProminentButtonStyle { static var glassProminent: GlassProminentButtonStyle }
// usage: .buttonStyle(.glass) / .buttonStyle(.glassProminent)   (both macOS 26+)

// Related macOS 26 extras present in SDK
func backgroundExtensionEffect() -> some View
func backgroundExtensionEffect(isEnabled: Bool) -> some View
```

### Usage rules from Apple doc "Applying Liquid Glass to custom views" [DOC]
- `glassEffect()` defaults to `.regular` in a `Capsule`. Use `.rect(cornerRadius:)` for bigger panels.
- Apply `glassEffect` AFTER other appearance modifiers (it captures the content for the container to render).
- Put multiple glass views inside ONE `GlassEffectContainer` for performance and blending. Container `spacing` larger than
  the inner HStack/VStack spacing makes shapes merge at rest; animating views in/out morphs them.
- `glassEffectID(_:in:)` + `@Namespace` + `withAnimation {}` gives morphing when views appear/disappear.
- `glassEffectUnion(id:namespace:)` merges several views into one glass shape even at rest.
- Perf: "Creating too many Liquid Glass effect containers and applying too many effects to views outside of containers can degrade performance."
- Accessibility: honor `@Environment(\.accessibilityReduceTransparency)` (swap glass for opaque background).
- `UIDesignRequiresCompatibility` Info.plist key (macOS 26.0+): YES = run with pre-26 look. Ignored when building for macOS 27+. Do NOT set it for VocaType 2.0.

Doc sample (verbatim, shape + tint + interactive):
```swift
Text("Hello, World!").font(.title).padding().glassEffect()
Text("Hello, World!").font(.title).padding().glassEffect(in: .rect(cornerRadius: 16.0))
Text("Hello, World!").font(.title).padding().glassEffect(.regular.tint(.orange).interactive())
```

### AppKit equivalents (AppKit/NSGlassEffectView.h, macOS 26.0)
```objc
typedef NS_ENUM(NSInteger, NSGlassEffectViewStyle) { NSGlassEffectViewStyleRegular, NSGlassEffectViewStyleClear }  // Swift: NSGlassEffectView.Style
@interface NSGlassEffectView : NSView
@property (nullable, strong) __kindof NSView *contentView;
@property CGFloat cornerRadius;
@property (nullable, copy) NSColor *tintColor;
@property NSGlassEffectViewStyle style;
@end
@interface NSGlassEffectContainerView : NSView
@property (nullable, strong) __kindof NSView *contentView;
@property CGFloat spacing;
@end
```

### Fallback for macOS 14/15 [TC with deployment target 14.0]
```swift
struct GlassBackground<S: Shape>: ViewModifier {
    var shape: S; var tint: Color? = nil; var interactive = false
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
// Buttons: if #available(macOS 26, *) { .buttonStyle(.glassProminent) } else { .buttonStyle(.borderedProminent) }
```
Note: `GlassEffectContainer`, `.glass` button styles and `glassEffectID` must also sit behind `if #available(macOS 26.0, *)`.
A `@ViewBuilder` `if #available` branch compiles fine for a 14.0 target (verified).

NSVisualEffectView wrapper when you need behind-window blur on 14/15 (materials available: `.titlebar .selection .menu .popover .sidebar .headerView .sheet .windowBackground .hudWindow .fullScreenUI .toolTip .contentBackground .underWindowBackground .underPageBackground`):
```swift
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material; v.blendingMode = blending
        v.state = .active                     // otherwise it goes flat/inactive when the app is not frontmost
        v.wantsLayer = true; v.layer?.cornerRadius = 22; v.layer?.masksToBounds = true
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material; v.blendingMode = blending }
}
```
SwiftUI-only alternatives on 14/15: `.background(.ultraThinMaterial / .thinMaterial / .regularMaterial, in: shape)`;
`containerBackground(_:for: .window)` exists but `.window` placement is macOS 15.0+.

---

## 2. Transparent borderless floating NSPanel hosting SwiftUI glass

Relevant SDK facts:
- `NSWindow.StyleMask`: `.borderless = 0`, `.nonactivatingPanel = 1<<7` (NSPanel only), `.utilityWindow = 1<<4`, `.hudWindow = 1<<13`, `.fullSizeContentView = 1<<15`.
- `NSPanel`: `isFloatingPanel`, `becomesKeyOnlyIfNeeded`, `worksWhenModal`.
- `NSWindow.CollectionBehavior`: `.canJoinAllSpaces .moveToActiveSpace .managed .transient .stationary .participatesInCycle .ignoresCycle .fullScreenPrimary .fullScreenAuxiliary .fullScreenNone .fullScreenAllowsTiling .fullScreenDisallowsTiling .primary(13) .auxiliary(13) .canJoinAllApplications(13)`.
- `NSHostingView.sizingOptions: NSHostingSizingOptions` (macOS 13): `.minSize .intrinsicContentSize .maxSize .preferredContentSize .standardBounds`.
  Default is `.standardBounds` (min + intrinsic + max), and when the hosting view is the window's contentView it also
  updates the window's `contentMinSize`/`contentMaxSize`. `[]` = no constraints; if the frame is bigger than the content,
  content is centered. [DOC]
- SwiftUI scene-level alternatives: `.windowStyle(.plain)` (`PlainWindowStyle`, macOS 15.0+), `.windowLevel(.floating)` (`WindowLevel`: `.automatic .desktop .floating .normal`), `windowBackgroundDragBehavior(_:)`. For a non-activating widget, a hand-made NSPanel is still the right tool.

Recommended panel [TC]:
```swift
final class FloatingPanel: NSPanel {
    init<Content: View>(rootView: Content) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 220, height: 56),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],   // set nonactivating AT INIT
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating                     // .statusBar if it must sit above full-screen app menus
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true                      // window server derives shadow from content alpha
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        animationBehavior = .utilityWindow
        // Fixed transparent canvas; SwiftUI animates the pill inside it (no window-resize jank).
        let host = NSHostingView(rootView: rootView.environment(\.appearsActive, true).ignoresSafeArea())
        host.sizingOptions = []
        contentView = host
    }
    override var canBecomeKey: Bool { true }   // false for a pure HUD (no text input)
    override var canBecomeMain: Bool { false }
}

@MainActor func showPanelBottomCenter(_ panel: NSPanel) {
    guard let screen = NSScreen.main else { return }
    let f = screen.visibleFrame, size = panel.frame.size
    panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.minY + 24))
    panel.orderFrontRegardless()      // show without activating the app (do NOT call NSApp.activate)
}
// After the visible shape changes (pill expands/collapses): panel.invalidateShadow()
```
SwiftUI content: `PillView().padding(12)` (leave room for the shadow), glass via `.glassEffect(.regular, in: .capsule)` or `vtGlass(in: Capsule())`.

Known issues / gotchas:
- Glass in a non-activating NSPanel reportedly degrades to a plain blur when the app is not focused
  ([HWS forum](https://www.hackingwithswift.com/forums/swiftui/glasseffect-in-floating-window-panel/30067), no answer).
  Candidate mitigations, in order: (a) `.environment(\.appearsActive, true)` on the hosted root (settable, back-deployed to 10.15; UNVERIFIED visually);
  (b) host content in AppKit `NSGlassEffectView` as the panel contentView; (c) accept the inactive look. Test on device.
- macOS 26.2 regression: `NSGlassEffectView` in a borderless window with custom mouse dragging shows a cached backdrop
  ([Apple forum 810314](https://developer.apple.com/forums/thread/810314)). Setting `isMovable = true` +
  `isMovableByWindowBackground = true` fixes updates while moving the window itself. Prefer system dragging, not manual `mouseDragged` moves.
- A working non-activating Liquid Glass panel exists in the wild ([akira-foundation PR #68](https://github.com/akira-foundation/unified-dev-swift/pull/68)): one `.glassEffect(.regular)` platter, 26 pt corner radius, inner padding for shadow, Reduce Transparency swaps glass for a solid fill.

---

## 3. SpeechAnalyzer / SpeechTranscriber (macOS 26) and Polish

### Verdict for Polish (measured on this Mac, macOS 26.5.2) [RUN]
| API | pl-PL |
|---|---|
| `SpeechTranscriber.supportedLocales` | NOT listed (30 locales: de, en, es, fr, it, ja, ko, pt, yue, zh variants) |
| `AssetInventory.status(forModules: [SpeechTranscriber(pl-PL)])` | `.unsupported` |
| `SpeechTranscriber.supportedLocale(equivalentTo: pl-PL)` | returns `pl_PL` (misleading, do not trust this alone) |
| `DictationTranscriber.supportedLocales` | listed (54 locales incl. pl-PL, cs, uk, ru, nl, ...) |
| `AssetInventory.status(forModules: [DictationTranscriber(pl-PL)])` | `.supported` -> `.installed` after `reserve` + download |
| `SFSpeechRecognizer(locale: pl-PL).supportsOnDeviceRecognition` | `true` |

End-to-end test: `say -v Zosia` generated 6.4 s of Polish speech, then `SpeechAnalyzer` + `DictationTranscriber(pl-PL, .longDictation)` transcribed it in 0.39-0.51 s:
"Dzień dobry to jest test transkrypcji mowy w języku polskim nagrywamy krótką notatkę głosową" (exact words; no punctuation on TTS input even with `.punctuation`).
So: **use `DictationTranscriber` for Polish** (Apple's documented fallback, same models as system dictation). `SpeechTranscriber` only for its 30 locales.
Community confirmation: Dictation covers more languages incl. Polish ([whispernotes](https://whispernotes.app/blog/apple-speech-vs-whisper), [ohr issue #3](https://github.com/Arthur-Ficial/ohr/issues/3), [WWDC25 session 277](https://developer.apple.com/videos/play/wwdc2025/277/)).
Always gate on `AssetInventory.status(forModules:)`, not on `supportedLocale(equivalentTo:)`.

### Exact signatures (Speech.swiftinterface, all macOS 26.0, watchOS unavailable)
```swift
final public actor SpeechAnalyzer: Sendable {
    public convenience init(modules: [any SpeechModule], options: SpeechAnalyzer.Options? = nil)
    public convenience init<S: AsyncSequence & Sendable>(inputSequence: S, modules: [any SpeechModule],
        options: SpeechAnalyzer.Options? = nil, analysisContext: AnalysisContext = .init(),
        volatileRangeChangedHandler: sending ((CMTimeRange, Bool, Bool) -> Void)? = nil) where S.Element == AnalyzerInput
    func prepareToAnalyze(in audioFormat: AVAudioFormat?) async throws
    func prepareToAnalyze(in audioFormat: AVAudioFormat?, withProgressReadyHandler: sending ((Progress) -> Void)?) async throws
    var modules: [any SpeechModule] { get }
    func setModules(_ newModules: [any SpeechModule]) async throws
    func start<S: AsyncSequence & Sendable>(inputSequence: S) async throws where S.Element == AnalyzerInput
    func analyzeSequence<S>(_ inputSequence: S) async throws -> CMTime?
    func start(inputAudioFile: AVAudioFile, finishAfterFile: Bool = false) async throws
    func analyzeSequence(from audioFile: AVAudioFile) async throws -> CMTime?
    func finalize(through: CMTime?) async throws
    func finalizeAndFinishThroughEndOfInput() async throws
    func finalizeAndFinish(through: CMTime) async throws
    func finish(after: CMTime) async throws
    func cancelAnalysis(before: CMTime)
    func cancelAndFinishNow() async
    var context: AnalysisContext { get };  func setContext(_ newContext: AnalysisContext) async throws
    static func bestAvailableAudioFormat(compatibleWith modules: [any SpeechModule]) async -> AVAudioFormat?
    static func bestAvailableAudioFormat(compatibleWith modules: [any SpeechModule], considering naturalFormat: AVAudioFormat?) async -> AVAudioFormat?
    struct Options { init(priority: TaskPriority, modelRetention: ModelRetention) } // ModelRetention: .whileInUse .lingering .processLifetime
}
public struct AnalyzerInput: @unchecked Sendable { init(buffer: AVAudioPCMBuffer); init(buffer: AVAudioPCMBuffer, bufferStartTime: CMTime?) }

final public class SpeechTranscriber: SpeechModule, LocaleDependentSpeechModule {
    convenience init(locale: Locale, preset: Preset)
    convenience init(locale: Locale, transcriptionOptions: Set<TranscriptionOption>, reportingOptions: Set<ReportingOption>, attributeOptions: Set<ResultAttributeOption>)
    // Preset: .transcription .transcriptionWithAlternatives .timeIndexedTranscriptionWithAlternatives .progressiveTranscription .timeIndexedProgressiveTranscription
    // TranscriptionOption: .etiquetteReplacements | ReportingOption: .volatileResults .alternativeTranscriptions .fastResults
    // ResultAttributeOption: .audioTimeRange .transcriptionConfidence
    static var isAvailable: Bool { get }
    static var supportedLocales: [Locale] { get async }; static var installedLocales: [Locale] { get async }
    static func supportedLocale(equivalentTo: Locale) async -> Locale?
    var results: some AsyncSequence<SpeechTranscriber.Result, any Error> & Sendable
    struct Result { let range: CMTimeRange; let resultsFinalizationTime: CMTime; var text: AttributedString; let alternatives: [AttributedString]; var isFinal: Bool }
}

final public class DictationTranscriber: SpeechModule, LocaleDependentSpeechModule {   // tvOS unavailable
    convenience init(locale: Locale, preset: Preset)
    convenience init(locale: Locale, contentHints: Set<ContentHint>, transcriptionOptions: Set<TranscriptionOption>,
                     reportingOptions: Set<ReportingOption>, attributeOptions: Set<ResultAttributeOption>)
    // Preset contents (printed at runtime):
    //   .phrase                    hints [shortForm]  opts []             reporting []
    //   .shortDictation            hints [shortForm]  opts [punctuation]  reporting []
    //   .progressiveShortDictation hints [shortForm]  opts [punctuation]  reporting [frequentFinalization, volatileResults]
    //   .longDictation             hints []           opts [punctuation]  reporting []
    //   .progressiveLongDictation  hints []           opts [punctuation]  reporting [volatileResults]
    //   .timeIndexedLongDictation
    // TranscriptionOption: .punctuation .emoji .etiquetteReplacements
    // ReportingOption: .volatileResults .alternativeTranscriptions .frequentFinalization
    // ContentHint: .shortForm .farField .atypicalSpeech .customizedLanguage(modelConfiguration: SFSpeechLanguageModel.Configuration)
    // same supportedLocales / installedLocales / supportedLocale(equivalentTo:) / results / Result shape as SpeechTranscriber
}

final public class AssetInventory {
    static var maximumReservedLocales: Int { get }        // 5 on this Mac
    static var reservedLocales: [Locale] { get async }
    @discardableResult static func reserve(locale: Locale) async throws -> Bool
    @discardableResult static func release(reservedLocale: Locale) async -> Bool
    enum Status: Comparable { case unsupported, supported, downloading, installed }
    static func status(forModules: [any SpeechModule]) async -> Status
    static func assetInstallationRequest(supporting: [any SpeechModule]) async throws -> AssetInstallationRequest?
}
final public class AssetInstallationRequest: NSObject, ProgressReporting, Sendable { var progress: Progress; func downloadAndInstall() async throws }
public final class AnalysisContext { var contextualStrings: [ContextualStringsTag: [String]]  /* .general */ ; var userData }
public final class SpeechDetector: SpeechModule { init(detectionOptions: DetectionOptions, reportResults: Bool) }  // VAD
// New SFSpeechError.Code: audioDisordered unexpectedAudioFormat noModel assetLocaleNotAllocated tooManyAssetLocalesAllocated
//   incompatibleAudioFormats moduleOutputFailed cannotAllocateUnsupportedLocale insufficientResources
```
Asset gotcha [RUN]: without `AssetInventory.reserve(locale:)` the status stays `.supported` after `downloadAndInstall()`;
after `reserve` it becomes `.installed`. Max 5 reserved locales per app. Dictionary words -> `AnalysisContext.contextualStrings[.general] = [...]` then `analyzer.setContext(ctx)`.

### File transcription sample [RUN, Polish OK]
```swift
guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: "pl-PL")) else { return }
let transcriber = DictationTranscriber(locale: locale, preset: .longDictation)
let modules: [any SpeechModule] = [transcriber]
try await AssetInventory.reserve(locale: locale)
if let req = try await AssetInventory.assetInstallationRequest(supporting: modules) { try await req.downloadAndInstall() }
let analyzer = SpeechAnalyzer(modules: modules)
let collector = Task { () -> String in
    var out = ""
    for try await r in transcriber.results where r.isFinal { out += String(r.text.characters) }
    return out
}
try await analyzer.start(inputAudioFile: try AVAudioFile(forReading: url), finishAfterFile: true)
let text = try await collector.value
```

### Live mic sample (Swift 6 clean) [TC]
Full file: `probe/LiveTranscriber.swift`. Key points:
```swift
let transcriber = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .lingering))
try await analyzer.prepareToAnalyze(in: analyzerFormat)            // pre-warm: cuts first-result latency
let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
// results task: volatile -> live preview, isFinal -> append
try await analyzer.start(inputSequence: stream)
Self.installTap(on: engine.inputNode, target: analyzerFormat, continuation: continuation) // nonisolated static helper
engine.prepare(); try engine.start()
// stop: removeTap, engine.stop(), continuation.finish(), try await analyzer.finalizeAndFinishThroughEndOfInput(), await resultsTask.value
```
CRITICAL Swift 6 gotcha: `AVAudioNodeTapBlock` is NOT `@Sendable` in the SDK, so a tap closure written inside a
`@MainActor` type inherits MainActor isolation and traps at runtime (dispatch_assert_queue) when the audio thread calls it.
Install the tap from a `nonisolated static func` (as in the probe) and convert with `AVAudioConverter` inside it.
Use `@preconcurrency import AVFoundation`. Same applies if you set `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.

Info.plist: `NSMicrophoneUsageDescription` (required). `NSSpeechRecognitionUsageDescription` only if you use `SFSpeechRecognizer`
(the CLI probes ran SpeechAnalyzer without any speech-recognition authorization prompt).

---

## 4. Launch at login: SMAppService.mainApp

ServiceManagement (macOS 13.0+):
```objc
typedef NS_ENUM(NSInteger, SMAppServiceStatus) { NotRegistered, Enabled, RequiresApproval, NotFound }   // Swift: SMAppService.Status
@property (class, readonly) SMAppService *mainAppService NS_SWIFT_NAME(mainApp);
- (BOOL)registerAndReturnError:(NSError **)error;      // Swift: func register() throws
- (BOOL)unregisterAndReturnError:(NSError **)error;    // Swift: func unregister() throws
- (void)unregisterWithCompletionHandler:(void (^)(NSError *))handler;   // Swift: async unregister()
@property (readonly) SMAppServiceStatus status;
+ (void)openSystemSettingsLoginItems;
+ (instancetype)loginItemServiceWithIdentifier:(NSString *)identifier;   // loginItem(identifier:) helper bundle, not needed
```
Doc: `register()` for the main app = "the application launches on subsequent logins"; already registered -> `kSMErrorAlreadyRegistered`,
not approved -> `kSMErrorLaunchDeniedByUser`.

Sample [TC]:
```swift
import ServiceManagement
@MainActor enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }
    static func set(_ on: Bool) throws {
        if on { if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() } }
        else  { try SMAppService.mainApp.unregister() }
    }
    static func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
```
Gotchas:
- The system status is the source of truth. Do not store a separate "launchAtLogin" pref and reconcile it at startup, because that
  can unregister a user who enabled it in System Settings ([klaxon PR #9](https://github.com/sleonia/klaxon/pull/9)). Bind the toggle to `status` and re-read it after `register()` and on `NSApplication.didBecomeActiveNotification`.
- `register()` can succeed while status becomes `.requiresApproval`; show a hint + `openSystemSettingsLoginItems()`.
- `.notFound` happens when running from DerivedData/build folders. Test from `/Applications/VocaType.app` (or `~/Applications`).
- No sandbox or helper needed; no Info.plist key needed. Linking `ServiceManagement` is automatic via `import` (the probe also listed it as an sdk dependency, which is optional).

---

## 5. SwiftData on macOS 14+ with a custom store URL

SwiftData.swiftinterface (macOS 14):
```swift
public struct ModelConfiguration: Identifiable, Hashable {
    public let url: URL; public let name: String; public var schema: Schema?
    public let allowsSave: Bool; public let isStoredInMemoryOnly: Bool
    public let groupContainer: GroupContainer; public let cloudKitDatabase: CloudKitDatabase
    public init(isStoredInMemoryOnly: Bool = false)
    public init(for forTypes: any PersistentModel.Type..., isStoredInMemoryOnly: Bool = false)
    public init(_ name: String? = nil, schema: Schema? = nil, isStoredInMemoryOnly: Bool = false, allowsSave: Bool = true,
                groupContainer: GroupContainer = .automatic, cloudKitDatabase: CloudKitDatabase = .automatic)
    public init(_ name: String? = nil, schema: Schema? = nil, url: URL, allowsSave: Bool = true,
                cloudKitDatabase: CloudKitDatabase = .automatic)          // <- custom URL
    // CloudKitDatabase: .automatic .none .private(_:)   GroupContainer: .automatic .none .identifier(_:)
}
public class ModelContainer {
    convenience init(for: any PersistentModel.Type..., migrationPlan: (any SchemaMigrationPlan.Type)? = nil, configurations: ModelConfiguration...) throws
    convenience init(for: Schema, migrationPlan: (any SchemaMigrationPlan.Type)? = nil, configurations: ModelConfiguration...) throws
    init(for: Schema, migrationPlan: (any SchemaMigrationPlan.Type)? = nil, configurations: [ModelConfiguration]) throws
}
// SwiftUI: .modelContainer(_ container: ModelContainer) on View and Scene; .modelContainer(for:inMemory:isAutosaveEnabled:isUndoEnabled:onSetup:)
// macOS 15+ only: #Unique<T>(...), #Index<T>(...), ModelContext.fetchHistory/deleteHistory (generic).  macOS 14: @Attribute(.unique) is fine.
```
Sample [RUN: created VocaType.store + -shm + -wal at the given path, insert + fetch OK]:
```swift
enum Store {
    static func makeContainer(appSupportFolder: String = "VocaType2") throws -> ModelContainer {
        let base = URL.applicationSupportDirectory.appending(path: appSupportFolder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)   // SwiftData does not create parent dirs reliably
        let url = base.appending(path: "VocaType.store")
        let schema = Schema([Transcription.self])
        let config = ModelConfiguration("VocaType", schema: schema, url: url, allowsSave: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }
}
```
Notes:
- Pass `cloudKitDatabase: .none` explicitly. `.automatic` tries CloudKit if the iCloud entitlement is present.
- A dedicated folder (`~/Library/Application Support/VocaType2/`) keeps it separate from the old fork (the old VoiceInk/VocaType store) and makes later data migration an explicit import step.
- For Swift 6: `@Model` classes are not Sendable; use `ModelActor` or pass `PersistentIdentifier` across actors.

---

## 6. XcodeGen project.yml (macOS app, SPM, entitlements, Info.plist, assets, hardened runtime, ad-hoc)

Verified with XcodeGen 2.46.0 + Xcode 26.6: `xcodegen generate` then
`xcodebuild -project VTProbe.xcodeproj -scheme VTProbe -configuration Debug|Release -derivedDataPath .dd build` -> BUILD SUCCEEDED,
KeyboardShortcuts resolved @ 2.4.0, AppIcon.icns + Assets.car compiled, entitlements embedded, ad-hoc signature.
Release: `flags=0x10002(adhoc,runtime)` (hardened runtime ON). Debug: `flags=0x2(adhoc)` (Xcode skips the runtime flag in Debug and injects `get-task-allow`).

```yaml
name: VocaType
options:
  bundleIdPrefix: pl.craftweb
  deploymentTarget:
    macOS: "14.0"
  createIntermediateGroups: true
  developmentLanguage: en
  minimumXcodeGenVersion: "2.40.0"
settings:
  base:
    SWIFT_VERSION: "6.0"
    MARKETING_VERSION: "2.0.0"
    CURRENT_PROJECT_VERSION: "1"
    DEAD_CODE_STRIPPING: YES
packages:
  KeyboardShortcuts:
    url: https://github.com/sindresorhus/KeyboardShortcuts
    from: 2.3.0            # 3.x (latest 3.1.0) also exists; check API before bumping
  # local: MyKit: { path: Packages/MyKit }
  # exact: Foo: { url: ..., exactVersion: 1.2.3 } | branch: main | revision: abc123
targets:
  VocaType:
    type: application
    platform: macOS
    sources:
      - path: App/Sources
      - path: App/Resources          # contains Assets.xcassets (AppIcon.appiconset, AccentColor.colorset)
    dependencies:
      - package: KeyboardShortcuts
      # - package: Foo
      #   product: FooUI
    info:
      path: App/Info.plist           # XcodeGen WRITES this file on every generate
      properties:
        CFBundleDisplayName: VocaType
        CFBundleShortVersionString: $(MARKETING_VERSION)   # REQUIRED: otherwise XcodeGen hardcodes "1.0"
        CFBundleVersion: $(CURRENT_PROJECT_VERSION)        # REQUIRED: otherwise "1"
        LSApplicationCategoryType: public.app-category.productivity
        LSMinimumSystemVersion: $(MACOSX_DEPLOYMENT_TARGET)
        LSUIElement: true                                  # menu-bar app, no Dock icon (flip at runtime with NSApp.setActivationPolicy)
        NSMicrophoneUsageDescription: VocaType needs the microphone to record your voice for transcription.
        NSAppleEventsUsageDescription: VocaType sends a paste command to the active app.
        NSHumanReadableCopyright: "(c) 2026 craftweb"
    entitlements:
      path: App/VocaType.entitlements  # XcodeGen WRITES this file; sets CODE_SIGN_ENTITLEMENTS
      properties:
        com.apple.security.app-sandbox: false             # non-sandboxed: needed for CGEvent paste / AX
        com.apple.security.device.audio-input: true       # REQUIRED with hardened runtime for mic
        com.apple.security.network.client: true          # cloud STT / LLM enhancement
        com.apple.security.automation.apple-events: true  # only if using AppleScript/System Events
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: pl.craftweb.vocatype2
        PRODUCT_NAME: VocaType
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor
        ENABLE_HARDENED_RUNTIME: YES      # NO to turn off
        CODE_SIGN_STYLE: Manual
        CODE_SIGN_IDENTITY: "-"           # ad-hoc
        DEVELOPMENT_TEAM: ""
        ENABLE_USER_SCRIPT_SANDBOXING: YES
        COMBINE_HIDPI_IMAGES: YES
        SWIFT_STRICT_CONCURRENCY: complete
        # Optional Xcode 26 settings (exist in 26.6 xcspec): SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor (default nonisolated),
        # SWIFT_APPROACHABLE_CONCURRENCY: YES (default NO). If enabled, keep audio callbacks in nonisolated funcs.
      configs:
        Debug:
          SWIFT_ACTIVE_COMPILATION_CONDITIONS: DEBUG
        Release:
          SWIFT_COMPILATION_MODE: wholemodule
    # postBuildScripts:
    #   - name: Copy to /Applications
    #     script: ditto "$BUILT_PRODUCTS_DIR/$FULL_PRODUCT_NAME" "/Applications/$FULL_PRODUCT_NAME"
    #     basedOnDependencyAnalysis: false
```
Spec reference (ProjectSpec.md @2.46.0): package deps `- package: Name` (+ `product:` / `products:`), remote package version keys
`from/majorVersion`, `minorVersion`, `exactVersion/version`, `minVersion+maxVersion`, `branch`, `revision`, optional `github: org/repo`;
local `path:`. Source `buildPhase: resources|sources|none|copyFiles{destination,subpath}`, `type: folder|group|syncedFolder`.
`info`/`entitlements` = `{path, properties}` (generated plists). Options: `projectFormat` (default xcode16_0), `xcodeVersion`, `settingPresets`.
Also exists as build setting in Xcode 26: `ENABLE_APP_SANDBOX` / `ENABLE_USER_SELECTED_FILES` (template uses them), but the explicit entitlements file above is simpler to reason about.

Asset catalog minimum: `Assets.xcassets/Contents.json`, `AppIcon.appiconset/Contents.json` with mac idiom sizes
16/32/128/256/512 at 1x and 2x (10 PNGs), `AccentColor.colorset/Contents.json`. (Probe generated PNGs via `sips` from the generic icon.)
A macOS 26 Icon Composer `.icon` file is optional; the classic appiconset still builds and shows fine.

### Ad-hoc signing + TCC (important for daily use)
- Ad-hoc designated requirement is `cdhash H"..."` [RUN], so it changes on every build. TCC grants (Accessibility for paste,
  Microphone) are pinned to it and silently reset after each rebuild ([klaxon PR #9](https://github.com/sleonia/klaxon/pull/9)).
- Fix: a stable self-signed code-signing identity. Proven recipe (klaxon `Scripts/setup-signing.sh`): system LibreSSL
  `/usr/bin/openssl req -x509 ... extendedKeyUsage=critical,codeSigning` -> `pkcs12 -export` (LibreSSL, no `-legacy` flag) ->
  dedicated keychain (`security create-keychain`, `set-keychain-settings` = never lock, `unlock-keychain`) -> ADD IT TO THE USER SEARCH LIST
  (`security list-keychains -d user -s <kc> <existing...>`) -> `security import ... -A -T /usr/bin/codesign` ->
  `security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k <pass> <kc>`. Then sign with
  `CODE_SIGN_IDENTITY: "VocaType Local Signing"` or re-sign after build: `codesign --force --options runtime --entitlements <file> -s "VocaType Local Signing" VocaType.app`.
  Identity never shows under `find-identity -v` (untrusted root); check with `find-identity -p codesigning` (no `-v`).
  NOT executed here: in a keychain that was NOT on the search list, `codesign --keychain <kc> -s <name|sha1>` failed with "no identity found",
  so the search-list step is mandatory. It changes the user's keychain list, so ask the user before doing it.
- Existing fork (the old VocaType repo) builds ad-hoc via `LocalBuild.xcconfig` + `make local`, copies to `~/Downloads/VocaType.app`, and has
  entitlements: sandbox false, apple-events, audio-input, files.user-selected.read-only, network.client/server, screen-capture. Its packages include
  Sparkle, SelectedTextKit, mediaremote-adapter, FluidAudio, LLMkit, Transcribe-cpp-swift (whisper), mlx-swift-lm, swift-huggingface, swift-transformers, swift-atomics, Zip, swift-markdown-ui.

---

## Quick decisions for VocaType 2.0
1. Deployment target: 14.0 with `#available(macOS 26, *)` glass branches and `.ultraThinMaterial` fallback (or 26.0 if only Tahoe matters; drops all fallback code).
2. Widget: borderless `.nonactivatingPanel` NSPanel + NSHostingView (`sizingOptions = []`, fixed canvas) + one `GlassEffectContainer`. Test inactive-app glass rendering early.
3. Local STT for Polish: `SpeechAnalyzer` + `DictationTranscriber` (macOS 26 only; on 14/15 fall back to `SFSpeechRecognizer` on-device or whisper/cloud). Pre-warm with `prepareToAnalyze`, `modelRetention: .lingering`, `reserve(locale:)`.
4. Launch at login: `SMAppService.mainApp`, status as source of truth.
5. Data: SwiftData, custom URL under `Application Support/VocaType2/`, `cloudKitDatabase: .none`.
6. Project: XcodeGen (install via brew), spec above; set version keys explicitly; plan a stable self-signed identity so TCC permissions survive rebuilds.
