package com.aryanrogye.iosfiretv

internal data class CaptionCue(val startMs: Long, val endMs: Long, val text: String,
                               val id: String = startMs.toString(), val revision: Long = 0,
                               val final: Boolean = false)

/** UI-only state. Late captions may appear briefly; media never waits for them. */
internal class CaptionTimeline {
    private var pending: CaptionCue? = null
    private var visible: CaptionCue? = null
    private var receivedAtMs = 0L
    private var newestStart = -1L
    private var newest: CaptionCue? = null

    fun offer(cue: CaptionCue, nowMs: Long) {
        val previous = newest
        if (previous?.id == cue.id) {
            if (cue.revision < previous.revision || previous.final && !cue.final) return
        } else if (cue.startMs < newestStart) return
        newest = cue
        newestStart = cue.startMs
        pending = cue
        receivedAtMs = nowMs
    }

    fun text(mediaMs: Long?, nowMs: Long): String {
        // Wall-clock expiry also clears subtitles if playback is paused/stalled.
        if (nowMs - receivedAtMs >= 4_000) { clear(); return "" }
        if (mediaMs == null) return ""
        pending?.let { cue ->
            if (mediaMs >= cue.startMs) {
                pending = null
                visible = if (mediaMs <= cue.endMs + 4_000) cue else null
            }
        }
        val cue = visible ?: return ""
        if (mediaMs > cue.endMs + 4_000) { visible = null; return "" }
        return cue.text
    }

    fun clear() {
        pending = null
        visible = null
        newestStart = -1L
        newest = null
        receivedAtMs = 0L
    }
}
