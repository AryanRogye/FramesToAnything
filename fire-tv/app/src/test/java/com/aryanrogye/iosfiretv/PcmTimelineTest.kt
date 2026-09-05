package com.aryanrogye.iosfiretv

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PcmTimelineTest {
    @Test fun `normal PCM packet rounding does not restart audio`() {
        assertFalse(PcmTimeline.isDiscontinuous(1_000, 1_024, 48_000, 1_022))
    }

    @Test fun `capture restart gap cannot be concatenated into old timeline`() {
        assertTrue(PcmTimeline.isDiscontinuous(1_000, 48_000, 48_000, 2_400))
    }

    @Test fun `replayed or backward audio is a discontinuity`() {
        assertTrue(PcmTimeline.isDiscontinuous(1_000, 48_000, 48_000, 1_700))
    }
}
