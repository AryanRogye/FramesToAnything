package com.aryanrogye.iosfiretv

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.AudioTimestamp
import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer
import java.util.concurrent.LinkedBlockingDeque
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/** Continuous, audio-clocked playback with a bounded cinema jitter buffer. */
class FireTVMediaPlayer(
    private val onReport: (CinemaPlaybackReport) -> Unit = {},
    private val onKeyFrameNeeded: (String, Long) -> Unit = { _, _ -> },
) {
    private val running = AtomicBoolean(true)
    private val decoderLock = Any()
    // Guarded by decoderLock; never reset while old workers may retain input.
    private val decoderGeneration = DecoderGeneration()
    private val audioLock = Any()
    // Decoder callbacks must never acquire the player lifecycle monitor (`this`).
    // configureVideo/reset hold that monitor while acquiring decoderLock; taking
    // them in reverse order on a dropped frame deadlocks the network reader and
    // decoder, stops incoming audio, and looks like a failed connection.
    // This short-lived lock protects counters/recovery state only and is always
    // released before waiting for a decoder or audio operation.
    private val playbackStateLock = Any()
    private val clock = AudioVideoClock(
        onInfo = { Log.i(TAG, it) },
        onWarning = { Log.w(TAG, it) },
    )
    private val videoQueue = LinkedBlockingDeque<VideoFrame>(MAX_VIDEO_FRAMES)
    private val audioQueue = LinkedBlockingDeque<AudioPacket>(MAX_AUDIO_PACKETS)

    private var surface: Surface? = null
    private var decoder: MediaCodec? = null
    private var audioDecoder: MediaCodec? = null
    private var audioTrack: AudioTrack? = null
    private var audioStreamFormat: AudioStreamFormat? = null
    private var videoConfiguration: VideoConfiguration? = null
    private var audioSampleRate = 0
    private var audioChannels = 0
    @Volatile private var audioEncoding = 0
    private var waitingForKeyFrame = true
    private var audioFramesWritten = 0L
    @Volatile private var firstAudioTimestampMilliseconds: Long? = null
    private var underruns = 0L
    private var recoveries = 0L
    @Volatile private var lastPresentedTimestampMilliseconds = 0L
    @Volatile private var lastReceivedVideoTimestampMilliseconds = 0L
    @Volatile private var firstPlayableVideoTimestampMilliseconds = 0L
    private var scheduledVideoFrames = 0L
    // Owned by decoderLock. A dequeued buffer remains ours until its deadline
    // is near; do not sleep under the lock or block incoming audio/configuration.
    private var pendingVideoOutput: Pair<Int, Long>? = null
    private var lastAudioArrivalNanoseconds = 0L

    private val outputInfo = MediaCodec.BufferInfo()

    private val videoWorker = thread(start = true, isDaemon = true, name = "fire-tv-video-decoder") {
        videoLoop()
    }
    private val audioWorker = thread(start = true, isDaemon = true, name = "fire-tv-audio-writer") {
        audioLoop()
    }
    private val reportWorker = thread(start = true, isDaemon = true, name = "fire-tv-cinema-reports") {
        while (running.get()) {
            try {
                Thread.sleep(REPORT_INTERVAL_MILLISECONDS)
                if (clock.isStarted() && lastReceivedVideoTimestampMilliseconds > 0) {
                    onReport(currentReport())
                }
            } catch (_: InterruptedException) {
                break
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
        val previous = videoConfiguration
        if (previous != null && previous.width == width && previous.height == height &&
            previous.rotationDegrees == rotationDegrees &&
            previous.sps.contentEquals(sps) && previous.pps.contentEquals(pps) &&
            synchronized(decoderLock) { decoder != null }
        ) {
            // The Mac resends SPS/PPS after a bitrate change or keyframe
            // request. An identical format does not require a decoder restart:
            // stopping the codec here clears the Surface and causes a blackout.
            Log.d(TAG, "Keeping decoder for repeated video configuration ${width}x$height")
            return
        }
        Log.i(TAG, "Configuring video decoder ${width}x$height")
        videoConfiguration = VideoConfiguration(
            width,
            height,
            rotationDegrees,
            sps.copyOf(),
            pps.copyOf(),
        )
        synchronized(decoderLock) {
            videoQueue.clear()
            waitingForKeyFrame = true
            startVideoDecoder()
        }
    }

    /** SurfaceView surfaces support timestamped presentation at VSYNC. */
    @Synchronized
    fun setSurface(newSurface: Surface?) {
        synchronized(decoderLock) {
            releaseVideoLocked()
            surface = newSurface
            waitingForKeyFrame = true
            videoConfiguration?.let { startVideoDecoder() }
        }
        if (newSurface != null) requestKeyFrame("surface_changed")
    }

    fun queueVideo(data: ByteArray, timestampMilliseconds: Long, keyFrame: Boolean) {
        var requestRecovery = false
        synchronized(decoderLock) {
            if (!running.get()) return
            lastReceivedVideoTimestampMilliseconds = timestampMilliseconds
            synchronized(playbackStateLock) {
                if (waitingForKeyFrame && !keyFrame) return
                if (keyFrame) waitingForKeyFrame = false
            }

            val frame = VideoFrame(data, timestampMilliseconds, keyFrame, decoderGeneration.current)
            if (!clock.isStarted() && keyFrame && firstAudioTimestampMilliseconds == null) {
                // Until audio is ready, retain only the newest complete GOP. Video
                // can arrive seconds before the first audio packet after capture
                // startup; decoding that old prefix makes the stream feel delayed.
                // Once audio pre-roll has begun, preserve that GOP: moving the
                // video start on every keyframe would discard the pictures paired
                // with already-buffered audio throughout the cinema pre-roll.
                videoQueue.clear()
                firstPlayableVideoTimestampMilliseconds = timestampMilliseconds
            } else if (firstPlayableVideoTimestampMilliseconds == 0L) {
                firstPlayableVideoTimestampMilliseconds = timestampMilliseconds
            }
            if (!videoQueue.offerLast(frame)) {
                requestRecovery = beginRecoveryLocked("video_queue_overflow")
                if (keyFrame) {
                    synchronized(playbackStateLock) { waitingForKeyFrame = false }
                    videoQueue.offerLast(frame.copy(generation = decoderGeneration.current))
                }
            }
        }
        // Network writes must not extend the decoder critical section.
        if (requestRecovery) requestKeyFrame("video_queue_overflow")
    }

    @Synchronized
    fun configureAudio(sampleRate: Int, channels: Int, encoding: Int, codecConfig: ByteArray) {
        val incomingFormat = AudioStreamFormat(sampleRate, channels.coerceIn(1, 2), encoding, codecConfig)
        if (encoding == AUDIO_PCM_16 && audioStreamFormat?.matches(incomingFormat) == true) {
            // A video recovery makes the Mac announce audio again. Resetting
            // identical PCM here discards audible samples and requests another
            // video recovery, creating a self-sustaining reset/stutter loop.
            // PCM packet PTS still detect genuine capture gaps in writePCM.
            // AAC is excluded: a new encoder may have different priming state.
            Log.d(TAG, "Keeping audio track for repeated PCM configuration")
            return
        }
        val requiresPlaybackRecovery = clock.isStarted()
        releaseAudio()
        audioQueue.clear()
        clock.reset()
        if (encoding != AUDIO_PCM_16 && encoding != AUDIO_AAC_LC) {
            Log.w(TAG, "Unsupported audio encoding $encoding (${codecConfig.size} config bytes)")
            return
        }
        audioSampleRate = sampleRate
        audioChannels = channels.coerceIn(1, 2)
        val channelMask = if (audioChannels == 1) {
            AudioFormat.CHANNEL_OUT_MONO
        } else {
            AudioFormat.CHANNEL_OUT_STEREO
        }
        val format = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(sampleRate)
            .setChannelMask(channelMask)
            .build()
        val attributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
            .build()
        // Capacity must exceed the pre-roll target or blocking writes fill the
        // stopped track before play() can ever be reached. Reserve one second
        // for a 750 ms pre-roll; both streams still follow the same audio clock.
        val trackCapacityBytes = sampleRate * audioChannels * PCM_BYTES_PER_SAMPLE
        val minimum = AudioTrack.getMinBufferSize(
            sampleRate,
            channelMask,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        val builder = AudioTrack.Builder()
            .setAudioAttributes(attributes)
            .setAudioFormat(format)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setBufferSizeInBytes(maxOf(minimum, trackCapacityBytes))
        synchronized(audioLock) {
            audioTrack = builder.build()
            if (encoding == AUDIO_AAC_LC) {
                val codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
                val decoderFormat = MediaFormat.createAudioFormat(
                    MediaFormat.MIMETYPE_AUDIO_AAC,
                    sampleRate,
                    audioChannels,
                ).apply {
                    setInteger(MediaFormat.KEY_IS_ADTS, 0)
                    setInteger(MediaFormat.KEY_AAC_PROFILE, 2)
                    setByteBuffer("csd-0", ByteBuffer.wrap(codecConfig))
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                        setInteger(MediaFormat.KEY_PCM_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
                    }
                }
                codec.configure(decoderFormat, null, null, 0)
                codec.start()
                audioDecoder = codec
            }
        }
        audioEncoding = encoding
        audioStreamFormat = incomingFormat
        audioFramesWritten = 0
        firstAudioTimestampMilliseconds = null
        if (requiresPlaybackRecovery) {
            enterRecovery("audio_codec_changed")
        }
    }

    fun queueAudio(data: ByteArray, timestampMilliseconds: Long) {
        if (!running.get() || audioSampleRate <= 0) return
        val now = System.nanoTime()
        val arrivalGapMs = (now - lastAudioArrivalNanoseconds) / 1_000_000L
        if (lastAudioArrivalNanoseconds != 0L && arrivalGapMs > 150L) {
            Log.w(TAG, "Audio delivery gap=${arrivalGapMs}ms queued=${audioQueue.size} pts=$timestampMilliseconds")
        }
        lastAudioArrivalNanoseconds = now
        val packet = AudioPacket(data, timestampMilliseconds)
        if (!audioQueue.offerLast(packet)) {
            audioQueue.pollFirst()
            audioQueue.offerLast(packet)
            synchronized(playbackStateLock) { underruns += 1 }
            Log.w(TAG, "audio queue exceeded the low-latency window")
        }
    }

    @Synchronized
    fun reset() {
        videoQueue.clear()
        audioQueue.clear()
        synchronized(decoderLock) { releaseVideoLocked() }
        releaseAudio()
        videoConfiguration = null
        waitingForKeyFrame = true
        firstPlayableVideoTimestampMilliseconds = 0L
        scheduledVideoFrames = 0
        clock.reset()
    }

    @Synchronized
    fun release() {
        if (!running.compareAndSet(true, false)) return
        videoWorker.interrupt()
        audioWorker.interrupt()
        reportWorker.interrupt()
        reset()
        surface = null
    }

    private fun startVideoDecoder() {
        val configuration = videoConfiguration ?: return
        val targetSurface = surface ?: return
        if (!targetSurface.isValid) return
        synchronized(decoderLock) {
            releaseVideoLocked()
            val codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            val format = MediaFormat.createVideoFormat(
                MediaFormat.MIMETYPE_VIDEO_AVC,
                configuration.width,
                configuration.height,
            ).apply {
                setByteBuffer("csd-0", ByteBuffer.wrap(START_CODE + configuration.sps))
                setByteBuffer("csd-1", ByteBuffer.wrap(START_CODE + configuration.pps))
                setInteger(MediaFormat.KEY_ROTATION, configuration.rotationDegrees)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
                }
                setInteger(MediaFormat.KEY_PRIORITY, 0)
            }
            codec.configure(format, targetSurface, null, 0)
            codec.start()
            decoder = codec
        }
    }

    private fun videoLoop() {
        while (running.get()) {
            try {
                val frame = videoQueue.pollFirst(VIDEO_POLL_MILLISECONDS, TimeUnit.MILLISECONDS)
                if (frame != null && !clock.isStarted()) {
                    videoQueue.offerFirst(frame)
                    Thread.sleep(VIDEO_POLL_MILLISECONDS)
                } else if (frame != null) {
                    feedVideo(frame)
                } else {
                    drainVideo()
                }
            } catch (_: InterruptedException) {
                break
            } catch (error: Exception) {
                Log.e(TAG, "video decoder failed", error)
                enterRecovery("decoder_error")
            }
        }
    }

    private fun feedVideo(frame: VideoFrame) {
        while (running.get()) {
            val accepted = synchronized(decoderLock) {
                if (!decoderGeneration.accepts(frame.generation)) return
                val codec = decoder ?: return
                // Output buffers can hold all decoder resources while waiting
                // for the Surface. Drain them before asking for input space;
                // a blocking 10 ms input wait here throttles every frame when
                // the codec is full and eventually overflows the video queue.
                drainVideoLocked(codec)
                val inputIndex = codec.dequeueInputBuffer(0)
                if (inputIndex < 0) {
                    drainVideoLocked(codec)
                    false
                } else {
                    val input = codec.getInputBuffer(inputIndex)
                    if (input == null || frame.data.size > input.remaining()) {
                        codec.queueInputBuffer(inputIndex, 0, 0, 0, 0)
                        enterRecovery("invalid_decoder_buffer")
                        return
                    }
                    input.clear()
                    input.put(frame.data)
                    codec.queueInputBuffer(
                        inputIndex,
                        0,
                        frame.data.size,
                        frame.timestampMilliseconds * 1_000,
                        if (frame.keyFrame) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0,
                    )
                    drainVideoLocked(codec)
                    true
                }
            }
            if (accepted) return
            Thread.sleep(1)
        }
    }

    private fun drainVideo() {
        synchronized(decoderLock) { decoder?.let(::drainVideoLocked) }
    }

    private fun drainVideoLocked(codec: MediaCodec) {
        while (true) {
            pendingVideoOutput?.let { (index, timestampMilliseconds) ->
                // Recompute each attempt: a device timestamp can be corrected
                // while this frame waits. Never clamp a future deadline to now;
                // that turns buffering into exactly the video-ahead regression.
                val renderTime = clock.renderTimeNanoseconds(timestampMilliseconds)
                when (VideoPresentationPolicy.action(renderTime, System.nanoTime())) {
                    VideoPresentationPolicy.Action.HOLD -> return
                    VideoPresentationPolicy.Action.DROP -> {
                        codec.releaseOutputBuffer(index, false)
                        synchronized(playbackStateLock) { underruns += 1 }
                    }
                    VideoPresentationPolicy.Action.RENDER -> {
                        codec.releaseOutputBuffer(index, requireNotNull(renderTime))
                        lastPresentedTimestampMilliseconds = timestampMilliseconds
                        scheduledVideoFrames += 1
                        if (scheduledVideoFrames == 1L || scheduledVideoFrames % 120L == 0L) {
                            Log.d(TAG, "A/V schedule frame=$scheduledVideoFrames " +
                                "videoMs=$timestampMilliseconds audioMs=${clock.currentMediaTimestampMilliseconds()} " +
                                "leadMs=${(renderTime - System.nanoTime()) / 1_000_000L}")
                        }
                    }
                }
                pendingVideoOutput = null
            }
            val outputIndex = codec.dequeueOutputBuffer(outputInfo, 0)
            when {
                outputIndex >= 0 -> {
                    pendingVideoOutput = outputIndex to outputInfo.presentationTimeUs / 1_000
                }
                outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED ->
                    Log.d(TAG, "decoder output format=${codec.outputFormat}")
                else -> return
            }
        }
    }

    private fun audioLoop() {
        while (running.get()) {
            try {
                val packet = audioQueue.pollFirst(
                    AUDIO_POLL_MILLISECONDS,
                    TimeUnit.MILLISECONDS,
                )
                if (packet == null) {
                    if (audioEncoding == AUDIO_AAC_LC) {
                        synchronized(audioLock) { audioDecoder?.let(::drainAudioLocked) }
                    }
                    continue
                }
                val firstVideoTimestamp = firstPlayableVideoTimestampMilliseconds
                if (firstVideoTimestamp == 0L) {
                    // Do not let audio establish the master clock before a
                    // decodable video keyframe exists. Keep the packet at the
                    // front so startup remains ordered and bounded.
                    audioQueue.offerFirst(packet)
                    Thread.sleep(AUDIO_POLL_MILLISECONDS)
                    continue
                }
                if (firstAudioTimestampMilliseconds == null && packet.timestampMilliseconds <
                    firstVideoTimestamp - STARTUP_SYNC_TOLERANCE_MILLISECONDS
                ) {
                    // Screen/audio capture can begin before VideoToolbox emits
                    // its first keyframe. Playing that prefix creates a
                    // permanent A/V offset, so align both streams at the first
                    // common playable region.
                    continue
                }
                if (audioEncoding == AUDIO_AAC_LC) {
                    decodeAAC(packet)
                } else {
                    writePCM(packet.data, packet.timestampMilliseconds)
                }
            } catch (_: InterruptedException) {
                break
            } catch (error: IllegalStateException) {
                Log.w(TAG, "audio track changed while writing", error)
            }
        }
    }

    private fun decodeAAC(packet: AudioPacket) {
        while (running.get()) {
            val accepted = synchronized(audioLock) {
                val codec = audioDecoder ?: return
                val inputIndex = codec.dequeueInputBuffer(CODEC_DEQUEUE_MICROSECONDS)
                if (inputIndex < 0) {
                    drainAudioLocked(codec)
                    false
                } else {
                    val input = codec.getInputBuffer(inputIndex)
                    if (input == null || packet.data.size > input.remaining()) {
                        codec.queueInputBuffer(inputIndex, 0, 0, 0, 0)
                        Log.w(TAG, "AAC access unit did not fit the decoder input")
                        return
                    }
                    input.clear()
                    input.put(packet.data)
                    codec.queueInputBuffer(
                        inputIndex,
                        0,
                        packet.data.size,
                        packet.timestampMilliseconds * 1_000,
                        0,
                    )
                    drainAudioLocked(codec)
                    true
                }
            }
            if (accepted) return
        }
    }

    private fun drainAudioLocked(codec: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        while (true) {
            val outputIndex = codec.dequeueOutputBuffer(info, 0)
            when {
                outputIndex >= 0 -> {
                    val output = codec.getOutputBuffer(outputIndex)
                    if (output != null && info.size > 0) {
                        output.position(info.offset)
                        output.limit(info.offset + info.size)
                        val pcm = ByteArray(info.size)
                        output.get(pcm)
                        writePCM(pcm, info.presentationTimeUs / 1_000)
                    }
                    codec.releaseOutputBuffer(outputIndex, false)
                }
                outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED ->
                    Log.d(TAG, "AAC decoder output format=${codec.outputFormat}")
                else -> return
            }
        }
    }

    private fun writePCM(data: ByteArray, timestampMilliseconds: Long) = synchronized(audioLock) {
        val track = audioTrack ?: return
        val firstPts = firstAudioTimestampMilliseconds
        if (firstPts != null && PcmTimeline.isDiscontinuous(
                firstPts, audioFramesWritten, audioSampleRate, timestampMilliseconds,
            )
        ) {
            // AudioTrack counts only frames submitted, not time missing from
            // capture. After a Mac capture restart (or queue loss), appending
            // new PCM against the old origin would permanently offset sound.
            // stop + flush resets the frame counter; reacquire a clock from the
            // new packet's actual PTS and buffer audio before resuming video.
            Log.w(TAG, "Audio capture timeline gap at $timestampMilliseconds; rebuffering")
            clock.reset()
            track.pause()
            track.flush()
            track.stop()
            audioFramesWritten = 0
            firstAudioTimestampMilliseconds = null
        }
        if (firstAudioTimestampMilliseconds == null) {
            firstAudioTimestampMilliseconds = timestampMilliseconds
        }
        var offset = 0
        while (offset < data.size && running.get()) {
            val written = track.write(
                data,
                offset,
                data.size - offset,
                AudioTrack.WRITE_BLOCKING,
            )
            if (written <= 0) break
            offset += written
            audioFramesWritten += written / (audioChannels * PCM_BYTES_PER_SAMPLE)
        }
        val bufferedMilliseconds = audioFramesWritten * 1_000 / audioSampleRate
        if (track.playState != AudioTrack.PLAYSTATE_PLAYING &&
            bufferedMilliseconds >= TARGET_BUFFER_MILLISECONDS
        ) {
            track.play()
            clock.start(
                AudioTrackPositionSource(track),
                firstAudioTimestampMilliseconds ?: timestampMilliseconds,
                audioSampleRate,
            )
            Log.i(
                TAG,
                "playback clock started audio=${firstAudioTimestampMilliseconds ?: timestampMilliseconds} " +
                    "video=$firstPlayableVideoTimestampMilliseconds buffered=${bufferedMilliseconds}ms",
            )
        }
    }

    private fun enterRecovery(reason: String) {
        val requested = synchronized(decoderLock) { beginRecoveryLocked(reason) }
        if (requested) requestKeyFrame(reason)
    }

    private fun beginRecoveryLocked(reason: String): Boolean {
        synchronized(playbackStateLock) {
            // Many packets can hit a full queue before the requested keyframe
            // returns. One outstanding recovery is enough; repeated requests
            // restart both encoders and prevent either pipeline from settling.
            if (waitingForKeyFrame) return false
            waitingForKeyFrame = true
            recoveries += 1
        }
        Log.w(TAG, "Video recovery requested: $reason")
        videoQueue.clear()
        // Flush invalidates both held output and input retained across retries.
        decoderGeneration.invalidate()
        pendingVideoOutput = null
        runCatching { decoder?.flush() }
        return true
    }

    private fun requestKeyFrame(reason: String) {
        onKeyFrameNeeded(reason, lastPresentedTimestampMilliseconds)
    }

    private fun currentReport(): CinemaPlaybackReport {
        val decoderBacklog = queueDurationMilliseconds(videoQueue.map { it.timestampMilliseconds })
        val queuedVideo = clock.currentMediaTimestampMilliseconds()?.let { current ->
            (lastReceivedVideoTimestampMilliseconds - current).coerceAtLeast(0)
        } ?: decoderBacklog
        val queuedAudio = queueDurationMilliseconds(audioQueue.map { it.timestampMilliseconds })
        val trackBuffered = synchronized(audioLock) {
            val track = audioTrack
            if (track != null && audioSampleRate > 0) {
                val played = track.playbackHeadPosition.toLong() and 0xffff_ffffL
                ((audioFramesWritten - played).coerceAtLeast(0) * 1_000) / audioSampleRate
            } else 0
        }
        return CinemaPlaybackReport(
            videoBufferMilliseconds = queuedVideo,
            audioBufferMilliseconds = queuedAudio + trackBuffered,
            decoderBacklogMilliseconds = decoderBacklog,
            underruns = synchronized(playbackStateLock) { underruns } + synchronized(audioLock) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    audioTrack?.underrunCount?.toLong() ?: 0
                } else 0
            },
            recoveries = synchronized(playbackStateLock) { recoveries },
            lastPresentedTimestampMilliseconds = lastPresentedTimestampMilliseconds,
            targetBufferMilliseconds = TARGET_BUFFER_MILLISECONDS,
        )
    }

    private fun queueDurationMilliseconds(timestamps: List<Long>): Long {
        if (timestamps.size < 2) return 0
        return (timestamps.last() - timestamps.first()).coerceAtLeast(0)
    }

    private fun releaseVideoLocked() {
        decoderGeneration.invalidate()
        pendingVideoOutput = null
        decoder?.let { codec ->
            runCatching { codec.stop() }
            runCatching { codec.release() }
        }
        decoder = null
    }

    @Suppress("DEPRECATION")
    private fun releaseAudio() {
        synchronized(audioLock) {
            audioDecoder?.let { codec ->
                runCatching { codec.stop() }
                runCatching { codec.release() }
            }
            audioDecoder = null
            audioTrack?.let { track ->
                runCatching { track.pause() }
                runCatching { track.flush() }
                runCatching { track.stop() }
                runCatching { track.release() }
            }
            audioTrack = null
        }
        audioSampleRate = 0
        audioChannels = 0
        audioEncoding = 0
        audioStreamFormat = null
        audioFramesWritten = 0
        firstAudioTimestampMilliseconds = null
    }

    private class AudioTrackPositionSource(private val track: AudioTrack) : AudioPositionSource {
        override fun timestamp(): AudioPosition? {
            val measured = AudioTimestamp()
            return if (runCatching { track.getTimestamp(measured) }.getOrDefault(false)) {
                AudioPosition(measured.framePosition, measured.nanoTime)
            } else {
                null
            }
        }

        override fun playbackHeadPosition(): Long = track.playbackHeadPosition.toLong()
    }

    private data class VideoFrame(
        val data: ByteArray,
        val timestampMilliseconds: Long,
        val keyFrame: Boolean,
        val generation: Long,
    )

    private data class AudioPacket(
        val data: ByteArray,
        val timestampMilliseconds: Long,
    )

    private data class VideoConfiguration(
        val width: Int,
        val height: Int,
        val rotationDegrees: Int,
        val sps: ByteArray,
        val pps: ByteArray,
    )

    private companion object {
        const val TAG = "FireTVMedia"
        const val AUDIO_PCM_16 = 1
        const val AUDIO_AAC_LC = 2
        const val PCM_BYTES_PER_SAMPLE = 2
        // Watching video values continuity over interactive mirroring latency.
        // Give short high-motion delivery bursts more headroom than the former
        // 180 ms pre-roll; actual underruns force clock reacquisition and stalls.
        const val TARGET_BUFFER_MILLISECONDS = 750L
        const val STARTUP_SYNC_TOLERANCE_MILLISECONDS = 80L
        const val REPORT_INTERVAL_MILLISECONDS = 250L
        const val VIDEO_POLL_MILLISECONDS = 10L
        const val AUDIO_POLL_MILLISECONDS = 10L
        const val CODEC_DEQUEUE_MICROSECONDS = 10_000L
        const val MAX_VIDEO_FRAMES = 120
        const val MAX_AUDIO_PACKETS = 100
        val START_CODE = byteArrayOf(0, 0, 0, 1)
    }
}
