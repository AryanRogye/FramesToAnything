package com.aryanrogye.iosfiretv

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer
import java.util.concurrent.LinkedBlockingDeque
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/** Hardware video decode and bounded, low-latency PCM playback for live mirroring. */
class FireTVMediaPlayer {
    private var surface: Surface? = null
    private var decoder: MediaCodec? = null
    private var audioTrack: AudioTrack? = null
    private var videoConfiguration: VideoConfiguration? = null
    private val outputInfo = MediaCodec.BufferInfo()
    private var queuedVideoFrames = 0L
    private var renderedVideoFrames = 0L
    private val audioQueue = LinkedBlockingDeque<ByteArray>(MAX_QUEUED_AUDIO_CHUNKS)
    private val audioWriterRunning = AtomicBoolean(true)
    private val audioWriter = thread(
        start = true,
        isDaemon = true,
        name = "fire-tv-audio-writer",
    ) {
        while (audioWriterRunning.get()) {
            try {
                val pcm = audioQueue.takeFirst()
                val track = synchronized(this) { audioTrack } ?: continue
                var offset = 0
                while (offset < pcm.size && audioWriterRunning.get()) {
                    val written = track.write(
                        pcm,
                        offset,
                        pcm.size - offset,
                        AudioTrack.WRITE_BLOCKING,
                    )
                    if (written <= 0) break
                    offset += written
                }
            } catch (_: InterruptedException) {
                // Release wakes the writer so its thread can exit.
            } catch (error: IllegalStateException) {
                Log.w(TAG, "audio track changed while writing", error)
            }
        }
    }

    @Synchronized
    fun configureVideo(
        width: Int,
        height: Int,
        rotationDegrees: Int,
        sps: ByteArray,
        pps: ByteArray,
    ) {
        val configuration = VideoConfiguration(
            width = width,
            height = height,
            rotationDegrees = rotationDegrees,
            sps = sps.copyOf(),
            pps = pps.copyOf(),
        )
        videoConfiguration = configuration
        startVideoDecoder(configuration)
    }

    /** Rebinds decoding whenever Android recreates the TextureView surface. */
    @Synchronized
    fun setSurface(newSurface: Surface?) {
        releaseVideo()
        surface?.release()
        surface = newSurface
        videoConfiguration?.let(::startVideoDecoder)
    }

    private fun startVideoDecoder(configuration: VideoConfiguration) {
        releaseVideo()
        val targetSurface = surface
        if (targetSurface == null || !targetSurface.isValid) {
            Log.i(TAG, "Video configuration retained until the display surface is ready")
            return
        }
        val (width, height, rotationDegrees, sps, pps) = configuration
        Log.i(TAG, "configureVideo ${width}x$height rotation=$rotationDegrees surfaceValid=${targetSurface.isValid}")
        val codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setByteBuffer("csd-0", ByteBuffer.wrap(START_CODE + sps))
            setByteBuffer("csd-1", ByteBuffer.wrap(START_CODE + pps))
            setInteger(MediaFormat.KEY_ROTATION, rotationDegrees)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            }
            setInteger(MediaFormat.KEY_PRIORITY, 0)
        }
        codec.configure(format, targetSurface, null, 0)
        codec.start()
        decoder = codec
        queuedVideoFrames = 0
        renderedVideoFrames = 0
    }

    @Synchronized
    fun queueVideo(data: ByteArray, timestampMilliseconds: Long, keyFrame: Boolean) {
        val codec = decoder ?: return
        drainVideo(codec)

        val inputIndex = codec.dequeueInputBuffer(0)
        if (inputIndex < 0) {
            if (queuedVideoFrames % 120L == 0L) Log.w(TAG, "decoder input busy after $queuedVideoFrames frames")
            return // Freshness is more important than retaining an old frame.
        }
        val input = codec.getInputBuffer(inputIndex) ?: return
        input.clear()
        if (data.size > input.remaining()) return
        input.put(data)
        codec.queueInputBuffer(
            inputIndex,
            0,
            data.size,
            timestampMilliseconds * 1_000,
            if (keyFrame) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0,
        )
        queuedVideoFrames += 1
        if (queuedVideoFrames == 1L || queuedVideoFrames % 120L == 0L) {
            Log.d(TAG, "queued video=$queuedVideoFrames rendered=$renderedVideoFrames bytes=${data.size} key=$keyFrame")
        }
        drainVideo(codec)
    }

    @Synchronized
    fun configureAudio(sampleRate: Int, channels: Int) {
        releaseAudio()
        audioQueue.clear()
        val channelMask = if (channels == 1) {
            AudioFormat.CHANNEL_OUT_MONO
        } else {
            AudioFormat.CHANNEL_OUT_STEREO
        }
        val minimum = AudioTrack.getMinBufferSize(
            sampleRate,
            channelMask,
            AudioFormat.ENCODING_PCM_16BIT,
        ).coerceAtLeast(sampleRate * channels / 20)
        val format = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(sampleRate)
            .setChannelMask(channelMask)
            .build()
        val attributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
            .build()
        val builder = AudioTrack.Builder()
            .setAudioAttributes(attributes)
            .setAudioFormat(format)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setBufferSizeInBytes(minimum * 2)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder.setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
        }
        audioTrack = builder.build().also { it.play() }
    }

    fun queueAudio(pcm: ByteArray) {
        if (!audioWriterRunning.get()) return
        if (!audioQueue.offerLast(pcm)) {
            audioQueue.pollFirst()
            audioQueue.offerLast(pcm)
            Log.w(TAG, "audio queue full; dropped oldest live chunk")
        }
    }

    @Synchronized
    fun reset() {
        releaseVideo()
        releaseAudio()
        videoConfiguration = null
    }

    @Synchronized
    fun release() {
        reset()
        audioWriterRunning.set(false)
        audioWriter.interrupt()
        surface?.release()
        surface = null
    }

    private fun drainVideo(codec: MediaCodec) {
        while (true) {
            val outputIndex = codec.dequeueOutputBuffer(outputInfo, 0)
            when {
                outputIndex >= 0 -> {
                    codec.releaseOutputBuffer(outputIndex, true)
                    renderedVideoFrames += 1
                    if (renderedVideoFrames == 1L || renderedVideoFrames % 120L == 0L) {
                        Log.d(TAG, "rendered video=$renderedVideoFrames queued=$queuedVideoFrames size=${outputInfo.size}")
                    }
                }
                outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED ->
                    Log.d(TAG, "decoder output format=${codec.outputFormat}")
                else -> return
            }
        }
    }

    private fun releaseVideo() {
        decoder?.let { codec ->
            runCatching { codec.stop() }
            runCatching { codec.release() }
        }
        decoder = null
    }

    @Suppress("DEPRECATION")
    private fun releaseAudio() {
        audioQueue.clear()
        audioTrack?.let { track ->
            runCatching { track.pause() }
            runCatching { track.flush() }
            runCatching { track.stop() }
            runCatching { track.release() }
        }
        audioTrack = null
    }

    private companion object {
        const val TAG = "FireTVMedia"
        const val MAX_QUEUED_AUDIO_CHUNKS = 10
        val START_CODE = byteArrayOf(0, 0, 0, 1)
    }

    private data class VideoConfiguration(
        val width: Int,
        val height: Int,
        val rotationDegrees: Int,
        val sps: ByteArray,
        val pps: ByteArray,
    )
}
