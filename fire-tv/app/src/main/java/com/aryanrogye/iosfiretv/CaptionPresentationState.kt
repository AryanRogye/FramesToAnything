package com.aryanrogye.iosfiretv

internal data class CaptionLines(val committed: String = "", val partial: String = "")

/** Two bounded rows; a new hypothesis never rewrites the finalized row. */
internal class CaptionPresentationState {
    private var committed = ""

    fun present(cue: CaptionCue?): CaptionLines {
        if (cue == null) { committed = ""; return CaptionLines() }
        if (cue.committedText != null && cue.partialText != null) {
            // The sender repeats the committed snapshot, so dropped packets are safe.
            // Keep the last finalized row while the next utterance begins.
            if (cue.committedText.isNotBlank()) committed = cue.committedText.takeLast(300)
            return CaptionLines(committed, cue.partialText.takeLast(300))
        }
        // Compatibility with senders that only provide the original combined text.
        if (cue.final) {
            committed = cue.text.takeLast(300)
            return CaptionLines(committed)
        }
        return CaptionLines(committed, cue.text.takeLast(300))
    }
}
