package com.aryanrogye.iosfiretv

/** Decides when missing video delivery is long enough to explain a frozen picture. */
object StreamDeliveryHealth {
    const val LAG_THRESHOLD_MILLISECONDS = 1_200L

    fun isLagging(
        streaming: Boolean,
        paused: Boolean,
        lastVideoArrivalMilliseconds: Long,
        nowMilliseconds: Long,
    ): Boolean {
        if (!streaming || paused || lastVideoArrivalMilliseconds == 0L) return false
        return nowMilliseconds - lastVideoArrivalMilliseconds >= LAG_THRESHOLD_MILLISECONDS
    }
}
