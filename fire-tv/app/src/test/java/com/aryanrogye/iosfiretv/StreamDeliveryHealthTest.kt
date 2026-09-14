package com.aryanrogye.iosfiretv

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class StreamDeliveryHealthTest {
    @Test fun reportsLagAfterVideoDeliveryStops() {
        assertFalse(StreamDeliveryHealth.isLagging(true, false, 1_000L, 2_199L))
        assertTrue(StreamDeliveryHealth.isLagging(true, false, 1_000L, 2_200L))
    }

    @Test fun doesNotReportBeforeTheFirstFrameOrOutsideActivePlayback() {
        assertFalse(StreamDeliveryHealth.isLagging(true, false, 0L, 10_000L))
        assertFalse(StreamDeliveryHealth.isLagging(false, false, 1_000L, 10_000L))
        assertFalse(StreamDeliveryHealth.isLagging(true, true, 1_000L, 10_000L))
    }

    @Test fun resumesHealthyStateAsSoonAsVideoArrives() {
        assertTrue(StreamDeliveryHealth.isLagging(true, false, 1_000L, 3_000L))
        assertFalse(StreamDeliveryHealth.isLagging(true, false, 2_950L, 3_000L))
    }
}
