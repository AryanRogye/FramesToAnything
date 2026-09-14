package com.aryanrogye.iosfiretv

import org.junit.Assert.*
import org.junit.Test

class DecoderGenerationTest {
    @Test fun retainedInputCannotSurviveFlushOrReplacement() {
        val decoder = DecoderGeneration()
        val heldInput = decoder.current
        repeat(10) { assertTrue(decoder.accepts(heldInput)) } // no input buffer yet
        decoder.invalidate() // network overflow flushes while worker retries
        assertFalse(decoder.accepts(heldInput))
        val keyframe = decoder.current
        assertTrue(decoder.accepts(keyframe))
        decoder.invalidate() // codec replacement
        assertFalse(decoder.accepts(keyframe))
    }
}
