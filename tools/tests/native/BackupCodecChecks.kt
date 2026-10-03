package com.mitskids.offline

import com.google.gson.GsonBuilder
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.file.Files
import java.security.MessageDigest
import java.security.SecureRandom

/** Real Tink/JCE/filesystem tests. Fixtures contain random bytes, not playable media. */
fun main() {
    val temporary = Files.createTempDirectory("mits-backup-codec-checks").toFile()
    val password = "correct multiword backup password".toCharArray()
    val json = GsonBuilder().disableHtmlEscaping().create()
    var checks = 0
    fun rejects(label: String, operation: () -> Unit) {
        var rejected = false
        try { operation() } catch (_: Exception) { rejected = true }
        check(rejected) { "Expected rejection: $label" }
        checks++
    }
    try {
        val media = File(temporary, "source.mp4")
        val data = ByteArray(2 * 1024 * 1024 + 79).also { SecureRandom().nextBytes(it) }
        media.writeBytes(data)
        val digest = MessageDigest.getInstance("SHA-256").digest(data).joinToString("") { "%02x".format(it) }
        val id = "abcdefghijk"
        val video = linkedMapOf<String, Any>("id" to id, "title" to "Private backup fixture title 395781",
            "author" to "Fixture channel", "channel_id" to "UCabcdefghijklmnopqrstuv",
            "source_url" to "https://www.youtube.com/watch?v=$id", "bytes" to media.length(), "sha256" to digest)
        val rules = mapOf("blockedChannels" to listOf("Blocked fixture"), "blockedKeywords" to listOf("example"),
            "blockShorts" to true, "blockLive" to true)
        val manifest = json.toJson(mapOf("version" to 1, "videos" to listOf(video), "rules" to rules)).toByteArray()
        val encrypted = ByteArrayOutputStream().also {
            BackupCodec.encrypt(manifest, mapOf(id to media), password, it)
        }.toByteArray()
        check(encrypted.copyOfRange(0, 8).contentEquals("MITSBKP1".toByteArray()))
        checks++
        check(!String(encrypted, Charsets.ISO_8859_1).contains(video["title"] as String))
        checks++
        fun restore(bytes: ByteArray, secret: CharArray = password, active: () -> Unit = {}): BackupCodec.Restored {
            val staging = Files.createTempDirectory(temporary.toPath(), "restore-").toFile()
            try { return BackupCodec.decrypt(ByteArrayInputStream(bytes), secret, staging, active) }
            catch (failure: Exception) {
                check(staging.list()?.isEmpty() == true) { "Rejected archive left plaintext files" }
                throw failure
            }
        }
        val restored = restore(encrypted)
        check(restored.manifest.videos.single().sha256 == digest && restored.files.getValue(id).readBytes().contentEquals(data))
        checks++
        rejects("wrong password") { restore(encrypted, "different multiword password".toCharArray()) }
        rejects("truncated final authentication tag") { restore(encrypted.copyOf(encrypted.size - 1)) }
        rejects("truncated middle segment") { restore(encrypted.copyOf(1024 * 1024)) }
        rejects("trailing ciphertext") { restore(encrypted + byteArrayOf(0)) }
        val changed = encrypted.copyOf().also { it[it.size / 2] = (it[it.size / 2].toInt() xor 1).toByte() }
        rejects("tampered ciphertext") { restore(changed) }
        val saltChanged = encrypted.copyOf().also { it[20] = (it[20].toInt() xor 1).toByte() }
        rejects("tampered authenticated header") { restore(saltChanged) }
        val versionChanged = encrypted.copyOf().also { it[9] = 2 }
        rejects("unknown version") { restore(versionChanged) }
        val excessiveCost = encrypted.copyOf().also { ByteBuffer.wrap(it).putInt(12, Int.MAX_VALUE) }
        rejects("unbounded KDF cost") { restore(excessiveCost) }
        val weakCost = encrypted.copyOf().also { ByteBuffer.wrap(it).putInt(12, 1) }
        rejects("weak KDF cost") { restore(weakCost) }
        val hugeKeyset = encrypted.copyOf().also { ByteBuffer.wrap(it).putInt(64, Int.MAX_VALUE) }
        rejects("unbounded keyset length") { restore(hugeKeyset) }
        var progress = 0
        rejects("cancel while restoring") { restore(encrypted, active = { if (++progress > 8) throw InterruptedException() }) }
        rejects("short password") { BackupCodec.encrypt(manifest, mapOf(id to media), "123456".toCharArray(), ByteArrayOutputStream()) }
        rejects("invalid surrogate password") { BackupCodec.encrypt(manifest, mapOf(id to media), ("a".repeat(20) + '\uD800').toCharArray(), ByteArrayOutputStream()) }
        val second = ByteArrayOutputStream().also { BackupCodec.encrypt(manifest, mapOf(id to media), password, it) }.toByteArray()
        check(!second.contentEquals(encrypted) && !second.copyOfRange(16, 64).contentEquals(encrypted.copyOfRange(16, 64)))
        checks++
        val empty = "{\"version\":1,\"videos\":[],\"rules\":null}".toByteArray()
        val emptyEncrypted = ByteArrayOutputStream().also { BackupCodec.encrypt(empty, emptyMap(), password, it) }.toByteArray()
        check(restore(emptyEncrypted).files.isEmpty())
        checks++
        val unicodePassword = "mångå ord för säker återställning".toCharArray()
        val unicodeEncrypted = ByteArrayOutputStream().also { BackupCodec.encrypt(empty, emptyMap(), unicodePassword, it) }.toByteArray()
        check(restore(unicodeEncrypted, unicodePassword).files.isEmpty())
        checks++
        rejects("duplicate JSON keys") { BackupManifest.parse(String(empty).replace("\"version\":1", "\"version\":1,\"version\":1").toByteArray()) }
        rejects("unknown secret field") { BackupManifest.parse(String(empty).replace("\"rules\":null", "\"rules\":null,\"pin\":\"123456\"").toByteArray()) }
        rejects("invalid UTF8") { BackupManifest.parse(byteArrayOf(0xC0.toByte(), 0xAF.toByte())) }
        rejects("duplicate videos") { BackupManifest.parse(json.toJson(mapOf("version" to 1, "videos" to listOf(video, video), "rules" to null)).toByteArray()) }
        rejects("ninth video") { BackupManifest.parse(json.toJson(mapOf("version" to 1, "videos" to List(9) { video }, "rules" to null)).toByteArray()) }
        rejects("oversized advertised media") { BackupManifest.parse(json.toJson(mapOf("version" to 1, "videos" to listOf(video + ("bytes" to Long.MAX_VALUE)), "rules" to null)).toByteArray()) }
        rejects("unsafe video identity") { BackupManifest.parse(String(manifest).replace(id, "../../hello").toByteArray()) }
        rejects("noncanonical URL") { BackupManifest.parse(String(manifest).replace("https://www.youtube.com/watch?v=", "http://www.youtube.com/watch?v=").toByteArray()) }
        rejects("oversized metadata") { BackupManifest.parse(ByteArray(BackupManifest.MAX_MANIFEST_BYTES + 1)) }
        rejects("fractional length") { BackupManifest.parse(String(manifest).replace("\"bytes\":${media.length()}", "\"bytes\":1.5").toByteArray()) }
        rejects("unknown rule fields") { BackupManifest.parse(String(manifest).replace("\"blockLive\":true", "\"blockLive\":true,\"allowEverything\":true").toByteArray()) }
        media.writeBytes(data.copyOf().also { it[0] = (it[0].toInt() xor 1).toByte() })
        rejects("changed source bytes") { BackupCodec.encrypt(manifest, mapOf(id to media), password, ByteArrayOutputStream()) }
    } finally {
        password.fill('\u0000')
        temporary.walkBottomUp().forEach { it.delete() }
    }
    println("$checks encrypted backup codec/manifest checks passed; SAF and Android codec checks remain separate.")
}
