# Mac → Fire TV live captions proof of concept

The Mac generates English captions with WhisperKit `tiny.en`; Fire TV renders
plain text above its unchanged video SurfaceView. This is an opt-in experiment.
No subtitles are burned into frames. No cloud transcription or microphone is used.
WhisperKit downloads model/tokenizer assets on first use, then runs locally.

## Run

1. Build/install the Mac Release app and the Fire TV receiver from this revision.
2. In the Mac Xcode scheme, add `FIRETV_LIVE_CAPTIONS=1` under Run → Arguments →
   Environment Variables. For realistic performance, use Release configuration.
   Alternatively, quit the app and launch its executable from Terminal:

   ```sh
   FIRETV_LIVE_CAPTIONS=1 /Applications/macOSFramesToFireTV.app/Contents/MacOS/macOSFramesToFireTV
   ```

3. Connect and start sharing as usual. Play English speech on the Mac. Look for
   `[Captions] Ready` and `[Captions partial/final]` in the Mac console; first-use
   downloading/compilation can take time. Subtitles appear at the TV's bottom.
4. To compare against the baseline, quit and launch without the environment
   variable. Caption capture/inference is then inactive. Stop/start streaming
   restarts a failed or thermally suspended caption session.

## Isolation and bounds

- The existing screen/audio capture, encoder settings, receiver pre-roll,
  media timestamps, and video send callback are unchanged.
- The existing system-audio callback sends audio first, then offers a retained
  sample buffer to a separate background queue. Admission never waits. At most
  four raw buffers can await conversion; overflow drops caption audio only.
- AVAudioConverter produces 16 kHz mono floats. A six-second rolling window is
  bounded even during model loading or slow inference. Gaps reset its generation;
  results from an earlier generation are rejected.
- A single background task decodes in-memory snapshots, at most once per second
  plus inference time. It advances a confirmed segment cursor via clip timestamps
  and keeps a revisable tail. It never exports or repeatedly reads audio files.
  The built-in WhisperKit microphone stream is intentionally not used.
- Model loading/storage follows the supplied file-transcriber approach, with a
  smaller English-only model, no GPU compute, no fallback retries, one decode
  worker, and a 128-token cap. A two-second callback budget is best effort, not
  Core ML preemption. Three consecutive slow passes or serious thermal pressure
  disable captions until the next streaming session.
- Captions use negotiated `live-captions-v1`, encrypted media kind `5`, and the
  existing AES-GCM session. Payload is UTF-8 JSON (`id`, `revision`, `startMs`, `endMs`, `text`,
  `final`), capped at 2 KB; header timestamp equals `startMs`. One pending caption
  replaces the previous one; caption overflow cannot restart encoders. Older
  receivers receive no captions. Audio/video packet formats remain unchanged.
- Fire TV keeps one incoming cue, polls its existing playback clock at 10 Hz,
  and changes its TextView only when text changes. Future cues wait for media time;
  late cues have a four-second grace period. Captions expire after four seconds
  without updates even while paused, and clear on disconnect. Nothing delays media.

## Demo limitations and validation

The existing ~750 ms is receiver playback buffering, not a sender-side deadline.
WhisperKit may need more speech context and inference time than that. This demo
allows late captions rather than increasing stream latency. Partial text updates one stable caption ID with increasing revisions. The Mac
retains a committed prefix while replacing the unconfirmed tail; the TV rejects
older revisions and partial updates after a final. Partial text can change; “final” is an age-based heuristic, not word-level agreement. Tiny English,
an energy gate, and latest-cue delivery trade accuracy/completeness for low load.
Music can still produce hallucinated text. No speaker separation or translation.

Use the same speech/video sequence with captions off and on. Compare visible
smoothness, audio continuity, latency, receiver underruns/recoveries and adaptive
quality changes. Watch Mac CPU/memory/thermal load. A successful build or
asynchronous architecture alone does not prove no performance regression.

Checks:

```sh
swift test --package-path macOSFramesToFireTV
cd fire-tv
./gradlew :app:verifyPlaybackSafety
```

Tests cover bounded audio history, gaps/restarts, snapshot stability, real
44.1/48 kHz stereo conversion, stop admission, caption timing/replacement/expiry,
and the existing sender/receiver playback and authentication contracts.

Implementation uses WhisperKit's in-memory transcription and clip timestamps:
https://github.com/argmaxinc/argmax-oss-swift/blob/v1.0.0/Sources/WhisperKit/Core/WhisperKit.swift

## Live verification

Verified on the connected AFTKRT Fire TV: `live-captions-v1` negotiated true,
encrypted caption packets reached the receiver, and the overlay visibly rendered
over the running stream. Receiver logs showed successive revisions of the same
caption ID updating displayed text. Playback started with 760 ms buffering.
A device screenshot was captured at `/tmp/firetv-caption-tv.png`. This confirms
end-to-end rendering; it is not a controlled performance comparison.

## Caption appearance editor

Press BACK to reveal the TV controls, then select **Captions**. Use Up/Down to
choose an option and Left/Right (or Select) to change it. The panel previews
text size, text color, and background; position changes the actual subtitle
overlay. On/Off hides subtitles locally without changing the stream. Changes
save automatically on the Fire TV. **Reset** restores the default appearance;
**Done** or BACK closes the panel. The dialog leaves media capture and playback
running.
