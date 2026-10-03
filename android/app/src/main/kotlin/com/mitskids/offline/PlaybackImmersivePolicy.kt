package com.mitskids.offline

/** Decides when a player may change its own window presentation, not system input. */
class PlaybackImmersivePolicy {
    enum class Action { NONE, APPLY, RESTORE }

    var requested = false
        private set
    var applied = false
        private set
    private var resumed = false
    private var focused = false
    private var left = true
    private var closed = false
    private var needsApply = false

    fun setLocked(locked: Boolean): Action {
        if (closed) return restoreIfNeeded()
        if (locked && !requested) needsApply = true
        requested = locked
        return if (locked) applyIfEligible() else restoreIfNeeded()
    }

    fun onResume(): Action {
        if (closed) return restoreIfNeeded()
        if (!resumed) needsApply = true
        resumed = true
        left = false
        return applyIfEligible()
    }

    fun onPause(): Action {
        resumed = false
        focused = false
        return Action.NONE
    }

    fun onFocusChanged(value: Boolean): Action {
        focused = value
        // Merely revealing/dismissing transient system UI must not hide it again.
        return if (value) applyIfEligible() else Action.NONE
    }

    fun onUserLeaveHint(): Action = leave()
    fun onStop(): Action = leave()

    fun close(): Action {
        closed = true
        requested = false
        return leave()
    }

    /** A failed partial window update still requires restoration. */
    fun didApply(success: Boolean, hasSnapshot: Boolean) {
        applied = hasSnapshot
        needsApply = !success
    }

    fun didRestore(success: Boolean) {
        if (success) {
            applied = false
            needsApply = requested
        }
    }

    private fun leave(): Action {
        resumed = false
        focused = false
        left = true
        needsApply = requested
        return restoreIfNeeded()
    }

    private fun applyIfEligible(): Action =
        if (!closed && requested && resumed && focused && !left && (!applied || needsApply)) {
            Action.APPLY
        } else {
            Action.NONE
        }

    private fun restoreIfNeeded(): Action = if (applied) Action.RESTORE else Action.NONE

    companion object {
        /** Restore only the flags this helper changed, preserving unrelated updates. */
        fun restoreLegacyFlags(current: Int, previous: Int, changedMask: Int): Int =
            (current and changedMask.inv()) or (previous and changedMask)
    }
}
