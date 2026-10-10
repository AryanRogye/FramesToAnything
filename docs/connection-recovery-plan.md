# Persistent Mac server and Fire TV connection recovery

## Architecture

macOS owns the TCP listener and persistent `_framesmac._tcp` advertisement.
Fire TV discovers Macs, selects one, and initiates every Mac session. No Mac
outgoing socket is used. Keep the existing six-digit code, mutual HMAC proofs,
AES-256-GCM records, authenticated receiver controls, and playback pipeline.

## Implementation order

1. Separate Mac listener lifetime from session cleanup; start at app launch.
2. Authenticate incoming receivers using their stable ID and existing trust.
3. Serialize capture startup/cleanup and automatically capture the main display.
4. Maintain a Fire TV Mac registry and explicit Connect/Disconnect intent.
5. Own discovery, resolution, attempts, cleanup, and retry deadlines by generation.
6. Negotiate authenticated/encrypted heartbeat support for silent-failure recovery.
7. Test state ownership, trust, retries, framing, playback, builds, and devices.

## Implementation and automated-check checklist

- [x] Mac launch starts persistent listener and Bonjour advertisement.
- [x] Session failure/disconnect leaves server available.
- [x] Listener/discovery failures recover with bounded retry.
- [x] Trusted incoming receiver selects credentials without Mac interaction.
- [x] Unknown receiver requires explicit code pairing.
- [x] Authentication failure cannot erase saved credentials.
- [x] Capture starts automatically after authentication and stops before restart.
- [x] Fire TV lists Macs and connects only on user intent.
- [x] One TV attempt/session; failed sockets close; stale callbacks are ignored.
- [x] Selected Mac survives service loss and is resolved again after address change.
- [x] Transient failures retry; explicit Disconnect and pairing failures do not loop.
- [x] Silent network failures have authenticated liveness deadlines.
- [x] Video/audio/captions/remote controls retain their existing protocol and policies.
- [x] Swift policy/security tests pass.
- [x] Fire TV playback safety gate and APK builds pass.
- [x] Mac Release application build passes.
- [x] Hardware: 50 connect/disconnect cycles without app restart.
- [x] Hardware: Mac restart automatically reconnects without a TV tap.
- [x] Hardware: Fire TV app and in-app restart retain trust.
- [x] Hardware: silent Mac server stall recovers automatically.
- [x] Hardware: caption cues reach Fire TV after recovery.
- [x] Hardware: repeated launcher re-entry and Home/return keep one Activity and release hidden sessions (8 cycles).
- [ ] Hardware: physical Wi-Fi loss, DHCP change, and system sleep/wake.
- [ ] Hardware: first-time pairing with neither peer previously trusted.
- [ ] Hardware: A/V sync, captions, controls, and adaptive quality through recovery.

Device checks must remain unchecked until tested on a real Mac and Fire TV.

## Runtime ownership

Mac session states are idle, awaiting hello, authenticating, and authenticated.
Listener ownership and its retry are independent of session ownership. Capture
work is serialized separately on the main actor, with a generation and a startup
deadline. Explicit Mac Stop leaves the advertisement alive but pauses admission.

Fire TV states are idle, resolving, connecting, authenticating, awaiting media,
streaming, backoff, pairing required, and stopped. A selected stable sender ID
owns connection intent. NSD discovery, per-service resolution versions, retries,
and socket completion return to one scheduled coordinator. Blocking socket I/O
and bounded control writes stay off that coordinator. Replacement receiver
instances reject old callbacks before they reach shared playback resources.

Recent Mac rows remain usable during periodic discovery refresh, while explicit
service loss or an expired grace period marks them unavailable. A service-name
reuse cannot impersonate another stable sender ID. Retries refresh resolution
and do not silently select another Mac.

## Reproducing physical checks

Both scripts require ADB and an already paired TV; neither clears credentials.

```sh
python3 scripts/verify-fire-tv-reconnect.py --serial FIRE_TV_IP:5555 --cycles 50
python3 scripts/verify-fire-tv-recovery.py --serial FIRE_TV_IP:5555
```

The recovery script briefly suspends the installed Mac app, resumes it in a
finally block, and restarts both apps. Run it when those interruptions are OK.
See [validation results](connection-validation.md) for measured results and
checks still requiring physical network/display/audio validation.
