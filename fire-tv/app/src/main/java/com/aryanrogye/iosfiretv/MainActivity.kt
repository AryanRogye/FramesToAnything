package com.aryanrogye.iosfiretv

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Gravity
import android.view.KeyEvent
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.ViewGroup
import android.view.View
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView

class MainActivity : Activity(), PairingServer.Listener {
    private lateinit var server: PairingServer
    private lateinit var surfaceView: SurfaceView
    private lateinit var mediaPlayer: FireTVMediaPlayer
    private lateinit var remoteMediaSession: MediaSession
    private lateinit var statusView: TextView
    private lateinit var codeView: TextView
    private lateinit var instructionsView: TextView
    private lateinit var pairingPanel: LinearLayout
    private lateinit var requestProgress: ProgressBar
    private lateinit var controlsPanel: LinearLayout
    private lateinit var resetHint: TextView
    private val mainHandler = Handler(Looper.getMainLooper())
    private var remoteControlsActive = false
    private var remotePlaybackIsPlaying = true
    private var lastRemoteCommandTime = 0L

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.decorView.keepScreenOn = true
        buildInterface()
        server = PairingServer(applicationContext, this)
        configureRemoteMediaSession()
        mediaPlayer = FireTVMediaPlayer(
            onReport = server::sendReceiverReport,
            onKeyFrameNeeded = server::requestKeyFrame,
        )
        surfaceView.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                mediaPlayer.setSurface(holder.surface)
            }

            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) = Unit

            override fun surfaceDestroyed(holder: SurfaceHolder) {
                mediaPlayer.setSurface(null)
            }
        })
        server.start()
    }

    override fun onDestroy() {
        remoteMediaSession.isActive = false
        remoteMediaSession.release()
        server.stop()
        mediaPlayer.release()
        super.onDestroy()
    }

    override fun onKeyUp(keyCode: Int, event: KeyEvent?): Boolean {
        if (keyCode == KeyEvent.KEYCODE_MENU) {
            mediaPlayer.reset()
            server.reset()
            showControls()
            return true
        }
        if (keyCode == KeyEvent.KEYCODE_BACK && controlsPanel.visibility != View.VISIBLE) {
            showControls()
            return true
        }
        return super.onKeyUp(keyCode, event)
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (remoteControlsActive && event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0 &&
            event.keyCode in REMOTE_MEDIA_KEY_CODES
        ) {
            sendPlayPauseToMac()
            return true
        }
        return super.dispatchKeyEvent(event)
    }

    override fun onPairingCode(code: String) = runOnUiThread {
        codeView.text = code.chunked(3).joinToString(" ")
    }

    override fun onPairingRequest(deviceName: String?) = runOnUiThread {
        requestProgress.visibility = View.VISIBLE
        statusView.text = if (deviceName == null) {
            "Someone is requesting to join…"
        } else {
            "$deviceName is requesting to join…"
        }
    }

    override fun onStatus(message: String, streaming: Boolean) = runOnUiThread {
        statusView.text = message
        requestProgress.visibility = if (message.startsWith("Authenticating")) {
            View.VISIBLE
        } else {
            View.GONE
        }
        pairingPanel.visibility = if (streaming) LinearLayout.GONE else LinearLayout.VISIBLE
        setRemoteControlsActive(streaming)
    }

    override fun onVideoConfiguration(
        width: Int,
        height: Int,
        rotationDegrees: Int,
        sps: ByteArray,
        pps: ByteArray,
    ) {
        mediaPlayer.configureVideo(width, height, rotationDegrees, sps, pps)
    }

    override fun onVideoFrame(data: ByteArray, timestampMilliseconds: Long, keyFrame: Boolean) {
        mediaPlayer.queueVideo(data, timestampMilliseconds, keyFrame)
    }

    override fun onAudioConfiguration(
        sampleRate: Int,
        channels: Int,
        encoding: Int,
        codecConfig: ByteArray,
    ) {
        mediaPlayer.configureAudio(sampleRate, channels, encoding, codecConfig)
    }

    override fun onAudioFrame(data: ByteArray, timestampMilliseconds: Long) {
        mediaPlayer.queueAudio(data, timestampMilliseconds)
    }

    override fun onMediaEnded() {
        mediaPlayer.reset()
        runOnUiThread { setRemoteControlsActive(false) }
    }

    private fun buildInterface() {
        val root = FrameLayout(this).apply {
            setBackgroundColor(Color.rgb(8, 11, 16))
        }

        surfaceView = SurfaceView(this)
        root.addView(
            surfaceView,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )

        pairingPanel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(64, 48, 64, 48)
            setBackgroundColor(Color.rgb(8, 11, 16))
        }

        statusView = label(28f, Color.rgb(151, 165, 184)).apply {
            text = "Starting receiver…"
        }
        requestProgress = ProgressBar(this).apply {
            isIndeterminate = true
            visibility = View.GONE
        }
        codeView = label(64f, Color.WHITE).apply {
            letterSpacing = 0.12f
            setPadding(0, 22, 0, 22)
        }
        instructionsView = label(22f, Color.rgb(151, 165, 184)).apply {
            text = "Select this receiver on your iPhone or Mac.\nEnter the code the first time; this device will be remembered."
            gravity = Gravity.CENTER
        }

        pairingPanel.addView(statusView)
        pairingPanel.addView(
            requestProgress,
            LinearLayout.LayoutParams(48, 48).apply {
                gravity = Gravity.CENTER_HORIZONTAL
                setMargins(0, 18, 0, 0)
            },
        )
        pairingPanel.addView(codeView)
        pairingPanel.addView(instructionsView)
        root.addView(
            pairingPanel,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.CENTER,
            ),
        )

        resetHint = label(18f, Color.rgb(151, 165, 184)).apply {
            text = "☰  Menu  ·  Reset session and show controls"
            setPadding(24, 14, 24, 14)
            setBackgroundColor(Color.argb(180, 24, 29, 38))
        }
        root.addView(
            resetHint,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.END or Gravity.TOP,
            ).apply {
                setMargins(36, 36, 36, 36)
            },
        )

        controlsPanel = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(18, 14, 18, 14)
            setBackgroundColor(Color.argb(235, 24, 29, 38))
        }
        val hideButton = actionButton("Hide controls") {
            controlsPanel.visibility = View.GONE
            resetHint.visibility = View.GONE
        }
        val resetButton = actionButton("Reset session") {
            mediaPlayer.reset()
            server.reset()
        }
        val restartButton = actionButton("Restart receiver") { restartReceiver() }
        controlsPanel.addView(hideButton)
        controlsPanel.addView(resetButton)
        controlsPanel.addView(restartButton)
        root.addView(
            controlsPanel,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.CENTER_HORIZONTAL or Gravity.BOTTOM,
            ).apply {
                setMargins(36, 36, 36, 36)
            },
        )

        setContentView(root)
        hideButton.post { hideButton.requestFocus() }
    }

    private fun actionButton(title: String, action: () -> Unit) = Button(this).apply {
        text = title
        isFocusable = true
        setOnClickListener { action() }
        setOnFocusChangeListener { _, focused ->
            alpha = if (focused) 1f else 0.72f
            scaleX = if (focused) 1.06f else 1f
            scaleY = if (focused) 1.06f else 1f
        }
        setPadding(24, 12, 24, 12)
    }

    private fun showControls() {
        controlsPanel.visibility = View.VISIBLE
        resetHint.visibility = View.VISIBLE
        controlsPanel.getChildAt(0)?.requestFocus()
    }

    /** Restarts networking and media without killing the Android process. */
    private fun restartReceiver() {
        statusView.text = "Restarting receiver…"
        requestProgress.visibility = View.VISIBLE
        mediaPlayer.reset()
        setRemoteControlsActive(false)
        server.stop()
        controlsPanel.visibility = View.GONE
        mainHandler.postDelayed({
            if (isFinishing || isDestroyed) return@postDelayed
            server = PairingServer(applicationContext, this)
            server.start()
        }, 400)
    }

    private fun label(size: Float, color: Int) = TextView(this).apply {
        textSize = size
        setTextColor(color)
        gravity = Gravity.CENTER
    }

    private fun configureRemoteMediaSession() {
        remoteMediaSession = MediaSession(this, "FramesFireTVRemote").apply {
            setCallback(
                object : MediaSession.Callback() {
                    override fun onPlay() = sendPlayPauseToMac()
                    override fun onPause() = sendPlayPauseToMac()

                    @Suppress("DEPRECATION")
                    override fun onMediaButtonEvent(mediaButtonIntent: Intent): Boolean {
                        val event = mediaButtonIntent.getParcelableExtra<KeyEvent>(
                            Intent.EXTRA_KEY_EVENT
                        ) ?: return false
                        if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0 &&
                            event.keyCode in REMOTE_MEDIA_KEY_CODES
                        ) {
                            sendPlayPauseToMac()
                            return true
                        }
                        return super.onMediaButtonEvent(mediaButtonIntent)
                    }
                },
                mainHandler,
            )
        }
        updateRemotePlaybackState(playing = true)
    }

    private fun setRemoteControlsActive(active: Boolean) {
        remoteControlsActive = active
        if (active) {
            remotePlaybackIsPlaying = true
            updateRemotePlaybackState(playing = true)
        }
        remoteMediaSession.isActive = active
    }

    private fun sendPlayPauseToMac() {
        if (!remoteControlsActive) return
        val now = SystemClock.elapsedRealtime()
        if (now - lastRemoteCommandTime < REMOTE_COMMAND_DEBOUNCE_MILLISECONDS) return
        lastRemoteCommandTime = now
        server.sendRemoteMediaCommand(REMOTE_COMMAND_TOGGLE_PLAY_PAUSE)
        updateRemotePlaybackState(playing = !remotePlaybackIsPlaying)
    }

    private fun updateRemotePlaybackState(playing: Boolean) {
        remotePlaybackIsPlaying = playing
        remoteMediaSession.setPlaybackState(
            PlaybackState.Builder()
                .setActions(
                    PlaybackState.ACTION_PLAY or
                        PlaybackState.ACTION_PAUSE or
                        PlaybackState.ACTION_PLAY_PAUSE
                )
                .setState(
                    if (playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                    PlaybackState.PLAYBACK_POSITION_UNKNOWN,
                    if (playing) 1f else 0f,
                )
                .build()
        )
    }

    private companion object {
        const val REMOTE_COMMAND_TOGGLE_PLAY_PAUSE = "toggle_play_pause"
        const val REMOTE_COMMAND_DEBOUNCE_MILLISECONDS = 250L
        val REMOTE_MEDIA_KEY_CODES = setOf(
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
            KeyEvent.KEYCODE_MEDIA_PLAY,
            KeyEvent.KEYCODE_MEDIA_PAUSE,
            KeyEvent.KEYCODE_HEADSETHOOK,
        )
    }
}
