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
- Offers HD, Full HD, QHD, and UHD bitrate presets.

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
