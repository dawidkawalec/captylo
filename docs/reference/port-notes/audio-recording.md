# Port note: AUDIO RECORDING (old VocaType / VoiceInk fork -> VocaType 2)

Source root: `<old repo>/VoiceInk` (read-only). Deployment target of old app: macOS 14.4, Swift 5 mode,
hardened runtime, NOT sandboxed (`com.apple.security.app-sandbox = false`).

## 1. What it does for the user

Essential (KEEP):
- Hotkey toggles a recording; audio goes from ONE chosen mic to `Recordings/<UUID>.wav` (16 kHz, mono, Int16 PCM WAV).
  Verified on disk: `afinfo` -> `1 ch, 16000 Hz, Int16`.
- The same 16 kHz Int16 PCM is streamed live, in small chunks, to the realtime transcriber (Parakeet via FluidAudio).
- Mic choice: "System Default" or "Custom Device". The user's real config is Custom Device =
  `selectedAudioDeviceUID = "BuiltInMicrophoneDevice"` (model UID `"Digital Mic"`).
- Lid-closed fallback: when the MacBook lid is closed (clamshell + external display), the built-in mic records silence,
  so the old app skips built-in devices and uses the first external input instead.
- Live level meter feeding the 15-bar waveform in the recorder widget.
- Start and stop sounds (one built-in pair) plus an "error/esc" blip on error notifications.
- "Mute system audio while recording" (defaults to ON; the user has it ON). Mutes the default OUTPUT device and restores it afterwards.
- A warm-up (prepare) of the audio unit at launch and on device change, so recording starts with near-zero latency.
- Cancel (Esc/dismiss) stops recording. The old app still saved the WAV plus a history row with status `canceled`.

Bloat (DROP):
- "Prioritized" input mode (ordered device list, `prioritizedDevicesData`, rebind logic). Keep only Default + Custom.
- Mid-recording hot device switching (`switchDevice(to:)`, `RecordingDeviceChangeRequest`, NotificationCenter plumbing).
  Replace with: if the active device dies mid-recording, stop and transcribe what was captured.
- Custom user sound files (`CustomSoundManager`, 423 lines, 7 built-in sounds, 3 s duration validation). Keep one start
  sound, one stop sound and one error sound behind a single on/off toggle.
- "Pause media while recording" (`PlaybackController` + private MediaRemote via `Beingpax/mediaremote-adapter`, plus a
  faked HID Play/Pause key). It is OFF by default and OFF for the user, and it relies on a fragile private API. Drop it for v1.
- Resume-delay picker (0-5 s, `audioResumptionDelay`, default 0). Hardcode 0.
- The "Using: <mic>" toast every time the device changes (`lastUsedMicrophoneDeviceID`). Optional, low value.
- Notch recorder vs mini recorder styles (`RecorderType`). The UI is a separate subsystem, but only one style is needed.
- Dropped-buffer counters and verbose device logging (transport type, manufacturer, buffer size).
- There is NO max-duration limit and NO silence detection or auto-stop at the recording layer. Nothing to port.
  (FluidAudio transcription pads 1 s of trailing zeros, `16_000` samples, for punctuation. That belongs to the transcription note.)

## 2. Key files and control flow

| File | Role |
|---|---|
| `CoreAudioRecorder.swift` (1307 LOC) | AUHAL capture, lock-free ring buffer, mono mixdown, resample, WAV write, chunk callback, meters |
| `Recorder.swift` + `Recorder+RecordingDeviceSetup.swift` | `@MainActor` facade: device resolution, serial setup queue, mute/pause, meter smoothing |
| `Services/AudioDeviceManager.swift` + `+RecordingRouting.swift` | Device enumeration, input mode, UID persistence, device-list listener, clamshell routing |
| `Services/ClamshellStateMonitor.swift` | IOKit `IOPMrootDomain` / `AppleClamshellState` watcher |
| `MediaController.swift` | System output mute/unmute (CoreAudio `kAudioDevicePropertyMute`) |
| `PlaybackController.swift` | MediaRemote pause/resume (DROP) |
| `SoundManager.swift`, `SoundPlaybackEngine.swift`, `Resources/Sounds/*` | AVAudioPlayer start/stop/esc sounds |
| `Views/Recorder/AudioVisualizerView.swift` | 15-bar waveform driven by `recorder.audioMeterSnapshot()` |
| `Transcription/Engine/VoiceInkEngine.swift` | `toggleRecord`, `RealtimeAudioChunkGate`, file naming, cancel, recordings dir |
| `Transcription/Engine/RecorderUIManager.swift` | Plays the start sound, shows the panel, calls `engine.toggleRecord()` |
| `Transcription/Engine/TranscriptionDelivery.swift` | Plays the stop sound right before paste (not at mic stop) |
| `Transcription/Streaming/PCMAudioConverter.swift` | Int16 `Data` -> `[Float]` (/32767, clamped) for FluidAudio |

Start flow:
1. Hotkey -> `RecorderUIManager.toggleRecorderPanel()`: `SoundManager.playStartSound()`, show the panel, then `engine.toggleRecord()`.
2. `toggleRecord` (idle branch): url = `recordingsDirectory/UUID().wav`. It installs `recorder.onAudioChunk = gate.receive`
   (the gate buffers chunks until the streaming session is ready), sets state `.starting`, then calls `await recorder.startRecording(url)`.
3. `Recorder.startRecording`: `resolveCurrentRecordingDevice()`; with no device it throws `noUsableMicrophone(builtInBlockedByClosedLid:)`.
   It calls `pauseMedia()` (immediately) and `muteSystemAudio()` (delayed **220 ms** so the start sound is audible), then on
   `audioSetupQueue` (serial, `.userInitiated`) runs `CoreAudioRecorder.startRecording(url, deviceID)`. If that fails while the lid is closed
   and the device was built-in, it retries once, excluding that device.
4. `CoreAudioRecorder.startRecording`: `stopRecording()` (idempotent), `prepare(deviceID)` (a no-op if already prepared for that device and it is alive),
   `createOutputFile`, reset ring indices, `AudioOutputUnitStart`.
5. Back in the engine: if the panel was dismissed or cancelled meanwhile, it stops. Otherwise state `.recording`, create the streaming session,
   `gate.activate(realCallback)` flushes the buffered chunks in order, then goes live.

Stop flow: `toggleRecord` (recording branch): state `.transcribing` -> `await recorder.stopRecording()` (on setupQueue: stop AU,
wait for in-flight callbacks, `AudioUnitReset`, drain the processing queue synchronously, `ExtAudioFileDispose`), then insert a pending
`Transcription` (with `audioFileURL = url.absoluteString`) and run the pipeline. Unmute and media resume run in a detached Task.
The stop sound plays later, in `paste()`, just before `CursorPaster` fires.

Cancel: `.starting/.recording` -> `shouldCancelRecording = true`, stop the recorder, save a "canceled" history row with the WAV and its duration
(`AVURLAsset.load(.duration)`), state `.idle`. Toggling again while `.starting` also cancels.

States: `enum RecordingState { idle, starting, recording, transcribing, enhancing, busy }`.

## 3. Exact technical details (easy to get wrong)

**Capture = AUHAL, not AVAudioEngine and not AVAudioRecorder.** AUHAL (`kAudioUnitSubType_HALOutput`) records from a specific
`AudioDeviceID` WITHOUT changing the system default input. That is the reason it was chosen (comment: "AUHAL-based, does not change system default device").
- Enable IO: `kAudioOutputUnitProperty_EnableIO` = 1 on `kAudioUnitScope_Input`, element **1**. Set it to 0 on `kAudioUnitScope_Output`, element **0**.
- Device: `kAudioOutputUnitProperty_CurrentDevice`, `kAudioUnitScope_Global`, element 0.
- Read the device format: `kAudioUnitProperty_StreamFormat`, `kAudioUnitScope_Input`, element 1.
- Callback (client) format: set on `kAudioUnitScope_Output`, element 1: Float32, interleaved, packed, **at the DEVICE sample rate**,
  channels = selected channel count. The AUHAL input side does not do sample-rate conversion, so resampling happens in our own code.
- Channel map: `kAudioOutputUnitProperty_ChannelMap` (Output scope, element 1) = `[Int32]` of 0-based device channels. Source:
  `kAudioDevicePropertyPreferredChannelsForStereo` (input scope, 1-based, 2 values). Validate that each value is in `1...channelCount`,
  dedupe, subtract 1. Fallback: the first `min(n, 2)` channels. This matters for multi-channel USB interfaces.
- Input callback: `kAudioOutputUnitProperty_SetInputCallback` (Global, element 0) with `Unmanaged.passUnretained(self)`.
  Inside the callback, call `AudioUnitRender(unit, flags, ts, bus, frames, &bufferList)` into a **pre-allocated** buffer. Never malloc in the callback.
- Prepare = create + configure + `AudioUnitInitialize`, but no Start. This runs at init and on the `"AudioDeviceChanged"` notification when not recording,
  and only if `AVCaptureDevice.authorizationStatus(for: .audio) == .authorized`. Start then only creates the file and calls `AudioOutputUnitStart`.
- Render capacity: `max(4096, kAudioDevicePropertyBufferFrameSize)` frames x channels.

**Real-time pipeline:** render callback -> meter calc -> copy into an SPSC ring of **96 pre-allocated slots** (atomic write/read
indices from `swift-atomics`, drop on overflow) -> schedule once (atomic flag) on the serial `audioProcessingQueue` (`.userInitiated`) ->
mono mixdown + resample -> `ExtAudioFileWrite` -> `onAudioChunk(Data)`. So **`onAudioChunk` runs on the processing queue, not
the RT thread and not the main thread**. Chunk = one render buffer (for example 512 frames at 48 kHz gives ~170 Int16 samples, ~340 bytes), little-endian.

**Output file:** `ExtAudioFileCreateWithURL(url, kAudioFileWAVEType, &fmt, nil, AudioFileFlags.eraseFile, &ref)` + set
`kExtAudioFileProperty_ClientDataFormat` to the same format. Format: 16000 Hz, LinearPCM, `SignedInteger|Packed`, 16-bit, 1 ch,
2 bytes/frame. **Call `ExtAudioFileDispose` before handing the file to anyone, because it finalizes the WAV header.**

**Stop sequence (order matters):** set `recordingActive=false` -> `AudioOutputUnitStop` -> spin until the in-flight callback counter is 0
(`Thread.sleep(0.001)`) -> `AudioUnitReset(Global,0)` -> drain the processing queue with `sync` (guard against calling it re-entrantly via a
`DispatchSpecificKey`) -> dispose the file -> reset the meters to -160 dB. The AU stays initialized for the next recording (warm).

**Known bugs / quirks in old code (do not copy):**
- Resampler: the old code resamples each buffer on its own with linear interpolation. It has no anti-alias low-pass (48k->16k aliases) and no state
  carried across buffers, and `outputFrameCount = UInt32(frames * ratio)` truncates the fractional frame every buffer (512@48k gives 170 instead of 170.67,
  so ~0.4 % of samples are lost and speech is slightly time-compressed). **Use a persistent `AVAudioConverter`** (Float32 mono @device-rate ->
  Int16 mono @16k) on the processing queue instead.
- Mono mixdown averages the mapped channels, so a mono mic on stereo channel 1 of 2 (with channel 2 silent) comes out 6 dB quieter.
- `requestRecordPermission` in the engine is a stub that always returns `true`. Mic permission is only requested during onboarding
  (`AVCaptureDevice.requestAccess(for: .audio)`). The new app must check the permission before each start.
- `AudioDeviceManager.deinit` removes the device-list listener with a *different* closure literal, which is a no-op. Use
  `AudioObjectAddPropertyListenerBlock` and keep the block so removal works.
- The recordings dir is inconsistent: the engine writes to `~/Library/Application Support/com.prakashjoshipax.VoiceInk/Recordings`
  (this is where the user's real files are), but the cleanup and file-transcription services use `.../pl.kawalec.VocaType/Recordings`, which does not exist.
  Use ONE `AppPaths.recordings` in v2. For the data migration, old rows store `audioFileURL` as `file://...` absoluteString pointing to the
  `com.prakashjoshipax.VoiceInk` dir.

**Device enumeration (CoreAudio HAL):**
- List: `kAudioHardwarePropertyDevices` on `kAudioObjectSystemObject`. An input device is one where `kAudioDevicePropertyStreamConfiguration`
  (scope `kAudioDevicePropertyScopeInput`) has an `AudioBufferList` with any `mNumberChannels > 0`. Allocate the raw buffer at the returned size
  with `AudioBufferList` alignment.
- Name `kAudioDevicePropertyDeviceNameCFString`, UID `kAudioDevicePropertyDeviceUID`, model UID `kAudioDevicePropertyModelUID`,
  transport `kAudioDevicePropertyTransportType` (`== kAudioDeviceTransportTypeBuiltIn` means built-in), alive `kAudioDevicePropertyDeviceIsAlive`.
- System default input: `kAudioHardwarePropertyDefaultInputDevice`. It is re-read at every start.
- Persist **UID + model UID** (`selectedAudioDeviceUID`, `selectedAudioDeviceModelUID`), never the `AudioDeviceID` (it is not stable across reboots
  or reconnects). Lookup: exact UID first, then the first available device with the same model UID (UIDs of some USB/BT devices change per port or reconnect).
  If neither is found, fall back.
- Fallback order: built-ins then externals; **when the lid is closed, externals then built-ins, and built-in devices are unusable**.
- Old UserDefaults keys (for migration): `audioInputMode` (`"System Default"|"Custom Device"|"Prioritized"`),
  `selectedAudioDeviceUID`, `selectedAudioDeviceModelUID`, `isSystemMuteEnabled` (default true), `isPauseMediaEnabled` (default false),
  `audioResumptionDelay` (0). Domains seen on disk: `com.prakashjoshipax.VoiceInk` and `pl.kawalec.VocaType`.

**Clamshell:** IOKit `IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))`, read the
`"AppleClamshellState"` CFBool, and subscribe with `IOServiceAddInterestNotification(port, root, kIOGeneralInterest, ...)` on a port whose
dispatch queue is main.

**Metering:** per callback over all float samples: `rms = sqrt(sum(x^2)/n)`, `peak = max|x|`, `dB = 20*log10(max(v, 1e-6))`,
stored as `Float.bitPattern` in relaxed atomics (the callback takes no locks). UI read path (`Recorder.audioMeterSnapshot`): clamp and normalize
`-60...0 dB -> 0...1`, then EMA `s = s*0.6 + new*0.4` (behind an NSLock), reset to 0 on start and stop. EMA runs **per UI frame** (TimelineView
~60 fps), so the smoothing depends on frame rate.

**Visualizer:** 15 bars, 3 pt wide, 2 pt gap, height 4...28 pt, `TimelineView(.animation(minimumInterval: 0.016))`.
`amp = pow(avg, 0.7)`, `wave = sin(t*8 + i*0.4)*0.5+0.5`, `centerBoost = 1 - (|i - 7.5| / 7)*0.4`,
`h = max(4, 4 + amp*wave*centerBoost*24)`. When idle it shows flat 4 pt bars at 50 % opacity.

**Sounds:** `AVAudioPlayer`, preloaded (`prepareToPlay`) on a private serial queue. Start = `sound5.mp3` (0.456 s), stop = `sound6.mp3`
(0.456 s), both at volume 0.3. Esc/error = `sound7.wav` (0.34 s) at volume 0.2, played by `NotificationManager` for `.error` notifications.
Start plays before the mic starts. Stop plays at paste time, after transcription.

**System mute (keep):** default output = `kAudioHardwarePropertyDefaultOutputDevice`. Property `kAudioDevicePropertyMute`, scope
`kAudioDevicePropertyScopeOutput`, element `Main`, **falling back to element 0** if `AudioObjectHasProperty` is false. Check
`AudioObjectIsPropertySettable` (some HDMI/USB outputs have no mute, so it fails silently). Ownership rule: **only unmute if WE muted.** If the user
had already muted, leave it muted. A `muteGeneration` counter stops a late unmute from undoing a newer mute.

**Permissions/entitlements:** `NSMicrophoneUsageDescription` in Info.plist, `com.apple.security.device.audio-input = true`,
hardened runtime. Denied -> deep link `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone`.

## 4. Code excerpts (verbatim, trimmed)

AUHAL setup (from `createAudioUnit` / `configureCaptureFormat`):
```swift
var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
    componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple,
    componentFlags: 0, componentFlagsMask: 0)
guard let component = AudioComponentFindNext(nil, &desc) else { throw ... }
AudioComponentInstanceNew(component, &unit)
var enableInput: UInt32 = 1
AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                     &enableInput, UInt32(MemoryLayout<UInt32>.size))
var disableOutput: UInt32 = 0
AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                     &disableOutput, UInt32(MemoryLayout<UInt32>.size))
// ... kAudioOutputUnitProperty_CurrentDevice (Global, 0) = deviceID
var callbackFormat = AudioStreamBasicDescription(
    mSampleRate: deviceFormat.mSampleRate, mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
    mBytesPerPacket: UInt32(MemoryLayout<Float32>.size) * channelCount, mFramesPerPacket: 1,
    mBytesPerFrame: UInt32(MemoryLayout<Float32>.size) * channelCount,
    mChannelsPerFrame: channelCount, mBitsPerChannel: 32, mReserved: 0)
AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                     &callbackFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
var channelMap = selection.deviceChannelIndices   // [Int32], 0-based
channelMap.withUnsafeMutableBytes { bytes in
    AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 1,
                         bytes.baseAddress, UInt32(bytes.count)) }
```

Render callback core (`handleInputBuffer`):
```swift
renderCallbacksInFlight.wrappingIncrement(ordering: .acquiringAndReleasing)
defer { renderCallbacksInFlight.wrappingDecrement(ordering: .acquiringAndReleasing) }
guard let audioUnit = audioUnit, recordingActive.load(ordering: .acquiring) else { return noErr }
let requiredSamples = inNumberFrames * channelCount
guard let renderBuf = renderBuffer, requiredSamples <= renderBufferSize,
      requiredSamples <= inputBufferCapacitySamples else { return noErr }   // count drop
var bufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
    mNumberChannels: channelCount, mDataByteSize: inNumberFrames * 4 * channelCount, mData: renderBuf))
let status = AudioUnitRender(audioUnit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, &bufferList)
if status != noErr { return status }
calculateMeters(from: &bufferList, frameCount: inNumberFrames)     // RMS/peak -> atomic bitPattern
enqueueInputBuffer(&bufferList, frameCount: inNumberFrames, inputSampleRate: inputSampleRate)
// enqueue: if write - read < 96 { copy into slot[write % 96]; write += 1 (releasing); schedule once }
```

Startup chunk gate (in `VoiceInkEngine.swift`). The idea to keep: buffer the first audio until the streaming model is ready, so the first word is not lost:
```swift
private final class RealtimeAudioChunkGate: @unchecked Sendable {
    private struct State { var bufferedChunks: [Data] = []; var callback: ((Data) -> Void)?
                           var isActive = false; var droppedChunks = 0 }
    private let maxBufferedChunks = 2_048
    private let state = OSAllocatedUnfairLock(initialState: State())
    func receive(_ data: Data) {
        let callback = state.withLock { s -> ((Data) -> Void)? in
            guard s.isActive else {
                if s.bufferedChunks.count < maxBufferedChunks { s.bufferedChunks.append(data) }
                else { s.droppedChunks += 1 }
                return nil }
            return s.callback }
        callback?(data)
    }
    // activate(cb): set callback, then loop { flush buffered outside the lock; if buffer empty under lock -> isActive = true; return }
}
```

Mute ownership (`MediaController.muteSystemAudio`):
```swift
unmuteTask?.cancel(); muteGeneration += 1
if isSystemAudioMuted() {
    if didMuteAudio { wasAudioMutedBeforeRecording = false }       // we muted earlier, still ours
    else { wasAudioMutedBeforeRecording = true; didMuteAudio = false } // user muted, never unmute
    return true
}
wasAudioMutedBeforeRecording = false
didMuteAudio = setSystemMuted(true)
// unmute: shouldUnmute = didMuteAudio && !wasAudioMutedBeforeRecording; after delay, only if generation unchanged
```

Clamshell read:
```swift
rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
let closed = IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellState" as CFString,
                                             kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
// notify: IONotificationPortCreate + IONotificationPortSetDispatchQueue(port, .main)
//         + IOServiceAddInterestNotification(port, rootDomain, kIOGeneralInterest, cb, refcon, &notifier)
```

## 5. Recommended minimal design for v2

- **`AudioCapture` (final class, `@unchecked Sendable`, ~300 LOC).** An AUHAL port of `CoreAudioRecorder`: `prepare(deviceID)`, `start(url:)`, `stop()`,
  `onChunk: (@Sendable ([Float]) -> Void)?`, `level: Float` (atomic). Keep the pre-allocated render buffer, the SPSC ring (use `Synchronization.Atomic`
  on macOS 15+, or `swift-atomics`) and the in-flight counter used at stop. Drop `switchDevice`.
- **Resampling:** one persistent `AVAudioConverter` (device-rate Float32 mono -> 16 kHz Float32 mono) on the processing queue. Mix down first
  (average, or better max-abs-channel pick for 2-ch). Emit `[Float]` at 16 kHz to the transcriber (FluidAudio wants Float anyway, so the
  Int16 -> Float round-trip goes away). Write Int16 to the WAV via `ExtAudioFile` (client format Float32, file format Int16, so ExtAudioFile converts).
- **`AudioDevices` (`@MainActor @Observable`).** Holds `inputs: [InputDevice{id, uid, modelUID, name, isBuiltIn}]`,
  `mode: .systemDefault | .custom(uid, modelUID)`, and `resolve() -> AudioDeviceID?` with the lid-closed rule. It refreshes on
  `AudioObjectAddPropertyListenerBlock(kAudioHardwarePropertyDevices)` and `kAudioHardwarePropertyDefaultInputDevice`.
- **`LidMonitor`.** About 40 LOC copied from `ClamshellStateMonitor`, publishing `isClosed`.
- **`RecordingController` (`@MainActor`, the single owner of state).** Holds `state: idle|starting|recording|processing`. `start()`: check mic
  permission -> resolve device (error toast if none) -> play start sound -> mute after 220 ms -> `await capture.start` on the setup queue -> `.recording`.
  `stop()` -> capture.stop -> unmute -> hand `(url, duration)` to the transcription pipeline. `cancel()` stops, deletes (or keeps) the file, returns to idle.
  If the device dies mid-recording, call `stop()`.
- **`ChunkGate`.** Keep the `RealtimeAudioChunkGate` idea (buffer up to ~2k chunks until the Parakeet stream is prepared, then flush in order).
- **`SystemMute`.** About 60 LOC: default output mute via CoreAudio with the "only unmute what we muted" rule and a generation counter. One toggle, default ON.
- **`Sounds`.** Three preloaded `AVAudioPlayer`s (start/stop/error, volumes 0.3/0.3/0.2) and one on/off toggle. Ship `sound5.mp3`, `sound6.mp3`
  and `sound7.wav`, or new assets.
- **`LevelMeter` for the UI:** read `capture.level` (dB) -> normalize -60...0 -> smooth with a **time-based** EMA (for example tau of about 80 ms), so it
  is frame-rate independent. The visualizer reuses the 15-bar formula above.
- **`AppPaths.recordings`:** a single source of truth, `~/Library/Application Support/<v2 bundle id>/Recordings/<UUID>.wav`. Store a
  **relative filename** in the DB, not an absolute `file://` URL, so the folder can move.
- Warm-up: call `capture.prepare(resolvedDevice)` at launch (only if mic is authorized) and whenever the device list, default input or lid state changes.
- Serial `setupQueue` for prepare/start/stop, bridged to async with `withCheckedThrowingContinuation`. Never call AUHAL setup on the main thread.
