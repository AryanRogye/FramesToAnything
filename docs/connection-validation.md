# Connection validation — October 7, 2026

macOS remains the TCP server. Fire TV initiates all Mac connections. The updated
Mac app is installed in `/Applications/macOSFramesToFireTV.app`; the updated debug
receiver is installed on the connected AFTKRT Fire TV. The previous Mac app was
backed up before replacement.

## Automated checks

- Mac Release Xcode application build: passed.
- Mac Swift tests: 21 passed (session ownership, pairing scope/expiry, captions,
  buffer policy, and authenticated-control vectors/replay/tampering).
- iOS receiver compatibility tests: 9 passed.
- Fire TV `:app:verifyPlaybackSafety`: 39 JVM tests passed; debug and release APKs built.
- `git diff --check`: passed.

## Physical Mac/Fire TV checks

- 50 consecutive trusted Connect/Disconnect cycles passed without restarting either app.
  Every cycle required a new authentication success and a new audio playback-clock
  startup. Median tap-to-clock time: 1.51 seconds; maximum: 2.04 seconds.
- Five additional reconnect cycles passed against the final installed Mac build.
- A fresh unknown receiver ID received `pairing_required`, not media.
- An unsigned `auth_failed` sent while impersonating a known receiver did not erase
  Mac trust: all subsequent trusted connections succeeded without code entry.
- An idle unauthenticated TCP peer was released after 15.76 seconds.
- A 15-second SIGSTOP of the Mac server triggered automatic recovery after resume.
  A new authenticated audio-clock startup appeared 1.04 seconds after SIGCONT.
- Restarting the Mac app automatically restored the selected TV session without
  a TV Connect tap: new audio-clock startup appeared 3.15 seconds after launching Mac.
- Fire TV app restart and in-app receiver restart retained trust. Clicking Connect
  only on the TV restored playback (4.27 and 4.12 seconds including UI automation).
- A short synthesized speech sample reached the live-caption receiver after recovery;
  receiver logs confirmed encrypted caption cues and rendered committed/partial rows.
- The 1920×1080 TV layout was inspected on device: Mac list and first-time pairing
  occupy separate columns; playback uses a compact four-action tray with diagnostics
  under More. No clipped controls or off-screen pairing content remained.

Background discovery refresh previously made recently resolved rows temporarily
unavailable. The implementation now retains them through a bounded grace period,
while explicit service loss still marks the affected service offline. The refreshed
implementation passed the full 50-cycle run; a JVM regression test covers this rule.

## Reproduce

```sh
swift test --package-path macOSFramesToFireTV
swift test --package-path iOSFramesReceiver
./fire-tv/gradlew -p fire-tv :app:verifyPlaybackSafety
python3 scripts/verify-fire-tv-reconnect.py --serial FIRE_TV_IP:5555 --cycles 50
python3 scripts/verify-fire-tv-recovery.py --serial FIRE_TV_IP:5555
```

The scripts save machine-readable results in `/tmp/fire-tv-reconnect-results.json`
and `/tmp/fire-tv-recovery-results.json` by default. Recovery testing deliberately
interrupts the Mac app and restarts both apps; it never clears credentials.

## Still requiring physical verification

- Actual Wi-Fi interruption, DHCP/address changes, and system sleep/wake. Retry,
  re-resolution, discovery refresh, and network callbacks are implemented; a suspended
  server is a silent-failure test, not a physical network-change test.
- First-time pairing on a device with neither peer's credentials saved. Code scoping
  and expiry are unit-tested; existing mutual code proofs remain unchanged.
- Prolonged high-motion lip-sync measurement, quality downgrades/restoration under
  real congestion, and system-media-key effects with macOS Accessibility permission.
  Playback safety tests passed; clock startup does not measure sound at the listener.

## October 9: normal launcher re-entry regression

The Fire TV task contained two live MainActivity instances. The older stopped
Activity still owned an authenticated Mac session because networking only stopped
in onDestroy. The visible instance started a second coordinator and retried a
Mac whose single receiver slot was already occupied. Closing the duplicate screen
exposed the original live stream immediately, confirming the ownership conflict.

The receiver now uses singleTask launch mode. Networking starts in onStart and
stops in onStop; returning from Home creates a fresh coordinator with the same
saved trust. Generation checks also prevent a delayed in-app restart from starting
a coordinator after the Activity backgrounds or resumes into a newer generation.
Video/audio/caption playback resources and UI timers are reset on backgrounding.
The Mac server and authentication/encryption protocol are unchanged.

Validation:

- Fire TV playback safety gate passed: 39 JVM tests, debug and release APK builds.
- Installed the updated receiver without restarting or re-pairing the Mac.
- Added `scripts/verify-fire-tv-lifecycle.py`: repeatedly connects, opens the launcher
  twice while streaming, goes Home, and returns through the launcher.
- Eight cycles passed on the physical TV.
- Each cycle checks exactly one receiver Activity, unchanged TV and Mac process
  IDs, trusted authentication and audio-clock startup, and a real TCP probe proving
  the Mac accepts a new unauthenticated peer after the TV backgrounds.

```sh
python3 scripts/verify-fire-tv-lifecycle.py --serial FIRE_TV_IP:5555 --cycles 8
```

Unlike the earlier force-stop/restart tests, this exercises Android's retained
Activity lifecycle and mixed explicit/launcher intents.

## October 9: Fire TV ±10-second controls

- Integrated the pinned ejbills MediaRemoteAdapter dynamic package, embedded and signed.
  Existing SnapCore/WhisperKit versions and sandbox/network entitlements are unchanged.
- Rewind/fast-forward keys and More-menu actions send separately negotiated fixed
  seek commands through the authenticated control path. Replies use AES-GCM kind 7.
- Mac Release build and deep bundle signature verification passed. Mac tests: 24 passed.
- Fire TV safety gate: 41 tests passed; debug and release APKs built and the updated
  receiver installed. The updated Mac app is installed in /Applications.
- On the physical Fire TV, key 90 then key 89 changed ComfyPortal Graphics and Media's
  actual Now Playing position by exactly +10.000 and −10.000 seconds. Playback state
  was preserved. Observed command-to-position changes took 1.84 and 1.07 seconds.
- Two additional launcher/Home-return cycles passed with the seek-enabled builds.
- The receiver was also installed on the replacement TV at 192.168.68.87; saved trust
  connected it to the Mac and the new More-menu seek actions were verified in its UI.
- Tests cover clamping at start/end, missing/live/nonfinite media data, unsupported
  offsets/commands, capability negotiation, key mapping, and unaffected D-pad keys.

Player compatibility is not universal: the source must expose a seekable Now Playing
position and duration. The helper requests a seek; whether a particular player honors
it is up to that player. Existing play/pause behavior is retained.
