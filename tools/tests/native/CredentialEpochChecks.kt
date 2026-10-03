package com.mitskids.offline

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

fun main() {
    val guard = CredentialEpoch()
    val initial = guard.current()
    var stored = "old verifier"
    guard.withCurrent(initial) { stored = "first verifier" }
    check(stored == "first verifier")
    guard.revoke()
    var interrupted = false
    try { guard.withCurrent(initial) { stored = "stale verifier" } }
    catch (_: InterruptedException) { interrupted = true }
    check(interrupted && stored == "first verifier")
    val current = guard.current()
    guard.withCurrent(current) { stored = "new verifier" }
    check(stored == "new verifier")

    // A concurrent revoke cannot split an already-started credential commit.
    val entered = CountDownLatch(1)
    val release = CountDownLatch(1)
    val revoked = CountDownLatch(1)
    val writer = thread {
        guard.withCurrent(current) {
            entered.countDown()
            check(release.await(5, TimeUnit.SECONDS))
            stored = "complete verifier"
        }
    }
    check(entered.await(5, TimeUnit.SECONDS))
    val revoker = thread { guard.revoke(); revoked.countDown() }
    check(!revoked.await(50, TimeUnit.MILLISECONDS))
    release.countDown()
    writer.join(5_000)
    revoker.join(5_000)
    check(!writer.isAlive && !revoker.isAlive && stored == "complete verifier")
    check(guard.current() != current)
    println("7 credential epoch and atomic-revocation checks passed.")
}
