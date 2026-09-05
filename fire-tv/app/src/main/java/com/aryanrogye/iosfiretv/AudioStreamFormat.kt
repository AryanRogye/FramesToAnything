package com.aryanrogye.iosfiretv

/** Repeated format announcements are common after video keyframe requests. */
internal class AudioStreamFormat(
    val sampleRate: Int,
    val channels: Int,
    val encoding: Int,
    codecConfig: ByteArray,
) {
    private val codecConfig = codecConfig.copyOf()

    fun matches(other: AudioStreamFormat): Boolean =
        sampleRate == other.sampleRate && channels == other.channels &&
            encoding == other.encoding && codecConfig.contentEquals(other.codecConfig)
}
