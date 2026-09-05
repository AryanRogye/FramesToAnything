package com.aryanrogye.iosfiretv

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AudioStreamFormatTest {
    @Test fun `reannouncing identical PCM preserves the track`() {
        assertTrue(AudioStreamFormat(48_000, 2, 1, byteArrayOf()).matches(
            AudioStreamFormat(48_000, 2, 1, byteArrayOf()),
        ))
    }

    @Test fun `real format changes still require reconfiguration`() {
        val original = AudioStreamFormat(48_000, 2, 1, byteArrayOf())
        assertFalse(original.matches(AudioStreamFormat(44_100, 2, 1, byteArrayOf())))
        assertFalse(original.matches(AudioStreamFormat(48_000, 1, 1, byteArrayOf())))
        assertFalse(original.matches(AudioStreamFormat(48_000, 2, 2, byteArrayOf(1))))
    }
}
