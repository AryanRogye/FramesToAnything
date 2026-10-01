package com.aryanrogye.iosfiretv

import org.junit.Assert.assertEquals
import org.junit.Test

class CaptionTimelineTest {
    @Test fun revisionsUpdateOneCaptionDespiteDriftingTimestamps() {
        val timeline = CaptionTimeline()
        timeline.offer(CaptionCue(1_000, 2_000, "Now", "a", 1), 100)
        assertEquals("Now", timeline.text(2_000, 150))
        timeline.offer(CaptionCue(900, 2_500, "Now the last option", "a", 2), 200)
        assertEquals("Now the last option", timeline.text(2_500, 250))
        timeline.offer(CaptionCue(1_000, 2_000, "stale", "a", 1), 300)
        assertEquals("Now the last option", timeline.text(2_500, 350))
        timeline.offer(CaptionCue(900, 2_500, "Now the last option.", "a", 3, true), 400)
        timeline.offer(CaptionCue(900, 2_500, "late partial", "a", 4), 450)
        assertEquals("Now the last option.", timeline.text(2_500, 500))
    }

    @Test fun earlyCueWaitsForPlaybackAndExpiresDuringPause() {
        val timeline = CaptionTimeline()
        timeline.offer(CaptionCue(1_000, 2_000, "hello"), 100)
        assertEquals("", timeline.text(null, 200))
        assertEquals("", timeline.text(999, 200))
        assertEquals("hello", timeline.text(1_000, 200))
        assertEquals("", timeline.text(1_000, 4_100))
    }

    @Test fun modestlyLateTextIsVisibleButStaleTextIsDropped() {
        val timeline = CaptionTimeline()
        timeline.offer(CaptionCue(1_000, 2_000, "hello"), 100)
        assertEquals("hello", timeline.text(3_000, 200))
        assertEquals("", timeline.text(6_001, 300))
    }

    @Test fun partialIsReplacedAndOldCuesCannotOverwriteNewSpeech() {
        val timeline = CaptionTimeline()
        timeline.offer(CaptionCue(1_000, 2_000, "hel"), 100)
        timeline.offer(CaptionCue(1_000, 2_000, "hello"), 200)
        assertEquals("hello", timeline.text(2_000, 300))
        timeline.offer(CaptionCue(500, 900, "old"), 400)
        assertEquals("hello", timeline.text(2_000, 500))
        timeline.clear()
        assertEquals("", timeline.text(2_000, 600))
        timeline.offer(CaptionCue(100, 500, "new session"), 700)
        assertEquals("new session", timeline.text(200, 800))
    }
}
