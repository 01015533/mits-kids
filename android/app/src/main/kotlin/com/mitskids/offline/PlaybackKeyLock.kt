package com.mitskids.offline

/** Input protection for a focused player; never system/device authority. */
class PlaybackKeyLock {
    private var resumed = false
    private var focused = false
    private var requested = false

    fun resume() { resumed = true }
    fun pause() { resumed = false; requested = false }
    fun focusChanged(value: Boolean) {
        focused = value
        if (!value) requested = false
    }
    fun detach() { resumed = false; focused = false; requested = false }

    /** Returns acknowledgement, including true for a successful unlock. */
    fun setTouchLocked(value: Boolean): Boolean {
        requested = value && resumed && focused
        return !value || requested
    }

    fun consumes(keyCode: Int, action: Int, hasModifiers: Boolean): Boolean =
        requested && resumed && focused && !hasModifiers && action in 0..1 &&
            keyCode in VOLUME_KEYS

    companion object {
        // Android KeyEvent: VOLUME_UP, VOLUME_DOWN, VOLUME_MUTE.
        // KEYCODE_MUTE (91) controls microphone mute and is deliberately excluded.
        private val VOLUME_KEYS = setOf(24, 25, 164)
    }
}
