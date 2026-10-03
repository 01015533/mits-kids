package com.mitskids.offline

fun main() {
    val lock = PlaybackKeyLock()
    var checks = 0
    fun verify(value: Boolean) { check(value); checks++ }
    verify(!lock.setTouchLocked(true))
    verify(!lock.consumes(24, 0, false))
    lock.resume()
    verify(!lock.setTouchLocked(true))
    lock.focusChanged(true)
    verify(lock.setTouchLocked(true))
    for (key in listOf(24, 25, 164)) {
        verify(lock.consumes(key, 0, false))
        verify(lock.consumes(key, 0, false)) // Repeated DOWN while held.
        verify(lock.consumes(key, 1, false))
        verify(!lock.consumes(key, 2, false))
        verify(!lock.consumes(key, 0, true))
    }
    for (key in listOf(3, 4, 26, 91, 187, 19, 66, 85)) {
        verify(!lock.consumes(key, 0, false))
        verify(!lock.consumes(key, 1, false))
    }
    verify(lock.setTouchLocked(false))
    verify(!lock.consumes(24, 0, false))
    verify(lock.setTouchLocked(true))
    lock.focusChanged(false)
    verify(!lock.consumes(24, 0, false))
    lock.focusChanged(true)
    verify(!lock.consumes(24, 0, false))
    verify(lock.setTouchLocked(true))
    lock.pause()
    verify(!lock.consumes(24, 0, false))
    verify(!lock.setTouchLocked(true))
    lock.resume()
    verify(!lock.consumes(24, 0, false))
    verify(lock.setTouchLocked(true))
    lock.detach()
    verify(!lock.consumes(24, 0, false))
    lock.resume()
    lock.focusChanged(true)
    verify(!lock.consumes(24, 0, false))
    verify(lock.setTouchLocked(false))
    println("Playback key lock checks passed: $checks")
}
