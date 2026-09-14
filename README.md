# Frames — Local Network Screen Mirroring


This repository is a collection of Apple and Android projects for securely mirroring an iPhone, iPad, or Mac over the local network.

Supported paths:

| Sender | Receiver | Project |
| --- | --- | --- |
| iPhone or iPad | Fire TV / Android TV | `iOSFramesToFireTV.xcodeproj` + `fire-tv/` |
| Mac | Fire TV / Android TV | `macOSFramesToFireTV/macOSFramesToFireTV.xcodeproj` + `fire-tv/` |
| Mac | iPhone or iPad | `macOSFramesToFireTV/macOSFramesToFireTV.xcodeproj` + `iOSFramesReceiver/iOSFramesReceiver.xcodeproj` |

All pairing and media traffic stays on the LAN. A six-digit code authenticates each session, PBKDF2-HMAC-SHA256 derives the session key, and AES-256-GCM protects every media packet.

## Repository layout

```text
.
├── iOSFramesToFireTV.xcodeproj/       iPhone/iPad sender project
├── iOSFramesToFireTV/                 Sender app and pairing UI
├── FireTVBroadcast/                   ReplayKit broadcast upload extension
├── FireTVBroadcastSetupUI/            ReplayKit setup UI extension
├── Configuration/                     Shared iOS sender configuration
├── macOSFramesToFireTV/
│   ├── macOSFramesToFireTV.xcodeproj/ Mac sender project
│   └── macOSFramesToFireTV/
│       └── macOS/                     Mac capture, encoding, and transport
├── iOSFramesReceiver/                 Standalone iPhone/iPad receiver project
└── fire-tv/                           Kotlin Android TV / Fire TV receiver
```

## Projects and targets

### `iOSFramesToFireTV.xcodeproj`

The original iPhone/iPad-to-Fire-TV sender consists of three targets.

#### `iOSFramesToFireTV`

The main SwiftUI app:

- Discovers Fire TV receivers through Bonjour using `_iosfiretv._tcp`.
- Supports a direct-IP fallback when multicast discovery is unavailable.
- Authenticates using the displayed six-digit code once, then remembers that Fire TV.
- Stores the chosen destination in the shared app-group container for the broadcast extension.
- Opens the system ReplayKit broadcast picker.

#### `FireTVBroadcast`

The ReplayKit broadcast upload extension:

- Receives screen and app-audio sample buffers while the sender app is backgrounded.
- Uses hardware H.264 encoding through VideoToolbox.
- Sends Annex-B H.264 access units and stereo PCM audio.
- Encrypts all media with the authenticated session key.
- Prioritizes fresh frames instead of allowing an old-frame queue to build up.

The microphone is intentionally excluded.

#### `FireTVBroadcastSetupUI`

The small ReplayKit setup extension used by the system broadcast flow.

### `macOSFramesToFireTV/macOSFramesToFireTV.xcodeproj`

This is the macOS-only SwiftUI sender target.

#### macOS build — Mac sender

The Mac version:

- Captures a user-selected display with SnapCore and ScreenCaptureKit.
- Captures stereo system audio while excluding the microphone and the sender app's own audio.
- Encodes H.264 in real time with B-frames disabled.
- Discovers named Fire TV and iPhone/iPad receivers and targets only the selected device.
- Advertises `_framesmac._tcp` so the Fire TV or iOS receiver can connect to it.
- Uses the receiver's six-digit code once, then remembers that receiver securely for later sessions.
- Treats HD, Full HD, QHD, and UHD as maximum-quality choices and adapts
  bitrate first, then resolution, without going below 720p.

Screen Recording permission is required on first launch.

### `iOSFramesReceiver/iOSFramesReceiver.xcodeproj`

This standalone iOS/iPadOS app uses bundle ID `com.aryanrogye.iOSFramesReceiver` so it can have its own App Store Connect and TestFlight record.

#### iOS/iPadOS Mac receiver

The iPhone/iPad version:

- Displays a rotating six-digit pairing code.
- Advertises its device name and a stable, non-secret receiver ID through Bonjour.
- Discovers `_framesmac._tcp` Mac senders using Bonjour.
- Remembers approved Macs so routine connections no longer require the code.
- Connects to the Mac and performs the same authenticated handshake as the Fire TV receiver.
- Parses and decrypts framed AES-GCM media records.
- Converts Annex-B H.264 access units for `AVSampleBufferDisplayLayer` hardware playback.
- Negotiates interleaved 16-bit PCM until AAC encoder-delay/trim metadata exists.
- Buffers about 750 ms and reconciles video against measured audio playback, including output latency.
- Caps queued audio at three seconds and restarts both timelines on audio gaps or starvation.
- Provides an embedded preview and a distraction-free full-screen player.
- Reconnects after interrupted sessions and offers a manual session reset.

The receiver is intended for foreground playback. iOS may suspend networking and video when the app is backgrounded or the device is locked.

### `fire-tv/`

The Kotlin Fire TV / Android TV receiver:

- Targets Android SDK 35 with a minimum SDK of 26.
- Advertises `_iosfiretv._tcp` for iPhone/iPad senders.
- Discovers `_framesmac._tcp` when receiving from a Mac.
- Displays and rotates a six-digit pairing code.
- Decrypts media using AES-GCM.
- Decodes H.264 with Android `MediaCodec` onto a `Surface`.
- Negotiates PCM audio so timestamps do not include unreported AAC priming delay.
- Uses a 750 ms startup buffer and timestamped `SurfaceView`
  presentation to avoid partial-frame updates and decoder corruption.
- For negotiated Mac sessions, routes the Fire TV remote's play/pause button
  to the Mac system media key so browser video responds normally.

The Android project uses Gradle, Kotlin, and Java 17.

The Fire TV receiver advertises the name configured on the device (falling back to its manufacturer and model) and remembers approved Macs in app-private storage.

## Requirements

- A Mac with the appropriate Xcode version for the deployment targets configured in each project.
- A physical iPhone or iPad for ReplayKit broadcasting and realistic receiver testing.
- Android Studio or a Java 17 environment for the Fire TV project.
- A Fire TV or Android TV device running Android 8.0 / API 26 or newer.
- Sender and receiver connected to the same local network.
- Local Network permission enabled for the Apple apps.
- Screen Recording permission enabled for the Mac sender.

A 5 GHz or wired receiver connection is recommended for 1080p/60 playback.

## Build and run

### iPhone/iPad → Fire TV

1. Build and install the Fire TV receiver:

   ```sh
   cd fire-tv
   ./gradlew assembleDebug
   adb install -r app/build/outputs/apk/debug/app-debug.apk
   ```

2. Launch the receiver and leave its pairing-code screen open.
3. Open `iOSFramesToFireTV.xcodeproj` in Xcode.
4. Select the `iOSFramesToFireTV` scheme and run it on a physical iPhone or iPad.
5. Select the discovered TV, or enter its IP address manually.
6. The first time, enter the TV's six-digit code and pair. Later sessions can use the remembered TV without a code.
7. Tap the broadcast button, choose `FireTVBroadcast`, and start broadcasting.

ReplayKit may intentionally produce black video for DRM-protected content. Some protected `AVPlayer` content cannot be captured.

### Mac → Fire TV

1. Build and launch `fire-tv/` on the television.
2. Open `macOSFramesToFireTV/macOSFramesToFireTV.xcodeproj` in Xcode.
3. Run the `macOSFramesToFireTV` scheme with **My Mac** selected.
4. Select the Fire TV. The first time, enter its displayed code and start pairing.
5. On later sessions, select the remembered Fire TV and connect without a code.
6. After authentication, choose a display and begin streaming.

### Mac → iPhone/iPad

1. Open `iOSFramesReceiver/iOSFramesReceiver.xcodeproj` in Xcode.
2. Run the `iOSFramesReceiver` scheme on the physical iPhone or iPad.
3. Leave the iOS receiver open and note its six-digit code.
4. Run the same scheme on the Mac.
5. Select the iOS receiver. The first time, enter its code in the Mac app and start pairing.
6. On later sessions, select the remembered receiver and connect without a code.
7. Choose a display on the Mac.
8. Tap the expand button in the iOS preview to enter full-screen playback.

The Mac includes the selected receiver's stable ID in its short-lived Bonjour advertisement, so other open receivers ignore that stream request.

## Protecting A/V synchronization

A/V synchronization is a merge-blocking correctness contract for the Fire TV
receiver. Video must use the measured audio playback position as its presentation
clock; queue arrival, decode completion, and `AudioTrack.play()` call time must
never become independent video clocks.

Run the same safety gate used by CI before merging receiver changes:

```sh
cd fire-tv
./gradlew :app:verifyPlaybackSafety
```

The gate runs deterministic clock regression tests and builds both debug and
release APKs. The tests cover delayed HDMI startup, invalid Fire OS timestamps,
clock discontinuities, stalled audio, jitter, long playback, counter wrapping,
reset behavior, and the video submission window. The latter reproduces a device
trace with video scheduled 1,921 ms early: SurfaceView may ignore timestamps
over about one second ahead, so decoded frames must remain application-owned
until within 30 ms of their audio-clock deadline. They must be reconsidered
against the current clock after a hold, and invalidated on codec flush/release.
The GitHub workflow is named `Fire TV playback safety`; make
its `A/V sync contract and APK builds` check required in the `main` branch
protection rules so a failing or skipped result cannot be merged.

Test the Mac's buffer policy too: `swift test --package-path macOSFramesToFireTV`.
Test iOS audio bounds, clock decisions, and control authentication with
`swift test --package-path iOSFramesReceiver`. Swift and Kotlin share an
OpenSSL-checked control authentication vector; tests reject tampering,
replays, and records from a different handshake.
CI runs it on every PR to main, including sender-only changes. The sender uses
the receiver's `targetBufferMs` report field (750 ms for older receivers that
omit it) so normal pre-roll is not misclassified using a different receiver's
latency target. Tests retain coverage for older 180 ms Fire TV builds.
Decoder pressure also excludes video intentionally waiting behind queued audio:
the raw video queue duration includes cinema pre-roll and must not itself
trigger a resolution/capture restart. Genuine excess backlog and audio
starvation remain downgrade signals.

Fire TV currently negotiates 16-bit PCM because the AAC wire format does not
carry encoder priming/trim metadata. At 48 kHz stereo this uses about 1.54 Mbps
for audio. PCM packet timestamp gaps cause audio to rebuffer on a fresh timeline;
repeated identical H.264 configuration packets preserve the existing decoder.

These checks verify software timing rules; they do not measure sound reaching
the listener. Before releasing playback changes, run a paired Mac-to-Fire TV
lip-sync clip through cold start, at least ten minutes of playback, pause/resume,
and reconnect. Include high-motion scenes and replay the same scene before and
after a change; a quiet desktop is not a congestion test. Check for blackouts,
stutter and persistent audio lead/lag as well as `FireTVMedia` delivery-gap,
clock-gap/recovery logs and AudioTrack underrun counts. Submission `leadMs`
must never exceed 30 ms, even when incoming video is seconds ahead of audio.
A successful APK launch alone is not a
playback synchronization test.

The clock/presentation test also simulates ten minutes of burst-delivered video
using the production clock and submission policy. This is deterministic fake
time, not a substitute for the ten-minute physical playback check above.

## Media pipeline

### Cinema playback

Mac-to-receiver sessions default to a playback-first pipeline:

- iOS accumulates about 750 ms before starting; Fire TV buffers 750 ms of audio
  and waits for an advancing playback position before presenting video.
  Fire TV's one-second AudioTrack capacity exceeds this pre-roll so startup
  cannot block on a full, stopped track. This deliberately favors watching
  continuity over minimum interactive mirroring latency; it does not guarantee
  uninterrupted playback across sustained network/capture outages.
- Audio is the playback clock; video presentation timestamps are scheduled
  against that clock instead of being displayed immediately on arrival.
- Sender and receiver queues preserve H.264 dependency order under normal
  congestion. If a hard bound is exceeded, the receiver flushes once and asks
  the Mac for a clean keyframe rather than decoding a broken GOP.
- Receivers report buffer health, decoder backlog, underruns, and recoveries
  four times per second. The Mac lowers bitrate first, then resolution, and
  cautiously restores quality after a sustained healthy period.
- The quality floor is 720p. The picker specifies the ceiling, not a forced
  resolution.

This remains an ordered, encrypted TCP protocol. Switching transports would
not remove H.264 frame dependencies; the buffering, clocking, recovery, and
adaptive policy are what make video playback resilient.

### Video

- Hardware H.264 encoding and decoding.
- Up to 60 frames per second.
- 10 Mbps default Full HD bitrate on macOS.
- Half-second keyframe interval for bounded recovery time.
- Real-time VideoToolbox encoding with B-frames disabled.
- SPS/PPS configuration followed by Annex-B access units.
- Bounded queues preserve ordered frames and recover at a clean keyframe only
  when a hard limit is reached.

### Audio

- AAC-LC at 192 kbps stereo or 96 kbps mono for capable Mac receivers.
- Interleaved signed 16-bit PCM fallback.
- Mono or stereo protocol support.
- App audio from ReplayKit on iOS.
- System audio from ScreenCaptureKit/SnapCore on macOS.
- Microphone audio is not transmitted.

## Discovery and connection roles

| Service | Advertised by | Discovered by |
| --- | --- | --- |
| `_iosfiretv._tcp` | Fire TV receiver | iOS sender and Mac sender |
| `_framesmac._tcp` | Mac sender while waiting for a receiver | Fire TV receiver and iOS receiver |

Fire TV also uses TCP port `49218` for the direct-IP fallback. The Mac sender uses a Bonjour-advertised listener endpoint.

Receiver advertisements include a friendly service name plus a stable random receiver ID in the Bonjour TXT record. A Mac sender advertisement includes that ID as its target, preventing a different open receiver from racing to connect.

## Pairing protocol

The receiver generates the code and initiates the authenticated handshake after a TCP connection is established:

1. Receiver sends `hello` with protocol version, a random 16-byte salt, and a random 32-byte server challenge.
2. Sender derives a 256-bit key using PBKDF2-HMAC-SHA256 with 120,000 iterations.
3. Sender returns its own 32-byte challenge and an HMAC-SHA256 client proof.
4. Receiver verifies the proof in constant time.
5. Receiver returns a server proof so the sender also authenticates the receiver.
6. Both sides use the derived key for AES-256-GCM media records.

Incorrect or completed sessions rotate the receiver's pairing code.

After a successful code-based pairing, both peers derive the same 256-bit remembered-device secret from the authenticated session without transmitting that secret. The Mac and iOS receiver store it in Keychain; the ReplayKit sender and its host app share it through their private app-group container; Fire TV stores it in app-private preferences with Android backup disabled. Future connections derive fresh session keys from the remembered secret, new random salt, and new challenges. If either side loses its saved state, the app falls back to one-time code pairing.

## Wire format

Every TCP record begins with:

```text
length: 4-byte unsigned big-endian integer
type:   1 byte
body:   length - 1 bytes
```

Packet types:

| Type | Purpose |
| --- | --- |
| `0` | UTF-8 JSON handshake or authenticated receiver-control message |
| `2` | AES-GCM combined media payload |

An encrypted payload is encoded as:

```text
12-byte nonce || ciphertext || 16-byte authentication tag
```

After decryption, a media record contains:

```text
version (1)
media kind (1)
timestamp milliseconds (8, big-endian)
flags (1)
payload (remaining bytes)
```

Media kinds:

| Kind | Payload |
| --- | --- |
| `1` | Video width, height, rotation, SPS, and PPS |
| `2` | Annex-B H.264 access unit |
| `3` | Audio sample rate, channel count, encoding, and optional codec configuration |
| `4` | PCM samples or one raw AAC-LC access unit |

The maximum framed media record is 8 MiB. JSON handshake records are limited to 64 KiB.

The handshake advertises optional `cinema-buffer-v1`, `receiver-report-v1`,
`keyframe-request-v1`, `aac-lc-v1`, `remote-media-controls-v1`, and
`authenticated-controls-v1`
capabilities. Older peers continue to use the established PCM media path and
receive no unnegotiated remote-control messages.

The first remote play/pause command may ask for macOS Accessibility permission.
Grant it to the Mac sender so it can post the same system media-key event as a
physical keyboard. Remote commands are accepted only from the currently
authenticated receiver.

### Authenticated receiver controls

Updated receivers wrap reports, keyframe requests, and remote commands in a
type-0 JSON envelope with `type: "authenticated_control"`, a positive decimal
string `sequence`, base64 `payload` (the exact inner JSON bytes), and base64
`proof`. The proof is HMAC-SHA256 using the session key over the concatenation:
`UTF8("receiver-control-v1") || serverChallenge[32] || clientChallenge[32] ||
sequence[8, big-endian] || payload`. Sequence numbers increase under the same
serialization lock/queue as socket writes and reset for each handshake.
The Mac verifies the tag and rejects non-increasing sequences before dispatch.
Challenges prevent cross-handshake replay, including with a reused pairing key.

Update the Mac and receiver together to retain reports, recovery requests, and
remote pause. Mixed versions can still stream media, but updated peers never
fall back to unsigned controls. Fire TV's PCM negotiation, audio clock, buffer
target, and presentation policy are unchanged by this control protocol addition.

## Current limitations

- A Mac sender accepts one receiver connection at a time.
- iOS receiver playback is foreground-oriented.
- DRM-protected video may be black or unavailable to ReplayKit and ScreenCaptureKit.
- Latency and sustainable resolution depend heavily on the sender, receiver hardware, and Wi-Fi conditions.
- The protocol is application-specific and is not AirPlay, Google Cast, or Miracast.

## Security notes

- Media does not pass through an external relay or cloud service.
- Pairing codes are short-lived session credentials and should not be reused.
- AES-GCM provides confidentiality and integrity for every media packet.
- Mutual HMAC proofs prevent either side from silently accepting a peer that does not know the displayed code.
- Discovery metadata is visible to devices on the local network; media content is encrypted after pairing.

## Contributing and security

Contributions are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md). Please report
security vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## License

This project is available under the [MIT License](LICENSE).
