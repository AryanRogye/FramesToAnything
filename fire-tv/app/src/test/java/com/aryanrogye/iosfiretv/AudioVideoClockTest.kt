package com.aryanrogye.iosfiretv

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Regression contract for the Fire TV playback clock.
 *
 * These tests deliberately model the failures seen on real Fire OS hardware.
 * Do not weaken them to accommodate a timing implementation: video being held
 * is acceptable while an audio clock is uncertain; video running ahead is not.
 */
class AudioVideoClockTest {
    @Test
    fun `play request is never treated as audible audio`() {
        val time = FakeTime()
        val source = FakeAudioPositionSource(playbackHead = 2_400)
        val clock = clock(time)

        clock.start(source, FIRST_MEDIA_MILLISECONDS, SAMPLE_RATE)
        assertNull(clock.renderTimeNanoseconds(FIRST_MEDIA_MILLISECONDS))

        time.advanceMilliseconds(299)
        source.playbackHead = 4_800
        assertNull(clock.renderTimeNanoseconds(FIRST_MEDIA_MILLISECONDS))

        time.advanceMilliseconds(1)
        assertTrue(clock.renderTimeNanoseconds(FIRST_MEDIA_MILLISECONDS) != null)
    }

    @Test
    fun `static playback head can never unlock video`() {
        val time = FakeTime()
        val source = FakeAudioPositionSource(playbackHead = 4_800)
        val clock = clock(time)

        clock.start(source, FIRST_MEDIA_MILLISECONDS, SAMPLE_RATE)
        assertNull(clock.renderTimeNanoseconds(FIRST_MEDIA_MILLISECONDS))

        // Even well past warm-up, a nonzero but motionless counter does not
        // prove that audio is playing. Treating it as proof recreates the exact
        // failure where a queued frame is shown before corresponding sound.
        time.advanceMilliseconds(1_000)
        assertNull(clock.renderTimeNanoseconds(FIRST_MEDIA_MILLISECONDS))
    }

    @Test
    fun `two device samples establish one timeline for audio and video`() {
        val time = FakeTime()
        val source = FakeAudioPositionSource()
        val clock = clock(time)
        clock.start(source, FIRST_MEDIA_MILLISECONDS, SAMPLE_RATE)

        source.timestamps += AudioPosition(framePosition = 0, nanoTime = time.now)
        assertNull(clock.renderTimeNanoseconds(FIRST_MEDIA_MILLISECONDS))

        time.advanceMilliseconds(100)
        source.timestamps += AudioPosition(framePosition = 4_800, nanoTime = time.now)

        // Frame 4,800 is media time 1,100 ms at 48 kHz. Therefore video time
        // 1,200 ms must be scheduled exactly 100 ms after that audio position.
        assertEquals(
            time.now + 100 * NANOS_PER_MILLISECOND,
            clock.renderTimeNanoseconds(FIRST_MEDIA_MILLISECONDS + 200),
        )
        assertEquals(FIRST_MEDIA_MILLISECONDS + 100, clock.currentMediaTimestampMilliseconds())
    }

    @Test
    fun `delayed HDMI startup delays video by the same amount`() {
        val time = FakeTime()
        val source = FakeAudioPositionSource()
        val clock = clock(time)
        clock.start(source, FIRST_MEDIA_MILLISECONDS, SAMPLE_RATE)

        time.advanceMilliseconds(350)
        source.timestamps += AudioPosition(framePosition = 0, nanoTime = time.now)
        assertNull(clock.renderTimeNanoseconds(FIRST_MEDIA_MILLISECONDS))

        time.advanceMilliseconds(100)
        source.timestamps += AudioPosition(framePosition = 4_800, nanoTime = time.now)

        assertEquals(
            time.now + 100 * NANOS_PER_MILLISECOND,
            clock.renderTimeNanoseconds(FIRST_MEDIA_MILLISECONDS + 200),
        )
    }

    @Test
    fun `future Fire OS timestamps cannot start video`() {
        val time = FakeTime()
        val source = FakeAudioPositionSource(
            playbackHead = 0,
            mirrorTimestampsToPlaybackHead = false,
        )
        val clock = clock(time)
        clock.start(source, FIRST_MEDIA_MILLISECONDS, SAMPLE_RATE)

        source.timestamps += AudioPosition(0, time.now + 5_000 * NANOS_PER_MILLISECOND)
        assertNull(clock.renderTimeNanoseconds(FIRST_MEDIA_MILLISECONDS))

        time.advanceMilliseconds(100)
        source.timestamps += AudioPosition(4_800, time.now + 5_000 * NANOS_PER_MILLISECOND)
        assertNull(clock.renderTimeNanoseconds(FIRST_MEDIA_MILLISECONDS))

        time.advanceMilliseconds(200)
        assertNull(clock.renderTimeNanoseconds(FIRST_MEDIA_MILLISECONDS))
    }

    @Test
    fun `stalled and implausibly fast samples are rejected`() {
        val time = FakeTime()
        val source = FakeAudioPositionSource()
        val clock = clock(time)
        clock.start(source, FIRST_MEDIA_MILLISECONDS, SAMPLE_RATE)

        source.timestamps += AudioPosition(1_000, time.now)
        assertNull(clock.renderTimeNanoseconds(FIRST_MEDIA_MILLISECONDS))

        time.advanceMilliseconds(100)
        source.timestamps += AudioPosition(1_000, time.now)
        assertNull(clock.renderTimeNanoseconds(FIRST_MEDIA_MILLISECONDS))

        time.advanceMilliseconds(100)
        source.timestamps += AudioPosition(50_000, time.now)
        assertNull(clock.renderTimeNanoseconds(FIRST_MEDIA_MILLISECONDS))
    }

    @Test
    fun `clock discontinuity holds video until a fresh stable pair is measured`() {
        val time = FakeTime()
        val warnings = mutableListOf<String>()
        val source = FakeAudioPositionSource()
        val clock = AudioVideoClock(
            monotonicNanoseconds = { time.now },
            onWarning = warnings::add,
        )
        clock.start(source, FIRST_MEDIA_MILLISECONDS, SAMPLE_RATE)

        source.timestamps += AudioPosition(0, time.now)
        assertNull(clock.renderTimeNanoseconds(FIRST_MEDIA_MILLISECONDS))
        time.advanceMilliseconds(100)
        source.timestamps += AudioPosition(4_800, time.now)
        assertTrue(clock.isStarted())

        // A 200 ms clock jump hidden inside a long sample interval can still
        // look like a plausible playback rate. The anchor continuity check must
        // catch it and stop presentation rather than shifting video out of sync.
        time.advanceMilliseconds(2_200)
        source.timestamps += AudioPosition(100_800, time.now)
        assertNull(clock.renderTimeNanoseconds(FIRST_MEDIA_MILLISECONDS + 2_100))
        assertTrue(warnings.any { "discontinuity" in it })

        time.advanceMilliseconds(20)
        source.timestamps += AudioPosition(101_760, time.now)
        assertTrue(clock.renderTimeNanoseconds(FIRST_MEDIA_MILLISECONDS + 2_200) != null)
    }

    @Test
    fun `audio stall invalidates the clock instead of letting video run ahead`() {
        val time = FakeTime()
        val warnings = mutableListOf<String>()
        val source = FakeAudioPositionSource()
        val clock = AudioVideoClock(
            monotonicNanoseconds = { time.now },
            onWarning = warnings::add,
        )
        clock.start(source, FIRST_MEDIA_MILLISECONDS, SAMPLE_RATE)

        source.timestamps += AudioPosition(0, time.now)
        assertNull(clock.renderTimeNanoseconds(FIRST_MEDIA_MILLISECONDS))
        time.advanceMilliseconds(100)
        source.timestamps += AudioPosition(4_800, time.now)
        assertTrue(clock.isStarted())

        // Neither the device timestamp nor playback head advances. Continuing
        // to extrapolate the old anchor would display video over stalled audio.
        time.advanceMilliseconds(751)
        assertNull(clock.renderTimeNanoseconds(FIRST_MEDIA_MILLISECONDS + 851))
        assertTrue(warnings.any { "stopped advancing" in it })
    }

    @Test
    fun `unsigned playback frame counter remains monotonic across wrap`() {
        val time = FakeTime()
        val source = FakeAudioPositionSource(playbackHead = 0x7fff_ff00L)
        val clock = clock(time)
        clock.start(source, FIRST_MEDIA_MILLISECONDS, SAMPLE_RATE)

        // Establish a realistic high-word reference first. A real AudioTrack
        // reaches this point continuously after hours of playback; jumping from
        // a brand-new frame-zero track straight to 0xffff_ff00 would itself be
        // corrupt device data and should not be treated as a normal wrap.
        assertNull(clock.renderTimeNanoseconds(FIRST_MEDIA_MILLISECONDS))
        time.advanceMilliseconds(300)
        source.playbackHead += 4_800
        assertTrue(clock.isStarted())

        source.timestamps += AudioPosition(0xffff_ff00L, time.now)
        time.advanceMilliseconds(20)
        assertTrue(clock.isStarted())
        source.timestamps += AudioPosition(704, time.now)
        time.advanceMilliseconds(20)
        assertTrue(clock.isStarted())

        val expectedMediaTime = FIRST_MEDIA_MILLISECONDS +
            0x1_0000_02c0L * 1_000L / SAMPLE_RATE + 20
        assertEquals(expectedMediaTime, clock.currentMediaTimestampMilliseconds())
    }

    @Test
    fun `reset removes every previous playback anchor`() {
        val time = FakeTime()
        val source = FakeAudioPositionSource()
        val clock = clock(time)
        clock.start(source, FIRST_MEDIA_MILLISECONDS, SAMPLE_RATE)

        source.timestamps += AudioPosition(0, time.now)
        assertNull(clock.renderTimeNanoseconds(FIRST_MEDIA_MILLISECONDS))
        time.advanceMilliseconds(100)
        source.timestamps += AudioPosition(4_800, time.now)
        assertTrue(clock.isStarted())

        clock.reset()

        assertFalse(clock.isStarted())
        assertNull(clock.currentMediaTimestampMilliseconds())
        assertNull(clock.renderTimeNanoseconds(FIRST_MEDIA_MILLISECONDS))
    }

    @Test
    fun `long playback with bounded jitter stays on the audio timeline`() {
        val time = FakeTime()
        val source = FakeAudioPositionSource()
        val clock = clock(time)
        clock.start(source, FIRST_MEDIA_MILLISECONDS, SAMPLE_RATE)

        source.timestamps += AudioPosition(0, time.now)
        assertNull(clock.renderTimeNanoseconds(FIRST_MEDIA_MILLISECONDS))
        time.advanceMilliseconds(100)
        source.timestamps += AudioPosition(4_800, time.now)
        assertTrue(clock.isStarted())

        var frames = 4_800L
        repeat(30) { index ->
            time.advanceMilliseconds(2_000)
            frames += SAMPLE_RATE * 2L
            val jitterMilliseconds = if (index % 2 == 0) 3L else -3L
            source.timestamps += AudioPosition(
                framePosition = frames,
                nanoTime = time.now + jitterMilliseconds * NANOS_PER_MILLISECOND,
            )
            val mediaNow = clock.currentMediaTimestampMilliseconds()
            assertTrue(mediaNow != null)
            assertTrue(kotlin.math.abs(mediaNow!! - (FIRST_MEDIA_MILLISECONDS + frames / 48)) <= 4)
        }
    }

    private fun clock(time: FakeTime) = AudioVideoClock(monotonicNanoseconds = { time.now })

    private class FakeTime(var now: Long = 10 * NANOS_PER_MILLISECOND) {
        fun advanceMilliseconds(milliseconds: Long) {
            now += milliseconds * NANOS_PER_MILLISECOND
        }
    }

    private class FakeAudioPositionSource(
        var playbackHead: Long = 0,
        private val mirrorTimestampsToPlaybackHead: Boolean = true,
    ) : AudioPositionSource {
        val timestamps = ArrayDeque<AudioPosition>()

        override fun timestamp(): AudioPosition? = timestamps.removeFirstOrNull()?.also {
            if (mirrorTimestampsToPlaybackHead) playbackHead = it.framePosition
        }

        override fun playbackHeadPosition(): Long = playbackHead
    }

    private companion object {
        const val SAMPLE_RATE = 48_000
        const val FIRST_MEDIA_MILLISECONDS = 1_000L
        const val NANOS_PER_MILLISECOND = 1_000_000L
    }
}
