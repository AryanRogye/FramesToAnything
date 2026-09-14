package com.aryanrogye.iosfiretv

import android.animation.ValueAnimator
import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.StateListDrawable
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
    private lateinit var statusDot: View
    private lateinit var codeView: TextView
    private lateinit var instructionsView: TextView
    private lateinit var pairingPanel: LinearLayout
    private lateinit var requestProgress: ProgressBar
    private lateinit var controlsPanel: LinearLayout
    private lateinit var resetHint: TextView
    private lateinit var liveBadge: LinearLayout
    private lateinit var connectionLagBadge: LinearLayout
    private lateinit var feedbackView: TextView
    private val mainHandler = Handler(Looper.getMainLooper())
    private var remoteControlsActive = false
    private var remotePlaybackIsPlaying = true
    private var lastRemoteCommandTime = 0L
    private var pairingPanelVisible = true
    private var streamingActive = false
    private var statusDotPulse: ValueAnimator? = null
    @Volatile private var lastVideoArrivalTime = 0L
    private var connectionLagVisible = false
    private val checkStreamDelivery = object : Runnable {
        override fun run() {
            updateConnectionLagIndicator()
            mainHandler.postDelayed(this, STREAM_HEALTH_POLL_MILLISECONDS)
        }
    }
    private val hideFeedback = Runnable {
        feedbackView.animate().alpha(0f).setDuration(260).withEndAction {
            feedbackView.visibility = View.GONE
        }.start()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.decorView.keepScreenOn = true
        buildInterface()
        server = PairingServer(applicationContext, this)
        configureRemoteMediaSession()
        mediaPlayer = FireTVMediaPlayer(
            // Resolve the current server when each callback fires. The receiver
            // can replace its PairingServer from the in-app restart control.
            onReport = { report -> server.sendReceiverReport(report) },
            onKeyFrameNeeded = { reason, timestamp ->
                server.requestKeyFrame(reason, timestamp)
            },
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
        mainHandler.post(checkStreamDelivery)
    }

    override fun onDestroy() {
        statusDotPulse?.cancel()
        mainHandler.removeCallbacks(hideFeedback)
        mainHandler.removeCallbacks(checkStreamDelivery)
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
            View.INVISIBLE
        }
        setStreamingLook(streaming)
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
        lastVideoArrivalTime = SystemClock.elapsedRealtime()
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

        liveBadge = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dip(18), dip(8), dip(18), dip(8))
            background = rounded(dipf(24), Color.argb(190, 30, 13, 20)).apply {
                setStroke(dip(1), Color.argb(120, 255, 92, 110))
            }
            addView(
                View(this@MainActivity).apply {
                    background = circle(Color.rgb(255, 92, 110))
                },
                LinearLayout.LayoutParams(dip(12), dip(12)).apply {
                    setMargins(0, 0, dip(9), 0)
                },
            )
            addView(
                label(15f, Color.rgb(255, 132, 146)).apply {
                    text = "LIVE"
                    letterSpacing = 0.18f
                    setTypeface(typeface, Typeface.BOLD)
                },
            )
            alpha = 0f
            visibility = View.GONE
        }
        root.addView(
            liveBadge,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.START or Gravity.TOP,
            ).apply {
                setMargins(dip(36), dip(36), dip(36), dip(36))
            },
        )

        connectionLagBadge = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dip(18), dip(10), dip(18), dip(10))
            background = rounded(dipf(24), Color.argb(220, 43, 31, 9)).apply {
                setStroke(dip(1), Color.argb(190, 255, 190, 72))
            }
            addView(
                ProgressBar(this@MainActivity).apply { isIndeterminate = true },
                LinearLayout.LayoutParams(dip(22), dip(22)).apply {
                    setMargins(0, 0, dip(10), 0)
                },
            )
            addView(
                label(17f, Color.rgb(255, 213, 118)).apply {
                    text = "Connection is slow"
                    setTypeface(typeface, Typeface.BOLD)
                },
            )
            alpha = 0f
            visibility = View.GONE
        }
        root.addView(
            connectionLagBadge,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.END or Gravity.TOP,
            ).apply {
                setMargins(dip(36), dip(36), dip(36), dip(36))
            },
        )

        pairingPanel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(dip(32), dip(24), dip(32), dip(24))
        }

        val title = label(26f, Color.WHITE).apply {
            text = "iOS Screen Receiver"
            letterSpacing = 0.04f
            setTypeface(typeface, Typeface.BOLD)
        }
        statusDot = View(this).apply {
            background = circle(Color.rgb(240, 180, 60))
        }
        statusView = label(24f, Color.rgb(151, 165, 184)).apply {
            text = "Starting receiver…"
        }
        val statusRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(
                statusDot,
                LinearLayout.LayoutParams(dip(12), dip(12)).apply {
                    setMargins(0, 0, dip(12), 0)
                },
            )
            addView(statusView)
        }
        requestProgress = ProgressBar(this).apply {
            isIndeterminate = true
            // Keep the status block's height stable while authentication starts.
            // A GONE spinner made the pairing content jump down when it appeared.
            visibility = View.INVISIBLE
        }
        codeView = label(72f, Color.WHITE).apply {
            typeface = Typeface.MONOSPACE
            setTypeface(typeface, Typeface.BOLD)
            letterSpacing = 0.14f
            setPadding(0, dip(14), 0, dip(10))
        }
        val codeCard = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(dip(56), dip(26), dip(56), dip(22))
            background = rounded(dipf(28), Color.rgb(17, 22, 31)).apply {
                setStroke(dip(1), Color.rgb(44, 52, 68))
            }
            addView(
                label(14f, Color.rgb(110, 168, 254)).apply {
                    text = "PAIRING CODE"
                    letterSpacing = 0.3f
                    setTypeface(typeface, Typeface.BOLD)
                },
            )
            addView(codeView)
        }
        instructionsView = label(20f, Color.rgb(151, 165, 184)).apply {
            text = "Select this receiver on your iPhone or Mac.\nEnter the code the first time; this device will be remembered."
            gravity = Gravity.CENTER
            setLineSpacing(dip(4).toFloat(), 1f)
        }

        pairingPanel.addView(
            title,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply {
                setMargins(0, 0, 0, dip(14))
            },
        )
        pairingPanel.addView(statusRow)
        pairingPanel.addView(
            requestProgress,
            LinearLayout.LayoutParams(dip(40), dip(40)).apply {
                gravity = Gravity.CENTER_HORIZONTAL
                setMargins(0, dip(16), 0, 0)
            },
        )
        pairingPanel.addView(
            codeCard,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply {
                gravity = Gravity.CENTER_HORIZONTAL
                setMargins(0, dip(22), 0, dip(22))
            },
        )
        pairingPanel.addView(instructionsView)
        root.addView(
            pairingPanel,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.CENTER,
            ).apply {
                // Reserve the lower band for the remote controls. Without this,
                // the instructions sit underneath the tray on a 1080p TV.
                bottomMargin = dip(40)
            },
        )

        resetHint = label(16f, Color.rgb(151, 165, 184)).apply {
            text = "☰  Menu  ·  Reset session and show controls"
            setPadding(dip(22), dip(12), dip(22), dip(12))
            background = rounded(dipf(26), Color.argb(180, 17, 22, 31)).apply {
                setStroke(dip(1), Color.argb(90, 58, 68, 88))
            }
            alpha = 0f
            visibility = View.GONE
        }
        root.addView(
            resetHint,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.END or Gravity.TOP,
            ).apply {
                setMargins(dip(36), dip(36), dip(36), dip(36))
            },
        )

        controlsPanel = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(dip(14), dip(12), dip(14), dip(12))
            background = rounded(dipf(999), Color.argb(235, 17, 22, 31)).apply {
                setStroke(dip(1), Color.argb(110, 58, 68, 88))
            }
        }
        val hideButton = actionButton("Hide controls") {
            setControlsVisible(visible = false)
            showFeedback("Controls hidden  ·  Press BACK to show")
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
                // Keep the tray clear of the pairing copy while preserving a
                // comfortable edge inset for the TV safe area.
                setMargins(dip(36), dip(16), dip(36), dip(16))
            },
        )

        feedbackView = label(22f, Color.WHITE).apply {
            setPadding(dip(34), dip(18), dip(34), dip(18))
            background = rounded(dipf(30), Color.argb(226, 17, 22, 31)).apply {
                setStroke(dip(1), Color.argb(120, 58, 68, 88))
            }
            alpha = 0f
            visibility = View.GONE
        }
        root.addView(
            feedbackView,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.CENTER,
            ),
        )

        setContentView(root)
        startStatusDotPulse()
        hideButton.post { hideButton.requestFocus() }
    }

    private fun actionButton(title: String, action: () -> Unit) = Button(this).apply {
        text = title
        isFocusable = true
        minWidth = 0
        minHeight = 0
        stateListAnimator = null
        textSize = 17f
        letterSpacing = 0.02f
        setTextColor(Color.rgb(196, 206, 220))
        background = pillSelector()
        setOnClickListener { action() }
        setOnFocusChangeListener { button, focused ->
            (button as Button).setTextColor(
                if (focused) Color.rgb(10, 14, 20) else Color.rgb(196, 206, 220),
            )
            // Focus color already provides a strong TV affordance. Growing the
            // button made the three-button tray collide at its seams.
            animate().scaleX(1f).scaleY(1f).setDuration(100).start()
        }
        setPadding(dip(34), dip(15), dip(34), dip(15))
    }

    /** Rounded pill that fills with the accent color while focused. */
    private fun pillSelector() = StateListDrawable().apply {
        addState(
            intArrayOf(android.R.attr.state_focused),
            rounded(dipf(999), Color.rgb(110, 168, 254)),
        )
        addState(
            intArrayOf(),
            rounded(dipf(999), Color.argb(255, 30, 36, 48)).apply {
                setStroke(dip(1), Color.argb(140, 58, 68, 88))
            },
        )
    }

    private fun rounded(cornerRadius: Float, color: Int) = GradientDrawable().apply {
        shape = GradientDrawable.RECTANGLE
        this.cornerRadius = cornerRadius
        setColor(color)
    }

    private fun circle(color: Int) = GradientDrawable().apply {
        shape = GradientDrawable.OVAL
        setColor(color)
    }

    private fun showControls() {
        setControlsVisible(visible = true)
        controlsPanel.getChildAt(0)?.requestFocus()
    }

    /** Keeps every piece of playback chrome in one visibility state. */
    private fun setControlsVisible(visible: Boolean) {
        fadeView(controlsPanel, visible = visible)
        // A hidden tray means a clean video surface. BACK/MENU still restores
        // it, so an always-on hamburger hint is unnecessary during playback.
        fadeView(resetHint, visible = false)
        fadeView(liveBadge, visible = visible && streamingActive)
    }

    /** Restarts networking and media without killing the Android process. */
    private fun restartReceiver() {
        statusView.text = "Restarting receiver…"
        requestProgress.visibility = View.VISIBLE
        mediaPlayer.reset()
        setRemoteControlsActive(false)
        server.stop()
        setControlsVisible(visible = false)
        mainHandler.postDelayed({
            if (isFinishing || isDestroyed) return@postDelayed
            server = PairingServer(applicationContext, this)
            server.start()
        }, 400)
    }

    private fun setStreamingLook(streaming: Boolean) {
        streamingActive = streaming
        if (!streaming) {
            lastVideoArrivalTime = 0L
            setConnectionLagVisible(false)
        }
        if (streaming) {
            statusDotPulse?.cancel()
            statusDot.alpha = 1f
            statusDot.background = circle(Color.rgb(76, 217, 100))
            fadeView(liveBadge, visible = controlsPanel.visibility == View.VISIBLE)
        } else {
            statusDot.background = circle(Color.rgb(240, 180, 60))
            startStatusDotPulse()
            fadeView(liveBadge, visible = false)
        }
        if (pairingPanelVisible == !streaming) return
        pairingPanelVisible = !streaming
        fadeView(pairingPanel, visible = !streaming)
    }

    /// Shows the warning only when video delivery itself stops. If packets keep
    /// arriving while the picture stalls, the decoder—not the connection—is implicated.
    private fun updateConnectionLagIndicator() {
        val lagging = StreamDeliveryHealth.isLagging(
            streaming = streamingActive,
            paused = !remotePlaybackIsPlaying,
            lastVideoArrivalMilliseconds = lastVideoArrivalTime,
            nowMilliseconds = SystemClock.elapsedRealtime(),
        )
        setConnectionLagVisible(lagging)
    }

    private fun setConnectionLagVisible(visible: Boolean) {
        if (connectionLagVisible == visible) return
        connectionLagVisible = visible
        fadeView(connectionLagBadge, visible)
    }

    private fun startStatusDotPulse() {
        statusDotPulse?.cancel()
        statusDotPulse = ValueAnimator.ofFloat(1f, 0.3f).apply {
            duration = 850
            repeatMode = ValueAnimator.REVERSE
            repeatCount = ValueAnimator.INFINITE
            addUpdateListener { statusDot.alpha = it.animatedValue as Float }
            start()
        }
    }

    /** Briefly shows a centered note, e.g. play/pause state changes. */
    private fun showFeedback(text: String) {
        feedbackView.text = text
        feedbackView.animate().cancel()
        mainHandler.removeCallbacks(hideFeedback)
        feedbackView.alpha = 0f
        feedbackView.visibility = View.VISIBLE
        feedbackView.animate().alpha(1f).setDuration(140).start()
        mainHandler.postDelayed(hideFeedback, 1_100)
    }

    private fun fadeView(view: View, visible: Boolean) {
        view.animate().cancel()
        if (visible) {
            view.visibility = View.VISIBLE
            view.animate().alpha(1f).setDuration(190).start()
        } else {
            view.animate()
                .alpha(0f)
                .setDuration(190)
                .withEndAction { view.visibility = View.GONE }
                .start()
        }
    }

    private fun dip(value: Int): Int = (value * resources.displayMetrics.density).toInt()
    private fun dipf(value: Int): Float = value * resources.displayMetrics.density

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
        showFeedback(if (remotePlaybackIsPlaying) "▶  Playing" else "‖  Paused")
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
        const val STREAM_HEALTH_POLL_MILLISECONDS = 250L
        val REMOTE_MEDIA_KEY_CODES = setOf(
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
            KeyEvent.KEYCODE_MEDIA_PLAY,
            KeyEvent.KEYCODE_MEDIA_PAUSE,
            KeyEvent.KEYCODE_HEADSETHOOK,
        )
    }
}
