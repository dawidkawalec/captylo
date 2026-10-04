import CoreAudio
import Foundation
import Observation

/// Input device list, system default, lid state and the persisted selection (brief 4.3).
/// Devices are matched by UID, then model UID, never by `AudioDeviceID` (gotcha 30).
/// `onRouteChange` fires on the main actor whenever the resolved device may have changed,
/// so the composition root can re-prepare `AudioCapture`.
@MainActor
@Observable
final class AudioDevices {
    struct Input: Identifiable, Hashable, Sendable {
        let id: AudioDeviceID
        let uid: String
        let modelUID: String
        let name: String
        let isBuiltIn: Bool
    }

    private(set) var inputs: [Input] = []
    /// UID of the system default input, nil when none is set.
    private(set) var defaultUID: String?
    private(set) var isLidClosed = false

    @ObservationIgnored var onRouteChange: (@MainActor () -> Void)?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var listeners: [AudioObjectListener] = []
    @ObservationIgnored private var lidMonitor: LidMonitor?

    init(settings: AppSettings) {
        self.settings = settings
        refresh()
        let system = AudioObjectID(kAudioObjectSystemObject)
        listeners = [
            AudioObjectListener(object: system, selector: kAudioHardwarePropertyDevices) { [weak self] in
                self?.handleChange("device list")
            },
            AudioObjectListener(object: system, selector: kAudioHardwarePropertyDefaultInputDevice) { [weak self] in
                self?.handleChange("default input")
            },
        ]
        let lid = LidMonitor { [weak self] closed in
            guard let self, self.isLidClosed != closed else { return }
            self.isLidClosed = closed
            Log.audio.info("Lid \(closed ? "closed" : "opened", privacy: .public)")
            self.onRouteChange?()
        }
        lidMonitor = lid
        isLidClosed = lid.isClosed
    }

    // MARK: Selection

    /// Persisted through `AppSettings.micSelection`; changing it fires `onRouteChange`.
    var selection: AudioInputSelection {
        get { settings.micSelection }
        set {
            guard settings.micSelection != newValue else { return }
            settings.micSelection = newValue
            onRouteChange?()
        }
    }

    /// Convenience for the picker: selects a listed device.
    func select(_ input: Input?) {
        selection = input.map { .device(uid: $0.uid, modelUID: $0.modelUID) } ?? .systemDefault
    }

    /// The device that will record now, honoring the lid rule.
    func resolveInput() -> Input? {
        Self.pick(selection: selection, inputs: inputs, defaultUID: defaultUID, lidClosed: isLidClosed)
    }

    func resolve() -> AudioDeviceID? {
        resolveInput()?.id
    }

    /// Pure selection rule: exact UID, then the same model UID, then the system default,
    /// then built-ins before externals. With the lid closed built-ins are excluded and
    /// externals win.
    nonisolated static func pick(
        selection: AudioInputSelection,
        inputs: [Input],
        defaultUID: String?,
        lidClosed: Bool
    ) -> Input? {
        let usable = lidClosed ? inputs.filter { !$0.isBuiltIn } : inputs
        if case .device(let uid, let modelUID) = selection {
            if let exact = usable.first(where: { $0.uid == uid }) { return exact }
            if let sameModel = usable.first(where: { $0.modelUID == modelUID }) { return sameModel }
        }
        if let defaultUID, let systemDefault = usable.first(where: { $0.uid == defaultUID }) {
            return systemDefault
        }
        return usable.first(where: \.isBuiltIn) ?? usable.first
    }

    // MARK: Refresh

    /// Re-reads the device list and the default input from the HAL.
    func refresh() {
        inputs = Self.enumerateInputs()
        let defaultID = Self.defaultInputDeviceID()
        defaultUID = inputs.first(where: { $0.id == defaultID })?.uid
            ?? defaultID.flatMap { Self.string(kAudioDevicePropertyDeviceUID, of: $0) }
    }

    private func handleChange(_ reason: String) {
        let before = (inputs, defaultUID)
        refresh()
        guard before.0 != inputs || before.1 != defaultUID else { return }
        Log.audio.info("Audio route changed (\(reason, privacy: .public)): \(self.inputs.count) inputs, default \(self.defaultUID ?? "none", privacy: .public)")
        onRouteChange?()
    }

    // MARK: Core Audio queries

    nonisolated static func enumerateInputs() -> [Input] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id -> Input? in
            guard inputChannelCount(of: id) > 0 else { return nil }
            guard let uid = string(kAudioDevicePropertyDeviceUID, of: id), !uid.isEmpty else { return nil }
            let name = string(kAudioDevicePropertyDeviceNameCFString, of: id) ?? uid
            let modelUID = string(kAudioDevicePropertyModelUID, of: id) ?? ""
            return Input(id: id, uid: uid, modelUID: modelUID, name: name, isBuiltIn: transportType(of: id) == kAudioDeviceTransportTypeBuiltIn)
        }
    }

    nonisolated static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    /// Sum of `mNumberChannels` over the input stream configuration (0 for output-only devices).
    nonisolated static func inputChannelCount(of device: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// True when the device reports alive (gone devices answer false or fail).
    nonisolated static func isAlive(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &alive) == noErr else { return false }
        return alive != 0
    }

    nonisolated private static func transportType(of device: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return 0 }
        return transport
    }

    nonisolated static func string(_ selector: AudioObjectPropertySelector, of device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
