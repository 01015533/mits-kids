package com.mitskids.offline

import com.mitskids.offline.PlaybackImmersivePolicy.Action

fun main() {
    var checks = 0
    fun verify(value: Boolean) { check(value); checks++ }
    fun expect(actual: Action, expected: Action) { check(actual == expected) { "$actual != $expected" }; checks++ }
    val policy = PlaybackImmersivePolicy()

    expect(policy.setLocked(true), Action.NONE)
    expect(policy.onResume(), Action.NONE)
    expect(policy.onFocusChanged(true), Action.APPLY)
    policy.didApply(true, true)
    verify(policy.applied && policy.requested)
    expect(policy.setLocked(true), Action.NONE)
    expect(policy.onResume(), Action.NONE)
    expect(policy.onFocusChanged(true), Action.NONE)

    // Notification/system bars may be revealed. Focus changes must not fight them.
    expect(policy.onFocusChanged(false), Action.NONE)
    expect(policy.onFocusChanged(true), Action.NONE)
    expect(policy.setLocked(true), Action.NONE)

    // Resume after a real pause may reapply once, without losing the original snapshot.
    expect(policy.onPause(), Action.NONE)
    expect(policy.onFocusChanged(false), Action.NONE)
    expect(policy.onResume(), Action.NONE)
    expect(policy.onFocusChanged(true), Action.APPLY)
    policy.didApply(true, true)
    expect(policy.onFocusChanged(true), Action.NONE)

    expect(policy.onUserLeaveHint(), Action.RESTORE)
    policy.didRestore(true)
    verify(!policy.applied && policy.requested)
    expect(policy.setLocked(true), Action.NONE) // Late channel request after Home.
    expect(policy.onFocusChanged(true), Action.NONE)
    expect(policy.onStop(), Action.NONE)
    expect(policy.onResume(), Action.NONE)
    expect(policy.onFocusChanged(true), Action.APPLY)
    policy.didApply(true, true)
    expect(policy.onStop(), Action.RESTORE)
    policy.didRestore(true)
    expect(policy.onResume(), Action.NONE)
    expect(policy.onFocusChanged(true), Action.APPLY)
    policy.didApply(true, true)

    expect(policy.onPause(), Action.NONE)
    expect(policy.setLocked(false), Action.RESTORE)
    policy.didRestore(true)
    verify(!policy.applied && !policy.requested)
    expect(policy.onResume(), Action.NONE)
    expect(policy.onFocusChanged(true), Action.NONE)
    expect(policy.setLocked(false), Action.NONE)
    expect(policy.setLocked(true), Action.APPLY)
    policy.didApply(true, true)
    expect(policy.close(), Action.RESTORE)
    policy.didRestore(true)
    expect(policy.setLocked(true), Action.NONE)
    expect(policy.onResume(), Action.NONE)
    expect(policy.onFocusChanged(true), Action.NONE)
    verify(!policy.applied && !policy.requested)

    val failed = PlaybackImmersivePolicy()
    failed.onResume()
    failed.onFocusChanged(true)
    expect(failed.setLocked(true), Action.APPLY)
    failed.didApply(false, false) // No attached window/controller yet.
    verify(!failed.applied)
    expect(failed.setLocked(true), Action.APPLY)
    failed.didApply(false, true) // Window changed partly; retain restoration duty.
    verify(failed.applied)
    expect(failed.setLocked(false), Action.RESTORE)
    failed.didRestore(false)
    verify(failed.applied)
    expect(failed.onStop(), Action.RESTORE)
    failed.didRestore(false)
    expect(failed.close(), Action.RESTORE)
    failed.didRestore(false)
    expect(failed.close(), Action.RESTORE)
    failed.didRestore(true)
    verify(!failed.applied)

    // Preserve layout/light-icon flag changes made by Flutter while locked.
    verify(PlaybackImmersivePolicy.restoreLegacyFlags(0b111110, 0b000001, 0b000111) == 0b111001)
    verify(PlaybackImmersivePolicy.restoreLegacyFlags(0b000001, 0b111110, 0b000111) == 0b000110)
    println("Playback immersive policy checks passed: $checks")
}
