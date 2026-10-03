package com.mitskids.offline

import com.google.crypto.tink.Aead
import com.google.crypto.tink.InsecureSecretKeyAccess
import com.google.crypto.tink.KeysetHandle
import com.google.crypto.tink.RegistryConfiguration
import com.google.crypto.tink.StreamingAead
import com.google.crypto.tink.TinkProtoKeysetFormat
import com.google.crypto.tink.aead.AeadConfig
import com.google.crypto.tink.aead.AesGcmKey
import com.google.crypto.tink.aead.AesGcmParameters
import com.google.crypto.tink.streamingaead.PredefinedStreamingAeadParameters
import com.google.crypto.tink.streamingaead.StreamingAeadConfig
import com.google.crypto.tink.util.SecretBytes
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.EOFException
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.nio.CharBuffer
import java.nio.charset.CodingErrorAction
import java.nio.file.Files
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.PBEKeySpec

/** Streaming archive codec; callers own parent authority, private staging and publication. */
object BackupCodec {
    const val ITERATIONS = 600_000
    const val MAX_ITERATIONS = 2_000_000
    private const val HEADER_BYTES = 64
    private const val MAX_WRAPPED_KEYSET = 2048
    private val MAGIC = "MITSBKP1".toByteArray(Charsets.US_ASCII)
    private val PAYLOAD = "MITSARC1".toByteArray(Charsets.US_ASCII)
    private val COMPLETE = "MITSEND1".toByteArray(Charsets.US_ASCII)
    private val parameters = PredefinedStreamingAeadParameters.AES256_GCM_HKDF_1MB
    init { AeadConfig.register(); StreamingAeadConfig.register() }

    data class Restored(val manifest: BackupManifest, val files: Map<String, File>)

    fun encrypt(manifestBytes: ByteArray, files: Map<String, File>, password: CharArray,
        output: OutputStream, checkActive: () -> Unit = {}) {
        val manifest = BackupManifest.parse(manifestBytes)
        require(files.keys == manifest.videos.map { it.id }.toSet()) { "Backup source files do not match metadata" }
        validatePassword(password)
        checkActive()
        val salt = ByteArray(32).also { SecureRandom().nextBytes(it) }
        val archiveId = ByteArray(16).also { SecureRandom().nextBytes(it) }
        val prefix = ByteArrayOutputStream().also { bytes ->
            DataOutputStream(bytes).apply {
                write(MAGIC); writeShort(1); writeByte(1); writeByte(1)
                writeInt(ITERATIONS); write(salt); write(archiveId)
            }
        }.toByteArray()
        val wrapping = wrappingKey(password, salt, ITERATIONS)
        checkActive()
        val keyset = KeysetHandle.generateNew(parameters)
        val wrapped = TinkProtoKeysetFormat.serializeEncryptedKeyset(keyset, wrapping, prefix, RegistryConfiguration.get())
        require(wrapped.size in 1..MAX_WRAPPED_KEYSET)
        val header = ByteArrayOutputStream().also { bytes ->
            DataOutputStream(bytes).apply { write(prefix); writeInt(wrapped.size); write(wrapped) }
        }.toByteArray()
        output.write(header)
        val primitive = keyset.getPrimitive(RegistryConfiguration.get(), StreamingAead::class.java)
        DataOutputStream(primitive.newEncryptingStream(output, header)).use { encrypted ->
            encrypted.write(PAYLOAD); encrypted.writeInt(manifestBytes.size); encrypted.write(manifestBytes)
            for ((index, video) in manifest.videos.withIndex()) {
                checkActive()
                val file = files.getValue(video.id)
                require(!Files.isSymbolicLink(file.toPath()) && file.isFile && file.length() == video.bytes) { "Backup source changed" }
                encrypted.writeInt(index); encrypted.writeLong(video.bytes)
                val digest = MessageDigest.getInstance("SHA-256")
                file.inputStream().use { source ->
                    copyExactly(source, encrypted, video.bytes, digest, checkActive)
                    require(source.read() == -1) { "Backup source changed" }
                }
                require(digest.hex() == video.sha256) { "Backup source integrity failed" }
            }
            checkActive()
            encrypted.write(COMPLETE); encrypted.write(sha256(manifestBytes))
            encrypted.writeInt(manifest.videos.size); encrypted.writeLong(manifest.totalBytes)
        }
        checkActive()
    }

    fun decrypt(input: InputStream, password: CharArray, staging: File,
        checkActive: () -> Unit = {}, onManifest: (BackupManifest) -> Unit = {}): Restored {
        validatePassword(password)
        require(!Files.isSymbolicLink(staging.toPath()) && staging.isDirectory && staging.list()?.isEmpty() == true) {
            "An empty private backup staging directory is required"
        }
        val files = linkedMapOf<String, File>()
        try {
            checkActive()
            val raw = DataInputStream(input)
            val prefix = ByteArray(HEADER_BYTES).also { raw.readFully(it) }
            val fields = DataInputStream(ByteArrayInputStream(prefix))
            require(fields.readBytesExact(8).contentEquals(MAGIC)) { "Not a MITS encrypted backup" }
            require(fields.readUnsignedShort() == 1 && fields.readUnsignedByte() == 1 && fields.readUnsignedByte() == 1) { "Unsupported backup format" }
            val iterations = fields.readInt()
            require(iterations in ITERATIONS..MAX_ITERATIONS) { "Unsupported backup password cost" }
            val salt = fields.readBytesExact(32)
            fields.readBytesExact(16)
            val length = raw.readInt()
            require(length in 1..MAX_WRAPPED_KEYSET) { "Invalid backup key header" }
            val wrapped = raw.readBytesExact(length)
            val header = ByteArrayOutputStream().also { bytes ->
                DataOutputStream(bytes).apply { write(prefix); writeInt(length); write(wrapped) }
            }.toByteArray()
            val wrapping = wrappingKey(password, salt, iterations)
            checkActive()
            val keyset = TinkProtoKeysetFormat.parseEncryptedKeyset(wrapped, wrapping, prefix, RegistryConfiguration.get())
            require(keyset.size() == 1 && keyset.primary.key.parameters == parameters) { "Unsupported backup stream key" }
            val primitive = keyset.getPrimitive(RegistryConfiguration.get(), StreamingAead::class.java)
            val restored = DataInputStream(primitive.newDecryptingStream(raw, header)).use { plaintext ->
                require(plaintext.readBytesExact(8).contentEquals(PAYLOAD)) { "Invalid backup payload" }
                val manifestLength = plaintext.readInt()
                require(manifestLength in 1..BackupManifest.MAX_MANIFEST_BYTES) { "Invalid backup metadata size" }
                val manifestBytes = plaintext.readBytesExact(manifestLength)
                checkActive()
                val manifest = BackupManifest.parse(manifestBytes)
                onManifest(manifest)
                for ((index, video) in manifest.videos.withIndex()) {
                    checkActive()
                    require(plaintext.readInt() == index && plaintext.readLong() == video.bytes) { "Invalid backup record order or length" }
                    // Archive data never supplies a filesystem name.
                    val file = File(staging, "$index.mp4")
                    require(file.createNewFile()) { "Backup staging collision" }
                    files[video.id] = file
                    val digest = MessageDigest.getInstance("SHA-256")
                    file.outputStream().use { destination ->
                        copyExactly(plaintext, destination, video.bytes, digest, checkActive)
                    }
                    require(digest.hex() == video.sha256 && file.length() == video.bytes) { "Backup media integrity failed" }
                }
                require(plaintext.readBytesExact(8).contentEquals(COMPLETE)) { "Missing backup completion" }
                require(MessageDigest.isEqual(plaintext.readBytesExact(32), sha256(manifestBytes))) { "Backup metadata integrity failed" }
                require(plaintext.readInt() == manifest.videos.size && plaintext.readLong() == manifest.totalBytes) { "Backup completion mismatch" }
                // This final read authenticates Tink's terminal segment and rejects
                // trailing plaintext/ciphertext. Partial authenticated chunks never publish.
                require(plaintext.read() == -1) { "Unexpected trailing backup data" }
                checkActive()
                Restored(manifest, files.toMap())
            }
            return restored
        } catch (failure: Exception) {
            files.values.forEach { it.delete() }
            throw failure
        }
    }

    private fun validatePassword(password: CharArray) {
        require(Character.codePointCount(password, 0, password.size) >= 16) { "Use a separate backup password of at least 16 characters" }
        require(password.size <= 1024) { "Backup password is too long" }
        val bytes = Charsets.UTF_8.newEncoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT).encode(CharBuffer.wrap(password))
        require(bytes.remaining() <= 1024) { "Backup password is too long" }
        while (bytes.hasRemaining()) bytes.put(bytes.position(), 0).position(bytes.position() + 1)
    }

    private fun wrappingKey(password: CharArray, salt: ByteArray, iterations: Int): Aead {
        val spec = PBEKeySpec(password, salt, iterations, 256)
        val derived = try { SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).encoded }
            finally { spec.clearPassword() }
        try {
            val params = AesGcmParameters.builder().setKeySizeBytes(32).setIvSizeBytes(12)
                .setTagSizeBytes(16).setVariant(AesGcmParameters.Variant.NO_PREFIX).build()
            val key = AesGcmKey.builder().setParameters(params)
                .setKeyBytes(SecretBytes.copyFrom(derived, InsecureSecretKeyAccess.get())).build()
            return KeysetHandle.newBuilder().addEntry(KeysetHandle.importKey(key).withFixedId(1).makePrimary())
                .build().getPrimitive(RegistryConfiguration.get(), Aead::class.java)
        } finally { derived.fill(0) }
    }

    private fun copyExactly(input: InputStream, output: OutputStream, count: Long,
        digest: MessageDigest, checkActive: () -> Unit) {
        var remaining = count
        val buffer = ByteArray(128 * 1024)
        while (remaining > 0) {
            checkActive()
            val read = input.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
            if (read < 0) throw EOFException("Truncated backup data")
            require(read > 0) { "Backup stream made no progress" }
            checkActive()
            digest.update(buffer, 0, read)
            output.write(buffer, 0, read)
            remaining -= read
        }
    }
    private fun DataInputStream.readBytesExact(count: Int): ByteArray = ByteArray(count).also { readFully(it) }
    private fun sha256(bytes: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(bytes)
    private fun MessageDigest.hex(): String = digest().joinToString("") { "%02x".format(it) }
}
