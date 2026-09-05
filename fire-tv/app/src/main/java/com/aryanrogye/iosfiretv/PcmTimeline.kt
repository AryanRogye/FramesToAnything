package com.aryanrogye.iosfiretv

import kotlin.math.abs

/** Detects missing or repeated capture time before PCM is appended to AudioTrack. */
internal object PcmTimeline {
    fun isDiscontinuous(firstPtsMs: Long, framesWritten: Long, sampleRate: Int, nextPtsMs: Long): Boolean {
        val expectedPtsMs = firstPtsMs + framesWritten * 1_000L / sampleRate
        // Millisecond packet rounding and AAC frame boundaries need tolerance.
        // A capture restart/queue loss is different: concatenating across that
        // gap permanently changes which sound belongs to each video timestamp.
        return abs(nextPtsMs - expectedPtsMs) > 80L
    }
}
