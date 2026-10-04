/// Marker stamped into `CGEvent.eventSourceUserData` on every event the app posts itself.
/// `KeySynth` writes it, `HotkeyTap` ignores events carrying it (gotcha 43). The value is a
/// stable internal marker (ASCII bytes of the first dev build's tag); it never shows up in the UI
/// and changing it buys nothing, so it stays as is.
enum SyntheticEventMarker {
    static let value: Int64 = 0x5654_4332
}
