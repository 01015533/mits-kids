package com.mitskids.offline

import javax.crypto.spec.SecretKeySpec
import java.security.MessageDigest

fun main() {
    val salt = ByteArray(32) { it.toByte() }
    val key = SecretKeySpec(ByteArray(32) { (it + 32).toByte() }, "HmacSHA256")
    val value = PinDerivation.verifier("123456", salt, key)
    check(value.joinToString("") { "%02x".format(it) } == "c2d409cb55337a3a8c7526273150f3c5c2837adcd2ef85e9da0aef9f5e9fd88e")
    check(MessageDigest.isEqual(value, PinDerivation.verifier("123456", salt, key)))
    check(!MessageDigest.isEqual(value, PinDerivation.verifier("654321", salt, key)))
    check(!MessageDigest.isEqual(value, PinDerivation.verifier("123456", ByteArray(32) { 4 }, key)))
    val other = SecretKeySpec(ByteArray(32) { 5 }, "HmacSHA256")
    check(!MessageDigest.isEqual(value, PinDerivation.verifier("123456", salt, other)))
    var invalidSaltRejected = false
    try { PinDerivation.verifier("123456", ByteArray(1), key) } catch (_: IllegalArgumentException) { invalidSaltRejected = true }
    check(invalidSaltRejected)
    for ((attempt, delay) in listOf(1 to 1000L, 4 to 1000L, 5 to 30000L, 6 to 60000L, 7 to 120000L, 8 to 240000L, 9 to 300000L, Int.MAX_VALUE to 300000L)) {
        check(RetryDelay.milliseconds(attempt) == delay)
    }
    println("14 native derivation/backoff checks passed; Android Keystore itself still requires a device test.")
}
