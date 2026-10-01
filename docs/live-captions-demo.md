# Mac → Fire TV live captions proof of concept

The Mac generates English subtitles with WhisperKit; Fire TV renders
plain text above its unchanged video SurfaceView. Captions are enabled by default and controlled in the Mac menu.
No subtitles are burned into frames. No cloud transcription or microphone is used.
WhisperKit downloads model/tokenizer assets on first use, then runs locally.

## Run

1. Build/install the Mac Release app and the Fire TV receiver from this revision.
2. Launch the app normally from Applications. No environment variables or special
   launch arguments are required. **Live Captions** in the Mac menu is enabled
   by default and remembers your choice. Switch it off to stop caption audio
   conversion and inference while keeping the video stream running.

3. Choose **Caption Mode** in the existing Mac menu:
   - **English → English Captions** uses multilingual `base`, `.transcribe`, source `en`.
   - **Hindi → English Translation** uses multilingual `small`, `.translate`, source `hi`.
   The selection is saved. You can change it while streaming; only the caption
   worker restarts. Its predecessor is cancelled and finishes before the new
   model loads, so two inference workers cannot compete. Caption revisions start
   fresh for the selected mode. Model downloads/loading continue in the background.
   Connect and start sharing as usual. Play speech in the selected source language. Look for
   `[Captions] Ready` and `[Captions partial/final]` in the Mac console; first-use
   downloading/compilation can take time. Subtitles appear at the TV's bottom.
4. To compare against the baseline, switch **Live Captions** off in the Mac menu.
   Stop/start streaming, or toggle captions off/on, to restart a failed or
   thermally suspended caption session.

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
  multilingual base model, no GPU compute, no fallback retries, one decode
  worker, and a 128-token cap. A two-second callback budget is best effort, not
  Core ML preemption. Three consecutive slow passes or serious thermal pressure
  disable captions until the next streaming session.
- Captions use negotiated `live-captions-v1`, encrypted media kind `5`, and the
  existing AES-GCM session. Payload is UTF-8 JSON (`id`, `revision`, `startMs`, `endMs`, `text`,
  `final`, `committedText`, `partialText`), capped at 2 KB; header timestamp equals `startMs`. One pending caption
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
older revisions and partial updates after a final. Partial text can change; “final” is an age-based heuristic, not word-level agreement. The base model,
an energy gate, and latest-cue delivery trade accuracy/completeness for low load.
Music can still produce hallucinated text. No speaker separation. English uses multilingual `base`; Hindi translation uses larger multilingual `small` for improved accuracy. Hindi translation
on short excerpts can still be imperfect.

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

## Known-good checkpoint

The working English captions and TV appearance editor were committed and pushed
before adding mode selection: `d7ca298` on `feature/macOS_transcription`. The Hindi
feature changes only the Mac mode selector and caption-worker configuration.

Hindi mode was also exercised with Hindi video playing: the worker loaded
multilingual `tiny`, emitted English output, and Fire TV logged received revisions
and displayed them. Observed decode passes were approximately 70–670 ms. Some
translations were unstable/repetitive; this validates the translation/rendering
path rather than translation accuracy. Screenshot: `/tmp/firetv-hindi-translation.png`.

## Stable two-line presentation

The Mac sends a committed-text snapshot and replaceable partial text with every
revision. The TV renders them in independent, left-aligned single-line rows.
Finalized words stay on the upper row; partial revisions update only the lower
row. The last finalized row remains while the next utterance starts. Overflow
shows the recent end of each phrase, keeping a bounded rolling reading window.
The overlay width and both row heights stay fixed during caption updates; only
changing font size or position in the editor alters its layout. Expiry clears
both rows. The original combined text remains available for older receivers.
No extra delay, animation, transcription pass, or caption backlog is added.

Verified fixed rows on the connected Fire TV: two hierarchy snapshots retained
“Thank you.” at `[160,856][1760,912]` while the partial changed independently in
`[160,912][1760,968]`. Each row stayed 56 px tall at the current size. Screenshot:
`/tmp/firetv-stable-captions.png`. Presentation tests cover frozen finalized rows,
partial replacement, final-to-next-utterance continuity, expiry, and missed revisions.
