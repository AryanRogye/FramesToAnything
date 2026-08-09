# Frames — Local Network Screen Mirroring


This repository is a collection of Apple and Android projects for securely mirroring an iPhone, iPad, or Mac over the local network.

Supported paths:

| Sender | Receiver | Project |
| --- | --- | --- |
| iPhone or iPad | Fire TV / Android TV | `iOSFramesToFireTV.xcodeproj` + `fire-tv/` |
| Mac | Fire TV / Android TV | `macOSFramesToFireTV/macOSFramesToFireTV.xcodeproj` + `fire-tv/` |
| Mac | iPhone or iPad | `macOSFramesToFireTV/macOSFramesToFireTV.xcodeproj` on both devices |

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
│   ├── macOSFramesToFireTV.xcodeproj/ Shared macOS/iOS project
│   └── macOSFramesToFireTV/
│       ├── macOS/                     Mac capture, encoding, and transport
│       └── iOS/                       iPhone/iPad receiver and media player
└── fire-tv/                           Kotlin Android TV / Fire TV receiver
```

## Projects and targets

### `iOSFramesToFireTV.xcodeproj`

The original iPhone/iPad-to-Fire-TV sender consists of three targets.

#### `iOSFramesToFireTV`

The main SwiftUI app:

- Discovers Fire TV receivers through Bonjour using `_iosfiretv._tcp`.
- Supports a direct-IP fallback when multicast discovery is unavailable.
- Authenticates using the six-digit code displayed on the receiver.
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

This is one multiplatform SwiftUI target with different implementations selected at compile time.

#### macOS build — Mac sender

The Mac version:

- Captures a user-selected display with SnapCore and ScreenCaptureKit.
- Captures stereo system audio while excluding the microphone and the sender app's own audio.
- Encodes H.264 in real time with B-frames disabled.
- Advertises `_framesmac._tcp` so the Fire TV or iOS receiver can connect to it.
- Accepts the receiver's six-digit code and completes mutual authentication.
- Offers HD, Full HD, QHD, and UHD bitrate presets.

Screen Recording permission is required on first launch.

#### iOS/iPadOS build — Mac receiver

The iPhone/iPad version:

- Displays a rotating six-digit pairing code.
- Discovers `_framesmac._tcp` Mac senders using Bonjour.
- Connects to the Mac and performs the same authenticated handshake as the Fire TV receiver.
- Parses and decrypts framed AES-GCM media records.
- Converts Annex-B H.264 access units for `AVSampleBufferDisplayLayer` hardware playback.
- Plays interleaved 16-bit PCM audio with `AVAudioEngine`.
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
- Plays bounded, low-latency PCM audio using `AudioTrack`.
- Drops stale queued media to keep live playback responsive.

The Android project uses Gradle, Kotlin, and Java 17.

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
6. Enter the TV's six-digit code and pair.
7. Tap the broadcast button, choose `FireTVBroadcast`, and start broadcasting.

ReplayKit may intentionally produce black video for DRM-protected content. Some protected `AVPlayer` content cannot be captured.

### Mac → Fire TV

1. Build and launch `fire-tv/` on the television.
2. Open `macOSFramesToFireTV/macOSFramesToFireTV.xcodeproj` in Xcode.
3. Run the `macOSFramesToFireTV` scheme with **My Mac** selected.
4. Enter the code displayed by the Fire TV and start pairing.
5. After authentication, choose a display and begin streaming.

### Mac → iPhone/iPad

1. Open `macOSFramesToFireTV/macOSFramesToFireTV.xcodeproj` in Xcode.
2. Run the `macOSFramesToFireTV` scheme on the physical iPhone or iPad.
3. Leave the iOS receiver open and note its six-digit code.
4. Run the same scheme on the Mac.
5. Enter the iOS receiver's code in the Mac app and start pairing.
6. Choose a display on the Mac.
7. Tap the expand button in the iOS preview to enter full-screen playback.

Only one receiver should be open while pairing. Fire TV, another iPhone/iPad, or a running Simulator receiver can discover the same Mac and race to claim its single incoming connection.

## Media pipeline

### Video

- Hardware H.264 encoding and decoding.
- Up to 60 frames per second.
- 10 Mbps default Full HD bitrate on macOS.
- One-second keyframe interval.
- Real-time VideoToolbox encoding with B-frames disabled.
- SPS/PPS configuration followed by Annex-B access units.
- Bounded queues favoring the newest available frame.

### Audio

- Interleaved signed 16-bit PCM.
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

## Pairing protocol

The receiver generates the code and initiates the authenticated handshake after a TCP connection is established:

1. Receiver sends `hello` with protocol version, a random 16-byte salt, and a random 32-byte server challenge.
2. Sender derives a 256-bit key using PBKDF2-HMAC-SHA256 with 120,000 iterations.
3. Sender returns its own 32-byte challenge and an HMAC-SHA256 client proof.
4. Receiver verifies the proof in constant time.
5. Receiver returns a server proof so the sender also authenticates the receiver.
6. Both sides use the derived key for AES-256-GCM media records.

Incorrect or completed sessions rotate the receiver's pairing code.

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
| `0` | UTF-8 JSON handshake message |
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
| `3` | PCM sample rate, channel count, and encoding |
| `4` | Interleaved PCM samples |

The maximum framed media record is 8 MiB. JSON handshake records are limited to 64 KiB.

## Current limitations

- A Mac sender accepts one receiver connection at a time.
- Multiple open receivers can race to connect because receiver targeting has not yet been implemented.
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
