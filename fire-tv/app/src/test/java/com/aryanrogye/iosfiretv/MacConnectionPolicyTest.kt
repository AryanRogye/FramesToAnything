package com.aryanrogye.iosfiretv

import org.junit.Assert.*
import org.junit.Test

class MacConnectionPolicyTest {
    @Test fun discoveryAloneDoesNotAuthorizeConnection() {
        val policy = MacConnectionPolicy()
        assertNull(policy.beginAttempt())
        assertFalse(policy.wantsConnection)
    }

    @Test fun repeatedConnectionsRejectOldCallbacksAndOverlap() {
        val policy = MacConnectionPolicy()
        var previous = -1L
        repeat(50) {
            policy.select("mac-a")
            val token = policy.beginAttempt()!!
            assertNull(policy.beginAttempt())
            assertFalse(policy.transition(previous, MacConnectionPolicy.State.CONNECTING, MacConnectionPolicy.State.AUTHENTICATING))
            assertTrue(policy.transition(token, MacConnectionPolicy.State.CONNECTING, MacConnectionPolicy.State.AUTHENTICATING))
            assertTrue(policy.transition(token, MacConnectionPolicy.State.AUTHENTICATING, MacConnectionPolicy.State.AWAITING_MEDIA))
            assertTrue(policy.transition(token, MacConnectionPolicy.State.AWAITING_MEDIA, MacConnectionPolicy.State.STREAMING))
            policy.disconnect()
            assertFalse(policy.failed(token))
            previous = token
        }
    }

    @Test fun transientFailuresRetrySameMacWithBoundedBackoff() {
        val policy = MacConnectionPolicy()
        policy.select("mac-a")
        var lastDelay = 0L
        repeat(30) {
            val token = policy.beginAttempt()!!
            assertTrue(policy.failed(token))
            assertEquals("mac-a", policy.selectedMac)
            assertTrue(policy.wantsConnection)
            val delay = policy.retryDelayMilliseconds()
            assertTrue(delay in lastDelay..15_000)
            lastDelay = delay
        }
    }

    @Test fun pairingFailureDoesNotRetryOrForgetSelection() {
        val policy = MacConnectionPolicy()
        policy.select("mac-a")
        assertTrue(policy.failed(policy.beginAttempt()!!, pairingRequired = true))
        assertEquals(MacConnectionPolicy.State.PAIRING_REQUIRED, policy.state)
        assertFalse(policy.wantsConnection)
        assertNull(policy.beginAttempt())
        assertEquals("mac-a", policy.selectedMac)
        policy.select("mac-a")
        assertNotNull(policy.beginAttempt())
    }

    @Test fun selectingAnotherMacInvalidatesDelayedRetry() {
        val policy = MacConnectionPolicy()
        policy.select("mac-a")
        val old = policy.beginAttempt()!!
        policy.failed(old)
        policy.select("mac-b")
        assertFalse(policy.failed(old))
        assertEquals("mac-b", policy.selectedMac)
        assertNotNull(policy.beginAttempt())
        policy.disconnect(stop = true)
        assertEquals(MacConnectionPolicy.State.STOPPED, policy.state)
        assertNull(policy.beginAttempt())
    }
    @Test fun refreshingDiscoveryDoesNotDisableRecentMacs() {
        assertTrue(MacDiscoveryAvailability.available(false, false, 10_000, 11_000))
        assertFalse(MacDiscoveryAvailability.available(false, true, 10_000, 11_000))
        assertFalse(MacDiscoveryAvailability.available(false, false, 10_000, 70_000))
        assertTrue(MacDiscoveryAvailability.available(true, false, 10_000, 70_000))
    }

}
