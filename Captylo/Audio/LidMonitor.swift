import Foundation
import IOKit

/// Clamshell state from `IOPMrootDomain` / `AppleClamshellState` (gotcha 30). Built-in
/// microphones record silence with the lid closed, so `AudioDevices` excludes them then.
/// Change notifications arrive on the main queue.
final class LidMonitor: @unchecked Sendable {
    private let rootDomain: io_service_t
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private let onChange: @MainActor (Bool) -> Void

    init(onChange: @escaping @MainActor (Bool) -> Void) {
        self.onChange = onChange
        rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0 else {
            Log.audio.error("IOPMrootDomain not found; lid state unavailable")
            return
        }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            Log.audio.error("IONotificationPortCreate failed; lid state will not update")
            return
        }
        self.port = port
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let status = IOServiceAddInterestNotification(
            port, rootDomain, kIOGeneralInterest, LidMonitor.interestCallback, refcon, &notifier)
        if status != KERN_SUCCESS {
            Log.audio.error("IOServiceAddInterestNotification failed: \(status)")
        }
    }

    deinit {
        if notifier != 0 { IOObjectRelease(notifier) }
        if let port { IONotificationPortDestroy(port) }
        if rootDomain != 0 { IOObjectRelease(rootDomain) }
    }

    /// Current clamshell state; false when unknown (desktop Macs have no lid).
    var isClosed: Bool {
        Self.readState(rootDomain: rootDomain)
    }

    private static func readState(rootDomain: io_service_t) -> Bool {
        guard rootDomain != 0 else { return false }
        let value = IORegistryEntryCreateCFProperty(
            rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (value as? Bool) ?? false
    }

    private static let interestCallback: IOServiceInterestCallback = { refcon, _, _, _ in
        guard let refcon else { return }
        let monitor = Unmanaged<LidMonitor>.fromOpaque(refcon).takeUnretainedValue()
        let closed = monitor.isClosed
        // The port's dispatch queue is main, which is the main actor's executor.
        MainActor.assumeIsolated { monitor.onChange(closed) }
    }
}
