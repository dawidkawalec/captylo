import SwiftUI

/// One mode in the "Tryby AI" panel: symbol in a glass badge, name, kind chip and time limit.
/// A click makes it the active mode (brighter glass pill and a blue checkmark); the round
/// "..." button and the context menu hold Edytuj, Duplikuj, the moves and Usuń.
@MainActor
struct AIModeRow: View {
    struct Actions {
        var activate: () -> Void
        var edit: () -> Void
        var duplicate: () -> Void
        var moveUp: () -> Void
        var moveDown: () -> Void
        var delete: () -> Void
    }

    let mode: AIMode
    let isActive: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let canDelete: Bool
    let actions: Actions

    @State private var isHovered = false

    /// The kind chip only adds something when the name does not already say it.
    private var showsKindChip: Bool {
        mode.name.trimmingCharacters(in: .whitespaces).localizedCaseInsensitiveCompare(mode.kind.title) != .orderedSame
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: GlassTokens.Radius.control + 2, style: .continuous)
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: actions.activate) {
                HStack(spacing: 12) {
                    GlassIconBadge(
                        systemImage: mode.symbol,
                        size: GlassTokens.Size.rowBadge,
                        tint: isActive ? GlassColor.accent : nil
                    )
                    VStack(alignment: .leading, spacing: 5) {
                        Text(verbatim: mode.name)
                            .font(GlassFont.ui(14, isActive ? .semibold : .regular))
                            .foregroundStyle(GlassColor.textPrimary)
                            .lineLimit(1)
                        HStack(spacing: 8) {
                            // Neutral for both kinds: the active pill and the checkmark are the
                            // only accent in the list. No chip when it would repeat the name
                            // (the built-in "Czyszczenie").
                            if showsKindChip {
                                GlassBadge(title: Text(mode.kind.title), systemImage: mode.kind.symbol, tone: .neutral)
                            }
                            Text(mode.limitLabel)
                                .font(GlassFont.caption.monospacedDigit())
                                .foregroundStyle(GlassColor.textSecondary)
                        }
                    }
                    .glassTextShadow()
                    Spacer(minLength: 8)
                    checkmark
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isActive ? Text("Ten tryb jest używany przy dyktowaniu") : Text("Kliknij, aby używać tego trybu"))
            .accessibilityLabel(Text(verbatim: mode.name))
            .accessibilityValue(Text(verbatim: "\(mode.kind.title), \(mode.limitLabel)"))
            .accessibilityHint(isActive ? Text("Aktywny tryb") : Text("Ustawia ten tryb jako aktywny"))
            .accessibilityAddTraits(isActive ? .isSelected : [])

            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(isHovered || isActive ? 0.92 : 0.7))
                    .frame(width: 30, height: 30)
                    .background {
                        Circle().fill(Color.white.opacity(isHovered ? 0.18 : GlassTokens.Opacity.control))
                    }
                    .overlay {
                        Circle().strokeBorder(GlassColor.rim(top: 0.32, bottom: 0.06), lineWidth: GlassTokens.Size.rimWidth)
                    }
                    .contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(Text("Więcej"))
            .accessibilityLabel(Text("Opcje trybu \(mode.name)"))
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .background {
            shape
                .fill(Color.white.opacity(isActive ? GlassTokens.Opacity.selection - 0.06 : (isHovered ? 0.06 : 0)))
                .overlay {
                    if isActive {
                        shape.strokeBorder(GlassColor.rim(top: 0.42, bottom: 0.08), lineWidth: GlassTokens.Size.rimWidth)
                    }
                }
                .shadow(color: .black.opacity(isActive ? 0.14 : 0), radius: 6, y: 3)
        }
        .contentShape(shape)
        .onHover { isHovered = $0 }
        .contextMenu { menuItems }
        .animation(GlassMotion.selection, value: isActive)
        .animation(GlassMotion.press, value: isHovered)
    }

    @ViewBuilder
    private var checkmark: some View {
        if isActive {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(Color.white, GlassColor.toggle)
                .shadow(color: GlassColor.toggle.opacity(0.5), radius: 6)
                .accessibilityHidden(true)
                .transition(.opacity)
        } else if isHovered {
            Image(systemName: "circle")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(GlassColor.textTertiary)
                .accessibilityHidden(true)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        if !isActive {
            Button {
                actions.activate()
            } label: {
                Label("Używaj tego trybu", systemImage: "checkmark.circle")
            }
            Divider()
        }
        Button {
            actions.edit()
        } label: {
            Label("Edytuj", systemImage: "pencil")
        }
        Button {
            actions.duplicate()
        } label: {
            Label("Duplikuj", systemImage: "plus.square.on.square")
        }
        Divider()
        Button {
            actions.moveUp()
        } label: {
            Label("Przesuń wyżej", systemImage: "arrow.up")
        }
        .disabled(!canMoveUp)
        Button {
            actions.moveDown()
        } label: {
            Label("Przesuń niżej", systemImage: "arrow.down")
        }
        .disabled(!canMoveDown)
        Divider()
        Button(role: .destructive) {
            actions.delete()
        } label: {
            Label("Usuń", systemImage: "trash")
        }
        .disabled(!canDelete)
    }
}
