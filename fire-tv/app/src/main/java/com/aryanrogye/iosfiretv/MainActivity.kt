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
    private val receiverCallbackLock = Any()
    @Volatile private var receiverGeneration = 0L
    private lateinit var server: PairingServer
    private lateinit var surfaceView: SurfaceView
    private lateinit var mediaPlayer: FireTVMediaPlayer
    private lateinit var remoteMediaSession: MediaSession
    private lateinit var statusView: TextView
    private lateinit var statusDot: View
    private lateinit var macList: LinearLayout
    private var displayedMacs: List<MacServer> = emptyList()
    private lateinit var codeView: TextView
    private lateinit var instructionsView: TextView
    private lateinit var pairingPanel: LinearLayout
    private lateinit var requestProgress: ProgressBar
    private lateinit var controlsPanel: LinearLayout
    private lateinit var resetHint: TextView
    private lateinit var liveBadge: LinearLayout
    private lateinit var connectionLagBadge: LinearLayout
    private lateinit var feedbackView: TextView
    private lateinit var captionView: RollingCaptionView
    private lateinit var captionAppearance: CaptionAppearance
    private var captionEditor: CaptionAppearanceEditor? = null
    private val captionTimeline = CaptionTimeline()
    // Network input replaces this single slot, never posts one UI task per cue.
    private val incomingCaption = java.util.concurrent.atomic.AtomicReference<CaptionCue?>(null)
    private val updateCaptions = object : Runnable {
        override fun run() {
            val now = SystemClock.elapsedRealtime()
            incomingCaption.getAndSet(null)?.let { captionTimeline.offer(it, now) }
            val cue = captionTimeline.cue(mediaPlayer.captionMediaTimeMilliseconds(), now)
            captionView.present(cue)
            captionView.visibility = if (cue == null || !captionAppearance.enabled) View.INVISIBLE else View.VISIBLE
            mainHandler.postDelayed(this, 100)
        }
    }
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

    /** Old receiver instances must never update this Activity after replacement. */
    private fun createReceiver(): PairingServer {
        val generation = synchronized(receiverCallbackLock) { ++receiverGeneration }
        fun ui(action: () -> Unit) = mainHandler.post {
            if (generation == receiverGeneration && !isDestroyed) action()
        }
        fun media(action: () -> Unit) = synchronized(receiverCallbackLock) {
            if (generation == receiverGeneration) action()
        }
        return PairingServer(applicationContext, object : PairingServer.Listener {
            override fun onMacsChanged(macs: List<MacServer>) { ui { this@MainActivity.onMacsChanged(macs) } }
            override fun onPairingCode(code: String) { ui { this@MainActivity.onPairingCode(code) } }
            override fun onPairingRequest(deviceName: String?) { ui { this@MainActivity.onPairingRequest(deviceName) } }
            override fun onStatus(message: String, streaming: Boolean) { ui { this@MainActivity.onStatus(message, streaming) } }
            override fun onVideoConfiguration(width: Int, height: Int, rotationDegrees: Int, sps: ByteArray, pps: ByteArray) {
                media { this@MainActivity.onVideoConfiguration(width, height, rotationDegrees, sps, pps) }
            }
            override fun onVideoFrame(data: ByteArray, timestampMilliseconds: Long, keyFrame: Boolean) {
                media { this@MainActivity.onVideoFrame(data, timestampMilliseconds, keyFrame) }
            }
            override fun onAudioConfiguration(sampleRate: Int, channels: Int, encoding: Int, codecConfig: ByteArray) {
                media { this@MainActivity.onAudioConfiguration(sampleRate, channels, encoding, codecConfig) }
            }
            override fun onAudioFrame(data: ByteArray, timestampMilliseconds: Long) {
                media { this@MainActivity.onAudioFrame(data, timestampMilliseconds) }
            }
            override fun onCaption(id: String, revision: Long, startMs: Long, endMs: Long, text: String, final: Boolean, committedText: String?, partialText: String?) {
                media { this@MainActivity.onCaption(id, revision, startMs, endMs, text, final, committedText, partialText) }
            }
            override fun onMediaEnded() {
                media { this@MainActivity.onMediaEnded() }
            }
        })
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.decorView.keepScreenOn = true
        captionAppearance = CaptionAppearance(this)
        buildInterface()
        server = createReceiver()
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
        mainHandler.post(updateCaptions)
    }

    override fun onDestroy() {
        synchronized(receiverCallbackLock) { receiverGeneration++ }
        captionEditor?.dismiss()
        statusDotPulse?.cancel()
        mainHandler.removeCallbacks(hideFeedback)
        mainHandler.removeCallbacks(checkStreamDelivery)
        mainHandler.removeCallbacks(updateCaptions)
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

    override fun onMacsChanged(macs: List<MacServer>) = runOnUiThread {
        if (isDestroyed || macs == displayedMacs) return@runOnUiThread
        val focusedID = macList.findFocus()?.tag
        displayedMacs = macs
        macList.removeAllViews()
        if (macs.isEmpty()) {
            macList.addView(label(18f, Color.rgb(151, 165, 184)).apply { text = "Looking for Macs…" })
        }
        macs.forEach { mac ->
            val button = actionButton("Connect to ${mac.name}${if (mac.trusted) " · Paired" else ""}${if (!mac.available) " · Offline" else ""}") {
                server.connect(mac.id)
            }.apply {
                tag = mac.id
                isEnabled = mac.available
            }
            button.isAllCaps = false
            button.textSize = 18f
            button.maxLines = 2
            button.ellipsize = android.text.TextUtils.TruncateAt.END
            macList.addView(button, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                bottomMargin = dip(8)
            })
            if (focusedID == mac.id) button.requestFocus()
        }
        if (focusedID == null && !streamingActive) macList.getChildAt(0)?.requestFocus()
    }

    override fun onPairingCode(code: String) = runOnUiThread {
        codeView.text = code.chunked(3).joinToString(" ")
    }

    override fun onPairingRequest(deviceName: String?) = runOnUiThread {
        requestProgress.visibility = View.VISIBLE
        statusView.text = if (deviceName == null) {
            "Authenticating with the Mac…"
        } else {
            "Authenticating with $deviceName…"
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

    override fun onCaption(id: String, revision: Long, startMs: Long, endMs: Long, text: String, final: Boolean, committedText: String?, partialText: String?) {
        incomingCaption.set(CaptionCue(startMs, endMs, text, id, revision, final, committedText, partialText))
    }

    override fun onMediaEnded() {
        val generation = receiverGeneration
        incomingCaption.set(null)
        runOnUiThread {
            if (generation != receiverGeneration) return@runOnUiThread
            captionTimeline.clear()
            captionView.present(null)
            captionView.visibility = View.INVISIBLE
        }
        mediaPlayer.reset()
        runOnUiThread { if (generation == receiverGeneration) setRemoteControlsActive(false) }
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
        }
        val title = label(28f, Color.WHITE).apply {
            text = "Connect to your Mac"
            setTypeface(typeface, Typeface.BOLD)
        }
        instructionsView = label(16f, Color.rgb(151, 165, 184)).apply {
            text = "Choose a Mac to mirror its display and audio."
            setPadding(0, dip(6), 0, dip(12))
        }
        statusDot = View(this).apply {
            background = circle(Color.rgb(240, 180, 60))
        }
        statusView = label(16f, Color.rgb(151, 165, 184)).apply {
            text = "Looking for Macs…"
            maxLines = 2
            maxWidth = dip(700)
            ellipsize = android.text.TextUtils.TruncateAt.END
        }
        requestProgress = ProgressBar(this).apply {
            isIndeterminate = true
            visibility = View.INVISIBLE
        }
        val statusRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(statusDot, LinearLayout.LayoutParams(dip(8), dip(8)).apply {
                marginEnd = dip(10)
            })
            addView(statusView, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            addView(requestProgress, LinearLayout.LayoutParams(dip(18), dip(18)))
        }
        pairingPanel.addView(title)
        pairingPanel.addView(instructionsView)
        pairingPanel.addView(statusRow, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
            gravity = Gravity.CENTER_HORIZONTAL
        })

        val body = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
        }
        val macCard = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dip(20), dip(18), dip(20), dip(18))
            background = rounded(dipf(20), Color.rgb(17, 22, 31)).apply {
                setStroke(dip(1), Color.rgb(44, 52, 68))
            }
        }
        macCard.addView(label(16f, Color.rgb(151, 165, 184)).apply {
            text = "AVAILABLE MACS"
            setPadding(0, 0, 0, dip(12))
        })
        macList = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
        }
        val macScroll = android.widget.ScrollView(this).apply {
            isFillViewport = false
            addView(macList)
        }
        macCard.addView(macScroll, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        body.addView(macCard, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1f).apply {
            marginEnd = dip(18)
        })

        val codeCard = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dip(20), dip(18), dip(20), dip(18))
            background = rounded(dipf(20), Color.rgb(17, 22, 31)).apply {
                setStroke(dip(1), Color.rgb(44, 52, 68))
            }
        }
        codeCard.addView(label(18f, Color.WHITE).apply {
            text = "First-time pairing"
            setTypeface(typeface, Typeface.BOLD)
        })
        codeCard.addView(label(15f, Color.rgb(151, 165, 184)).apply {
            text = "Enter this code in your Mac’s pairing window, then choose Connect here."
            setPadding(0, dip(12), 0, dip(10))
        })
        codeView = label(32f, Color.rgb(110, 168, 254)).apply {
            typeface = Typeface.MONOSPACE
            letterSpacing = 0.06f
            setTypeface(typeface, Typeface.BOLD)
            isSingleLine = true
        }
        codeCard.addView(codeView)
        codeCard.addView(label(14f, Color.rgb(151, 165, 184)).apply {
            text = "Paired Macs connect without a code."
            setPadding(0, dip(10), 0, 0)
        })
        body.addView(codeCard, LinearLayout.LayoutParams(dip(260), ViewGroup.LayoutParams.MATCH_PARENT))
        pairingPanel.addView(body, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f).apply { topMargin = dip(18) })
        root.addView(pairingPanel, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT).apply {
            setMargins(dip(36), dip(28), dip(36), dip(100))
        })

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
        val hideButton = actionButton("Hide") {
            setControlsVisible(visible = false)
            showFeedback("Controls hidden  ·  Press BACK to show")
        }
        controlsPanel.addView(hideButton)
        controlsPanel.addView(actionButton("Captions") { showCaptionEditor() })
        controlsPanel.addView(actionButton("Disconnect") { server.disconnect() })
        val moreButton = actionButton("More") {}
        moreButton.setOnClickListener {
            android.widget.PopupMenu(this, moreButton).apply {
                menu.add("Reset session").setOnMenuItemClickListener {
                    server.reset()
                    true
                }
                menu.add("Restart receiver").setOnMenuItemClickListener {
                    restartReceiver()
                    true
                }
                show()
            }
        }
        controlsPanel.addView(moreButton)
        for (index in 0 until controlsPanel.childCount) {
            (controlsPanel.getChildAt(index) as? Button)?.apply {
                textSize = 15f
                setPadding(dip(20), dip(12), dip(20), dip(12))
                isSingleLine = true
            }
        }
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

        captionView = RollingCaptionView(this)
        root.addView(captionView, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL,
        ).apply {
            bottomMargin = dip(48)
            leftMargin = dip(64)
            rightMargin = dip(64)
        })
        captionView.applyAppearance(captionAppearance)
        setContentView(root)
        startStatusDotPulse()
        hideButton.post { hideButton.requestFocus() }
    }

    private fun showCaptionEditor() {
        if (captionEditor?.isShowing == true) return
        val editor = CaptionAppearanceEditor(this, captionAppearance) {
            captionView.applyAppearance(captionAppearance)
            captionView.visibility = if (captionAppearance.enabled && captionView.hasText) View.VISIBLE else View.INVISIBLE
        }
        captionEditor = editor
        editor.setOnDismissListener {
            captionEditor = null
            controlsPanel.getChildAt(1)?.requestFocus()
        }
        editor.show()
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
        synchronized(receiverCallbackLock) { receiverGeneration++ }
        statusView.text = "Restarting receiver…"
        requestProgress.visibility = View.VISIBLE
        mediaPlayer.reset()
        setRemoteControlsActive(false)
        server.stop()
        setControlsVisible(visible = false)
        mainHandler.postDelayed({
            if (isFinishing || isDestroyed) return@postDelayed
            displayedMacs = emptyList()
            server = createReceiver()
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
