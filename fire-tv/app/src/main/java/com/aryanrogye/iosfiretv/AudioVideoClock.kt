package com.aryanrogye.iosfiretv

import kotlin.math.abs

/** A sampled audio-frame position and the monotonic time at which it is presented. */
internal data class AudioPosition(
    val framePosition: Long,
    val nanoTime: Long,
)

/**
 * The narrow portion of AudioTrack needed to establish the playback clock.
 *
 * Keeping Android behind this interface is intentional: synchronization is a
 * correctness rule, so its failure cases must be reproducible in fast JVM tests
 * without depending on a particular Fire TV, HDMI route, or wall-clock timing.
 */
internal interface AudioPositionSource {
    fun timestamp(): AudioPosition?
    fun playbackHeadPosition(): Long
}

/**
 * Maps every media timestamp onto the audio device's monotonic playback clock.
 *
 * CRITICAL A/V INVARIANT:
 * A video frame may be presented only at the monotonic time derived from the
 * audio playback position for the same media timestamp. Queue arrival time,
 * decode completion time, and the call to AudioTrack.play() are never clocks.
 *
 * The preferred anchor is an AudioTimestamp-style device position. Two samples
 * must advance at the configured sample rate before they are trusted. If the
 * device does not expose timestamps, the advancing playback head is used only
 * after a warm-up delay. If an established device clock jumps, video is held
 * while a new pair of consistent samples is acquired; continuing with a stale
 * mapping would be more harmful than briefly dropping/holding video.
 */
internal class AudioVideoClock(
    private val monotonicNanoseconds: () -> Long = System::nanoTime,
    private val onInfo: (String) -> Unit = {},
    private val onWarning: (String) -> Unit = {},
) {
    private val lock = Any()
    private var source: AudioPositionSource? = null
    private var firstAudioTimestampMilliseconds = 0L
    private var sampleRate = 0
    private var playbackRequestedNanoseconds = 0L
    private var reacquireStartedNanoseconds = 0L
    private var lastTimestampPollNanoseconds = 0L
    private var lastPlaybackHeadPollNanoseconds = 0L
    private var lastAudioProgressNanoseconds = 0L
    private var lastPlaybackHeadPosition: Long? = null
    private var playbackHeadAdvancedSinceReacquire = false
    private var maximumObservedFramePosition = 0L
    private var timestampCandidate: AudioPosition? = null
    private var timestampAnchor: AudioPosition? = null
    private var playbackHeadAnchor: AudioPosition? = null
    private var loggedTimestampAnchor = false
    private var loggedPlaybackHeadFallback = false

    /**
     * Begins acquisition of the one playback timeline shared by audio and video.
     *
     * AudioTrack.play() only requests playback. AudioFlinger, HDMI, and the TV
     * can still hold audio after that call returns, so the call time is recorded
     * only to enforce warm-up—it is never used as the presentation-time anchor.
     */
    fun start(
        source: AudioPositionSource,
        firstAudioTimestampMilliseconds: Long,
        sampleRate: Int,
    ) {
        require(sampleRate > 0) { "sampleRate must be positive" }
        synchronized(lock) {
            this.source = source
            this.firstAudioTimestampMilliseconds = firstAudioTimestampMilliseconds
            this.sampleRate = sampleRate
            playbackRequestedNanoseconds = monotonicNanoseconds()
            reacquireStartedNanoseconds = playbackRequestedNanoseconds
            // Permit the first query immediately. Subsequent warm-up queries
            // remain rate-limited, but there is no reason to add 20 ms before
            // the device can begin proving that its audio clock is valid.
            lastTimestampPollNanoseconds =
                playbackRequestedNanoseconds - TIMESTAMP_WARMUP_POLL_NANOSECONDS
            lastPlaybackHeadPollNanoseconds =
                playbackRequestedNanoseconds - PLAYBACK_HEAD_POLL_NANOSECONDS
            lastAudioProgressNanoseconds = playbackRequestedNanoseconds
            lastPlaybackHeadPosition = null
            playbackHeadAdvancedSinceReacquire = false
            maximumObservedFramePosition = 0
            timestampCandidate = null
            timestampAnchor = null
            playbackHeadAnchor = null
            loggedTimestampAnchor = false
            loggedPlaybackHeadFallback = false
        }
    }

    /** Returns null while audio has not supplied a trustworthy playback clock. */
    fun renderTimeNanoseconds(mediaTimestampMilliseconds: Long): Long? = synchronized(lock) {
        val anchor = refreshAudioAnchorLocked() ?: return null
        anchor.nanoTime +
            (mediaTimestampMilliseconds - mediaTimestampAt(anchor)) * NANOS_PER_MILLISECOND
    }

    /** Video decoding may begin only after audio has supplied a real clock. */
    fun isStarted(): Boolean = synchronized(lock) { refreshAudioAnchorLocked() != null }

    fun currentMediaTimestampMilliseconds(): Long? = synchronized(lock) {
        val anchor = refreshAudioAnchorLocked() ?: return null
        mediaTimestampAt(anchor) +
            (monotonicNanoseconds() - anchor.nanoTime) / NANOS_PER_MILLISECOND
    }

    fun reset() {
        synchronized(lock) {
            source = null
            sampleRate = 0
            playbackRequestedNanoseconds = 0
            reacquireStartedNanoseconds = 0
            lastTimestampPollNanoseconds = 0
            lastPlaybackHeadPollNanoseconds = 0
            lastAudioProgressNanoseconds = 0
            lastPlaybackHeadPosition = null
            playbackHeadAdvancedSinceReacquire = false
            maximumObservedFramePosition = 0
            timestampCandidate = null
            timestampAnchor = null
            playbackHeadAnchor = null
        }
    }

    private fun refreshAudioAnchorLocked(): AudioPosition? {
        val activeSource = source ?: return null
        if (sampleRate <= 0 || playbackRequestedNanoseconds == 0L) return null
        val now = monotonicNanoseconds()
        val pollInterval = if (timestampAnchor == null) {
            TIMESTAMP_WARMUP_POLL_NANOSECONDS
        } else {
            TIMESTAMP_STABLE_POLL_NANOSECONDS
        }

        if (now - lastTimestampPollNanoseconds >= pollInterval) {
            lastTimestampPollNanoseconds = now
            val measured = runCatching { activeSource.timestamp() }.getOrNull()
            if (measured != null) {
                processTimestampLocked(measured, now)
            } else if (timestampAnchor == null) {
                // A missing sample must break the validation pair. Otherwise two
                // observations separated by a route restart could look stable.
                timestampCandidate = null
            }
        }

        val observedPlaybackHead = pollPlaybackHeadLocked(activeSource, now)
        if (timestampAnchor != null &&
            now - lastAudioProgressNanoseconds > MAX_AUDIO_STALL_NANOSECONDS
        ) {
            invalidateAnchorLocked(
                now = now,
                reason = "Audio playback stopped advancing; holding video while reacquiring",
            )
            return null
        }

        timestampAnchor?.let { return it }

        // This applies both at startup and after a detected clock discontinuity.
        // It prevents the approximate playback head from immediately masking a
        // route transition before the device has had time to expose a new clock.
        if (now - reacquireStartedNanoseconds < AUDIO_CLOCK_WARMUP_NANOSECONDS) return null

        val playedFrames = observedPlaybackHead ?: lastPlaybackHeadPosition ?: return null
        if (playedFrames <= 0 || !playbackHeadAdvancedSinceReacquire) return null
        if (now - lastAudioProgressNanoseconds > MAX_AUDIO_STALL_NANOSECONDS) return null

        val previousHeadAnchor = playbackHeadAnchor
        if (previousHeadAnchor == null || playedFrames > previousHeadAnchor.framePosition) {
            playbackHeadAnchor = AudioPosition(playedFrames, now)
        }
        if (!loggedPlaybackHeadFallback) {
            loggedPlaybackHeadFallback = true
            onWarning(
                "Audio timestamp unavailable after warm-up; " +
                    "using playback-head clock at frame=$playedFrames",
            )
        }
        return playbackHeadAnchor
    }

    private fun processTimestampLocked(rawSample: AudioPosition, now: Long) {
        val framePosition = unwrapFramePosition(rawSample.framePosition)
        val sample = rawSample.copy(framePosition = framePosition)
        val closeToMonotonicNow =
            abs(sample.nanoTime - now) <= MAX_TIMESTAMP_DISTANCE_NANOSECONDS
        val previous = timestampCandidate
        val advancesAtPlaybackRate = previous != null &&
            sample.framePosition > previous.framePosition &&
            sample.nanoTime > previous.nanoTime &&
            isExpectedPlaybackRate(previous, sample)

        // A timestamp far from the monotonic clock is known-bad vendor data, so
        // it must not move the 32-bit wrap reference. Doing so could shift the
        // otherwise trustworthy playback-head fallback by a full 2^32 epoch.
        if (closeToMonotonicNow) observeFramePosition(framePosition)

        if (closeToMonotonicNow && advancesAtPlaybackRate) {
            val established = timestampAnchor
            if (established != null && isDiscontinuous(established, sample)) {
                // Never continue scheduling video from an audio mapping that the
                // device has contradicted. Hold video and validate a fresh pair.
                invalidateAnchorLocked(
                    now = now,
                    reason = "Audio clock discontinuity detected; holding video while reacquiring",
                    nextCandidate = sample,
                )
                return
            }

            timestampAnchor = sample
            playbackHeadAnchor = null
            lastAudioProgressNanoseconds = now
            if (!loggedTimestampAnchor) {
                loggedTimestampAnchor = true
                onInfo(
                    "A/V clock anchored to audio timestamp " +
                        "frame=${sample.framePosition} " +
                        "offsetMs=${(sample.nanoTime - now) / NANOS_PER_MILLISECOND}",
                )
            }
        }
        timestampCandidate = if (closeToMonotonicNow) sample else null
    }

    private fun pollPlaybackHeadLocked(
        activeSource: AudioPositionSource,
        now: Long,
    ): Long? {
        if (now - lastPlaybackHeadPollNanoseconds < PLAYBACK_HEAD_POLL_NANOSECONDS) {
            return null
        }
        lastPlaybackHeadPollNanoseconds = now
        val rawPosition = runCatching { activeSource.playbackHeadPosition() }.getOrNull()
            ?: return null
        val position = unwrapFramePosition(rawPosition)
        observeFramePosition(position)
        val previous = lastPlaybackHeadPosition
        if (previous != null && position > previous) {
            lastAudioProgressNanoseconds = now
            playbackHeadAdvancedSinceReacquire = true
        }
        lastPlaybackHeadPosition = position
        return position
    }

    private fun invalidateAnchorLocked(
        now: Long,
        reason: String,
        nextCandidate: AudioPosition? = null,
    ) {
        timestampAnchor = null
        playbackHeadAnchor = null
        timestampCandidate = nextCandidate
        reacquireStartedNanoseconds = now
        playbackHeadAdvancedSinceReacquire = false
        loggedTimestampAnchor = false
        loggedPlaybackHeadFallback = false
        onWarning(reason)
    }

    private fun mediaTimestampAt(anchor: AudioPosition): Long =
        firstAudioTimestampMilliseconds +
            anchor.framePosition * MILLIS_PER_SECOND / sampleRate

    private fun isExpectedPlaybackRate(previous: AudioPosition, current: AudioPosition): Boolean {
        val elapsedNanoseconds = current.nanoTime - previous.nanoTime
        if (elapsedNanoseconds <= 0) return false
        val measuredFramesPerSecond =
            (current.framePosition - previous.framePosition).toDouble() * NANOS_PER_SECOND /
                elapsedNanoseconds.toDouble()
        return measuredFramesPerSecond in
            (sampleRate * MIN_VALID_RATE_RATIO)..(sampleRate * MAX_VALID_RATE_RATIO)
    }

    private fun isDiscontinuous(previous: AudioPosition, current: AudioPosition): Boolean {
        val predictedNanoTime = previous.nanoTime +
            (current.framePosition - previous.framePosition) * NANOS_PER_SECOND / sampleRate
        return abs(current.nanoTime - predictedNanoTime) > MAX_ANCHOR_JUMP_NANOSECONDS
    }

    /** Expands Android's wrapping unsigned 32-bit audio frame counter. */
    private fun unwrapFramePosition(rawPosition: Long): Long {
        val lowBits = rawPosition and FRAME_POSITION_MASK
        val reference = maximumObservedFramePosition
        var candidate = (reference and FRAME_POSITION_HIGH_BITS_MASK) or lowBits
        if (candidate + FRAME_POSITION_HALF_RANGE < reference) {
            candidate += FRAME_POSITION_FULL_RANGE
        } else if (candidate - FRAME_POSITION_HALF_RANGE > reference) {
            candidate -= FRAME_POSITION_FULL_RANGE
        }
        return candidate.coerceAtLeast(0)
    }

    private fun observeFramePosition(framePosition: Long) {
        maximumObservedFramePosition = maxOf(maximumObservedFramePosition, framePosition)
    }

    private companion object {
        const val NANOS_PER_MILLISECOND = 1_000_000L
        const val NANOS_PER_SECOND = 1_000_000_000L
        const val MILLIS_PER_SECOND = 1_000L
        const val TIMESTAMP_WARMUP_POLL_NANOSECONDS = 20_000_000L
        const val TIMESTAMP_STABLE_POLL_NANOSECONDS = 500_000_000L
        const val PLAYBACK_HEAD_POLL_NANOSECONDS = 20_000_000L
        const val AUDIO_CLOCK_WARMUP_NANOSECONDS = 300_000_000L
        const val MAX_AUDIO_STALL_NANOSECONDS = 750_000_000L
        const val MAX_TIMESTAMP_DISTANCE_NANOSECONDS = 1_000_000_000L
        const val MAX_ANCHOR_JUMP_NANOSECONDS = 80_000_000L
        const val MIN_VALID_RATE_RATIO = 0.80
        const val MAX_VALID_RATE_RATIO = 1.20
        const val FRAME_POSITION_MASK = 0xffff_ffffL
        const val FRAME_POSITION_HIGH_BITS_MASK = -0x1_0000_0000L
        const val FRAME_POSITION_HALF_RANGE = 0x8000_0000L
        const val FRAME_POSITION_FULL_RANGE = 0x1_0000_0000L
    }
}
