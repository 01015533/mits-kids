package com.mitskids.offline

import android.Manifest
import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** A parent can start one approved transfer; that job never grants parent UI authority. */
class DownloadJobPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware,
    Application.ActivityLifecycleCallbacks {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private var activity: Activity? = null
    private var application: Application? = null
    private var resumed = false
    private val owner = Any()
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "mits_kids/download_job")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        ApprovedDownloadJobs.cancelOwner(owner, "engine_closed")
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "start" -> {
                    check(resumed && activity != null) { "Start an approved save while the app is visible" }
                    ParentAuthority.requireToken(call.argument<String>("token") ?: "")
                    val videoId = call.argument<String>("videoId") ?: ""
                    require(Regex("^[A-Za-z0-9_-]{11}$").matches(videoId))
                    val title = call.argument<String>("title") ?: ""
                    require(title.isNotBlank() && title.length <= 4096)
                    var responded = false
                    val job = ApprovedDownloadJobs.begin(context, owner, videoId, title,
                        onStarted = { id ->
                            if (!responded) {
                                responded = true
                                result.success(mapOf("job" to id))
                                // Permission UI may lock Parent. The exact transfer has
                                // already been approved and promoted to foreground.
                                main.post { requestNotifications(id) }
                            }
                        }, onCancelled = { id, reason ->
                            if (!responded) {
                                responded = true
                                result.error("DOWNLOAD_JOB_STOPPED", "The approved download could not start", null)
                            } else {
                                channel.invokeMethod("cancelled", mapOf("job" to id, "reason" to reason))
                            }
                        })
                    try {
                        context.startForegroundService(Intent(context, ApprovedDownloadService::class.java)
                            .putExtra(ApprovedDownloadService.EXTRA_JOB, job))
                    } catch (_: Exception) {
                        ApprovedDownloadJobs.cancel(job, "start_failed")
                    }
                }
                "update" -> {
                    ApprovedDownloadJobs.update(owner, call.argument<String>("job") ?: "",
                        call.argument<String>("status") ?: "Saving approved video",
                        call.argument<Number>("progress")?.toDouble())
                    result.success(null)
                }
                "finish" -> {
                    ApprovedDownloadJobs.finish(owner, call.argument<String>("job") ?: "")
                    result.success(null)
                }
                "cancelPending" -> {
                    // The adapter uses this only while start has not returned an
                    // opaque ID; ownership is still confined to this engine.
                    ApprovedDownloadJobs.cancelOwner(owner, "start_cancelled")
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (_: Exception) {
            result.error("DOWNLOAD_JOB_UNAVAILABLE", "The background download could not start or continue", null)
        }
    }

    private fun requestNotifications(job: String) {
        if (Build.VERSION.SDK_INT < 33 || !ApprovedDownloadJobs.belongsTo(owner, job)) return
        val current = activity ?: return
        if (!resumed || current.isFinishing || current.isDestroyed ||
            current.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) return
        val preferences = context.getSharedPreferences("mits_download_ui", Context.MODE_PRIVATE)
        if (preferences.getBoolean("notifications_requested", false)) return
        // This preference controls prompting only, never job or parent authority.
        preferences.edit().putBoolean("notifications_requested", true).apply()
        try { current.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 49382) }
        catch (_: Exception) { /* Notification denial does not invalidate the approved transfer. */ }
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        application = binding.activity.application
        application?.registerActivityLifecycleCallbacks(this)
    }
    private fun detachActivity() {
        application?.unregisterActivityLifecycleCallbacks(this)
        activity = null; application = null; resumed = false
    }
    override fun onDetachedFromActivity() = detachActivity()
    override fun onDetachedFromActivityForConfigChanges() = detachActivity()
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onActivityResumed(value: Activity) { if (value === activity) resumed = true }
    override fun onActivityPaused(value: Activity) { if (value === activity) resumed = false }
    override fun onActivityCreated(value: Activity, state: Bundle?) {}
    override fun onActivityStarted(value: Activity) {}
    override fun onActivityStopped(value: Activity) {}
    override fun onActivitySaveInstanceState(value: Activity, state: Bundle) {}
    override fun onActivityDestroyed(value: Activity) {}
}
