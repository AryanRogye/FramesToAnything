package com.aryanrogye.iosfiretv

object RemoteMediaCommand {
    const val TOGGLE = "toggle_play_pause"
    const val FORWARD_10 = "seek_forward_10"
    const val BACKWARD_10 = "seek_backward_10"
    const val SEEK_FEATURE = "remote-seek-v1"

    fun isSeek(command: String) = command == FORWARD_10 || command == BACKWARD_10
    fun allowed(command: String, seekNegotiated: Boolean) =
        command == TOGGLE || (seekNegotiated && isSeek(command))

    // Android media key codes; D-pad navigation remains untouched.
    fun forKey(keyCode: Int): String? = when (keyCode) {
        79, 85, 126, 127 -> TOGGLE
        89 -> BACKWARD_10
        90 -> FORWARD_10
        else -> null
    }
}
