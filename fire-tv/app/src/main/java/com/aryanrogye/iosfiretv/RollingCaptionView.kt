package com.aryanrogye.iosfiretv

import android.content.Context
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.TextView
import kotlin.math.ceil

/** Fixed-width, fixed-baseline two-row overlay. Text updates never resize it. */
internal class RollingCaptionView(context: Context) : LinearLayout(context) {
    private val presentation = CaptionPresentationState()
    private val committed = row()
    private val partial = row().apply { alpha = 0.8f }
    private var lines = CaptionLines()
    val hasText: Boolean get() = lines.committed.isNotEmpty() || lines.partial.isNotEmpty()

    init {
        orientation = VERTICAL
        val density = resources.displayMetrics.density
        setPadding((16 * density).toInt(), (8 * density).toInt(), (16 * density).toInt(), (8 * density).toInt())
        addView(committed, LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0))
        addView(partial, LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0))
        // Keep captions above elevated playback controls.
        elevation = 16 * density
        visibility = View.INVISIBLE
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    fun present(cue: CaptionCue?) {
        val next = presentation.present(cue)
        // Only the changed row gets new text/layout. No animations or deferred partials.
        if (next.committed != lines.committed) committed.text = next.committed
        if (next.partial != lines.partial) partial.text = next.partial
        if (next != lines) android.util.Log.i("FramesCaptions", "rows committed=${next.committed} partial=${next.partial}")
        if (next != lines) {
            // Surface playback does not invalidate the app window. Explicitly
            // damage the overlay when text changes, even with chrome hidden.
            postInvalidateOnAnimation()
            (parent as? View)?.postInvalidateOnAnimation()
        }
        lines = next
    }

    fun applyAppearance(appearance: CaptionAppearance) {
        appearance.applyText(committed, includeBackground = false)
        appearance.applyText(partial, includeBackground = false)
        val metrics = committed.paint.fontMetrics
        val height = ceil(metrics.bottom - metrics.top + 4 * resources.displayMetrics.density).toInt()
        for (row in listOf(committed, partial)) {
            row.layoutParams = LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, height)
        }
        background = GradientDrawable().apply {
            cornerRadius = 8 * resources.displayMetrics.density
            setColor(Color.argb(CaptionAppearance.BACKGROUNDS[appearance.background], 0, 0, 0))
        }
        appearance.applyPosition(this)
    }

    private fun row() = TextView(context).apply {
        setSingleLine(true)
        // Show the recent end of a long rolling phrase without wrapping other rows.
        ellipsize = TextUtils.TruncateAt.START
        gravity = Gravity.START or Gravity.CENTER_VERTICAL
        includeFontPadding = false
        setPadding(0, 0, 0, 0)
        isFocusable = false
    }
}
