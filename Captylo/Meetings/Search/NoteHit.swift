import Foundation

/// One note matched by the search index: the best rank of its title and body rows (lower is better).
struct NoteHit: Sendable, Equatable {
    var noteID: UUID
    var rank: Double
}
