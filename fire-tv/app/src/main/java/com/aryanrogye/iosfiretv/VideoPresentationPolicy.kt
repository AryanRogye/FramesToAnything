package com.aryanrogye.iosfiretv

/**
 * Keep decoded video in the application until its AUDIO-clock deadline is near.
 * MediaCodec's timestamped Surface API is not an arbitrary-future scheduler:
 * SurfaceView may ignore deadlines more than ~1 second away and render early.
 * Even inside that limit, queuing many frames makes a later audio-clock correction
 * ineffective because already released buffers cannot be rescheduled.
 * https://developer.android.com/reference/android/media/MediaCodec#releaseOutputBuffer(int,long)
 */
internal object VideoPresentationPolicy {
    enum class Action { HOLD, DROP, RENDER }

    fun action(renderTimeNs: Long?, nowNs: Long): Action = when {
        // Reacquiring audio is not permission to discard a future video frame.
        renderTimeNs == null -> Action.HOLD
        renderTimeNs < nowNs - 100_000_000L -> Action.DROP
        renderTimeNs > nowNs + 30_000_000L -> Action.HOLD
        else -> Action.RENDER
    }
}
