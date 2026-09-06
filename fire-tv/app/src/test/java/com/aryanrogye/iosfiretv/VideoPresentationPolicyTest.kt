package com.aryanrogye.iosfiretv

import org.junit.Assert.assertEquals
import org.junit.Test
import com.aryanrogye.iosfiretv.VideoPresentationPolicy.Action.*

class VideoPresentationPolicyTest {
    private val now = 10_000_000_000L

    @Test fun burstFramesAreHeldUntilNearTheirAudioDeadline() {
        // Recorded failing session: leadMs=1921, outside SurfaceView's window.
        val deadline = now + 1_921_000_000L
        assertEquals(HOLD, VideoPresentationPolicy.action(deadline, now))
        assertEquals(HOLD, VideoPresentationPolicy.action(deadline, deadline - 30_000_001L))
        assertEquals(RENDER, VideoPresentationPolicy.action(deadline, deadline - 30_000_000L))
    }

    @Test fun clockReacquisitionHoldsInsteadOfDiscardingOrRenderingEarly() {
        assertEquals(HOLD, VideoPresentationPolicy.action(null, now))
        assertEquals(HOLD, VideoPresentationPolicy.action(now + 500_000_000L, now))
        // The same frame can be reconsidered when audio catches up.
        assertEquals(RENDER, VideoPresentationPolicy.action(now + 500_000_000L, now + 480_000_000L))
    }

    @Test fun staleFrameIsDroppedRatherThanBurstRendered() {
        assertEquals(DROP, VideoPresentationPolicy.action(now - 100_000_001L, now))
        assertEquals(RENDER, VideoPresentationPolicy.action(now - 100_000_000L, now))
    }

    @Test fun cinemaPrerollNeverBecomesImmediatePresentation() {
        for (leadMs in listOf(750L, 1_000L, 2_000L, 5_000L)) {
            assertEquals(HOLD, VideoPresentationPolicy.action(now + leadMs * 1_000_000L, now))
        }
    }
}
