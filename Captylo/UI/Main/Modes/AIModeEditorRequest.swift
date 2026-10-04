import Foundation

/// Opens the mode editor sheet: an existing mode (Edytuj, Duplikuj) or a new, still unsaved one
/// (Dodaj tryb, added only on Zapisz).
struct AIModeEditorRequest: Identifiable, Sendable {
    let id = UUID()
    var mode: AIMode
    var isNew: Bool
}
