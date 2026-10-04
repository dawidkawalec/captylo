# Coding standards

## Swift

- Swift 6 language mode, `SWIFT_STRICT_CONCURRENCY=complete`, no default actor isolation. Mark SwiftUI views, AppKit wrappers and observable UI models `@MainActor`. Long-running or shared services are `actor`s (`WhisperEngine`, `Enhancer`, `LivePreview`, `Database` as a `ModelActor` on its own `DatabaseExecutor` queue; do not switch it back to `@ModelActor`, whose default executor runs store work on the caller's thread, often main).
- Audio and event-tap callbacks run off the main thread: keep them in `nonisolated` code, never capture `@MainActor` state, hand results to the main actor with `Task { @MainActor in ... }` or an `AsyncStream`.
- `@Model` classes never cross actors; pass value structs (`DictationRecord`) or `PersistentIdentifier`.
- Shared mutable state on hot paths uses `OSAllocatedUnfairLock`; no `Synchronization` module (macOS 15 only), no `DispatchSemaphore` on the cooperative pool.
- Synchronous blocking calls (Core ML load, `AsrModels.loadLocal`) run on a dedicated `DispatchQueue` bridged with `withCheckedThrowingContinuation`.
- `os.Logger(subsystem: "com.captylo.app", category: ...)` through `Log`; `OSSignposter` around the hot path. No `print` except the debug CLI output.
- Errors are typed enums conforming to `LocalizedError` with Polish `errorDescription`. Never store an error message in a transcript field.
- Regex work uses `NSRegularExpression` with `escapedTemplate(for:)` for replacements (the old Swift Regex path lost `$` and `\`).
- One file per type, folder = module. File names match the primary type.

## SwiftUI / AppKit

- Design tokens live in `UI/Glass/GlassTokens.swift` (Dusk Glass in Deep Tide: radii, paddings, opacities, scrims, Grainient uniforms, `GlassColor`, `GlassFont` on Manrope + Inter, `GlassMotion`) and `UI/DesignSystem.swift` (brand colors, widget sizes, `vtGlass(in:)`). No ad-hoc hex colors, materials or `glassEffect` in views: use `glassSurface` and the components in `UI/Glass/` ([docs/design/dusk-glass.md](design/dusk-glass.md)).
- Check UI changes with `scripts/snap.sh <target> <out.png>` (design preview, fake data) and compare with the mockups in `docs/design/`.
- Views observe `@Observable` models; the waveform pulls the level inside `TimelineView` instead of observing a 60 Hz property.
- Panels never activate the app: `orderFrontRegardless()`, never `NSApp.activate` or `makeKey` from the widget.
- Animations: springs `response 0.35-0.4, dampingFraction 0.85`; live transcript updates use `.transaction { $0.disablesAnimations = true }`. Honor `accessibilityReduceMotion` and `accessibilityReduceTransparency`.

## Localization

- Source strings are Polish, written as SwiftUI literals or `String(localized: "...")`. English lives in `Captylo/Resources/Localizable.xcstrings`.
- The product name in every string is "Captylo" (no version suffix); the version shows as "Wersja 1.0.0".
- Use plural variants in the catalog for counts ("1 słowo", "2 słowa", "5 słów").
- `make build` does not sync new keys into the catalog (only the Xcode IDE does): add every new Polish key with its English value to `Localizable.xcstrings` by hand. The keys the compiler extracted are in `.local-build/**/Captylo.build/Objects-normal/arm64/*.stringsdata`.
- Info.plist strings (`NSMicrophoneUsageDescription`) are translated in `Captylo/Resources/InfoPlist.xcstrings`.
- Numbers, dates and language names use `AppLocale.current` (pl_PL under the Polish UI, en_US under the English one), never a hardcoded `Locale(identifier:)` or the system region.
- Never build a sentence from a localized literal plus an unlocalized fragment (`"Kopiuj \(x ? "AI" : "oryginał")"`): write each full variant as its own key.
- No long dashes in any text (UI, docs, commits): use "-".

## Tests

- Swift Testing (`import Testing`), one file per module under `CaptyloTests/`. Pure logic (text processing, hotkey matching, stats, request builders, parsers) must be covered; UI and hardware are not unit-tested.
- Network code is tested with `URLProtocol` stubs and JSON fixtures, never against live APIs.

## Git

- Commit messages: imperative subject <= 72 chars, body explains what and why. No attribution lines, no AI mentions.
- The generated `Captylo.xcodeproj` is ignored; `project.yml` is the source.
