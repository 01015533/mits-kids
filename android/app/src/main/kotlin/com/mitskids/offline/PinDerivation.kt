package com.mitskids.offline

import javax.crypto.Mac
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.PBEKeySpec

/** Standard platform primitives; the HMAC key is non-exportable on Android. */
object PinDerivation {
    fun verifier(pin: String, salt: ByteArray, key: SecretKey): ByteArray {
        require(salt.size == 32)
        val chars = pin.toCharArray()
        val spec = PBEKeySpec(chars, salt, 600_000, 256)
        chars.fill('\u0000')
        val derived = try { SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).encoded }
            finally { spec.clearPassword() }
        return try { Mac.getInstance("HmacSHA256").apply { init(key) }.doFinal(derived) }
            finally { derived.fill(0) }
    }
}
