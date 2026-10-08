# macOS code guide

The Mac app captures screen video and system/app audio, sends them to a paired
receiver, and independently generates live captions. The reorganization splits
files by responsibility without introducing new queues or changing method bodies.

## Start here

1. [App entry point](../macOSFramesToFireTV/macOSFramesToFireTV/App/macOSFramesToFireTVApp.swift)
   creates the shared model, menu-bar UI, and pairing window.
2. [Menu bar](../macOSFramesToFireTV/macOSFramesToFireTV/macOS/UI/MacMenuBarContent.swift)
   shows receivers, quality, caption settings, and streaming controls.
3. [Streaming model](../macOSFramesToFireTV/macOSFramesToFireTV/macOS/Streaming/MacStreamingModel.swift)
   connects the UI to SnapCore capture, transport, and captions. Its initializer
   wires callbacks; `startStreaming()` and `stopStreaming()` own capture lifecycle.
4. [Transport](../macOSFramesToFireTV/macOSFramesToFireTV/macOS/Transport/MacFireTVTransport.swift)
   owns the connection, encoder, session state, locks, queue, and limits.

## Folder map

All feature code lives under `macOSFramesToFireTV/macOSFramesToFireTV/macOS/`.

| Folder | Files and responsibilities |
| --- | --- |
| `UI` | `MacMenuBarContent.swift`: menu controls. `MacPairingView.swift`: pairing window and its window identifier. |
| `Streaming` | `MacStreamingModel.swift`: capture/session coordination. `MacStreamQuality.swift`: user-facing quality choices. `CinemaQualityLevel.swift`: adaptive bitrate ladder. `ReceiverBufferPolicy.swift`: buffer health classification. `CinemaAACEncoder.swift`: PCM-to-AAC conversion and its converter callback. |
| `Transport` | `MacFireTVTransport.swift`: shared state, encoder setup, session cleanup, frame admission, and protocol limits. `MacFireTVDevice.swift`: receiver identity and connection-state presentation. `Data+WireEncoding.swift`: big-endian wire encoding. `MacMediaKeyController.swift`: remote play/pause key injection. |
| `Transport` extensions | `+Discovery.swift`: browsing and connection setup. `+Pairing.swift`: incoming JSON, authentication, trust, and commands. `+Media.swift`: video/audio/caption entry points, packet encryption, and network writes. `+AdaptiveQuality.swift`: receiver reports and quality changes. |
| `Captions` | `LiveCaptionExperiment.swift`: WhisperKit loading/inference lifecycle. `CaptionMode.swift`: language/task/model choices. `CaptionAudioTap.swift`: bounded audio admission and 16 kHz conversion. `CaptionAudioWindow.swift`: rolling inference input. `CaptionRevisionState.swift`: committed text, partial revisions, and outgoing cue format. |
| `Security` | `TrustedReceiverStore.swift`: remembered receiver secrets and service-name associations. `ReceiverControlAuthentication.swift`: authenticated control-message validation. |

Files with `+` in their names are Swift extensions of the **same transport object**,
not additional services. They share state; they do not add another connection or
an extra stage to frame delivery. Members shared across these files have internal
access because Swift `private` cannot cross source files. They remain implementation
details of this application, with queue/lock ownership preserved.

App metadata, entitlements, asset catalogs, the Xcode project, and shared schemes
retain their conventional locations. The independent test package remains at
`macOSFramesToFireTV/Package.swift`; test files are grouped into `Captions`,
`Streaming`, and `Security` under `Tests/PlaybackPolicyTests/`.

## Trace a frame

`ScreenRecordService.onScreenFrame` → `MacFireTVTransport.sendVideo` →
SnapCore `LiveMediaEncoder` → encoder `onPacket` → `sendMedia` →
`encryptAndSend` → bounded `enqueue`/`write` → receiver.

The capture callback forwards the original pixel buffer and presentation timestamp.
The transport bounds encoder admission and pending writes. The approximately
750 ms playback buffer belongs to the receiver; the Mac does not hold a frame
while waiting for Whisper.

## Trace audio and a caption

`ScreenRecordService.onAudioFrame` forwards each audio buffer to both:

- `transport.sendAudio`: the normal media path, including negotiated AAC conversion.
- `captions.offer`: bounded background audio conversion and rolling-window input.

`LiveCaptionExperiment` runs Whisper inference independently, passes results through
`CaptionRevisionState`, and emits cues through `transport.sendCaption`. Caption
packets share the encrypted connection, but have a single pending slot rather
than an accumulating subtitle backlog. The receiver renders them over video.

## Concurrency rules to preserve

- `MacStreamingModel` and the UI run on the main actor.
- Connection/session state and pending writes belong to the transport's `networkQueue`.
- Streaming-key/audio-format reads use `keyLock`; encoder admission uses
  `frameAdmissionLock` because capture and encoder callbacks cross queues.
- SnapCore owns its encoder processing queue. AAC conversion keeps its existing lock.
- Caption conversion and Whisper inference stay outside frame delivery. Inference
  never gates video capture or sending.

## Verify changes

Run `swift test --package-path macOSFramesToFireTV` for caption audio conversion,
rolling windows, revision handling, buffer policy, and authenticated controls.
Build the `macOSFramesToFireTV` Xcode scheme in Release to verify application wiring.
For changes to capture, transport, or inference, also check a real stream with
speech playing; a build and unit tests do not establish runtime smoothness.
