import CoreAudio
import Foundation

/// Read-only view of Core Audio's process objects (macOS 14+): who uses the mic, who plays audio.
/// No permission needed.
enum CoreAudioProcesses {
    struct Process: Sendable, Equatable {
        let objectID: AudioObjectID
        let pid: pid_t
        let bundleID: String
        let isRunningInput: Bool
        let isRunningOutput: Bool
    }

    static func all() -> [Process] {
        objectIDs().map { id in
            Process(
                objectID: id,
                pid: read(id, kAudioProcessPropertyPID, default: pid_t(-1)),
                bundleID: readString(id, kAudioProcessPropertyBundleID) ?? "",
                isRunningInput: read(id, kAudioProcessPropertyIsRunningInput, default: UInt32(0)) != 0,
                isRunningOutput: read(id, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0
            )
        }
    }

    static func ownObjectID() -> AudioObjectID? {
        var pid = ProcessInfo.processInfo.processIdentifier
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object
        )
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    /// True when a process other than Captylo is running audio output. Called for every silent
    /// buffer of the system track, so it reads one property per process and the PID only of
    /// the ones that play (no bundle ID strings).
    static func anyOtherProcessPlaying() -> Bool {
        let own = ProcessInfo.processInfo.processIdentifier
        return objectIDs().contains { id in
            read(id, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0
                && read(id, kAudioProcessPropertyPID, default: pid_t(-1)) != own
        }
    }

    // MARK: Property helpers

    private static func objectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        // The list can shrink between the two calls.
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func read<T: BitwiseCopyable>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, default value: T) -> T {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var result = value
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &result) == noErr ? result : value
    }

    /// The returned CFString is +1 (the caller releases it), hence `takeRetainedValue`.
    private static func readString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
