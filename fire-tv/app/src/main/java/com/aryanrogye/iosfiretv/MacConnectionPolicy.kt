package com.aryanrogye.iosfiretv

/** Serialized by the receiver coordinator; sockets/NSD stay outside this policy. */
class MacConnectionPolicy {
    enum class State { IDLE, RESOLVING, CONNECTING, AUTHENTICATING, AWAITING_MEDIA, STREAMING, BACKOFF, PAIRING_REQUIRED, STOPPED }
    var state = State.IDLE
        private set
    var generation = 0L
        private set
    var selectedMac: String? = null
        private set
    var wantsConnection = false
        private set
    var failures = 0
        private set

    fun select(mac: String) {
        generation++
        selectedMac = mac
        wantsConnection = true
        failures = 0
        state = State.RESOLVING
    }

    fun beginAttempt(): Long? {
        if (!wantsConnection || state !in setOf(State.RESOLVING, State.BACKOFF)) return null
        generation++
        state = State.CONNECTING
        return generation
    }

    fun transition(token: Long, expected: State, next: State): Boolean {
        if (token != generation || state != expected) return false
        state = next
        return true
    }

    fun failed(token: Long, pairingRequired: Boolean = false): Boolean {
        if (token != generation || !wantsConnection) return false
        failures = (failures + 1).coerceAtMost(30)
        state = if (pairingRequired) State.PAIRING_REQUIRED else State.BACKOFF
        if (pairingRequired) wantsConnection = false
        return true
    }

    fun healthy(token: Long) {
        if (token == generation && state == State.STREAMING) failures = 0
    }

    fun disconnect(stop: Boolean = false) {
        generation++
        wantsConnection = false
        state = if (stop) State.STOPPED else State.IDLE
    }

    fun retryDelayMilliseconds(): Long = (1_000L shl failures.coerceAtMost(4)).coerceAtMost(15_000)
}

data class MacServer(val id: String, val name: String, val available: Boolean, val trusted: Boolean)

/** Discovery restarts aren't service loss. Keep a recently resolved row usable. */
object MacDiscoveryAvailability {
    fun available(servicePresent: Boolean, explicitlyLost: Boolean, lastSeen: Long, now: Long): Boolean =
        !explicitlyLost && (servicePresent || now - lastSeen < 60_000)
}
