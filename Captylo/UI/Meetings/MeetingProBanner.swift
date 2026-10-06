import SwiftUI

/// Free, over the transcript of a finished meeting: what Pro would add to this very meeting, a
/// look at the "Notatki AI" sample and the offer (`ProOffer`: the 7-day trial signed out, Pro
/// signed in). The close button hides it for two weeks, like the sidebar's `SupportCard`.
@MainActor
struct MeetingProBanner: View {
    let offer: ProOffer
    let onShowSample: () -> Void
    let onOffer: () -> Void
    let onClose: () -> Void

    /// Free, a finished meeting with a transcript, and not closed lately.
    nonisolated static func isVisible(offer: ProOffer, status: MeetingStatus, hasTranscript: Bool, hiddenUntil: Date?, now: Date) -> Bool {
        offer != .none && status == .completed && hasTranscript
            && SupportPromo.isVisible(hiddenUntil: hiddenUntil, now: now)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            GlassIconBadge(systemImage: "sparkles", size: 30, tint: VTColor.brandViolet)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Spotkanie zapisane na tym Macu")
                    .font(GlassFont.bodyMedium)
                    .foregroundStyle(GlassColor.textPrimary)
                Text("W Captylo Pro miałoby notatki AI z decyzjami i zadaniami, podpisy mówców i Zapytaj o to, co padło w rozmowie.")
                    .font(GlassFont.caption)
                    .foregroundStyle(GlassColor.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(action: onOffer) {
                        Text(verbatim: offer.buttonTitle)
                    }
                    .buttonStyle(.glass(.accent, size: .small, shape: .capsule))
                    Button("Zobacz przykład", action: onShowSample)
                        .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                }
                .padding(.top, 2)
                if let note = offer.note {
                    Text(verbatim: note)
                        .font(GlassFont.caption)
                        .foregroundStyle(GlassColor.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(GlassColor.textTertiary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("Ukryj na dwa tygodnie"))
            .accessibilityLabel(Text("Ukryj na dwa tygodnie"))
        }
        .padding(14)
        .glassSurface(.raised, cornerRadius: GlassTokens.Radius.card)
        .accessibilityElement(children: .contain)
    }
}
