import SwiftUI

/// The meeting title at the top of the details, with a pencil after it. A click turns it into a
/// field of the same size, the text where the title was: Return or a click elsewhere saves,
/// Escape keeps the old title. Works while the meeting records, so the AI notes written at the
/// stop see the new title (and the template it picks).
///
/// The caller decides what is saved (`MeetingRecord.editedTitle`: an empty or unchanged title
/// is not), and gives each meeting its own editor (`.id`), so a field left open never carries
/// over to another meeting.
@MainActor
struct MeetingTitleEditor: View {
    static let font = GlassFont.display(20)
    /// Room between the field's track and its text; the field moves out by as much, so neither
    /// the text nor the lines under it shift when the field opens.
    private static let fieldInset: CGFloat = 8
    private static let fieldVerticalInset: CGFloat = 3

    let title: String
    var lineLimit: Int
    /// The text typed, as it is.
    let onSave: (String) -> Void

    @State private var isEditing: Bool
    @State private var draft: String
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    /// - Parameter startsEditing: opens with the field (design preview only).
    init(title: String, lineLimit: Int = 2, startsEditing: Bool = false, onSave: @escaping (String) -> Void) {
        self.title = title
        self.lineLimit = lineLimit
        self.onSave = onSave
        _isEditing = State(initialValue: startsEditing)
        _draft = State(initialValue: title)
    }

    var body: some View {
        if isEditing {
            field
        } else {
            label
        }
    }

    private var label: some View {
        Button(action: beginEditing) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: title)
                    .font(Self.font)
                    .foregroundStyle(GlassColor.textPrimary)
                    .lineLimit(lineLimit)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "pencil")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isHovered ? GlassColor.textSecondary : GlassColor.textTertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(Text("Zmień tytuł spotkania"))
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityHint(Text("Zmień tytuł spotkania"))
        .accessibilityAddTraits(.isHeader)
    }

    private var field: some View {
        let shape = RoundedRectangle(cornerRadius: GlassTokens.Radius.control - 2, style: .continuous)
        return TextField("Tytuł spotkania", text: $draft)
            .textFieldStyle(.plain)
            .font(Self.font)
            .foregroundStyle(GlassColor.textPrimary)
            .focused($isFocused)
            .onSubmit(commit)
            .onExitCommand(perform: cancel)
            .padding(.horizontal, Self.fieldInset)
            .padding(.vertical, Self.fieldVerticalInset)
            .background(shape.fill(Color.black.opacity(GlassTokens.Opacity.track)))
            .background(shape.fill(Color.white.opacity(GlassTokens.Opacity.trackLift)))
            .overlay(shape.strokeBorder(GlassColor.rim(top: 0.06, bottom: 0.16), lineWidth: GlassTokens.Size.rimWidth))
            .padding(.horizontal, -Self.fieldInset)
            .padding(.vertical, -Self.fieldVerticalInset)
            .onAppear { isFocused = true }
            .onChange(of: isFocused) { _, focused in
                if !focused {
                    commit()
                }
            }
    }

    private func beginEditing() {
        draft = title
        isEditing = true
    }

    private func commit() {
        guard isEditing else { return }
        isEditing = false
        onSave(draft)
    }

    private func cancel() {
        guard isEditing else { return }
        draft = title
        isEditing = false
    }
}
