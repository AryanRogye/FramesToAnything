package com.aryanrogye.iosfiretv

/** Access only while holding decoderLock, including the final codec submission. */
internal class DecoderGeneration {
    var current = 0L
        private set
    fun invalidate() { current += 1 }
    fun accepts(generation: Long) = generation == current
}
