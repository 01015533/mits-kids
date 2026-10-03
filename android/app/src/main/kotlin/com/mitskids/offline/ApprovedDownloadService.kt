package com.mitskids.offline

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import java.util.UUID

/** Main-thread-only, memory-only authority for one exact parent-approved job. */
internal object ApprovedDownloadJobs {
    const val MAX_MILLIS = 30L * 60 * 1000
    private val main = Handler(Looper.getMainLooper())
    internal class Job(val id: String, val owner: Any, val videoId: String, val title: String,
        val deadline: Long, val context: Context,
        val onStarted: (String) -> Unit, val onCancelled: (String, String) -> Unit) {
        var service: ApprovedDownloadService? = null
        var status = "Preparing approved video"
        var progress: Double? = null
        @Volatile var cancelled = false
        lateinit var timeout: Runnable
        lateinit var startTimeout: Runnable
    }
    private var current: Job? = null

    fun begin(context: Context, owner: Any, videoId: String, title: String,
        onStarted: (String) -> Unit, onCancelled: (String, String) -> Unit): String {
        check(current == null) { "Another approved download is active" }
        val job = Job(UUID.randomUUID().toString(), owner, videoId, clean(title),
            SystemClock.elapsedRealtime() + MAX_MILLIS, context, onStarted, onCancelled)
        job.timeout = Runnable { cancel(job.id, "timeout") }
        job.startTimeout = Runnable { if (get(job.id)?.service == null) cancel(job.id, "start_timeout") }
        current = job
        main.postDelayed(job.timeout, MAX_MILLIS)
        main.postDelayed(job.startTimeout, 4000)
        return job.id
    }

    fun get(id: String?): Job? = current?.takeIf { it.id == id }
    fun belongsTo(owner: Any, id: String): Boolean = get(id)?.owner === owner
    fun hasJob(): Boolean = current != null

    /** Captured on the channel thread; the mux worker reads only this job's flag/deadline. */
    fun cancellationCheck(): () -> Unit {
        val job = current ?: return {}
        return { check(!job.cancelled && SystemClock.elapsedRealtime() < job.deadline) { "Approved download stopped" } }
    }

    fun update(owner: Any, id: String, status: String, progress: Double?) {
        val job = get(id) ?: error("No active approved download")
        check(job.owner === owner)
        if (SystemClock.elapsedRealtime() >= job.deadline) { cancel(id, "timeout"); return }
        job.status = clean(status)
        job.progress = progress?.takeIf { it.isFinite() }?.coerceIn(0.0, 1.0)
        job.service?.refresh(job)
    }

    fun started(job: Job, service: ApprovedDownloadService) {
        check(current === job)
        job.service = service
        main.removeCallbacks(job.startTimeout)
        job.onStarted(job.id)
    }

    fun finish(owner: Any, id: String) {
        val job = get(id) ?: return
        if (job.owner !== owner) return
        stop(job, null)
    }
    fun cancelOwner(owner: Any, reason: String) { current?.takeIf { it.owner === owner }?.let { stop(it, reason) } }
    fun cancel(id: String, reason: String) { get(id)?.let { stop(it, reason) } }

    private fun stop(job: Job, reason: String?) {
        if (current !== job) return
        current = null
        job.cancelled = true
        main.removeCallbacks(job.timeout)
        main.removeCallbacks(job.startTimeout)
        job.service?.stopApprovedJob()
            ?: job.context.stopService(Intent(job.context, ApprovedDownloadService::class.java))
        if (reason != null) job.onCancelled(job.id, reason)
    }
    private fun clean(value: String): String = value.filter { it.code >= 32 }.take(180)
}

/** No engine creation, persistent job, boot receiver, binding or automatic retry. */
class ApprovedDownloadService : Service() {
    private var jobId: String? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private val manager get() = getSystemService(NotificationManager::class.java)

    override fun onCreate() {
        super.onCreate()
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "Approved video downloads",
            NotificationManager.IMPORTANCE_LOW).apply {
            description = "Progress and cancellation for a video approved by a parent"
            setShowBadge(false)
        })
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val job = ApprovedDownloadJobs.get(intent?.getStringExtra(EXTRA_JOB))
        if (job == null) {
            // An obsolete delivery must never stop a later approved job.
            if (!ApprovedDownloadJobs.hasJob()) stopSelf(startId)
            return START_NOT_STICKY
        }
        if (SystemClock.elapsedRealtime() >= job.deadline) {
            ApprovedDownloadJobs.cancel(job.id, "timeout")
            if (!ApprovedDownloadJobs.hasJob()) stopSelf(startId)
            return START_NOT_STICKY
        }
        jobId = job.id
        try {
            val notification = notification(job)
            if (Build.VERSION.SDK_INT >= 29) startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            else startForeground(NOTIFICATION_ID, notification)
            if (wakeLock == null) {
                wakeLock = getSystemService(PowerManager::class.java)
                    .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$packageName:approved-download").apply {
                        setReferenceCounted(false)
                        acquire((job.deadline - SystemClock.elapsedRealtime()).coerceAtLeast(1))
                    }
            }
            ApprovedDownloadJobs.started(job, this)
        } catch (_: Exception) {
            ApprovedDownloadJobs.cancel(job.id, "service_failed")
            stopApprovedJob()
        }
        return START_NOT_STICKY
    }

    internal fun refresh(job: ApprovedDownloadJobs.Job) {
        if (jobId != job.id) return
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        try { manager.notify(NOTIFICATION_ID, notification(job)) }
        catch (_: SecurityException) { /* A denied notification permission does not cancel work. */ }
    }

    private fun notification(job: ApprovedDownloadJobs.Job): Notification {
        val cancel = Intent(this, DownloadCancelReceiver::class.java)
            .setAction(ACTION_CANCEL).setData(Uri.parse("mits-download://cancel/${job.id}"))
            .putExtra(EXTRA_JOB, job.id)
        val pendingCancel = PendingIntent.getBroadcast(this, 0, cancel,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val builder = Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("Saving approved video")
            .setContentText(job.status)
            .setSubText(job.title)
            .setOnlyAlertOnce(true).setOngoing(true).setCategory(Notification.CATEGORY_PROGRESS)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setPublicVersion(Notification.Builder(this, CHANNEL)
                .setSmallIcon(android.R.drawable.stat_sys_download)
                .setContentTitle("Saving an approved video").build())
            .setProgress(100, ((job.progress ?: 0.0) * 100).toInt(), job.progress == null)
            .addAction(Notification.Action.Builder(android.graphics.drawable.Icon.createWithResource(this,
                android.R.drawable.ic_menu_close_clear_cancel), "Cancel", pendingCancel).build())
        packageManager.getLaunchIntentForPackage(packageName)?.let { launch ->
            builder.setContentIntent(PendingIntent.getActivity(this, 1, launch,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
        }
        if (Build.VERSION.SDK_INT >= 31) builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        return builder.build()
    }

    internal fun stopApprovedJob() {
        jobId = null
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }
    override fun onTaskRemoved(rootIntent: Intent?) {
        jobId?.let { ApprovedDownloadJobs.cancel(it, "task_removed") }
        stopApprovedJob()
    }
    override fun onTimeout(startId: Int, fgsType: Int) {
        jobId?.let { ApprovedDownloadJobs.cancel(it, "system_timeout") }
        stopApprovedJob()
    }
    override fun onDestroy() {
        jobId?.let { id ->
            if (ApprovedDownloadJobs.get(id)?.service === this) ApprovedDownloadJobs.cancel(id, "service_closed")
        }
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        super.onDestroy()
    }
    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        internal const val EXTRA_JOB = "approved_job"
        internal const val ACTION_CANCEL = "com.mitskids.offline.CANCEL_APPROVED_DOWNLOAD"
        private const val CHANNEL = "mits_approved_downloads"
        private const val NOTIFICATION_ID = 49383
    }
}

/** Explicit immutable PendingIntent is the only external holder of this cancellation capability. */
class DownloadCancelReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == ApprovedDownloadService.ACTION_CANCEL) {
            intent.getStringExtra(ApprovedDownloadService.EXTRA_JOB)?.let { ApprovedDownloadJobs.cancel(it, "user_cancelled") }
        }
    }
}
