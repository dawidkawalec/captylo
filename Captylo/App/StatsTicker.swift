import Observation

/// Version counter bumped after every saved, updated or deleted dictation. Views reload with
/// `.task(id: appState.statsVersion)`. Lives apart from `AppState` so services built inside
/// `AppState.init` can capture it without a reference to the half-built root.
@MainActor
@Observable
final class StatsTicker {
    private(set) var version = 0

    func bump() {
        version += 1
    }
}
