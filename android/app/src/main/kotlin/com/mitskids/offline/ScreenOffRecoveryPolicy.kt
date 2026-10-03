package com.mitskids.offline

/** A short, single-use opportunity to recover an accidental screen-off transition. */
class ScreenOffRecoveryPolicy {
    data class Notice(val method: String, val session: Long, val cycle: Long)
    private data class Attempt(
        val session: Long,
        val cycle: Long,
        val expiresAt: Long,
        var screenOnObserved: Boolean = false,
    )

    private var resumed = false
    private var focused = false
    private var stopped = true
    private var newestSession = 0L
    private var graceUntil: Long? = null
    private var attempt: Attempt? = null
    private var unavailable: Notice? = null
    private var handoffUntil: Long? = null
    private val failures = ArrayDeque<Long>()
    private var screenIsOff = false
    var currentCycle = 0L
        private set

    /** Exact player allowed above keyguard, independent of a consumed attempt. */
    var visibilitySession: Long? = null
        private set

    val observing: Boolean get() = visibilitySession != null
    val attempting: Boolean get() = attempt != null
    val foreground: Boolean get() = resumed && focused && !stopped
    val nextDeadline: Long? get() = listOfNotNull(attempt?.expiresAt, graceUntil, handoffUntil).minOrNull()

    fun staleCycle(session: Long, cycle: Long): Boolean =
        session == newestSession && cycle >= 0 && cycle < currentCycle

    fun setEligible(eligible: Boolean, session: Long, now: Long, interactive: Boolean,
                    cycle: Long = 0): Boolean {
        expire(now)
        if (session <= 0 || session < newestSession) return false
        if (session > newestSession) {
            clear()
            newestSession = session
            currentCycle = 0
        }
        if (!eligible) {
            clear()
            return true
        }
        if (cycle < 0 || cycle > currentCycle) return false
        // A prior cycle's async completion cannot cancel or extend the latest
        // cycle. Its ACK is deliberately benign so Dart need not revoke it.
        if (cycle < currentCycle) return true
        if (visibilitySession == session) {
            // An in-flight wake stays bounded regardless of Dart arming races.
            if (attempt != null) return true
            if (resumed && !focused && !stopped && interactive) {
                // A matching ACK confirms the same player is playing again,
                // even if the shade opened while Dart completed Play. Finish
                // that handoff without granting any new lock-screen owner.
                handoffUntil = null
                return true
            }
            // Re-arming while actually paused/noninteractive must not extend
            // the screen-off ordering grace or an unanswered handoff deadline.
            if ((!foreground || !interactive) && (graceUntil != null || handoffUntil != null)) return true
        }
        if (!resumed || !focused || stopped || !interactive) return false
        visibilitySession = session
        handoffUntil = null
        graceUntil = null
        unavailable = null
        return true
    }

    fun resume() {
        resumed = true
        stopped = false
    }

    fun pause(now: Long) {
        startGrace(now)
        resumed = false
    }

    fun focusChanged(value: Boolean, now: Long, interactive: Boolean = true) {
        // The notification shade and other system windows can take focus while
        // this Activity stays resumed. Keep its existing player lease; lack of
        // focus never authorizes a new lease. Screen-off ordering still has a
        // short grace when focus is lost after the display becomes noninteractive.
        if (!value && !interactive) startGrace(now)
        focused = value
    }

    fun stop(now: Long, interactive: Boolean) {
        expire(now)
        resumed = false
        focused = false
        stopped = true
        // SCREEN_OFF and Activity callbacks are not ordered together. Retain
        // only an existing, bounded candidate while the display is already off.
        if (attempt == null && (interactive || graceUntil == null)) clear()
    }

    fun userLeave() {
        clear()
        // onUserLeaveHint can precede onPause. Reject a queued Dart arming
        // call in that gap until Android reports a new foreground return.
        resumed = false
        focused = false
        stopped = true
    }

    fun detach() {
        clear()
        resumed = false
        focused = false
        stopped = true
    }

    /** Returns the one session permitted to attempt a wake for this broadcast. */
    fun screenOff(now: Long, interactive: Boolean): Long? {
        expire(now)
        val session = visibilitySession ?: return null
        if (interactive || screenIsOff) return null
        if ((!resumed || stopped) && graceUntil == null && attempt == null && handoffUntil == null) return null
        while (failures.isNotEmpty() && now - failures.first() >= RATE_WINDOW_MS) {
            failures.removeFirst()
        }
        currentCycle++
        if (failures.size >= MAX_FAILURES) {
            clear()
            unavailable = Notice("unavailable", session, currentCycle)
            return null
        }
        // Real rapid OFF/ON cycles may supersede a pending completion, but may
        // never extend its first unanswered deadline or an existing handoff.
        val deadline = minOf(now + ATTEMPT_MS, attempt?.expiresAt ?: Long.MAX_VALUE)
        screenIsOff = true
        attempt = Attempt(session, currentCycle, deadline)
        graceUntil = null
        return session
    }

    fun screenOn(now: Long, interactive: Boolean) {
        expire(now)
        if (!interactive || !screenIsOff) return
        screenIsOff = false
        attempt?.screenOnObserved = true
    }

    fun wakeFailed(session: Long, now: Long, cycle: Long = currentCycle) {
        if (attempt?.session != session || attempt?.cycle != cycle) return
        failures.addLast(now)
        clear()
        unavailable = Notice("unavailable", session, cycle)
    }

    /** Success requires an actual attempt, a live session and a focused return. */
    fun poll(now: Long, interactive: Boolean): Notice? {
        expire(now)
        if (!resumed || !focused || stopped || !interactive) return null
        attempt?.let {
            if (!it.screenOnObserved || screenIsOff) return null
            // Keep this player's window above keyguard while Dart resumes it.
            // A fresh same-session eligibility ACK must complete the handoff.
            attempt = null
            graceUntil = null
            handoffUntil = minOf(handoffUntil ?: Long.MAX_VALUE, now + HANDOFF_MS)
            return Notice("recovered", it.session, it.cycle)
        }
        unavailable?.let {
            unavailable = null
            return it
        }
        return null
    }

    private fun startGrace(now: Long) {
        expire(now)
        if (visibilitySession != null && attempt == null && graceUntil == null &&
            resumed && !stopped) {
            graceUntil = now + ORDERING_GRACE_MS
        }
    }

    private fun expire(now: Long) {
        attempt?.let {
            if (now >= it.expiresAt) {
                failures.addLast(it.expiresAt)
                clear()
                unavailable = Notice("unavailable", it.session, it.cycle)
            }
        }
        graceUntil?.let { if (now >= it) clear() }
        handoffUntil?.let {
            if (now >= it) {
                val session = visibilitySession
                failures.addLast(it)
                clear()
                unavailable = session?.let { Notice("unavailable", it, currentCycle) }
            }
        }
    }

    private fun clear() {
        graceUntil = null
        attempt = null
        unavailable = null
        visibilitySession = null
        handoffUntil = null
        screenIsOff = false
    }

    companion object {
        const val ORDERING_GRACE_MS = 1_000L
        const val ATTEMPT_MS = 3_000L
        const val HANDOFF_MS = 3_000L
        const val RATE_WINDOW_MS = 60_000L
        const val MAX_FAILURES = 3
    }
}
