package com.mitskids.offline

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.system.Os
import android.system.OsConstants
import android.system.StructStat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/** Representative seek pictures from completed private MP4s. No network, imports or persisted images. */
class SeekPreviewPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private lateinit var worker: ExecutorService
    private val main = Handler(Looper.getMainLooper())
    private var queue = LatestSeekPreviewQueue<Request>()
    private var cache = SeekPreviewCache()
    private var attached = false
    private var attachment = 0L
    private var cacheSession = 0L

    private class Request(val path: String, val positionMs: Long, result: MethodChannel.Result) {
        var result: MethodChannel.Result? = result
        val deadline = SystemClock.elapsedRealtime() + CALLBACK_TIMEOUT_MS
        var timeout: Runnable? = null
    }
    private data class Frame(val bytes: ByteArray, val positionMs: Long)

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        queue = LatestSeekPreviewQueue()
        cache = SeekPreviewCache()
        cacheSession = 0
        worker = Executors.newSingleThreadExecutor()
        attachment++
        attached = true
        channel = MethodChannel(binding.binaryMessenger, "mits_kids/seek_preview")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        queue.close().forEach { settle(it, null) }
        attached = false
        attachment++
        channel.setMethodCallHandler(null)
        main.removeCallbacksAndMessages(null)
        cache.clear()
        // MediaMetadataRetriever has no safe interruption API. The one active call
        // releases its retriever/FD/bitmap in finally; it can never publish afterward.
        worker.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (!attached) { result.success(null); return }
        if (call.method !in setOf("frame", "cancel", "dispose")) { result.notImplemented(); return }
        val args = call.arguments as? Map<*, *>
        val session = integer(args?.get("session"))
        if (session == null || session <= 0) { badArguments(result); return }
        if (call.method != "frame") {
            queue.cancel(session, dispose = call.method == "dispose").forEach { settle(it, null) }
            if (session >= cacheSession && call.method == "dispose") cache.clear()
            result.success(true)
            return
        }
        val request = integer(args?.get("request"))
        val position = integer(args?.get("positionMs"))
        val path = args?.get("path") as? String
        if (request == null || request <= 0 || position == null ||
            position !in 0..SeekPreviewInputs.MAX_DURATION_MS || path == null || path.length !in 1..4096) {
            badArguments(result)
            return
        }
        val submitted = queue.submit(session, request, Request(path, position, result))
        submitted.cancelled.forEach { settle(it, null) }
        val job = submitted.accepted
        if (job == null) { result.success(null); return }
        if (session > cacheSession) { cacheSession = session; cache.clear() }
        val timeout = Runnable { if (queue.expire(job)) settle(job, null) }
        job.payload.timeout = timeout
        main.postDelayed(timeout, CALLBACK_TIMEOUT_MS)
        submitted.start?.let { start(it) }
    }

    private fun start(job: LatestSeekPreviewQueue.Job<Request>) {
        val expectedAttachment = attachment
        val jobCache = cache
        val application = context
        worker.execute {
            val frame = try {
                if (!allowed(job)) null else decode(
                    application.getDir("flutter", Context.MODE_PRIVATE), job, jobCache)
            } catch (_: Exception) { null }
            main.post {
                if (!attached || attachment != expectedAttachment) return@post
                val completed = queue.complete(job)
                settle(job, if (completed.deliver && allowed(job)) frame else null)
                completed.next?.let { start(it) }
            }
        }
    }

    private fun settle(job: LatestSeekPreviewQueue.Job<Request>, frame: Frame?) {
        job.payload.timeout?.let { main.removeCallbacks(it) }
        job.payload.timeout = null
        val result = job.payload.result ?: return
        job.payload.result = null
        result.success(frame?.let { mapOf("bytes" to it.bytes, "positionMs" to it.positionMs) })
    }

    private fun allowed(job: LatestSeekPreviewQueue.Job<Request>): Boolean =
        !job.cancelled && SystemClock.elapsedRealtime() < job.payload.deadline

    private fun decode(
        flutterDirectory: File,
        job: LatestSeekPreviewQueue.Job<Request>,
        cache: SeekPreviewCache,
    ): Frame? {
        val file = SeekPreviewInputs.privateFile(flutterDirectory, job.payload.path)
        if (!allowed(job)) return null
        // Refuse a substituted final-component symlink even after path validation.
        val descriptor = Os.open(file.path, OsConstants.O_RDONLY or OsConstants.O_CLOEXEC or OsConstants.O_NOFOLLOW, 0)
        try {
            val before = Os.fstat(descriptor)
            require(OsConstants.S_ISREG(before.st_mode) && before.st_size in 8..SeekPreviewInputs.MAX_FILE_BYTES)
            val header = ByteArray(8)
            require(Os.pread(descriptor, header, 0, header.size, 0) == header.size && SeekPreviewInputs.hasMp4Header(header))
            if (!allowed(job)) return null
            val retriever = MediaMetadataRetriever()
            try {
                retriever.setDataSource(descriptor, 0, before.st_size)
                if (!allowed(job)) return null
                val width = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: return null
                val height = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: return null
                val duration = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: return null
                require(SeekPreviewInputs.supportedSource(width, height))
                val position = SeekPreviewInputs.position(job.payload.positionMs, duration)
                val key = identity(file, before, position)
                // API 26 stat exposes only whole seconds; skip caching there rather
                // than risk a same-inode, same-size modification within one second.
                if (Build.VERSION.SDK_INT >= 27) cache.get(key)?.let {
                    if (allowed(job) && identity(file, Os.fstat(descriptor), position) == key) return Frame(it, position)
                }
                if (!allowed(job)) return null
                // Closest decoded frame (including non-keyframes) keeps the
                // picture near the seek target across sparse keyframe intervals.
                val frame = if (Build.VERSION.SDK_INT >= 27) {
                    retriever.getScaledFrameAtTime(position * 1000, MediaMetadataRetriever.OPTION_CLOSEST,
                        SeekPreviewInputs.MAX_WIDTH, SeekPreviewInputs.MAX_HEIGHT)
                } else {
                    // supportedSource checked above before this API 26 allocation.
                    retriever.getFrameAtTime(position * 1000, MediaMetadataRetriever.OPTION_CLOSEST)
                } ?: return null
                try {
                    if (!allowed(job) || !SeekPreviewInputs.supportedSource(frame.width, frame.height)) return null
                    // Android already applies the video's rotation metadata. Fit its
                    // returned display orientation; applying rotation again is wrong.
                    val (targetWidth, targetHeight) = SeekPreviewInputs.fit(frame.width, frame.height)
                    val thumbnail = if (frame.width == targetWidth && frame.height == targetHeight) frame
                        else Bitmap.createScaledBitmap(frame, targetWidth, targetHeight, true)
                    try {
                        if (!allowed(job)) return null
                        val output = LimitedJpegOutput()
                        require(thumbnail.compress(Bitmap.CompressFormat.JPEG, 75, output))
                        val bytes = output.toByteArray()
                        if (!allowed(job) || identity(file, Os.fstat(descriptor), position) != key) return null
                        if (Build.VERSION.SDK_INT >= 27) cache.put(key, bytes) { allowed(job) }
                        return Frame(bytes, position)
                    } finally { if (thumbnail !== frame) thumbnail.recycle() }
                } finally { frame.recycle() }
            } finally { try { retriever.release() } catch (_: Exception) { /* release attempted on every exit */ } }
        } finally { try { Os.close(descriptor) } catch (_: Exception) { /* no retained descriptor */ } }
    }

    private fun identity(file: File, stat: StructStat, position: Long) = SeekPreviewCacheKey(
        path = file.path, device = stat.st_dev, inode = stat.st_ino, size = stat.st_size,
        modifiedSeconds = stat.st_mtime, changedSeconds = stat.st_ctime, positionMs = position,
        modifiedNanos = if (Build.VERSION.SDK_INT >= 27) stat.st_mtim.tv_nsec else 0,
        changedNanos = if (Build.VERSION.SDK_INT >= 27) stat.st_ctim.tv_nsec else 0,
    )

    private class LimitedJpegOutput : ByteArrayOutputStream(16 * 1024) {
        override fun write(value: Int) {
            require(count < SeekPreviewInputs.MAX_JPEG_BYTES)
            super.write(value)
        }
        override fun write(value: ByteArray, offset: Int, length: Int) {
            require(length >= 0 && count <= SeekPreviewInputs.MAX_JPEG_BYTES - length)
            super.write(value, offset, length)
        }
    }

    private fun integer(value: Any?): Long? = when (value) {
        is Int -> value.toLong()
        is Long -> value
        else -> null
    }

    private fun badArguments(result: MethodChannel.Result) =
        result.error("BAD_PREVIEW_ARGUMENTS", "A private video, position and preview session are required", null)

    companion object { private const val CALLBACK_TIMEOUT_MS = 5000L }
}
