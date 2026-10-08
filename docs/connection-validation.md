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
