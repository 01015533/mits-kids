package com.mitskids.offline

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Bounded player recovery and lock-screen visibility; never intercepts keys or launches an Activity. */
class ScreenOffRecoveryController(
    private val activity: Activity,
    messenger: BinaryMessenger,
) {
    private val policy = ScreenOffRecoveryPolicy()
    private val visibility = PlayerLockScreenVisibility(AndroidPlayerLockScreenWindow(activity))
    private val main = Handler(Looper.getMainLooper())
    private val power = activity.getSystemService(PowerManager::class.java)
    private val channel = MethodChannel(messenger, "mits_kids/screen_off_recovery")
    private var registered = false
    private var closed = false
    private var wakeLock: PowerManager.WakeLock? = null
    private var guardCheckUntil = 0L
    private val releaseWake = Runnable { releaseWakeLock() }
    private val expire = Runnable { synchronize() }
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (closed) return
            when (intent?.action) {
                Intent.ACTION_SCREEN_OFF -> {
                    val session = policy.screenOff(now(), power.isInteractive)
                    val cycle = policy.currentCycle
                    synchronize()
                    if (session != null && policy.attempting && visibility.ownerSession == session) {
                        channel.invokeMethod("recovering", mapOf("session" to session, "cycle" to cycle))
                        attemptWake(session, cycle)
                    }
                }
                Intent.ACTION_SCREEN_ON -> {
                    policy.screenOn(now(), power.isInteractive)
                    synchronize()
                }
            }
        }
    }

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "setEligible") {
                result.notImplemented()
            } else {
                val arguments = call.arguments as? Map<*, *>
                val eligible = arguments?.get("eligible") as? Boolean
                val session = when (val value = arguments?.get("session")) {
                    is Int -> value.toLong()
                    is Long -> value
                    else -> null
                }
                val cycle = when (val value = arguments?.get("cycle")) {
                    null -> 0L
                    is Int -> value.toLong()
                    is Long -> value
                    else -> null
                }
                if (closed || eligible == null || session == null || cycle == null) {
                    result.success(false)
                } else {
                    // Expiry must revoke an old visibility lease before a late
                    // arming message can request another one with the same ID.
                    synchronize()
                    val stale = eligible && policy.staleCycle(session, cycle)
                    val acknowledged = policy.setEligible(eligible, session, now(), power.isInteractive, cycle)
                    val synchronized = synchronize()
                    val confirmed = acknowledged && (stale || (synchronized &&
                        (!eligible || registered || policy.attempting)))
                    // Cancellation may overtake a queued recovering event.
                    // Return the native cycle boundary so a later fresh arm
                    // cannot accidentally acknowledge an obsolete cycle.
                    if (!eligible && confirmed) {
                        result.success(mapOf("confirmed" to true, "cycle" to policy.currentCycle))
                    } else result.success(confirmed)
                }
            }
        }
    }

    fun onResume() {
        policy.resume()
        guardCheckUntil = now() + GUARD_CHECK_MS
        synchronize()
    }
    fun onPause() { policy.pause(now()); synchronize() }
    fun onFocusChanged(focused: Boolean) {
        policy.focusChanged(focused, now(), power.isInteractive)
        if (focused) guardCheckUntil = now() + GUARD_CHECK_MS
        synchronize()
    }
    fun onStop() { policy.stop(now(), power.isInteractive); synchronize() }
    fun onUserLeaveHint() { policy.userLeave(); synchronize() }

    fun close() {
        if (closed) return
        closed = true
        policy.detach()
        channel.setMethodCallHandler(null)
        main.removeCallbacksAndMessages(null)
        unregister()
        releaseWakeLock()
        // A locked/unknown keyguard keeps the in-window guard until the window
        // disappears or a new controller confirms a fully unlocked foreground.
        if (!visibility.apply(null, false)) finishForConcealmentFailure()
    }

    @Suppress("DEPRECATION")
    private fun attemptWake(session: Long, cycle: Long) {
        releaseWakeLock()
        try {
            // Deprecated, still implemented by Android. The device may ignore
            // ACQUIRE_CAUSES_WAKEUP; acquisition is never a success signal.
            val lock = power.newWakeLock(
                PowerManager.SCREEN_DIM_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP or
                    PowerManager.ON_AFTER_RELEASE,
                "MITS:AccidentalScreenOffRecovery",
            )
            lock.setReferenceCounted(false)
            wakeLock = lock
            lock.acquire(WAKE_LOCK_MS)
            main.postDelayed(releaseWake, WAKE_LOCK_MS)
        } catch (_: RuntimeException) {
            releaseWakeLock()
            policy.wakeFailed(session, now(), cycle)
        }
        synchronize()
    }

    private fun synchronize(): Boolean {
        if (closed) return false
        var notice = policy.poll(now(), foregroundReady())
        val desiredSession = policy.visibilitySession
        val applied = visibility.apply(desiredSession, foregroundReady())
        if (!applied) {
            if (desiredSession != null) {
                policy.setEligible(false, desiredSession, now(), power.isInteractive)
                if (notice?.method == "recovered") {
                    notice = ScreenOffRecoveryPolicy.Notice("unavailable", desiredSession, policy.currentCycle)
                }
            }
            if (!visibility.apply(null, foregroundReady())) finishForConcealmentFailure()
        }
        if (!policy.attempting) releaseWakeLock()
        if (policy.observing && !registered) {
            try {
                val filter = IntentFilter(Intent.ACTION_SCREEN_OFF).apply { addAction(Intent.ACTION_SCREEN_ON) }
                if (Build.VERSION.SDK_INT >= 33) {
                    activity.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
                } else {
                    @Suppress("DEPRECATION")
                    activity.registerReceiver(receiver, filter)
                }
                registered = true
            } catch (_: RuntimeException) {
                policy.userLeave()
                if (!visibility.apply(null, false)) finishForConcealmentFailure()
            }
        } else if (!policy.observing) unregister()
        main.removeCallbacks(expire)
        var deadline = policy.nextDeadline
        if (visibility.guarding && foregroundReady()) {
            if (guardCheckUntil == 0L) guardCheckUntil = now() + GUARD_CHECK_MS
            if (now() < guardCheckUntil) {
                deadline = minOf(deadline ?: Long.MAX_VALUE, now() + GUARD_RETRY_MS)
            }
        } else guardCheckUntil = 0L
        deadline?.let { main.postDelayed(expire, (it - now()).coerceAtLeast(1L)) }
        if (notice != null) channel.invokeMethod(notice.method,
            mapOf("session" to notice.session, "cycle" to notice.cycle))
        return applied
    }

    private fun unregister() {
        if (!registered) return
        registered = false
        try { activity.unregisterReceiver(receiver) } catch (_: RuntimeException) { }
    }

    private fun releaseWakeLock() {
        main.removeCallbacks(releaseWake)
        val previous = wakeLock
        wakeLock = null
        try { if (previous?.isHeld == true) previous.release() } catch (_: RuntimeException) { }
    }

    private fun now() = SystemClock.elapsedRealtime()

    private fun foregroundReady(): Boolean = policy.foreground && power.isInteractive &&
        activity.hasWindowFocus() && !activity.isFinishing && !activity.isDestroyed

    private fun finishForConcealmentFailure() {
        // Never leave another Flutter route visible when both concealment and
        // flag revocation cannot be confirmed. No task is launched or relaunched.
        if (!activity.isFinishing && !activity.isDestroyed) activity.finish()
    }

    companion object {
        private const val WAKE_LOCK_MS = 1_500L
        private const val GUARD_CHECK_MS = 5_000L
        private const val GUARD_RETRY_MS = 200L
    }
}
