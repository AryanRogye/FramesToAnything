package com.aryanrogye.iosfiretv

import org.junit.Assert.assertEquals
import org.junit.Test

class CaptionPresentationStateTest {
    private fun cue(committed: String, partial: String, id: String = "a") =
        CaptionCue(1_000, 2_000, "$committed $partial".trim(), id, 1,
            partial.isEmpty(), committed, partial)

    @Test fun partialRevisionsCannotRewriteFinalizedRow() {
        val state = CaptionPresentationState()
        val first = state.present(cue("Keep this stable.", "Now"))
        val revised = state.present(cue("Keep this stable.", "Now the last option"))
        assertEquals(first.committed, revised.committed)
        assertEquals("Now the last option", revised.partial)
        val shorter = state.present(cue("Keep this stable.", "The option"))
        assertEquals(first.committed, shorter.committed)
        assertEquals("The option", shorter.partial)
    }

    @Test fun finalizedTextSurvivesNextUtteranceAndClearsAtExpiry() {
        val state = CaptionPresentationState()
        assertEquals(CaptionLines("Finished sentence."), state.present(cue("Finished sentence.", "")))
        assertEquals(CaptionLines("Finished sentence.", "Next"), state.present(cue("", "Next", "b")))
        assertEquals(CaptionLines("Next sentence.", "More"), state.present(cue("Next sentence.", "More", "b")))
        assertEquals(CaptionLines(), state.present(null))
        assertEquals(CaptionLines("", "New session"), state.present(cue("", "New session", "c")))
    }

    @Test fun snapshotsRecoverMissingRevisionsAndRemainBounded() {
        val state = CaptionPresentationState()
        state.present(cue("One.", "Two"))
        assertEquals(CaptionLines("One. Two. Three.", "Four"), state.present(cue("One. Two. Three.", "Four")))
        val long = state.present(cue("x".repeat(1_000), "y".repeat(1_000)))
        assertEquals(300, long.committed.length)
        assertEquals(300, long.partial.length)
    }
}
