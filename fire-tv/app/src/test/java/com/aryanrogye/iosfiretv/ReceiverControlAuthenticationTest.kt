package com.aryanrogye.iosfiretv

import org.junit.Assert.*
import org.junit.Test

class ReceiverControlAuthenticationTest {
    @Test fun matchesSwiftAndOpenSSLVector() {
        val signer = ReceiverControlAuthentication(ByteArray(32) { 2 }, ByteArray(32), ByteArray(32) { 1 })
        val payload = """{"type":"request_keyframe"}""".toByteArray()
        val (sequence, proof) = signer.next(payload)
        assertEquals(1L, sequence)
        assertEquals("6869ddeed7d23e5044885a5694477a851b8ab834879fbd2d40715b0f0cfc3a03",
            proof.joinToString("") { "%02x".format(it) })
        val (next, secondProof) = signer.next(payload)
        assertEquals(2L, next)
        assertFalse(proof.contentEquals(secondProof))
        val otherSession = ReceiverControlAuthentication(ByteArray(32) { 2 }, ByteArray(32), ByteArray(32) { 3 })
        assertFalse(proof.contentEquals(otherSession.next(payload).second))
    }
}
