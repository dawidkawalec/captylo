import SwiftUI

/// Sidebar of the main window (docs/design/dusk-glass.md, "Main window"), attached to the left
/// edge from top to bottom (Brand Direction 01, the owner's pick #38): an Abyss-tinted frosted
/// column with a hairline on its right, the "captylo" wordmark on top, the seven sections as white
/// icon + label rows with a brighter glass pill under the selection that slides between them,
/// the Free plan support card, version and captylo.com at the bottom.
/// Keyboard: Cmd+1...7 jump to a section; with the sidebar focused, the arrow keys move.
@MainActor
struct MainSidebar: View {
    @Binding var selection: MainSection

    @Namespace private var pill
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 24)

            VStack(spacing: 4) {
                ForEach(Array(MainSection.allCases.enumerated()), id: \.element) { index, section in
                    item(section, shortcut: index + 1)
                }
            }
            .padding(.horizontal, 10)
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                move(by: press.key == .upArrow ? -1 : 1)
                return .handled
            }

            Spacer(minLength: 16)

            SupportCard(now: Date())
                .padding(.horizontal, 12)
                .padding(.bottom, 14)

            footer
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
        }
        .frame(width: MainShellMetrics.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            SidebarBackdrop()
                .ignoresSafeArea()
        }
    }

    // MARK: Brand

    private var brand: some View {
        BrandWordmark(height: 28)
            .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Captylo"))
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Items

    private func item(_ section: MainSection, shortcut: Int) -> some View {
        let isSelected = section == selection
        return Button {
            select(section)
        } label: {
            SidebarItemLabel(section: section, isSelected: isSelected, pill: pill)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(Character(String(shortcut))), modifiers: .command)
        .accessibilityLabel(Text(section.title))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private func select(_ section: MainSection) {
        guard section != selection else { return }
        if reduceMotion {
            selection = section
        } else {
            withAnimation(GlassMotion.selection) {
                selection = section
            }
        }
    }

    private func move(by offset: Int) {
        let all = MainSection.allCases
        guard let index = all.firstIndex(of: selection) else { return }
        let next = min(max(index + offset, 0), all.count - 1)
        select(all[next])
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            GlassRowSeparator()
            VStack(alignment: .leading, spacing: 4) {
                Text("Wersja \(Self.version)")
                    .font(GlassFont.caption)
                    .foregroundStyle(GlassColor.textTertiary)
                Link(destination: SiteLinks.url("/")) {
                    HStack(spacing: 4) {
                        Text(verbatim: "captylo.com")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(GlassFont.caption)
                    .foregroundStyle(GlassColor.textSecondary)
                }
                .buttonStyle(.plain)
                .pointerStyleLink()
            }
        }
    }
}

/// One sidebar row: outline icon + title, white; the selection is a brighter glass capsule
/// (matched geometry, so it slides) and hover a faint white wash.
@MainActor
private struct SidebarItemLabel: View {
    let section: MainSection
    let isSelected: Bool
    let pill: Namespace.ID

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: section.symbol)
                .font(.system(size: 15, weight: isSelected ? .medium : .regular))
                .frame(width: 22)
            Text(section.title)
                .font(GlassFont.face(isSelected ? .interSemiBold : .interRegular, 14))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(isSelected ? GlassColor.textPrimary : Color.white.opacity(0.78))
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background {
            if isSelected {
                Capsule()
                    .fill(Color.white.opacity(0.2))
                    .overlay { Capsule().strokeBorder(GlassColor.rim(top: 0.5, bottom: 0.08), lineWidth: 1) }
                    .shadow(color: .black.opacity(0.16), radius: 6, y: 3)
                    .matchedGeometryEffect(id: "selection", in: pill)
            } else if isHovered {
                Capsule().fill(Color.white.opacity(0.07))
            }
        }
        .contentShape(Capsule())
        .onHover { isHovered = $0 }
    }
}

/// The sidebar column: frosted glass over the window background, washed with Abyss so white type
/// holds over the brightest part of the gradient (a little more than the panels' smoke), and a
/// hairline along its right edge. Reduce Transparency: solid Abyss.
@MainActor
private struct SidebarBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.windowTone) private var tone

    var body: some View {
        ZStack(alignment: .trailing) {
            if reduceTransparency {
                GlassColor.solidPanel
            } else {
                Rectangle().fill(.ultraThinMaterial)
                VTColor.abyss.opacity(MainShellMetrics.sidebarInkWash + tone.smokeOpacity)
            }
            Rectangle()
                .fill(Color.white.opacity(MainShellMetrics.sidebarHairline))
                .frame(width: 1)
        }
    }
}

private extension View {
    /// Pointing-hand cursor over links (macOS 15 `pointerStyle`, cursor push below).
    @ViewBuilder
    func pointerStyleLink() -> some View {
        if #available(macOS 15.0, *) {
            pointerStyle(.link)
        } else {
            onHover { inside in
                if inside {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
        }
    }
}
