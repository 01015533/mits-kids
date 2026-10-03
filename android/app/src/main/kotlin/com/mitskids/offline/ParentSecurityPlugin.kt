package com.mitskids.offline

import android.app.Activity
import android.app.Application
import android.content.Context
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.view.WindowManager
import android.webkit.WebView
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.Executors
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

/** No web interface. Calls originate only from the Flutter engine. */
class ParentSecurityPlugin : FlutterPlugin, MethodChannel.MethodCallHandler,
    ActivityAware, Application.ActivityLifecycleCallbacks {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val epoch = CredentialEpoch()
    private var activity: Activity? = null
    private var application: Application? = null
    private val preferences get() = context.getSharedPreferences("mits_parent_v2", Context.MODE_PRIVATE)
    private val legacyPreferences get() = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
    private val legacyKey = "flutter.parent_pin_sha256_v1"
    private val alias = "mits.parent.pin.hmac.v2"

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "mits_kids/parent_security")
        channel.setMethodCallHandler(this)
        // Explicitly disabled even in debug builds containing a parent's session.
        WebView.setWebContentsDebuggingEnabled(false)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        revokeAuthority()
        channel.setMethodCallHandler(null)
        worker.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "lock") {
            revokeAuthority()
            result.success(null)
            return
        }
        val requestedEpoch = epoch.current()
        worker.execute {
            try {
                val response: Any? = when (call.method) {
                    "status" -> mapOf(
                        "configured" to (preferences.contains("verifier") || legacyPreferences.contains(legacyKey)),
                        "legacy" to (!preferences.contains("verifier") && legacyPreferences.contains(legacyKey))
                    )
                    "setup" -> {
                        check(!preferences.contains("verifier") && !legacyPreferences.contains(legacyKey)) { "Parent setup is already complete." }
                        val pin = call.argument<String>("pin") ?: ""
                        requireNewPin(pin)
                        savePin(pin, requestedEpoch)
                        issueToken(requestedEpoch)
                    }
                    "authenticate" -> {
                        authenticate(call, requestedEpoch)
                        issueToken(requestedEpoch)
                    }
                    "changePin" -> {
                        check(preferences.contains("verifier")) { "Complete parent setup or migration first." }
                        val replacement = call.argument<String>("newPin") ?: ""
                        requireNewPin(replacement)
                        // Re-authentication uses the same persistent guess budget.
                        // It never relies on a token supplied by Flutter or a webpage.
                        authenticate(call, requestedEpoch)
                        savePin(replacement, requestedEpoch, createKey = false)
                        issueToken(requestedEpoch)
                    }
                    else -> throw IllegalArgumentException("Unknown security operation.")
                }
                main.post {
                    if (call.method != "status" && requestedEpoch != epoch.current()) {
                        result.error("LOCKED", "The app was interrupted. Unlock again.", null)
                    } else result.success(response)
                }
            } catch (e: Rejected) {
                main.post { result.error("REJECTED", e.message, null) }
            } catch (_: InterruptedException) {
                main.post { result.error("LOCKED", "The app was interrupted. Unlock again.", null) }
            } catch (e: IllegalArgumentException) {
                main.post { result.error("INVALID", e.message, null) }
            } catch (_: Exception) {
                // No keys, PINs, verifier material or exception details in logs.
                main.post { result.error("SECURITY_UNAVAILABLE", "Parent security is unavailable or locked. Reopen the app and try again. Existing credentials have not been reset.", null) }
            }
        }
    }

    private class Rejected(message: String) : Exception(message)

    private fun issueToken(requestedEpoch: Long): Map<String, String> = epoch.withCurrent(requestedEpoch) {
        val token = UUID.randomUUID().toString()
        ParentAuthority.unlock(token)
        mapOf("token" to token)
    }

    private fun revokeAuthority() {
        epoch.revoke()
        ParentAuthority.revoke()
    }

    private fun requireNewPin(pin: String) {
        require(Regex("^[0-9]{6,12}$").matches(pin)) { "Use a 6–12 digit parent PIN." }
    }

    private fun key(create: Boolean): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val existing = store.getKey(alias, null)
        if (existing is SecretKey) return existing
        check(create && !preferences.contains("verifier")) { "Missing parent key" }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_HMAC_SHA256, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY)
                .setDigests(KeyProperties.DIGEST_SHA256).setKeySize(256).build())
        }.generateKey()
    }

    private fun savePin(pin: String, requestedEpoch: Long, createKey: Boolean = true) {
        val salt = ByteArray(32).also { SecureRandom().nextBytes(it) }
        val value = PinDerivation.verifier(pin, salt, key(create = createKey))
        try {
            epoch.withCurrent(requestedEpoch) {
                val p = preferences
                val oldSalt = p.getString("salt", null)
                val oldVerifier = p.getString("verifier", null)
                val oldFailures = p.getInt("failures", 0)
                val oldUntilElapsed = p.getLong("untilElapsed", 0)
                val oldUntilWall = p.getLong("untilWall", 0)
                // One synchronous editor transaction replaces both credential fields.
                // The Keystore alias/key is reused and is never deleted or rotated.
                val committed = p.edit()
                    .putString("salt", Base64.encodeToString(salt, Base64.NO_WRAP))
                    .putString("verifier", Base64.encodeToString(value, Base64.NO_WRAP))
                    .putInt("failures", 0).putLong("untilElapsed", 0).putLong("untilWall", 0).commit()
                if (!committed) {
                    // SharedPreferences updates its memory before reporting a disk
                    // failure. Restore that memory too so the existing PIN remains
                    // usable, even if the second disk write also cannot complete.
                    p.edit().putString("salt", oldSalt).putString("verifier", oldVerifier)
                        .putInt("failures", oldFailures).putLong("untilElapsed", oldUntilElapsed)
                        .putLong("untilWall", oldUntilWall).commit()
                    error("Credential commit failed")
                }
                // Migration only removes the legacy hash after the stronger record commits.
                if (legacyPreferences.contains(legacyKey)) check(legacyPreferences.edit().remove(legacyKey).commit())
            }
        } finally {
            salt.fill(0)
            value.fill(0)
        }
    }

    private fun bootCount(): Int = Settings.Global.getInt(context.contentResolver, Settings.Global.BOOT_COUNT, -1)

    private fun remainingDelay(): Long {
        val p = preferences
        val wall = System.currentTimeMillis()
        val sameBoot = bootCount() == p.getInt("boot", -2) && SystemClock.elapsedRealtime() >= p.getLong("attemptElapsed", 0)
        if (sameBoot) return (p.getLong("untilElapsed", 0) - SystemClock.elapsedRealtime()).coerceAtLeast(0)
        // Reboot cannot clear a outstanding cooldown, even if the clock changes.
        if (p.getInt("failures", 0) > 0 && p.getLong("untilElapsed", 0) > 0) {
            val delay = RetryDelay.milliseconds(p.getInt("failures", 0))
            persistDelay(p.getInt("failures", 0), delay)
            return delay
        }
        return (p.getLong("untilWall", 0) - wall).coerceIn(0, 300_000)
    }

    private fun persistDelay(failures: Int, delay: Long) {
        check(preferences.edit().putInt("failures", failures)
            .putLong("attemptElapsed", SystemClock.elapsedRealtime())
            .putInt("boot", bootCount()).putLong("untilElapsed", SystemClock.elapsedRealtime() + delay)
            .putLong("untilWall", System.currentTimeMillis() + delay).commit())
    }

    private fun authenticate(call: MethodCall, requestedEpoch: Long) {
        epoch.withCurrent(requestedEpoch) { }
        val delay = remainingDelay()
        if (delay > 0) throw Rejected("Wait ${(delay + 999) / 1000} seconds before trying again.")
        val failures = (preferences.getInt("failures", 0) + 1).coerceAtMost(100)
        // Persist BEFORE checking. Killing the process cannot erase a failed attempt.
        persistDelay(failures, RetryDelay.milliseconds(failures))
        val pin = call.argument<String>("pin") ?: ""
        if (!Regex("^[0-9]{4,12}$").matches(pin)) throw Rejected("Incorrect PIN.")
        if (preferences.contains("verifier")) {
            val salt = Base64.decode(preferences.getString("salt", null), Base64.NO_WRAP)
            val expected = Base64.decode(preferences.getString("verifier", null), Base64.NO_WRAP)
            check(salt.size == 32 && expected.size == 32)
            if (!MessageDigest.isEqual(expected, PinDerivation.verifier(pin, salt, key(create = false)))) throw Rejected("Incorrect PIN.")
        } else {
            val expected = legacyPreferences.getString(legacyKey, null) ?: throw Rejected("Complete parent setup first.")
            val actual = MessageDigest.getInstance("SHA-256").digest(pin.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) }
            if (!MessageDigest.isEqual(expected.toByteArray(Charsets.US_ASCII), actual.toByteArray(Charsets.US_ASCII))) throw Rejected("Incorrect PIN.")
            val replacement = call.argument<String>("newPin") ?: ""
            requireNewPin(replacement)
            savePin(replacement, requestedEpoch)
        }
        epoch.withCurrent(requestedEpoch) {
            if (legacyPreferences.contains(legacyKey)) check(legacyPreferences.edit().remove(legacyKey).commit())
            check(preferences.edit().putInt("failures", 0).putLong("untilElapsed", 0).putLong("untilWall", 0).commit())
        }
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activity?.window?.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        application = binding.activity.application
        application?.registerActivityLifecycleCallbacks(this)
    }
    override fun onDetachedFromActivity() {
        revokeAuthority()
        application?.unregisterActivityLifecycleCallbacks(this)
        activity = null; application = null
    }
    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onActivityPaused(value: Activity) { if (value === activity) revokeAuthority() }
    override fun onActivityCreated(value: Activity, state: Bundle?) {}
    override fun onActivityStarted(value: Activity) {}
    override fun onActivityResumed(value: Activity) {}
    override fun onActivityStopped(value: Activity) {}
    override fun onActivitySaveInstanceState(value: Activity, state: Bundle) {}
    override fun onActivityDestroyed(value: Activity) {}
}
