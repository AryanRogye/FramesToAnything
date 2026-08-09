package com.aryanrogye.iosfiretv

import android.app.Activity
import android.graphics.Color
import android.graphics.SurfaceTexture
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.KeyEvent
import android.view.Surface
import android.view.TextureView
import android.view.ViewGroup
import android.view.View
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView

class MainActivity : Activity(), PairingServer.Listener {
    private lateinit var server: PairingServer
    private lateinit var textureView: TextureView
    private lateinit var mediaPlayer: FireTVMediaPlayer
    private lateinit var statusView: TextView
    private lateinit var codeView: TextView
    private lateinit var instructionsView: TextView
    private lateinit var pairingPanel: LinearLayout
    private lateinit var requestProgress: ProgressBar
    private lateinit var controlsPanel: LinearLayout
    private lateinit var resetHint: TextView
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.decorView.keepScreenOn = true
        buildInterface()
        mediaPlayer = FireTVMediaPlayer()
        textureView.surfaceTextureListener = object : TextureView.SurfaceTextureListener {
            override fun onSurfaceTextureAvailable(
                surfaceTexture: SurfaceTexture,
                width: Int,
                height: Int,
            ) {
                mediaPlayer.setSurface(Surface(surfaceTexture))
            }

            override fun onSurfaceTextureSizeChanged(
                surfaceTexture: SurfaceTexture,
                width: Int,
                height: Int,
            ) = Unit

            override fun onSurfaceTextureDestroyed(surfaceTexture: SurfaceTexture): Boolean {
                mediaPlayer.setSurface(null)
                return true
            }

            override fun onSurfaceTextureUpdated(surfaceTexture: SurfaceTexture) = Unit
        }
        if (textureView.isAvailable) {
            textureView.surfaceTexture?.let { mediaPlayer.setSurface(Surface(it)) }
        }

        server = PairingServer(applicationContext, this)
        server.start()
    }

    override fun onDestroy() {
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

    override fun onAudioConfiguration(sampleRate: Int, channels: Int) {
        mediaPlayer.configureAudio(sampleRate, channels)
    }

    override fun onAudioFrame(pcm: ByteArray) {
        mediaPlayer.queueAudio(pcm)
    }

    override fun onMediaEnded() {
        mediaPlayer.reset()
    }

    private fun buildInterface() {
        val root = FrameLayout(this).apply {
            setBackgroundColor(Color.rgb(8, 11, 16))
        }

        textureView = TextureView(this).apply { isOpaque = true }
        root.addView(
            textureView,
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
            text = "Open Frames to Fire TV on your iPhone or Mac,\nselect this TV, and enter the code."
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
}
