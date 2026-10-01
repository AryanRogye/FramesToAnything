package com.aryanrogye.iosfiretv

import android.app.Dialog
import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.StateListDrawable
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.view.Window
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

/** Receiver-owned appearance preferences; read only by the UI thread. */
internal class CaptionAppearance(context: Context) {
    private val preferences = context.getSharedPreferences("caption_appearance", Context.MODE_PRIVATE)
    var enabled = preferences.getBoolean("enabled", true)
    var size = preferences.getInt("size", 2).coerceIn(SIZES.indices)
    var color = preferences.getInt("color", 0).coerceIn(COLORS.indices)
    var background = preferences.getInt("background", 2).coerceIn(BACKGROUNDS.indices)
    var position = preferences.getInt("position", 0).coerceIn(POSITIONS.indices)

    fun save() {
        preferences.edit().putBoolean("enabled", enabled).putInt("size", size)
            .putInt("color", color).putInt("background", background)
            .putInt("position", position).apply()
    }

    fun reset() {
        enabled = true; size = 2; color = 0; background = 2; position = 0
        save()
    }

    fun applyText(view: TextView) {
        val density = view.resources.displayMetrics.density
        view.textSize = SIZES[size]
        view.setTextColor(COLORS[color])
        view.setShadowLayer(3f, 0f, 2f, Color.BLACK)
        view.background = GradientDrawable().apply {
            cornerRadius = 8 * density
            setColor(Color.argb(BACKGROUNDS[background], 0, 0, 0))
        }
    }

    fun applyPosition(view: TextView) {
        val density = view.resources.displayMetrics.density
        (view.layoutParams as? FrameLayout.LayoutParams)?.let { params ->
            params.gravity = Gravity.CENTER_HORIZONTAL or when (position) {
                1 -> Gravity.CENTER_VERTICAL
                2 -> Gravity.TOP
                else -> Gravity.BOTTOM
            }
            params.topMargin = (48 * density).toInt()
            params.bottomMargin = (48 * density).toInt()
            view.layoutParams = params
        }
    }

    companion object {
        val SIZES = listOf(14f, 16f, 18f, 20f, 24f, 28f)
        val COLORS = listOf(Color.WHITE, Color.rgb(255, 224, 102), Color.rgb(125, 239, 162), Color.rgb(135, 218, 255))
        val COLOR_NAMES = listOf("White", "Yellow", "Green", "Blue")
        val BACKGROUNDS = listOf(0, 100, 200, 255)
        val BACKGROUND_NAMES = listOf("None", "Soft", "Dark", "Solid")
        val POSITIONS = listOf("Bottom", "Center", "Top")
    }
}

/** A remote-friendly dialog over playback. Changes apply immediately and persist. */
internal class CaptionAppearanceEditor(
    context: Context,
    private val appearance: CaptionAppearance,
    private val onChanged: () -> Unit,
) : Dialog(context) {
    private val rows = mutableListOf<Pair<Button, () -> String>>()
    private lateinit var preview: TextView
    private val density = context.resources.displayMetrics.density
    private fun dp(value: Int) = (value * density).toInt()

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        requestWindowFeature(Window.FEATURE_NO_TITLE)
        val panel = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(24), dp(16), dp(24), dp(16))
            background = rounded(Color.rgb(17, 22, 31))
        }
        panel.addView(TextView(context).apply {
            text = "Captions"
            textSize = 25f
            setTextColor(Color.WHITE)
            setTypeface(typeface, Typeface.BOLD)
        })
        panel.addView(TextView(context).apply {
            text = "Use ← → to adjust · Select to cycle"
            textSize = 14f
            setTextColor(Color.rgb(151, 165, 184))
            setPadding(0, dp(6), 0, dp(12))
        })
        preview = TextView(context).apply {
            text = "This is how your captions will look."
            gravity = Gravity.CENTER
            setPadding(dp(12), dp(8), dp(12), dp(8))
            maxLines = 3
        }
        panel.addView(preview, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, dp(64),
        ).apply { bottomMargin = dp(12) })
        addRow(panel, { "Captions: ${if (appearance.enabled) "On" else "Off"}" }) {
            appearance.enabled = !appearance.enabled
        }
        addRow(panel, { "Size: ${CaptionAppearance.SIZES[appearance.size].toInt()}" }) {
            appearance.size = cycle(appearance.size, it, CaptionAppearance.SIZES.size)
        }
        addRow(panel, { "Text color: ${CaptionAppearance.COLOR_NAMES[appearance.color]}" }) {
            appearance.color = cycle(appearance.color, it, CaptionAppearance.COLORS.size)
        }
        addRow(panel, { "Background: ${CaptionAppearance.BACKGROUND_NAMES[appearance.background]}" }) {
            appearance.background = cycle(appearance.background, it, CaptionAppearance.BACKGROUNDS.size)
        }
        addRow(panel, { "Position: ${CaptionAppearance.POSITIONS[appearance.position]}" }) {
            appearance.position = cycle(appearance.position, it, CaptionAppearance.POSITIONS.size)
        }
        val footer = LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL }
        footer.addView(button("Reset").apply {
            setOnClickListener { appearance.reset(); refresh(); onChanged() }
        }, LinearLayout.LayoutParams(0, dp(46), 1f))
        footer.addView(button("Done").apply { setOnClickListener { dismiss() } },
            LinearLayout.LayoutParams(0, dp(46), 1f).apply { leftMargin = dp(8) })
        panel.addView(footer, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
        ).apply { topMargin = dp(10) })
        setContentView(ScrollView(context).apply { addView(panel); isFillViewport = true })
        window?.apply {
            setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
            addFlags(android.view.WindowManager.LayoutParams.FLAG_DIM_BEHIND)
            setDimAmount(0.35f)
            setGravity(Gravity.END or Gravity.CENTER_VERTICAL)
            val screen = context.resources.displayMetrics
            setLayout(minOf(dp(400), (screen.widthPixels * 0.9).toInt()), (screen.heightPixels * 0.9).toInt())
            attributes = attributes.apply { horizontalMargin = 0.025f }
        }
        setOnKeyListener { _, key, event ->
            if (key == KeyEvent.KEYCODE_MENU) {
                if (event.action == KeyEvent.ACTION_UP) dismiss()
                true
            } else false
        }
        refresh()
        rows.first().first.requestFocus()
    }

    private fun addRow(panel: LinearLayout, title: () -> String, change: (Int) -> Unit) {
        val row = button(title()).apply {
            gravity = Gravity.CENTER_VERTICAL or Gravity.START
            fun adjust(direction: Int) { change(direction); appearance.save(); refresh(); onChanged() }
            setOnClickListener { adjust(1) }
            setOnKeyListener { _, key, event ->
                if (key == KeyEvent.KEYCODE_DPAD_LEFT || key == KeyEvent.KEYCODE_DPAD_RIGHT) {
                    if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
                        adjust(if (key == KeyEvent.KEYCODE_DPAD_LEFT) -1 else 1)
                    }
                    true
                } else false
            }
        }
        rows.add(row to title)
        panel.addView(row, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(42))
            .apply { bottomMargin = dp(4) })
    }

    private fun refresh() {
        rows.forEach { (button, title) -> button.text = title() }
        appearance.applyText(preview)
        preview.alpha = if (appearance.enabled) 1f else 0.4f
    }

    private fun cycle(index: Int, direction: Int, count: Int) = (index + direction + count) % count
    private fun rounded(color: Int) = GradientDrawable().apply { cornerRadius = dp(12).toFloat(); setColor(color) }
    private fun button(title: String) = Button(context).apply {
        text = title
        isAllCaps = false
        textSize = 16f
        isFocusable = true
        minHeight = 0
        minWidth = 0
        setPadding(dp(16), 0, dp(16), 0)
        stateListAnimator = null
        background = StateListDrawable().apply {
            addState(intArrayOf(android.R.attr.state_focused), rounded(Color.rgb(110, 168, 254)))
            addState(intArrayOf(), rounded(Color.rgb(30, 36, 48)))
        }
        setTextColor(Color.rgb(196, 206, 220))
        setOnFocusChangeListener { _, focused ->
            setTextColor(if (focused) Color.rgb(10, 14, 20) else Color.rgb(196, 206, 220))
        }
    }
}
