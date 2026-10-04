import CoreAudio
import Foundation

/// Mutes the default output device while recording (gotcha 33) and only ever undoes its own mute.
/// The mute is delayed so the start cue stays audible; a generation counter drops a delayed
/// mute that `restore()` already overtook.
///
/// The mute is also recorded in UserDefaults (`markerKey`: output UID and time) and cleared by
/// `restore()`. A crash, kill or Force Quit never reaches `restore()` or `applicationWillTerminate`,
/// so the next launch calls `recoverAfterAbnormalExit()`, which undoes a mute that is still on.
@MainActor
final class SystemMute: SystemMuting {
    /// What a mute left behind in UserDefaults until `restore()` clears it.
    struct Marker: Codable, Equatable, Sendable {
        let uid: String
        let mutedAt: Date
    }

    nonisolated static let markerKey = "systemMute.marker"
    /// An older marker is dropped without touching the device: by then the user has surely
    /// noticed the silence, and a mute they set since must not be undone.
    nonisolated static let markerMaxAge: TimeInterval = 24 * 3600

    private let settings: AppSettings
    private let defaults: UserDefaults
    private var generation = 0
    private var pending: Task<Void, Never>?
    /// Device we muted, nil when the mute is not ours (user muted first, or no mute yet).
    private var mutedDevice: AudioDeviceID?

    /// True while a meeting records: muting would silence the call (notetaker spec 3.1), so a
    /// scheduled mute never fires. Turning it on also cancels a pending mute and undoes one
    /// already in effect (a take that started before the meeting).
    var isSuppressed = false {
        didSet {
            guard isSuppressed, !oldValue else { return }
            restore()
        }
    }

    init(settings: AppSettings, defaults: UserDefaults = .standard) {
        self.settings = settings
        self.defaults = defaults
    }

    // MARK: Crash recovery

    var marker: Marker? {
        guard let data = defaults.data(forKey: Self.markerKey) else { return nil }
        return try? JSONDecoder().decode(Marker.self, from: data)
    }

    func recordMarker(uid: String, at date: Date = Date()) {
        guard let data = try? JSONEncoder().encode(Marker(uid: uid, mutedAt: date)) else { return }
        defaults.set(data, forKey: Self.markerKey)
    }

    func clearMarker() {
        defaults.removeObject(forKey: Self.markerKey)
    }

    /// The device UID to unmute for a marker left by an abnormal exit, or nil when it is too old
    /// (or dated in the future).
    nonisolated static func uidToRecover(from marker: Marker?, now: Date = Date()) -> String? {
        guard let marker else { return nil }
        let age = now.timeIntervalSince(marker.mutedAt)
        guard age >= 0, age <= markerMaxAge else { return nil }
        return marker.uid
    }

    /// Launch step: a marker means the last run muted the output and never restored it. Unmutes
    /// that device when it is present and still muted, then clears the marker either way.
    func recoverAfterAbnormalExit(now: Date = Date()) {
        guard let marker else { return }
        clearMarker()
        guard let uid = Self.uidToRecover(from: marker, now: now) else {
            Log.audio.info("Stale system mute marker dropped")
            return
        }
        guard let device = Self.device(uid: uid), let element = Self.muteElement(on: device),
              Self.isMuted(device: device, element: element) == true else { return }
        if Self.setMuted(false, on: device, element: element) {
            Log.audio.notice("System output unmuted after an abnormal exit during a take")
        }
    }

    /// Schedules a mute after `delay`; the `muteWhileRecording` setting is read when it fires.
    func muteIfEnabled(after delay: Duration) {
        generation += 1
        let myGeneration = generation
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.generation == myGeneration else { return }
            self.muteNow()
        }
    }

    /// Cancels a pending mute and unmutes only when the mute is ours.
    func restore() {
        generation += 1
        pending?.cancel()
        pending = nil
        guard let device = mutedDevice else { return }
        mutedDevice = nil
        if Self.setMuted(false, on: device) {
            Log.audio.info("System output unmuted")
        }
        clearMarker()
    }

    /// True while our own mute is in effect.
    var isMutedByUs: Bool { mutedDevice != nil }

    private func muteNow() {
        guard settings.muteWhileRecording, !isSuppressed, mutedDevice == nil else { return }
        guard let device = Self.defaultOutputDevice(), let element = Self.muteElement(on: device) else {
            Log.audio.info("Default output has no settable mute; skipping system mute")
            return
        }
        if Self.isMuted(device: device, element: element) == true {
            // The user muted before us: leave it alone and never unmute.
            Log.audio.info("System output already muted by the user")
            return
        }
        // Written before the mute: a crash between the two must still be recoverable.
        let uid = AudioDevices.string(kAudioDevicePropertyDeviceUID, of: device)
        if let uid {
            recordMarker(uid: uid)
        }
        if Self.setMuted(true, on: device, element: element) {
            mutedDevice = device
            Log.audio.info("System output muted")
        } else if uid != nil {
            clearMarker()
        }
    }

    // MARK: Core Audio

    private static func device(uid: String) -> AudioDeviceID? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return nil }
        return ids.first { AudioDevices.string(kAudioDevicePropertyDeviceUID, of: $0) == uid }
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func muteAddress(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element)
    }

    /// First element with a settable mute: main, then 0 (identical on current SDKs, kept for
    /// older ones), then channel 1 for devices that only expose per-channel mute.
    private static func muteElement(on device: AudioDeviceID) -> AudioObjectPropertyElement? {
        var tried: Set<AudioObjectPropertyElement> = []
        for element in [kAudioObjectPropertyElementMain, 0, 1] where tried.insert(element).inserted {
            var address = muteAddress(element: element)
            guard AudioObjectHasProperty(device, &address) else { continue }
            var settable = DarwinBoolean(false)
            guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { continue }
            return element
        }
        return nil
    }

    private static func isMuted(device: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool? {
        var address = muteAddress(element: element)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    @discardableResult
    private static func setMuted(_ muted: Bool, on device: AudioDeviceID, element: AudioObjectPropertyElement? = nil) -> Bool {
        guard let element = element ?? muteElement(on: device) else { return false }
        var address = muteAddress(element: element)
        var value: UInt32 = muted ? 1 : 0
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        if status != noErr {
            Log.audio.error("kAudioDevicePropertyMute set failed: \(status)")
        }
        return status == noErr
    }
}
