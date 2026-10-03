package com.mitskids.offline

import android.os.Build
import android.view.View
import android.view.Window
import android.view.WindowInsets
import android.view.WindowInsetsController

/**
 * Scoped immersive presentation for a touch-locked player. Android edge gestures
 * and the notification panel remain available; this grants no device authority.
 * Call on the activity's main thread, alongside its ordinary lifecycle callbacks.
 */
class PlaybackImmersiveController(private val window: Window) {
    private val policy = PlaybackImmersivePolicy()
    private var snapshot: Snapshot? = null

    private data class Snapshot(
        val legacyFlags: Int = 0,
        val behavior: Int = 0,
        val statusVisible: Boolean = true,
        val navigationVisible: Boolean = true,
    )

    /** Acknowledges a presentation request, never suppression of Android gestures. */
    fun setLocked(locked: Boolean): Boolean {
        val success = perform(policy.setLocked(locked))
        return success && if (locked) policy.requested && policy.applied else !policy.applied
    }

    fun onResume() { perform(policy.onResume()) }
    fun onPause() { perform(policy.onPause()) }
    fun onFocusChanged(focused: Boolean) { perform(policy.onFocusChanged(focused)) }
    fun onUserLeaveHint() { perform(policy.onUserLeaveHint()) }
    fun onStop() { perform(policy.onStop()) }
    fun close() { perform(policy.close()) }

    private fun perform(action: PlaybackImmersivePolicy.Action): Boolean = when (action) {
        PlaybackImmersivePolicy.Action.NONE -> true
        PlaybackImmersivePolicy.Action.APPLY -> applyPresentation().also {
            policy.didApply(it, snapshot != null)
        }
        PlaybackImmersivePolicy.Action.RESTORE -> restorePresentation().also {
            policy.didRestore(it)
        }
    }

    @Suppress("DEPRECATION")
    private fun applyPresentation(): Boolean = try {
        if (Build.VERSION.SDK_INT >= 30) {
            val controller = window.insetsController
            val insets = window.decorView.rootWindowInsets
            if (controller == null || insets == null) {
                false
            } else {
                if (snapshot == null) {
                    snapshot = Snapshot(
                        behavior = controller.systemBarsBehavior,
                        statusVisible = insets.isVisible(WindowInsets.Type.statusBars()),
                        navigationVisible = insets.isVisible(WindowInsets.Type.navigationBars()),
                    )
                }
                controller.systemBarsBehavior =
                    WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                controller.hide(WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars())
                true
            }
        } else {
            val decor = window.decorView
            if (snapshot == null) snapshot = Snapshot(legacyFlags = decor.systemUiVisibility)
            decor.systemUiVisibility = decor.systemUiVisibility or LEGACY_CHANGED_MASK
            true
        }
    } catch (_: RuntimeException) {
        // Keep a captured snapshot even after partial application so exit can restore it.
        false
    }

    @Suppress("DEPRECATION")
    private fun restorePresentation(): Boolean {
        val previous = snapshot ?: return true
        return try {
            if (Build.VERSION.SDK_INT >= 30) {
                val controller = window.insetsController ?: return false
                controller.systemBarsBehavior = previous.behavior
                if (previous.statusVisible) controller.show(WindowInsets.Type.statusBars())
                else controller.hide(WindowInsets.Type.statusBars())
                if (previous.navigationVisible) controller.show(WindowInsets.Type.navigationBars())
                else controller.hide(WindowInsets.Type.navigationBars())
            } else {
                val decor = window.decorView
                decor.systemUiVisibility = PlaybackImmersivePolicy.restoreLegacyFlags(
                    decor.systemUiVisibility, previous.legacyFlags, LEGACY_CHANGED_MASK,
                )
            }
            snapshot = null
            true
        } catch (_: RuntimeException) {
            // A later explicit unlock/stop/close can retry an interrupted restoration.
            false
        }
    }

    companion object {
        @Suppress("DEPRECATION")
        private val LEGACY_CHANGED_MASK = View.SYSTEM_UI_FLAG_FULLSCREEN or
            View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
    }
}
