package com.mitskids.offline

/** Window operations are isolated so revocation order is verified on the JVM. */
interface PlayerLockScreenWindow {
    val guardPresent: Boolean
    fun keyguardLocked(): Boolean?
    fun showGuard(): Boolean
    fun setShowWhenLocked(enabled: Boolean): Boolean
    fun removeGuard(): Boolean
}

/** Only the same already-authorized player may remain visible above keyguard. */
class PlayerLockScreenVisibility(private val window: PlayerLockScreenWindow) {
    var ownerSession: Long? = null
        private set
    private var windowStateKnown = false
    private var revocationNeedsGuard = false
    val guarding: Boolean get() = window.guardPresent

    fun apply(session: Long?, foregroundReady: Boolean): Boolean {
        if (session == ownerSession && windowStateKnown) {
            if (session == null) {
                if (revocationNeedsGuard && window.keyguardLocked() != false && !window.showGuard()) {
                    return false
                }
                revealIfUnlocked(foregroundReady)
            }
            return true
        }
        // A new player cannot inherit an older player's lock-screen window.
        if (!revoke(foregroundReady)) return false
        if (session == null) return true
        if (session <= 0 || !foregroundReady || window.keyguardLocked() != false) return false
        if (window.guardPresent && !window.removeGuard()) return false
        if (!window.setShowWhenLocked(true)) {
            windowStateKnown = false
            revoke(foregroundReady)
            return false
        }
        ownerSession = session
        windowStateKnown = true
        return true
    }

    private fun revoke(foregroundReady: Boolean): Boolean {
        // Hide both Flutter pixels and semantics before the asynchronous window
        // manager transition can expose another Dart route above keyguard.
        val needsGuard = ownerSession != null || !windowStateKnown ||
            window.guardPresent || window.keyguardLocked() != false
        revocationNeedsGuard = revocationNeedsGuard || needsGuard
        val guarded = !needsGuard || window.showGuard()
        val cleared = window.setShowWhenLocked(false)
        ownerSession = null
        windowStateKnown = cleared
        if (!guarded || !cleared) return false
        revealIfUnlocked(foregroundReady)
        return true
    }

    private fun revealIfUnlocked(foregroundReady: Boolean) {
        if (foregroundReady && window.keyguardLocked() == false) {
            if (!window.guardPresent || window.removeGuard()) revocationNeedsGuard = false
        }
    }
}
