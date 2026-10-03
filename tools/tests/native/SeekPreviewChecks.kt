package com.mitskids.offline

import java.io.File
import java.io.RandomAccessFile
import java.nio.file.Files

fun main() {
    var checks = 0
    fun verify(value: Boolean) { check(value); checks++ }
    fun rejects(block: () -> Unit) {
        var rejected = false
        try { block() } catch (_: IllegalArgumentException) { rejected = true }
        verify(rejected)
    }
    val temporary = Files.createTempDirectory("mits-seek-preview-checks").toFile()
    try {
        val flutter = File(temporary, "app_flutter").apply { mkdir() }
        val offline = File(flutter, "offline").apply { mkdir() }
        val videoName = "YE7VzlLtp-4-1789900000000000.mp4"
        val file = File(offline, videoName).apply { writeBytes(ByteArray(16)) }
        verify(SeekPreviewInputs.privateFile(flutter, file.path) == file.canonicalFile)
        rejects { SeekPreviewInputs.privateFile(flutter, videoName) }
        rejects { SeekPreviewInputs.privateFile(flutter, "https://example.invalid/$videoName") }
        rejects { SeekPreviewInputs.privateFile(flutter, File(temporary, videoName).apply { writeBytes(ByteArray(16)) }.path) }
        rejects { SeekPreviewInputs.privateFile(flutter, File(offline, "loose.mp4").apply { writeBytes(ByteArray(16)) }.path) }
        rejects { SeekPreviewInputs.privateFile(flutter, File(offline, "${videoName}.part").apply { writeBytes(ByteArray(16)) }.path) }
        rejects { SeekPreviewInputs.privateFile(flutter, File(File(offline, ".pending-a").apply { mkdir() }, videoName).apply { writeBytes(ByteArray(16)) }.path) }
        rejects { SeekPreviewInputs.privateFile(flutter, File(File(offline, ".restore-a").apply { mkdir() }, videoName).apply { writeBytes(ByteArray(16)) }.path) }
        val link = File(offline, "YE7VzlLtp-4-1789900000000001.mp4")
        Files.createSymbolicLink(link.toPath(), file.toPath())
        rejects { SeekPreviewInputs.privateFile(flutter, link.path) }
        val alias = File(temporary, "aliased-offline")
        Files.createSymbolicLink(alias.toPath(), offline.toPath())
        rejects { SeekPreviewInputs.privateFile(flutter, File(alias, videoName).path) }
        val directory = File(offline, "YE7VzlLtp-4-1789900000000002.mp4").apply { mkdir() }
        rejects { SeekPreviewInputs.privateFile(flutter, directory.path) }
        file.writeBytes(ByteArray(0))
        rejects { SeekPreviewInputs.privateFile(flutter, file.path) }
        RandomAccessFile(file, "rw").use { it.setLength(SeekPreviewInputs.MAX_FILE_BYTES + 1) }
        rejects { SeekPreviewInputs.privateFile(flutter, file.path) }
        file.delete()
    } finally {
        // Do not traverse the intentionally created symbolic links.
        Files.walk(temporary.toPath()).use { stream -> stream.sorted(Comparator.reverseOrder()).forEach { Files.delete(it) } }
    }

    verify(SeekPreviewInputs.position(0, 1000) == 0L)
    verify(SeekPreviewInputs.position(1000, 1000) == 999L)
    verify(SeekPreviewInputs.position(900, 1000) == 900L)
    verify(SeekPreviewInputs.position(SeekPreviewInputs.MAX_DURATION_MS, 1) == 0L)
    rejects { SeekPreviewInputs.position(-1, 1000) }
    rejects { SeekPreviewInputs.position(Long.MAX_VALUE, 1000) }
    rejects { SeekPreviewInputs.position(0, 0) }
    rejects { SeekPreviewInputs.position(0, SeekPreviewInputs.MAX_DURATION_MS + 1) }
    verify(SeekPreviewInputs.supportedSource(1280, 720))
    verify(SeekPreviewInputs.supportedSource(720, 1280))
    verify(SeekPreviewInputs.supportedSource(4096, 720))
    verify(!SeekPreviewInputs.supportedSource(4097, 720))
    verify(!SeekPreviewInputs.supportedSource(1920, 1080))
    verify(!SeekPreviewInputs.supportedSource(0, 720))
    verify(!SeekPreviewInputs.supportedSource(Int.MAX_VALUE, Int.MAX_VALUE))
    verify(SeekPreviewInputs.fit(1280, 720) == (320 to 180))
    verify(SeekPreviewInputs.fit(720, 1280) == (101 to 180))
    verify(SeekPreviewInputs.fit(720, 720) == (180 to 180))
    verify(SeekPreviewInputs.fit(100, 50) == (100 to 50))
    verify(SeekPreviewInputs.fit(4096, 1) == (320 to 1))
    rejects { SeekPreviewInputs.fit(0, 720) }
    verify(SeekPreviewInputs.hasMp4Header(byteArrayOf(0, 0, 0, 24, 102, 116, 121, 112)))
    verify(!SeekPreviewInputs.hasMp4Header(byteArrayOf(0, 0, 0, 8, 102, 116, 121, 112)))
    verify(!SeekPreviewInputs.hasMp4Header(byteArrayOf(0, 0, 0, 24, 102, 116, 121, 0)))
    verify(!SeekPreviewInputs.hasMp4Header(ByteArray(4)))

    // Rapid scrubbing keeps the physical decoder occupied by A until it returns,
    // immediately cancels callbacks A/B, and starts only newest request C next.
    val queue = LatestSeekPreviewQueue<String>()
    val a = queue.submit(1, 1, "A")
    verify(a.accepted != null && a.start === a.accepted && a.cancelled.isEmpty())
    val b = queue.submit(1, 2, "B")
    verify(b.start == null && b.cancelled == listOf(a.accepted))
    val c = queue.submit(1, 3, "C")
    verify(c.start == null && c.cancelled == listOf(b.accepted))
    verify(queue.submit(1, 3, "duplicate").accepted == null)
    verify(queue.submit(1, 2, "old").accepted == null)
    val afterA = queue.complete(a.accepted!!)
    verify(!afterA.deliver && afterA.next === c.accepted)
    verify(queue.complete(a.accepted).next == null) // duplicate completion is inert
    val afterC = queue.complete(c.accepted!!)
    verify(afterC.deliver && afterC.next == null)

    val d = queue.submit(1, 4, "D").accepted!!
    verify(queue.cancel(1) == listOf(d))
    verify(d.cancelled && queue.cancel(1).isEmpty())
    val e = queue.submit(1, 5, "E")
    verify(e.accepted != null && e.start == null)
    verify(queue.complete(d).next === e.accepted)
    verify(queue.complete(e.accepted!!).deliver)

    // A late cancel/dispose from a previous route cannot interrupt the new route.
    val old = queue.submit(1, 6, "old route").accepted!!
    val newer = queue.submit(2, 1, "new route")
    verify(newer.cancelled == listOf(old) && newer.start == null)
    verify(queue.cancel(1, dispose = true).isEmpty())
    verify(!newer.accepted!!.cancelled)
    verify(queue.submit(1, 7, "late old frame").accepted == null)
    verify(queue.complete(old).next === newer.accepted)
    verify(queue.complete(newer.accepted).deliver)
    verify(queue.cancel(2, dispose = true).isEmpty())
    verify(queue.submit(2, 2, "disposed route").accepted == null)
    verify(queue.submit(3, 1, "next route").start != null)

    // Timeout settles a callback; it does not pretend a stuck decoder has ended.
    val deadlines = LatestSeekPreviewQueue<String>()
    val active = deadlines.submit(1, 1, "active").accepted!!
    verify(deadlines.expire(active))
    verify(!deadlines.expire(active))
    val waiting = deadlines.submit(1, 2, "waiting")
    verify(waiting.start == null)
    verify(deadlines.expire(waiting.accepted!!))
    verify(deadlines.complete(active).next == null)
    val next = deadlines.submit(1, 3, "next")
    verify(next.start === next.accepted)
    val pending = deadlines.submit(1, 4, "pending")
    verify(deadlines.close() == listOf(pending.accepted))
    verify(!deadlines.complete(next.accepted!!).deliver)
    verify(deadlines.submit(2, 1, "after detach").accepted == null)
    verify(deadlines.cancel(2).isEmpty())
    verify(deadlines.complete(pending.accepted!!).next == null)

    val beforeFrame = LatestSeekPreviewQueue<String>()
    verify(beforeFrame.cancel(4, dispose = true).isEmpty())
    verify(beforeFrame.submit(4, 1, "late frame after dispose").accepted == null)
    verify(beforeFrame.submit(0, 1, "bad session").accepted == null)
    verify(beforeFrame.submit(5, 0, "bad request").accepted == null)
    verify(beforeFrame.submit(5, 1, "new session").start != null)

    val cache = SeekPreviewCache()
    val key = SeekPreviewCacheKey("/private/ready.mp4", 1, 2, 100, 3, 4, 50, 6, 7)
    cache.put(key, byteArrayOf(1, 2, 3))
    verify(cache.get(key)?.contentEquals(byteArrayOf(1, 2, 3)) == true)
    verify(cache.get(key.copy(inode = 3)) == null)
    verify(cache.get(key.copy(modifiedNanos = 7)) == null)
    verify(cache.get(key.copy(changedNanos = 8)) == null)
    verify(cache.get(key.copy(size = 101)) == null)
    verify(cache.get(key.copy(positionMs = 51)) == null)
    cache.clear()
    verify(cache.get(key) == null)
    cache.put(key, byteArrayOf(1)) { false }
    verify(cache.get(key) == null)
    cache.put(key, ByteArray(SeekPreviewInputs.MAX_JPEG_BYTES + 1))
    verify(cache.get(key) == null)
    cache.put(key, ByteArray(0))
    verify(cache.get(key) == null)
    for (i in 0L..7L) cache.put(key.copy(positionMs = i), ByteArray(SeekPreviewInputs.MAX_JPEG_BYTES))
    verify(cache.get(key.copy(positionMs = 0)) != null) // make 0 newest
    cache.put(key.copy(positionMs = 8), byteArrayOf(8))
    verify(cache.get(key.copy(positionMs = 1)) == null)
    verify(cache.get(key.copy(positionMs = 0)) != null)
    verify(cache.get(key.copy(positionMs = 8))?.contentEquals(byteArrayOf(8)) == true)

    println("$checks seek preview path, image bounds, scheduling and cache checks passed; Android frame decoding requires device validation.")
}
