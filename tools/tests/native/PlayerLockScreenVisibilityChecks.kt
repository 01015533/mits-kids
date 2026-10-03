package com.mitskids.offline

private class FakePlayerLockScreenWindow : PlayerLockScreenWindow {
    override var guardPresent = false
    var locked: Boolean? = false
    var showing = false
    var failGuard = false
    var failFlag = false
    var failRemove = false
    val calls = mutableListOf<String>()
    override fun keyguardLocked() = locked
    override fun showGuard(): Boolean {
        calls.add("guard")
        if (failGuard) return false
        guardPresent = true
        return true
    }
    override fun setShowWhenLocked(enabled: Boolean): Boolean {
        calls.add("flag:$enabled")
        if (failFlag) return false
        showing = enabled
        return true
    }
    override fun removeGuard(): Boolean {
        calls.add("reveal")
        if (failRemove) return false
        guardPresent = false
        return true
    }
}

fun main() {
    var checks = 0
    fun verify(value: Boolean) { check(value) { "Lock-screen visibility check ${checks + 1} failed" }; checks++ }

    val window = FakePlayerLockScreenWindow()
    val visibility = PlayerLockScreenVisibility(window)
    verify(visibility.apply(1, true))
    verify(visibility.ownerSession == 1L && window.showing && !window.guardPresent)
    verify(window.calls.indexOf("guard") < window.calls.indexOf("flag:false"))
    window.locked = true
    window.calls.clear()
    verify(visibility.apply(1, false)) // Screen-off ordering preserves this owner.
    verify(visibility.apply(1, true)) // Recovered handoff never hides its video.
    verify(window.calls.isEmpty() && window.showing)

    // Revocation while keyguard is locked is acknowledged only after the
    // opaque guard is installed and show-when-locked has been disabled.
    verify(visibility.apply(null, true))
    verify(window.calls == listOf("guard", "flag:false"))
    verify(!window.showing && visibility.guarding && visibility.ownerSession == null)
    verify(visibility.apply(null, true) && window.guardPresent)
    window.locked = null
    verify(visibility.apply(null, true) && window.guardPresent)
    window.locked = false
    verify(visibility.apply(null, false) && window.guardPresent)
    verify(visibility.apply(null, true) && !window.guardPresent)
    verify(window.calls.last() == "reveal")

    // A new route cannot inherit the prior owner's flag over a locked device.
    verify(visibility.apply(2, true))
    window.locked = true
    window.calls.clear()
    verify(!visibility.apply(3, true))
    verify(window.calls == listOf("guard", "flag:false"))
    verify(visibility.ownerSession == null && window.guardPresent && !window.showing)
    verify(!visibility.apply(3, true))
    verify(!visibility.apply(2, true)) // Prior owner is not resurrected either.
    window.locked = false
    verify(!visibility.apply(3, false))
    verify(visibility.apply(3, true) && window.showing && !window.guardPresent)

    // An unknown keyguard state never authorizes new lock-screen visibility.
    val unknown = FakePlayerLockScreenWindow().also { it.locked = null }
    val unknownVisibility = PlayerLockScreenVisibility(unknown)
    verify(!unknownVisibility.apply(4, true))
    verify(unknown.guardPresent && !unknown.showing)
    verify(unknownVisibility.apply(null, false) && unknown.guardPresent)

    // Guard failure cannot yield an optimistic false-eligibility ACK, even
    // if flag removal itself succeeded; a retry must install the guard.
    val brokenGuard = FakePlayerLockScreenWindow()
    val guardedVisibility = PlayerLockScreenVisibility(brokenGuard)
    verify(guardedVisibility.apply(1, true))
    brokenGuard.locked = true
    brokenGuard.failGuard = true
    verify(!guardedVisibility.apply(null, true))
    verify(!brokenGuard.showing && !brokenGuard.guardPresent)
    verify(!guardedVisibility.apply(null, true))
    brokenGuard.failGuard = false
    verify(guardedVisibility.apply(null, true) && brokenGuard.guardPresent)

    // Flag removal failure leaves the guard in place and returns failure.
    // Repeated cancellation/close is safe and cannot reveal Flutter early.
    val brokenFlag = FakePlayerLockScreenWindow()
    val flagVisibility = PlayerLockScreenVisibility(brokenFlag)
    verify(flagVisibility.apply(1, true))
    brokenFlag.locked = true
    brokenFlag.failFlag = true
    verify(!flagVisibility.apply(null, false))
    verify(brokenFlag.guardPresent && brokenFlag.showing)
    verify(!flagVisibility.apply(null, true) && brokenFlag.guardPresent)
    brokenFlag.failFlag = false
    verify(flagVisibility.apply(null, false))
    verify(!brokenFlag.showing && brokenFlag.guardPresent)
    verify(flagVisibility.apply(null, false) && brokenFlag.guardPresent)
    brokenFlag.locked = false
    brokenFlag.failRemove = true
    verify(flagVisibility.apply(null, true) && brokenFlag.guardPresent)
    brokenFlag.failRemove = false
    verify(flagVisibility.apply(null, true) && !brokenFlag.guardPresent)

    // A previously guarded Activity/engine is restored only after confirmed
    // unlock and a real focused foreground return, not merely construction.
    val inherited = FakePlayerLockScreenWindow().also {
        it.locked = true; it.guardPresent = true; it.showing = true
    }
    val newEngine = PlayerLockScreenVisibility(inherited)
    verify(newEngine.apply(null, false))
    verify(inherited.guardPresent && !inherited.showing)
    inherited.locked = false
    verify(newEngine.apply(null, false) && inherited.guardPresent)
    verify(newEngine.apply(null, true) && !inherited.guardPresent)

    println("Player lock-screen visibility checks passed: $checks")
}
