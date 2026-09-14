package com.aryanrogye.iosfiretv

import java.nio.ByteBuffer
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/** Wire-compatible with ReceiverControlAuthentication.swift. No Android dependencies. */
internal class ReceiverControlAuthentication(
    private val key: ByteArray,
    private val server: ByteArray,
    private val client: ByteArray,
) {
    private var sequence = 0L

    // Caller serializes signing and writes under outputLock.
    fun next(payload: ByteArray): Pair<Long, ByteArray> {
        check(sequence < Long.MAX_VALUE)
        sequence += 1
        return sequence to proof(sequence, payload)
    }

    fun proof(sequence: Long, payload: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        mac.update("receiver-control-v1".toByteArray(Charsets.UTF_8))
        mac.update(server)
        mac.update(client)
        mac.update(ByteBuffer.allocate(8).putLong(sequence).array())
        return mac.doFinal(payload)
    }

    companion object {
        const val FEATURE = "authenticated-controls-v1"
    }
}
