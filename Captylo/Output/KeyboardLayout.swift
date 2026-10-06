import Carbon
import CoreGraphics
import Foundation

/// Resolves the virtual key code that produces "v" (paste) or "c" (copy for "Popraw") in the
/// current keyboard layout (gotcha 49). Apps match Cmd shortcuts by the character the layout
/// produces, so the ANSI `0x09` misfires on Dvorak or Colemak. The lookup runs `UCKeyTranslate`
/// with the Command modifier held (so the "QWERTY ⌘" layouts resolve correctly), caches the
/// result per input source id and drops the cache when the selected keyboard input source
/// changes. Main thread only (TIS rule).
@MainActor
enum KeyboardLayout {
    /// ANSI V and C, used when the layout cannot be inspected.
    static let fallbackKeyCodeForV: CGKeyCode = 0x09
    static let fallbackKeyCodeForC: CGKeyCode = 0x08

    private static var cachedSourceID: String?
    private static var cachedKeyCodes: [UInt8: CGKeyCode] = [:]
    private static var changeObserver: (any NSObjectProtocol)?

    /// Key code producing "v" with Command held in the current layout, `0x09` when unknown.
    static func keyCodeForV() -> CGKeyCode {
        keyCode(for: UInt8(ascii: "v"), fallback: fallbackKeyCodeForV)
    }

    /// Key code producing "c" with Command held in the current layout, `0x08` when unknown.
    static func keyCodeForC() -> CGKeyCode {
        keyCode(for: UInt8(ascii: "c"), fallback: fallbackKeyCodeForC)
    }

    private static func keyCode(for character: UInt8, fallback: CGKeyCode) -> CGKeyCode {
        installChangeObserverIfNeeded()

        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else {
            // Happens during fast user switching; do not cache the fallback.
            Log.output.warning("No keyboard layout input source, using the ANSI key")
            return fallback
        }

        let sourceID = inputSourceID(of: source)
        if cachedSourceID != sourceID {
            cachedSourceID = sourceID
            cachedKeyCodes = [:]
        }
        if let cached = cachedKeyCodes[character] {
            return cached
        }

        let keyCode = resolveKeyCode(for: character, in: source) ?? fallback
        cachedKeyCodes[character] = keyCode
        Log.output.info("Keyboard layout \(sourceID ?? "?", privacy: .public): \(String(UnicodeScalar(character)), privacy: .public) is key code 0x\(String(keyCode, radix: 16), privacy: .public)")
        return keyCode
    }

    /// Drops the cached key codes; the next lookup inspects the layout again.
    static func invalidateCache() {
        cachedSourceID = nil
        cachedKeyCodes = [:]
    }

    // MARK: - Lookup

    /// Scans key codes 0...127 and returns the first one that maps to `character` with Command held.
    static func resolveKeyCode(for character: UInt8, in source: TISInputSource) -> CGKeyCode? {
        guard let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }

        return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            let commandState = UInt32((cmdKey >> 8) & 0xFF)
            let keyboardType = UInt32(LMGetKbdType())
            let options = OptionBits(1 << kUCKeyTranslateNoDeadKeysBit)

            for keyCode in CGKeyCode(0)...CGKeyCode(127) {
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout,
                    keyCode,
                    UInt16(kUCKeyActionDown),
                    commandState,
                    keyboardType,
                    options,
                    &deadKeyState,
                    characters.count,
                    &length,
                    &characters
                )
                guard status == noErr, length == 1 else { continue }
                if characters[0] == UniChar(character) {
                    return keyCode
                }
            }
            return nil
        }
    }

    /// `kTISPropertyInputSourceID` of the source, nil when the property is missing.
    static func inputSourceID(of source: TISInputSource) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    // MARK: - Invalidation

    private static func installChangeObserverIfNeeded() {
        guard changeObserver == nil else { return }
        let name = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
        changeObserver = DistributedNotificationCenter.default().addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                invalidateCache()
            }
        }
    }
}
