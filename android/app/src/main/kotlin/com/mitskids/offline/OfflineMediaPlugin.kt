package com.mitskids.offline

import android.content.Context
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Handler
import android.os.Build
import android.os.Looper
import android.os.StatFs
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.Executors

/** Combines local AVC/AAC tracks. No sockets, streaming URLs or transcoding. */
class OfflineMediaPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "mits_kids/offline_media")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        worker.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "availableBytes") {
            val path = call.argument<String>("path")
            if (path == null) {
                result.error("BAD_ARGUMENTS", "The private offline directory is required", null)
                return
            }
            worker.execute {
                try {
                    val directory = OfflineStoragePaths.directory(
                        context.getDir("flutter", Context.MODE_PRIVATE), path)
                    val available = StatFs(directory.path).availableBytes
                    check(available >= 0)
                    main.post { result.success(available) }
                } catch (_: Exception) {
                    result.errorOnMain("STORAGE_UNAVAILABLE", "Available private storage could not be checked")
                }
            }
            return
        }
        if (call.method != "mux") { result.notImplemented(); return }
        val video = call.argument<String>("video")
        val audio = call.argument<String>("audio")
        val output = call.argument<String>("output")
        if (video == null || audio == null || output == null) {
            result.error("BAD_ARGUMENTS", "Local paths are required", null)
            return
        }
        val checkApprovedJob = ApprovedDownloadJobs.cancellationCheck()
        worker.execute {
            try {
                checkApprovedJob()
                val v = privateFile(video)
                val a = privateFile(audio)
                val out = privateFile(output)
                require(v.isFile && a.isFile && !out.exists())
                require(v != out && a != out && v != a)
                require(v.length() + a.length() <= 1024L * 1024 * 1024)
                combine(v, a, out, checkApprovedJob)
                main.post { result.success(null) }
            } catch (error: Exception) {
                main.post { result.error("MUX_FAILED", error.javaClass.simpleName, null) }
            }
        }
    }

    private fun MethodChannel.Result.errorOnMain(code: String, message: String) {
        main.post { error(code, message, null) }
    }

    private fun privateFile(path: String): File {
        val file = File(path).canonicalFile
        val root = OfflineStoragePaths.directory(context.getDir("flutter", Context.MODE_PRIVATE))
        val staging = file.parentFile ?: error("Missing staging directory")
        require(staging.parentFile == root && staging.name.startsWith(".pending-")) {
            "Only private offline staging files are supported"
        }
        return file
    }

    private fun track(extractor: MediaExtractor, prefix: String): Int {
        for (i in 0 until extractor.trackCount) {
            val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: ""
            if (mime.startsWith(prefix)) return i
        }
        error("Missing $prefix track")
    }

    private fun combine(video: File, audio: File, output: File, checkApprovedJob: () -> Unit) {
        val v = MediaExtractor()
        val a = MediaExtractor()
        var muxer: MediaMuxer? = null
        var started = false
        var complete = false
        try {
            checkApprovedJob()
            v.setDataSource(video.path)
            a.setDataSource(audio.path)
            val vi = track(v, "video/")
            val ai = track(a, "audio/")
            val vf = v.getTrackFormat(vi)
            val af = a.getTrackFormat(ai)
            require(vf.getString(MediaFormat.KEY_MIME) == "video/avc")
            require(af.getString(MediaFormat.KEY_MIME) == "audio/mp4a-latm")
            v.selectTrack(vi)
            a.selectTrack(ai)
            val writer = MediaMuxer(output.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            muxer = writer
            val vo = writer.addTrack(vf)
            val ao = writer.addTrack(af)
            if (vf.containsKey(MediaFormat.KEY_ROTATION)) {
                writer.setOrientationHint(vf.getInteger(MediaFormat.KEY_ROTATION))
            }
            writer.start()
            started = true
            var buffer = ByteBuffer.allocateDirect(8 * 1024 * 1024)
            val info = MediaCodec.BufferInfo()
            var videoSamples = 0
            var audioSamples = 0
            var payloadBytes = 0L
            val deadline = System.nanoTime() + 120L * 1_000_000_000L
            while (v.sampleTime >= 0 || a.sampleTime >= 0) {
                checkApprovedJob()
                check(System.nanoTime() < deadline) { "Mux timed out" }
                val useVideo = a.sampleTime < 0 || (v.sampleTime >= 0 && v.sampleTime <= a.sampleTime)
                val input = if (useVideo) v else a
                val index = if (useVideo) vo else ao
                val size = if (Build.VERSION.SDK_INT >= 28) input.sampleSize else 0L
                require(size in 0..(32L * 1024 * 1024)) { "Invalid sample size" }
                if (buffer.capacity() < size) buffer = ByteBuffer.allocateDirect(size.toInt())
                buffer.clear()
                val read = input.readSampleData(buffer, 0)
                check(read > 0 && (size == 0L || read == size.toInt())) { "Truncated sample" }
                payloadBytes += read
                check(payloadBytes <= 1024L * 1024 * 1024) { "Media payload exceeds limit" }
                require((input.sampleFlags and MediaExtractor.SAMPLE_FLAG_ENCRYPTED) == 0) {
                    "Encrypted tracks are unsupported"
                }
                val flags = if ((input.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC) != 0)
                    MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
                info.set(0, read, input.sampleTime, flags)
                writer.writeSampleData(index, buffer, info)
                if (useVideo) videoSamples++ else audioSamples++
                input.advance()
            }
            check(videoSamples > 0 && audioSamples > 0)
            checkApprovedJob()
            writer.stop()
            started = false
            checkApprovedJob()
            complete = true
        } finally {
            if (started) try { muxer?.stop() } catch (_: Exception) { }
            try { muxer?.release() } finally { v.release(); a.release() }
            if (!complete) output.delete()
        }
    }
}
