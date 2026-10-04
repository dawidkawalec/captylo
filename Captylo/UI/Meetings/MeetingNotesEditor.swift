import SwiftUI

/// The user's own notes of a meeting: a plain editor on the recessed track with the placeholder
/// "Pisz notatki. Captylo połączy je z rozmową.". Every change goes to `MeetingNotesDraft` with
/// the meeting time from `elapsed` (the recording clock, or the meeting's length afterwards),
/// which stamps each new line and saves a second after the last keystroke. Fills the height it
/// is given.
@MainActor
struct MeetingNotesEditor: View {
    let draft: MeetingNotesDraft
    let elapsed: () -> Double

    var body: some View {
        TextEditor(text: Binding(
            get: { draft.text },
            set: { draft.edit($0, at: elapsed()) }
        ))
        .font(GlassFont.body)
        .foregroundStyle(GlassColor.textPrimary)
        .lineSpacing(3)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .overlay(alignment: .topLeading) {
            if draft.text.isEmpty {
                Text("Pisz notatki. Captylo połączy je z rozmową.")
                    .font(GlassFont.body)
                    .foregroundStyle(GlassColor.textTertiary)
                    .padding(.leading, 13)
                    .padding(.trailing, 10)
                    .padding(.top, 10)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassSurface(.track, cornerRadius: GlassTokens.Radius.control, shadow: false)
        .accessibilityLabel(Text("Notatki"))
    }
}
