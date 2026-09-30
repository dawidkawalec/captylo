import AppKit

/// Refuses an import while something else may write the stores involved: the old app (its
/// store could be copied mid-write) or a second Captylo process on the same data folder.
@MainActor
enum LegacyImportGuard {
    /// The old app and its VoiceInk upstream (compared case-insensitively).
    static let oldAppBundleIdentifiers = [
        "com.dawidkawalec.vocatype",
        "pl.kawalec.VocaType",
        "com.prakashjoshipax.VoiceInk",
    ]

    /// - Parameters:
    ///   - checkOtherCaptylo: false when this process writes a different data folder
    ///     (`CAPTYLO_DATA_DIR`) or writes nothing (dry run).
    static func blockingError(checkOtherCaptylo: Bool) -> LegacyImportError? {
        let running = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        let oldIDs = Set(oldAppBundleIdentifiers.map { $0.lowercased() })
        if let old = running.first(where: { oldIDs.contains($0.bundleIdentifier?.lowercased() ?? "") }) {
            return .oldAppRunning(old.localizedName ?? "VocaType")
        }
        if checkOtherCaptylo, let own = Bundle.main.bundleIdentifier {
            let pid = ProcessInfo.processInfo.processIdentifier
            if running.contains(where: { $0.bundleIdentifier == own && $0.processIdentifier != pid }) {
                return .otherCaptyloRunning
            }
        }
        return nil
    }
}
