package com.mitskids.offline

import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption
import kotlin.math.min

/** Limits shared by Android decoding and host tests; previews never accept staging/import paths. */
object SeekPreviewInputs {
    const val MAX_FILE_BYTES = 1024L * 1024 * 1024 + 16L * 1024 * 1024
    const val MAX_DURATION_MS = 86_400_000L
    const val MAX_WIDTH = 320
    const val MAX_HEIGHT = 180
    const val MAX_JPEG_BYTES = 128 * 1024
    private val readyName = Regex("^[A-Za-z0-9_-]{11}-[0-9]{16,20}\\.mp4$")

    fun privateFile(flutterDirectory: File, requestedPath: String): File {
        val requested = File(requestedPath)
        require(requested.isAbsolute && readyName.matches(requested.name))
        val root = OfflineStoragePaths.directory(flutterDirectory, requested.parent)
        require(!Files.isSymbolicLink(requested.toPath()))
        val canonical = requested.canonicalFile
        require(canonical.parentFile == root && canonical.name == requested.name)
        require(Files.isRegularFile(canonical.toPath(), LinkOption.NOFOLLOW_LINKS))
        require(canonical.length() in 8..MAX_FILE_BYTES)
        return canonical
    }

    fun position(positionMs: Long, durationMs: Long): Long {
        require(positionMs in 0..MAX_DURATION_MS)
        require(durationMs in 1..MAX_DURATION_MS)
        return min(positionMs, durationMs - 1)
    }

    /** Check before the API 26 fallback can allocate a full decoded frame. */
    fun supportedSource(width: Int, height: Int): Boolean =
        width in 1..4096 && height in 1..4096 &&
            min(width, height) <= 720 && width.toLong() * height <= 4096L * 720

    fun fit(width: Int, height: Int): Pair<Int, Int> {
        require(width > 0 && height > 0)
        val scale = min(1.0, min(MAX_WIDTH.toDouble() / width, MAX_HEIGHT.toDouble() / height))
        return maxOf(1, (width * scale).toInt()) to maxOf(1, (height * scale).toInt())
    }

    fun hasMp4Header(header: ByteArray): Boolean = header.size >= 8 &&
        header[4] == 'f'.code.toByte() && header[5] == 't'.code.toByte() &&
        header[6] == 'y'.code.toByte() && header[7] == 'p'.code.toByte() &&
        (((header[0].toLong() and 255) shl 24) or
            ((header[1].toLong() and 255) shl 16) or
            ((header[2].toLong() and 255) shl 8) or (header[3].toLong() and 255)) in 16..4096
}

/** Main-thread scheduling only. Cancellation never starts a second simultaneous platform decoder. */
class LatestSeekPreviewQueue<T> {
    class Job<T>(val session: Long, val request: Long, val payload: T) {
        @Volatile var cancelled = false
            internal set
    }
    data class Submitted<T>(val accepted: Job<T>?, val start: Job<T>?, val cancelled: List<Job<T>>)
    data class Completed<T>(val deliver: Boolean, val next: Job<T>?)

    private var session = 0L
    private var request = 0L
    private var disposed = false
    private var closed = false
    private var active: Job<T>? = null
    private var pending: Job<T>? = null

    fun submit(session: Long, request: Long, payload: T): Submitted<T> {
        if (closed || session <= 0 || request <= 0 || session < this.session ||
            (session == this.session && (disposed || request <= this.request))) {
            return Submitted(null, null, emptyList())
        }
        val cancelled = cancelJobs()
        if (session > this.session) { this.session = session; disposed = false }
        this.request = request
        val job = Job(session, request, payload)
        val start = if (active == null) { active = job; job } else { pending = job; null }
        return Submitted(job, start, cancelled)
    }

    fun cancel(session: Long, dispose: Boolean = false): List<Job<T>> {
        if (closed || session <= 0 || session < this.session) return emptyList()
        if (session > this.session) { this.session = session; request = 0; disposed = false }
        if (dispose) disposed = true
        return cancelJobs()
    }

    fun expire(job: Job<T>): Boolean {
        if ((active !== job && pending !== job) || job.cancelled) return false
        job.cancelled = true
        if (pending === job) pending = null
        return true
    }

    fun complete(job: Job<T>): Completed<T> {
        if (active !== job) return Completed(false, null)
        val deliver = !closed && !job.cancelled && job.session == session && job.request == request && !disposed
        active = null
        val next = pending?.takeUnless { closed || it.cancelled }
        pending = null
        active = next
        return Completed(deliver, next)
    }

    fun close(): List<Job<T>> { closed = true; return cancelJobs() }

    private fun cancelJobs(): List<Job<T>> {
        val cancelled = listOfNotNull(active, pending).filter { !it.cancelled }
        cancelled.forEach { it.cancelled = true }
        pending = null
        // A cancelled active decoder still owns the worker until complete().
        return cancelled
    }
}

/** Only compressed thumbnails are retained. The descriptor identity prevents path-replacement hits. */
data class SeekPreviewCacheKey(
    val path: String,
    val device: Long,
    val inode: Long,
    val size: Long,
    val modifiedSeconds: Long,
    val changedSeconds: Long,
    val positionMs: Long,
    val modifiedNanos: Long = 0,
    val changedNanos: Long = 0,
)

class SeekPreviewCache {
    private val entries = LinkedHashMap<SeekPreviewCacheKey, ByteArray>(8, 0.75f, true)
    private var bytes = 0

    @Synchronized fun get(key: SeekPreviewCacheKey): ByteArray? = entries[key]

    @Synchronized fun put(key: SeekPreviewCacheKey, value: ByteArray, allowed: () -> Boolean = { true }) {
        if (!allowed() || value.isEmpty() || value.size > SeekPreviewInputs.MAX_JPEG_BYTES) return
        entries.remove(key)?.let { bytes -= it.size }
        entries[key] = value
        bytes += value.size
        while (entries.size > 8 || bytes > 1024 * 1024) {
            val oldest = entries.entries.iterator()
            val entry = oldest.next()
            bytes -= entry.value.size
            oldest.remove()
        }
    }

    @Synchronized fun clear() { entries.clear(); bytes = 0 }
}
