import CoreAudio
import Foundation

/// One `AudioObjectAddPropertyListenerBlock` registration that keeps its block so the
/// removal in `deinit` really matches (gotcha 31). The handler runs on the main queue.
final class AudioObjectListener: @unchecked Sendable {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock
    private let installed: Bool

    init(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        handler: @escaping @MainActor () -> Void
    ) {
        self.object = object
        self.address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            // Dispatched on DispatchQueue.main, which is the main actor's executor.
            MainActor.assumeIsolated { handler() }
        }
        self.block = block
        let status = AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block)
        installed = status == noErr
        if status != noErr {
            Log.audio.error("AudioObjectAddPropertyListenerBlock(\(selector)) failed: \(status)")
        }
    }

    deinit {
        guard installed else { return }
        AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, block)
    }
}
