import AppKit
import SwiftUI

/// Settings / onboarding control for the recording shortcut (hotkeys note 3.8, gotchas 44, 45).
/// Shows the current `Hotkey.displayName`, a "Zmień" button that enters capture mode, a presets
/// menu, validation errors in Polish and the Globe-key hint when Fn is chosen.
/// While capturing the global tap is paused (`tap.setHotkey(nil)`) so it cannot swallow the combo,
/// and a local `NSEvent` monitor (works only while our window is key) captures the next combo
/// or modifier-only chord.
@MainActor
struct HotkeyRecorderView: View {
    static let keyboardSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!

    @Bindable var settings: AppSettings
    let tap: HotkeyTap

    @State private var capture = HotkeyCaptureModel()

    init(settings: AppSettings, tap: HotkeyTap) {
        self.settings = settings
        self.tap = tap
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VTSpacing.s) {
            HStack(spacing: VTSpacing.m) {
                shortcutBadge
                Button {
                    if capture.isCapturing {
                        cancelCapture()
                    } else {
                        beginCapture()
                    }
                } label: {
                    if capture.isCapturing {
                        Label("Anuluj", systemImage: "xmark")
                    } else {
                        Label("Zmień", systemImage: "record.circle")
                    }
                }
                // Neutral: the screen's one accent is its primary action ("Dalej" in onboarding);
                // the keycap itself turns violet while it listens.
                .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                presetsMenu
            }
            if capture.isCapturing {
                Text("Naciśnij nowy skrót. Esc anuluje.")
                    .font(GlassFont.caption)
                    .foregroundStyle(GlassColor.textSecondary)
            }
            if let error = capture.errorText {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(GlassFont.caption)
                    .foregroundStyle(GlassColor.destructive)
            }
            if settings.hotkey == .fn {
                fnHint
            }
        }
        .onDisappear {
            cancelCapture()
        }
    }

    // MARK: Pieces

    /// The shortcut as a glass capsule, as tall as the buttons next to it; violet with a soft
    /// glow while it listens for a new combo.
    private var shortcutBadge: some View {
        Text(badgeText)
            .font(.system(size: 15, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(GlassColor.textPrimary)
            .frame(minWidth: 96)
            .padding(.horizontal, 16)
            .frame(height: GlassTokens.Size.buttonHeightSmall)
            .glassSurface(
                .control,
                in: Capsule(),
                tint: capture.isCapturing ? GlassColor.accent.opacity(0.45) : nil,
                shadow: false
            )
            .shadow(color: GlassColor.accent.opacity(capture.isCapturing ? 0.55 : 0), radius: 12)
            .animation(GlassMotion.spring, value: capture.isCapturing)
            .accessibilityLabel(Text("Skrót nagrywania"))
            .accessibilityValue(Text(badgeText))
    }

    private var badgeText: String {
        if capture.isCapturing {
            return capture.preview?.displayName ?? String(localized: "Naciśnij skrót...")
        }
        return settings.hotkey.displayName
    }

    private var presetsMenu: some View {
        Menu {
            ForEach(Hotkey.presets, id: \.self) { preset in
                Button {
                    apply(preset)
                } label: {
                    if preset == settings.hotkey {
                        Label(preset.displayName, systemImage: "checkmark")
                    } else {
                        Text(preset.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text("Presety")
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(GlassColor.textSecondary)
            }
            .font(GlassFont.button.weight(.medium))
            .foregroundStyle(GlassColor.textPrimary)
            .padding(.horizontal, 12)
            .frame(height: GlassTokens.Size.buttonHeightSmall)
            .glassSurface(.control, in: Capsule(), shadow: false)
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text("Presety"))
    }

    private var fnHint: some View {
        VStack(alignment: .leading, spacing: VTSpacing.xs) {
            Label("W Ustawieniach systemowych > Klawiatura ustaw klawisz 🌐 na \"Nic nie rób\", inaczej Fn otworzy też emoji lub dyktowanie systemowe.", systemImage: "globe")
                .font(GlassFont.caption)
                .foregroundStyle(GlassColor.textSecondary)
            Button("Otwórz ustawienia klawiatury") {
                NSWorkspace.shared.open(Self.keyboardSettingsURL)
            }
            .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
        }
    }

    // MARK: Actions

    private func beginCapture() {
        capture.errorText = nil
        tap.setHotkey(nil)
        capture.begin { outcome in
            switch outcome {
            case .captured(let hotkey):
                commit(hotkey)
            case .cancelled:
                cancelCapture()
            }
        }
    }

    private func cancelCapture() {
        guard capture.isCapturing else { return }
        capture.end()
        tap.setHotkey(settings.hotkey)
    }

    /// Validates, then persists and re-arms the tap. On a validation error capture stays open.
    private func commit(_ hotkey: Hotkey) {
        if let error = Hotkey.validate(hotkey) {
            capture.errorText = error
            capture.restart()
            return
        }
        capture.end()
        apply(hotkey)
    }

    private func apply(_ hotkey: Hotkey) {
        capture.errorText = nil
        settings.hotkey = hotkey
        tap.setHotkey(hotkey)
        Log.hotkey.info("Hotkey set to \(hotkey.displayName, privacy: .public)")
    }
}
