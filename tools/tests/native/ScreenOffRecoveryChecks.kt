package com.mitskids.offline

private class CycleLockScreenWindow : PlayerLockScreenWindow {
    override var guardPresent = false
    var locked = false
    var showing = false
    var revocations = 0
    override fun keyguardLocked(): Boolean = locked
    override fun showGuard(): Boolean { guardPresent = true; return true }
    override fun setShowWhenLocked(enabled: Boolean): Boolean {
        showing = enabled
        if (!enabled) revocations++
        return true
    }
    override fun removeGuard(): Boolean { guardPresent = false; return true }
}

fun main() {
    var checks = 0
    fun verify(value: Boolean) { check(value) { "Screen recovery check ${checks + 1} failed" }; checks++ }
    fun ready(session: Long = 1): ScreenOffRecoveryPolicy = ScreenOffRecoveryPolicy().also {
        it.resume()
        it.focusChanged(true, 0)
        verify(it.setEligible(true, session, 0, true))
        verify(it.observing && it.currentCycle == 0L)
    }
    fun foreground(policy: ScreenOffRecoveryPolicy, now: Long) {
        policy.resume()
        policy.focusChanged(true, now)
    }
    fun completed(policy: ScreenOffRecoveryPolicy, now: Long, cycle: Long) {
        policy.screenOn(now, true)
        verify(policy.poll(now, true) == ScreenOffRecoveryPolicy.Notice("recovered", 1, cycle))
    }

    val off = ScreenOffRecoveryPolicy()
    verify(!off.observing && !off.attempting && off.visibilitySession == null)
    verify(!off.setEligible(true, 1, 0, true))
    off.resume()
    verify(!off.setEligible(true, 1, 0, true))
    off.focusChanged(true, 0)
    verify(!off.setEligible(true, 0, 0, true))
    verify(!off.setEligible(true, 1, 0, false))
    verify(!off.setEligible(true, 1, 0, true, -1))
    verify(!off.setEligible(true, 1, 0, true, 1))
    verify(off.screenOff(0, false) == null && off.poll(0, true) == null)

    // Already-occluding activities need no pause/resume callbacks. Require an
    // actual OFF followed by interactive ON, then current foreground/focus.
    val stable = ready()
    verify(stable.screenOff(100, true) == null)
    verify(stable.screenOff(100, false) == 1L && stable.currentCycle == 1L)
    verify(stable.observing && stable.attempting && stable.nextDeadline == 3_100L)
    verify(stable.poll(101, true) == null)
    stable.screenOn(102, false)
    verify(stable.poll(102, true) == null)
    completed(stable, 110, 1)
    verify(stable.poll(111, true) == null && !stable.attempting && stable.observing)
    verify(stable.visibilitySession == 1L && stable.nextDeadline == 3_110L)
    verify(stable.setEligible(true, 1, 120, true, 1))
    verify(stable.nextDeadline == null && stable.observing)

    // More than five fast successes, then a 10-second-spaced success: no
    // successful-cycle quota/cooldown and no Android credential unlock.
    for (cycle in 2L..7L) {
        val time = cycle * 400
        verify(stable.screenOff(time, false) == 1L && stable.currentCycle == cycle)
        completed(stable, time + 20, cycle)
        verify(stable.setEligible(true, 1, time + 30, true, cycle))
        verify(stable.visibilitySession == 1L && stable.nextDeadline == null)
    }
    verify(stable.screenOff(13_000, false) == 1L)
    completed(stable, 13_020, 8)
    verify(stable.setEligible(true, 1, 13_030, true, 8))

    // Coupled regression: Android remains locked after first setup. Every
    // cycle retains the exact existing window owner until explicit revocation.
    val coupled = ready()
    val window = CycleLockScreenWindow()
    val visibility = PlayerLockScreenVisibility(window)
    verify(visibility.apply(coupled.visibilitySession, true))
    window.locked = true
    val initialRevocations = window.revocations
    for (cycle in 1L..5L) {
        val time = cycle * 500
        verify(coupled.screenOff(time, false) == 1L)
        verify(visibility.apply(coupled.visibilitySession, false))
        verify(window.showing && !window.guardPresent && visibility.ownerSession == 1L)
        completed(coupled, time + 30, cycle)
        verify(visibility.apply(coupled.visibilitySession, true))
        verify(coupled.setEligible(true, 1, time + 40, true, cycle))
        verify(visibility.apply(coupled.visibilitySession, true))
        verify(window.revocations == initialRevocations && window.locked)
    }
    verify(coupled.setEligible(false, 1, 3_000, true, 0))
    verify(visibility.apply(coupled.visibilitySession, true))
    verify(!window.showing && window.guardPresent && window.locked)

    // Duplicate broadcasts cannot retry or extend a cycle.
    val duplicates = ready()
    verify(duplicates.screenOff(100, false) == 1L)
    verify(duplicates.screenOff(101, false) == null)
    verify(duplicates.screenOff(2_000, false) == null)
    verify(duplicates.currentCycle == 1L && duplicates.nextDeadline == 3_100L)
    completed(duplicates, 2_100, 1)
    duplicates.screenOn(2_200, true)
    verify(duplicates.poll(2_200, true) == null && duplicates.nextDeadline == 5_100L)

    // OFF during Dart handoff is observed. Stale true cannot end or extend
    // the newer cycle's lease. Preserve the first unanswered deadline.
    val handoff = ready()
    verify(handoff.screenOff(100, false) == 1L)
    completed(handoff, 200, 1)
    verify(handoff.nextDeadline == 3_200L && handoff.observing)
    verify(handoff.screenOff(500, false) == 1L && handoff.currentCycle == 2L)
    verify(handoff.nextDeadline == 3_200L)
    verify(handoff.setEligible(true, 1, 510, true, 1))
    verify(handoff.nextDeadline == 3_200L && handoff.attempting)
    completed(handoff, 600, 2)
    verify(handoff.nextDeadline == 3_200L)
    verify(handoff.setEligible(true, 1, 610, true, 1))
    verify(handoff.nextDeadline == 3_200L)
    verify(handoff.setEligible(true, 1, 620, true, 2))
    verify(handoff.nextDeadline == null && handoff.visibilitySession == 1L)

    val stalled = ready()
    verify(stalled.screenOff(100, false) == 1L)
    completed(stalled, 200, 1)
    for (cycle in 2L..5L) {
        val time = cycle * 500
        verify(stalled.screenOff(time, false) == 1L)
        completed(stalled, time + 20, cycle)
        verify(stalled.nextDeadline == 3_200L)
    }
    verify(stalled.poll(3_200, true) == ScreenOffRecoveryPolicy.Notice("unavailable", 1, 5))
    verify(!stalled.observing && stalled.visibilitySession == null)
    verify(stalled.setEligible(true, 1, 3_201, true, 4))
    verify(!stalled.observing && stalled.visibilitySession == null)

    // SCREEN_ON without focus cannot complete. Another genuine OFF supersedes
    // the pending cycle without extending its first attempt expiry.
    val pending = ready()
    pending.focusChanged(false, 10)
    verify(pending.screenOff(100, false) == 1L)
    pending.screenOn(200, true)
    verify(pending.poll(200, true) == null)
    verify(pending.screenOff(300, false) == 1L && pending.currentCycle == 2L)
    verify(pending.nextDeadline == 3_100L)
    pending.screenOn(400, true)
    foreground(pending, 410)
    verify(pending.poll(410, false) == null)
    verify(pending.poll(411, true) == ScreenOffRecoveryPolicy.Notice("recovered", 1, 2))

    // Re-arm racing focus loss is an acknowledged no-op. Its original grace
    // remains bounded despite subsequent pause/stop/rearm callbacks.
    val grace = ready()
    grace.focusChanged(false, 100, interactive = false)
    verify(grace.nextDeadline == 1_100L)
    verify(grace.setEligible(true, 1, 200, true, 0))
    verify(grace.nextDeadline == 1_100L && grace.visibilitySession == 1L)
    grace.pause(500)
    grace.stop(600, false)
    verify(grace.nextDeadline == 1_100L)
    verify(grace.screenOff(1_099, false) == 1L)
    verify(grace.setEligible(true, 1, 1_200, false, 1))
    verify(grace.nextDeadline == 4_099L)
    grace.screenOn(1_300, true)
    verify(grace.poll(1_300, true) == null)
    foreground(grace, 1_301)
    verify(grace.poll(1_301, true)?.method == "recovered")
    val expiredGrace = ready()
    expiredGrace.pause(100)
    verify(expiredGrace.screenOff(1_100, false) == null)
    verify(!expiredGrace.observing && expiredGrace.visibilitySession == null)

    // A notification shade can keep the Activity resumed but unfocused for an
    // arbitrary interval. It must not revoke an established window owner above
    // keyguard or produce a recovery event when no OFF/ON happened.
    val shade = ready()
    val shadeWindow = CycleLockScreenWindow()
    val shadeVisibility = PlayerLockScreenVisibility(shadeWindow)
    verify(shadeVisibility.apply(shade.visibilitySession, true))
    shadeWindow.locked = true
    val beforeShadeRevocations = shadeWindow.revocations
    shade.focusChanged(false, 100, interactive = true)
    verify(!shade.foreground && shade.nextDeadline == null)
    for (time in listOf(1_100L, 4_100L, 20_100L, 120_100L)) {
        verify(shade.poll(time, true) == null)
        verify(shade.setEligible(true, 1, time, true, 0))
        verify(shade.nextDeadline == null && shade.visibilitySession == 1L)
        verify(shadeVisibility.apply(shade.visibilitySession, false))
        verify(shadeWindow.showing && !shadeWindow.guardPresent)
        verify(shadeWindow.revocations == beforeShadeRevocations)
    }
    shade.focusChanged(true, 120_200)
    verify(shade.foreground && shade.poll(120_200, true) == null)
    verify(shadeVisibility.apply(shade.visibilitySession, true))
    verify(shadeWindow.revocations == beforeShadeRevocations)

    // Even under an open shade, a real power OFF/ON still gets exactly one
    // bounded attempt, and cannot claim recovery until window focus returns.
    shade.focusChanged(false, 121_000, interactive = true)
    verify(shade.screenOff(122_100, false) == 1L)
    verify(shade.currentCycle == 1L && shade.nextDeadline == 125_100L)
    shade.screenOn(122_200, true)
    verify(shade.poll(122_200, true) == null)
    shade.focusChanged(true, 122_300)
    verify(shade.poll(122_300, true) == ScreenOffRecoveryPolicy.Notice("recovered", 1, 1))
    verify(shade.setEligible(true, 1, 122_400, true, 1))
    verify(shadeVisibility.apply(shade.visibilitySession, true))
    verify(shadeWindow.showing && !shadeWindow.guardPresent && shadeWindow.revocations == beforeShadeRevocations)

    // The shade can open while Dart completes a recovered Play. Only a current
    // cycle ACK from this still-resumed/interactive owner finishes the handoff;
    // stale ACKs, no ACK, and an in-flight wake keep their original deadlines.
    val shadeHandoff = ready()
    verify(shadeHandoff.screenOff(100, false) == 1L)
    completed(shadeHandoff, 200, 1)
    shadeHandoff.focusChanged(false, 201, interactive = true)
    verify(shadeHandoff.setEligible(true, 1, 202, true, 0))
    verify(shadeHandoff.nextDeadline == 3_200L)
    verify(shadeHandoff.setEligible(true, 1, 203, true, 1))
    verify(shadeHandoff.nextDeadline == null && shadeHandoff.visibilitySession == 1L)
    verify(shadeHandoff.poll(20_000, true) == null && shadeHandoff.visibilitySession == 1L)
    val shadeUnconfirmed = ready()
    verify(shadeUnconfirmed.screenOff(100, false) == 1L)
    completed(shadeUnconfirmed, 200, 1)
    shadeUnconfirmed.focusChanged(false, 201, interactive = true)
    verify(shadeUnconfirmed.poll(3_200, true) == null && shadeUnconfirmed.visibilitySession == null)
    val shadePending = ready()
    verify(shadePending.screenOff(100, false) == 1L)
    shadePending.focusChanged(false, 101, interactive = true)
    verify(shadePending.setEligible(true, 1, 102, true, 1))
    verify(shadePending.nextDeadline == 3_100L && shadePending.attempting)
    verify(shadePending.poll(3_100, true) == null && shadePending.visibilitySession == null)

    // An actual pause after focus was already lost still starts its own bounded
    // ordering grace; it must not inherit an unlimited shade retention.
    val shadePause = ready()
    shadePause.focusChanged(false, 100, interactive = true)
    shadePause.pause(10_000)
    verify(shadePause.nextDeadline == 11_000L)
    verify(shadePause.setEligible(true, 1, 10_500, true))
    verify(shadePause.nextDeadline == 11_000L)
    verify(shadePause.poll(11_000, true) == null && shadePause.visibilitySession == null)
    verify(!shadePause.setEligible(true, 1, 11_100, true))
    verify(shadePause.screenOff(11_101, false) == null)

    val shadeOff = ready()
    shadeOff.focusChanged(false, 100, interactive = true)
    shadeOff.pause(10_000)
    verify(shadeOff.screenOff(10_999, false) == 1L)
    verify(shadeOff.nextDeadline == 13_999L)

    // Same-session benign ACKs never allow first-time acquisition or a new
    // route above keyguard while unfocused. Home/stop/dispose still revoke.
    val unarmedShade = ScreenOffRecoveryPolicy()
    unarmedShade.resume()
    unarmedShade.focusChanged(false, 100, interactive = true)
    verify(!unarmedShade.setEligible(true, 1, 100, true))
    verify(unarmedShade.visibilitySession == null && unarmedShade.screenOff(200, false) == null)
    val newShadeSession = ready()
    newShadeSession.focusChanged(false, 100, interactive = true)
    verify(!newShadeSession.setEligible(true, 2, 200, true))
    verify(newShadeSession.visibilitySession == null)
    shade.focusChanged(false, 123_000, interactive = true)
    shade.userLeave()
    verify(!shade.setEligible(true, 1, 123_001, true, 1))
    verify(shade.screenOff(123_002, false) == null)
    verify(shadeVisibility.apply(shade.visibilitySession, false))
    verify(!shadeWindow.showing && shadeWindow.guardPresent && shadeWindow.locked)
    val shadeStop = ready()
    shadeStop.focusChanged(false, 100, interactive = true)
    shadeStop.stop(101, true)
    verify(shadeStop.visibilitySession == null && shadeStop.screenOff(102, false) == null)
    val shadeCancel = ready()
    shadeCancel.focusChanged(false, 100, interactive = true)
    verify(shadeCancel.setEligible(false, 1, 101, true))
    verify(shadeCancel.visibilitySession == null && shadeCancel.screenOff(102, false) == null)

    // Only failures consume the budget, across player sessions, for60s. A
    // refused new OFF receives a fresh cycle ID but never attempts another wake.
    val failures = ready()
    for (cycle in 1L..3L) {
        val time = cycle * 1_000
        verify(failures.setEligible(true, 1, time, true, cycle - 1))
        verify(failures.screenOff(time, false) == 1L)
        failures.wakeFailed(1, time + 1, cycle)
        verify(failures.poll(time + 2, true) == ScreenOffRecoveryPolicy.Notice("unavailable", 1, cycle))
        verify(failures.visibilitySession == null)
    }
    verify(failures.setEligible(true, 2, 4_000, true, 0))
    verify(failures.screenOff(4_000, false) == null && failures.currentCycle == 1L)
    verify(failures.poll(4_001, true) == ScreenOffRecoveryPolicy.Notice("unavailable", 2, 1))
    verify(failures.setEligible(true, 2, 61_001, true, 1))
    verify(failures.screenOff(61_001, false) == 2L && failures.currentCycle == 2L)
    failures.wakeFailed(1, 61_002, 2)
    failures.wakeFailed(2, 61_002, 1)
    verify(failures.attempting && failures.visibilitySession == 2L)

    val timeout = ready()
    verify(timeout.screenOff(100, false) == 1L)
    timeout.pause(101)
    verify(timeout.poll(3_100, false) == null && !timeout.observing)
    foreground(timeout, 3_200)
    verify(timeout.poll(3_200, true) == ScreenOffRecoveryPolicy.Notice("unavailable", 1, 1))
    verify(timeout.poll(3_201, true) == null)

    // Whole-session false, Home, normal stop and detach always revoke. Queued
    // true after Home is denied; stale sessions cannot clear a newer owner.
    val cancel = ready()
    verify(cancel.screenOff(100, false) == 1L)
    verify(cancel.setEligible(false, 1, 101, false, 0))
    cancel.screenOn(102, true)
    verify(cancel.poll(102, true) == null && !cancel.observing)
    val home = ready()
    home.userLeave()
    verify(!home.setEligible(true, 1, 10, true))
    home.focusChanged(true, 11)
    verify(!home.setEligible(true, 1, 12, true))
    home.pause(13)
    verify(home.screenOff(14, false) == null)
    val leavePending = ready()
    verify(leavePending.screenOff(100, false) == 1L)
    leavePending.userLeave()
    leavePending.screenOn(101, true)
    foreground(leavePending, 102)
    verify(leavePending.poll(102, true) == null && leavePending.visibilitySession == null)
    val stop = ready()
    stop.pause(100)
    stop.stop(101, true)
    verify(stop.screenOff(102, false) == null && !stop.observing)
    val detach = ready()
    verify(detach.screenOff(100, false) == 1L)
    detach.detach()
    detach.screenOn(101, true)
    foreground(detach, 102)
    verify(detach.poll(102, true) == null && detach.visibilitySession == null)
    val sessions = ready(2)
    verify(!sessions.setEligible(false, 1, 100, true) && sessions.visibilitySession == 2L)
    verify(!sessions.setEligible(true, 1, 101, true) && sessions.visibilitySession == 2L)
    verify(sessions.setEligible(true, 3, 102, true) && sessions.currentCycle == 0L)
    verify(!sessions.setEligible(false, 2, 103, true) && sessions.visibilitySession == 3L)

    println("Screen-off recovery policy checks passed: $checks")
}
