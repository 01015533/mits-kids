package com.mitskids.offline

import com.google.gson.Strictness
import com.google.gson.stream.JsonReader
import com.google.gson.stream.JsonToken
import java.io.StringReader
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction

/** The portable archive contains only reviewed metadata, never paths or authority. */
data class BackupVideo(val id: String, val title: String, val author: String,
    val channelId: String, val sourceUrl: String, val bytes: Long, val sha256: String)

data class BackupManifest(val json: String, val videos: List<BackupVideo>) {
    val totalBytes: Long get() = videos.sumOf { it.bytes }

    companion object {
        const val MAX_MANIFEST_BYTES = 256 * 1024
        const val MAX_VIDEO_BYTES = 1024L * 1024 * 1024 + 16L * 1024 * 1024
        const val MAX_VIDEOS = 8
        private val videoId = Regex("^[A-Za-z0-9_-]{11}$")
        private val channelId = Regex("^UC[A-Za-z0-9_-]{22}$")
        private val hash = Regex("^[0-9a-f]{64}$")

        fun parse(bytes: ByteArray): BackupManifest {
            require(bytes.size in 1..MAX_MANIFEST_BYTES) { "Invalid backup metadata size" }
            val text = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString()
            val value = JsonReader(StringReader(text)).use { reader ->
                reader.strictness = Strictness.STRICT
                val parsed = readValue(reader, 0)
                require(reader.peek() == JsonToken.END_DOCUMENT) { "Trailing backup metadata" }
                parsed
            }
            val root = objectValue(value, setOf("version", "videos", "rules"))
            require(root["version"] == 1L) { "Unsupported backup metadata version" }
            val items = root["videos"] as? List<*> ?: error("Missing backup videos")
            require(items.size <= MAX_VIDEOS) { "Too many backup videos" }
            val videos = items.map { raw ->
                val item = objectValue(raw, setOf("id", "title", "author", "channel_id", "source_url", "bytes", "sha256"))
                val id = string(item, "id", 11)
                val channel = string(item, "channel_id", 24)
                val source = string(item, "source_url", 2048)
                val digest = string(item, "sha256", 64)
                val size = item["bytes"] as? Long ?: error("Invalid backup video size")
                require(videoId.matches(id) && channelId.matches(channel) && hash.matches(digest)) { "Invalid backup video identity" }
                require(source == "https://www.youtube.com/watch?v=$id") { "Invalid backup source URL" }
                require(size in 1..MAX_VIDEO_BYTES) { "Backup video is too large" }
                BackupVideo(id, string(item, "title", 4096), string(item, "author", 4096), channel, source, size, digest)
            }
            require(videos.map { it.id }.toSet().size == videos.size) { "Duplicate backup video" }
            root["rules"]?.let { raw ->
                val rules = objectValue(raw, setOf("blockedChannels", "blockedKeywords", "blockShorts", "blockLive"))
                require(rules["blockShorts"] is Boolean && rules["blockLive"] is Boolean) { "Invalid backup rules" }
                for (name in listOf("blockedChannels", "blockedKeywords")) {
                    val values = rules[name] as? List<*> ?: error("Invalid backup rules")
                    require(values.size <= 256)
                    values.forEach { require(it is String && validText(it, 1024)) { "Invalid backup rule" } }
                }
            }
            return BackupManifest(text, videos)
        }

        private fun objectValue(value: Any?, keys: Set<String>): Map<*, *> {
            val map = value as? Map<*, *> ?: error("Invalid backup metadata object")
            require(map.keys == keys) { "Unexpected backup metadata fields" }
            return map
        }

        private fun string(map: Map<*, *>, name: String, maxBytes: Int): String {
            val value = map[name] as? String ?: error("Invalid backup metadata string")
            require(validText(value, maxBytes)) { "Invalid backup metadata string" }
            return value
        }

        private fun validText(value: String, maxBytes: Int): Boolean = value.isNotBlank() &&
            value.toByteArray(Charsets.UTF_8).size <= maxBytes && value.none { it.code < 32 } &&
            Charsets.UTF_8.newEncoder().canEncode(value)

        private fun readValue(reader: JsonReader, depth: Int): Any? {
            require(depth <= 6) { "Backup metadata is too deeply nested" }
            return when (reader.peek()) {
                JsonToken.BEGIN_OBJECT -> {
                    val result = linkedMapOf<String, Any?>()
                    reader.beginObject()
                    while (reader.hasNext()) {
                        require(result.size < 32) { "Too many backup metadata fields" }
                        val name = reader.nextName()
                        require(!result.containsKey(name)) { "Duplicate backup metadata field" }
                        result[name] = readValue(reader, depth + 1)
                    }
                    reader.endObject()
                    result
                }
                JsonToken.BEGIN_ARRAY -> {
                    val result = mutableListOf<Any?>()
                    reader.beginArray()
                    while (reader.hasNext()) {
                        require(result.size < 256) { "Too many backup metadata entries" }
                        result.add(readValue(reader, depth + 1))
                    }
                    reader.endArray()
                    result
                }
                JsonToken.STRING -> reader.nextString()
                JsonToken.NUMBER -> {
                    val number = reader.nextString()
                    require(Regex("^(0|[1-9][0-9]{0,18})$").matches(number)) { "Invalid backup metadata number" }
                    number.toLong()
                }
                JsonToken.BOOLEAN -> reader.nextBoolean()
                JsonToken.NULL -> { reader.nextNull(); null }
                else -> error("Invalid backup metadata")
            }
        }
    }
}
