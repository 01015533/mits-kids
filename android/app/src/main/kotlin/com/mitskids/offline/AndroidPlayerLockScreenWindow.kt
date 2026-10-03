package com.mitskids.offline

import android.app.Activity
import android.app.KeyguardManager
import android.graphics.Color
import android.os.Build
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.TextView

/** An ordinary view in this Activity; never a system overlay or keyguard dismissal. */
class AndroidPlayerLockScreenWindow(private val activity: Activity) : PlayerLockScreenWindow {
    private val decor: ViewGroup? get() = activity.window.decorView as? ViewGroup
    private val guard: FlutterGuard? get() = decor?.findViewWithTag(GUARD_TAG)
    override val guardPresent: Boolean get() = guard != null

    override fun keyguardLocked(): Boolean? = try {
        activity.getSystemService(KeyguardManager::class.java)?.isKeyguardLocked
    } catch (_: RuntimeException) { null }

    override fun showGuard(): Boolean = try {
        val root = decor
        if (root == null || activity.isDestroyed) false else {
            val cover = guard ?: FlutterGuard(activity).also {
                root.addView(it, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT))
            }
            cover.hideFlutter()
            cover.bringToFront()
            cover.requestFocus()
            true
        }
    } catch (_: RuntimeException) { false }

    @Suppress("DEPRECATION")
    override fun setShowWhenLocked(enabled: Boolean): Boolean = try {
        if (Build.VERSION.SDK_INT >= 27) activity.setShowWhenLocked(enabled)
        // API26 requires the window flag. Always clear it on revocation too,
        // including after a prior engine/controller on the same Activity.
        if (enabled && Build.VERSION.SDK_INT == 26) {
            activity.window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED)
        } else if (!enabled) {
            activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED)
        }
        true
    } catch (_: RuntimeException) { false }

    override fun removeGuard(): Boolean = try {
        guard?.let {
            it.restoreFlutter()
            (it.parent as? ViewGroup)?.removeView(it)
        }
        true
    } catch (_: RuntimeException) { false }

    private class FlutterGuard(private val activity: Activity) : FrameLayout(activity) {
        private var hiddenContent: ViewGroup? = null
        private var previousVisibility = View.VISIBLE
        private var previousAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_AUTO
        private var previousFocusability = ViewGroup.FOCUS_BEFORE_DESCENDANTS

        init {
            tag = GUARD_TAG
            setBackgroundColor(Color.BLACK)
            isClickable = true
            isFocusable = true
            isFocusableInTouchMode = true
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
            contentDescription = "Unlock Android to continue"
            addView(TextView(activity).apply {
                text = "Unlock Android to continue"
                setTextColor(Color.WHITE)
                textSize = 18f
                gravity = Gravity.CENTER
                val padding = (24 * resources.displayMetrics.density).toInt()
                setPadding(padding, padding, padding, padding)
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            }, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT, Gravity.CENTER))
        }

        fun hideFlutter() {
            val content = activity.findViewById<ViewGroup>(android.R.id.content)
                ?: throw IllegalStateException("The Flutter content root is unavailable")
            if (hiddenContent !== content) {
                check(hiddenContent == null)
                hiddenContent = content
                previousVisibility = content.visibility
                previousAccessibility = content.importantForAccessibility
                previousFocusability = content.descendantFocusability
            }
            content.clearFocus()
            content.descendantFocusability = ViewGroup.FOCUS_BLOCK_DESCENDANTS
            content.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
            // Also hide the Flutter SurfaceView, not only its surrounding pixels.
            content.visibility = View.INVISIBLE
        }

        fun restoreFlutter() {
            hiddenContent?.let {
                it.visibility = previousVisibility
                it.importantForAccessibility = previousAccessibility
                it.descendantFocusability = previousFocusability
            }
            hiddenContent = null
        }
    }

    companion object { private const val GUARD_TAG = "mits.private.lock_screen_guard" }
}
