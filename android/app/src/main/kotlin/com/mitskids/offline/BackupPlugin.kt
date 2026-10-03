package com.mitskids.offline

import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.Intent
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import android.os.Bundle
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.StatFs
import android.provider.DocumentsContract
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/** SAF is limited to selected documents; no broad storage grant or media import. */
class BackupPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware,
    PluginRegistry.ActivityResultListener, Application.ActivityLifecycleCallbacks {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val epoch = AtomicLong()
    private var binding: ActivityPluginBinding? = null
    private var activity: Activity? = null
    private var application: Application? = null
    private var resumed = false
    private var picker: MethodChannel.Result? = null
    private var pickerExport = false
    private val selections = mutableMapOf<String, Selection>()
    private val jobs = mutableMapOf<String, File>()
    @Volatile private var active: Operation? = null

    private data class Selection(val uri: Uri, val export: Boolean)
    private class Operation(val requestedEpoch: Long, val token: String, val result: MethodChannel.Result) {
        val cancelled = AtomicBoolean(false)
        val completed = AtomicBoolean(false)
        val signal = CancellationSignal()
        @Volatile var descriptor: ParcelFileDescriptor? = null
        @Volatile var directory: File? = null
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "mits_kids/backup")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        cancelActive()
        discardJobs()
        selections.clear()
        channel.setMethodCallHandler(null)
        worker.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "chooseExport", "chooseRestore" -> choose(call.method == "chooseExport", result)
            "export", "inspect" -> start(call, result)
            "cancel" -> { cancelActive(); discardJobs(); result.success(null) }
            "discard" -> {
                val job = call.argument<String>("job")
                jobs.remove(job)?.let { deleteStaging(it) }
                result.success(null)
            }
            "forget" -> { selections.remove(call.argument<String>("handle")); result.success(null) }
            else -> result.notImplemented()
        }
    }

    private fun choose(export: Boolean, result: MethodChannel.Result) {
        val owner = activity
        if (owner == null || !resumed || picker != null || active != null) {
            result.error("BACKUP_BUSY", "Finish the current operation before selecting a backup", null)
            return
        }
        if (selections.size >= 4) selections.clear()
        picker = result
        pickerExport = export
        val intent = Intent(if (export) Intent.ACTION_CREATE_DOCUMENT else Intent.ACTION_OPEN_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE).setType("application/octet-stream")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or if (export) Intent.FLAG_GRANT_WRITE_URI_PERMISSION else 0)
        if (export) intent.putExtra(Intent.EXTRA_TITLE, "MITS-Kids-${System.currentTimeMillis()}.mitsbackup")
        try { owner.startActivityForResult(intent, REQUEST_DOCUMENT) }
        catch (_: Exception) {
            picker = null
            result.error("PICKER_UNAVAILABLE", "The Android document picker could not open", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_DOCUMENT) return false
        val result = picker ?: return true
        picker = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) { result.success(null); return true }
        if (uri.scheme != "content") {
            result.error("INVALID_DOCUMENT", "Choose a document through Android's document picker", null)
            return true
        }
        val handle = UUID.randomUUID().toString()
        selections[handle] = Selection(uri, pickerExport)
        // The result is an inert selection. It does not restore parent authority,
        // derive a password, or open the document's content.
        // A provider can block even a display-name query. Keep picker completion
        // local and immediate; the operation worker owns all provider I/O after
        // a deliberate start with freshly authenticated parent authority.
        result.success(mapOf("handle" to handle, "name" to
            if (pickerExport) "Selected backup destination" else "Selected backup archive"))
        return true
    }

    private fun start(call: MethodCall, result: MethodChannel.Result) {
        if (active != null || !resumed) { result.error("BACKUP_BUSY", "Unlock and finish the current backup operation first", null); return }
        val token = call.argument<String>("token") ?: ""
        try { ParentAuthority.requireToken(token) }
        catch (_: Exception) { result.error("LOCKED", "Unlock Parent again before continuing", null); return }
        val selection = selections[call.argument<String>("handle")]
        if (selection == null || selection.export != (call.method == "export")) {
            result.error("INVALID_DOCUMENT", "Select the backup document again", null); return
        }
        // A successful export must never be overwritten/deleted by a later retry.
        if (selection.export) selections.remove(call.argument<String>("handle"))
        val password = (call.argument<String>("password") ?: "").toCharArray()
        val operation = Operation(epoch.get(), token, result)
        active = operation
        val timeout = Runnable {
            if (!operation.completed.get()) {
                abort(operation)
                finish(operation, null, "BACKUP_TIMEOUT", "The backup operation timed out; existing library data is unchanged")
            }
        }
        main.postDelayed(timeout, OPERATION_MILLIS)
        worker.execute {
            var outputCreated = false
            var stagedJob: String? = null
            try {
                checkActive(operation)
                val root = OfflineStoragePaths.directory(context.getDir("flutter", Context.MODE_PRIVATE))
                val descriptor = context.contentResolver.openFileDescriptor(selection.uri,
                    if (selection.export) "w" else "r", operation.signal) ?: error("Document unavailable")
                operation.descriptor = descriptor
                checkActive(operation)
                val response: Map<String, Any> = if (selection.export) {
                    outputCreated = true
                    val json = call.argument<String>("manifest") ?: error("Missing backup metadata")
                    require(json.length <= BackupManifest.MAX_MANIFEST_BYTES)
                    val manifestBytes = json.toByteArray(Charsets.UTF_8)
                    val manifest = BackupManifest.parse(manifestBytes)
                    val sources = call.argument<List<Map<String, String>>>("files") ?: error("Missing backup files")
                    require(sources.size == manifest.videos.size)
                    val files = linkedMapOf<String, File>()
                    sources.forEach { source ->
                        val id = source["id"] ?: error("Missing backup video identity")
                        require(!files.containsKey(id))
                        val supplied = File(source["path"] ?: error("Missing private backup source"))
                        val file = supplied.canonicalFile
                        require(supplied.isAbsolute && !Files.isSymbolicLink(supplied.toPath()) &&
                            file.parentFile == root && file.isFile && GENERATED_MP4.matches(file.name)) { "Invalid private backup source" }
                        files[id] = file
                    }
                    ParcelFileDescriptor.AutoCloseOutputStream(descriptor).use { destination ->
                        BackupCodec.encrypt(manifestBytes, files, password, destination) { checkActive(operation) }
                    }
                    mapOf("bytes" to manifest.totalBytes)
                } else {
                    val job = UUID.randomUUID().toString()
                    val staging = File(root, ".restore-$job")
                    require(staging.mkdir())
                    operation.directory = staging
                    var checkpoints = 0
                    val restored = ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { source ->
                        BackupCodec.decrypt(source, password, staging, checkActive = {
                            checkActive(operation)
                            if (++checkpoints % 64 == 0) require(StatFs(root.path).availableBytes >= RESERVE_BYTES) { "Private storage is low" }
                        }, onManifest = { manifest ->
                            require(StatFs(root.path).availableBytes >= manifest.totalBytes + RESERVE_BYTES) { "Not enough private storage for this backup" }
                        })
                    }
                    restored.files.values.forEach { file -> validateMedia(file) { checkActive(operation) } }
                    checkActive(operation)
                    stagedJob = job
                    mapOf("job" to job, "manifest" to restored.manifest.json,
                        "files" to restored.files.map { (id, file) -> mapOf("id" to id, "path" to file.path) })
                }
                checkActive(operation)
                val finalJob = stagedJob
                main.post {
                    try {
                        checkActive(operation)
                        if (finalJob != null) operation.directory?.let { jobs[finalJob] = it }
                        finish(operation, response)
                    } catch (_: Exception) {
                        operation.directory?.let { deleteStaging(it) }
                        finish(operation, null, "LOCKED", "Parent access was locked; inspect the backup again")
                    }
                }
            } catch (_: Exception) {
                operation.directory?.let { deleteStaging(it) }
                if (outputCreated) try { DocumentsContract.deleteDocument(context.contentResolver, selection.uri) } catch (_: Exception) { }
                main.post { finish(operation, null, "BACKUP_FAILED", "Backup could not complete. Check the password, archive and available storage. An incomplete export may need deleting from its selected folder.") }
            } finally {
                password.fill('\u0000')
                try { operation.descriptor?.close() } catch (_: Exception) { }
                operation.descriptor = null
                main.removeCallbacks(timeout)
            }
        }
    }

    private fun checkActive(operation: Operation) {
        check(!operation.cancelled.get() && operation.requestedEpoch == epoch.get()) { "Backup cancelled" }
        ParentAuthority.requireToken(operation.token)
    }

    private fun finish(operation: Operation, value: Any?, code: String? = null, message: String? = null) {
        if (!operation.completed.compareAndSet(false, true)) return
        if (active === operation) active = null
        if (code == null) operation.result.success(value) else operation.result.error(code, message, null)
    }

    private fun abort(operation: Operation) {
        operation.cancelled.set(true)
        operation.signal.cancel()
        try { operation.descriptor?.close() } catch (_: Exception) { }
    }

    private fun cancelActive() {
        epoch.incrementAndGet()
        active?.let { abort(it) }
    }

    private fun discardJobs() {
        jobs.values.toList().forEach { deleteStaging(it) }
        jobs.clear()
    }

    private fun deleteStaging(directory: File) {
        // Only directories created by this plugin enter jobs/operation.directory.
        if (Files.isSymbolicLink(directory.toPath())) { directory.delete(); return }
        directory.listFiles()?.forEach { if (!it.isDirectory || Files.isSymbolicLink(it.toPath())) it.delete() }
        directory.delete()
    }

    private fun validateMedia(file: File, checkActive: () -> Unit) {
        file.inputStream().use { source ->
            val header = java.io.DataInputStream(source)
            val size = header.readInt()
            val kind = ByteArray(4).also { header.readFully(it) }
            require(size in 16..4096 && size.toLong() <= file.length() &&
                kind.contentEquals("ftyp".toByteArray(Charsets.US_ASCII))) { "Backup video must be an MP4 file" }
        }
        val extractor = MediaExtractor()
        try {
            file.inputStream().use { source ->
                extractor.setDataSource(source.fd)
                require(extractor.trackCount == 2) { "Backup video must contain one AVC and one AAC track" }
                var video = 0
                var audio = 0
                for (index in 0 until extractor.trackCount) {
                    checkActive()
                    val format = extractor.getTrackFormat(index)
                    val duration = if (format.containsKey(MediaFormat.KEY_DURATION)) format.getLong(MediaFormat.KEY_DURATION) else 0L
                    require(duration in 1..86_400_000_000L) { "Invalid backup media duration" }
                    when (format.getString(MediaFormat.KEY_MIME)) {
                        "video/avc" -> {
                            video++
                            require(format.getInteger(MediaFormat.KEY_HEIGHT) in 1..720 && format.getInteger(MediaFormat.KEY_WIDTH) in 1..4096)
                        }
                        "audio/mp4a-latm" -> audio++
                        else -> error("Unsupported backup media track")
                    }
                }
                require(video == 1 && audio == 1)
            }
        } finally { extractor.release() }
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        this.binding = binding
        activity = binding.activity
        application = binding.activity.application
        binding.addActivityResultListener(this)
        application?.registerActivityLifecycleCallbacks(this)
    }
    override fun onDetachedFromActivity() {
        cancelActive(); discardJobs()
        binding?.removeActivityResultListener(this)
        application?.unregisterActivityLifecycleCallbacks(this)
        picker?.error("PICKER_INTERRUPTED", "Select the document again after unlocking", null)
        picker = null
        binding = null; activity = null; application = null; resumed = false
    }
    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onActivityPaused(value: Activity) {
        if (value === activity) { resumed = false; cancelActive(); discardJobs() }
    }
    override fun onActivityResumed(value: Activity) { if (value === activity) resumed = true }
    override fun onActivityCreated(value: Activity, state: Bundle?) {}
    override fun onActivityStarted(value: Activity) {}
    override fun onActivityStopped(value: Activity) {}
    override fun onActivitySaveInstanceState(value: Activity, state: Bundle) {}
    override fun onActivityDestroyed(value: Activity) {}

    companion object {
        private const val REQUEST_DOCUMENT = 49381
        private const val OPERATION_MILLIS = 5L * 60 * 1000
        private const val RESERVE_BYTES = 128L * 1024 * 1024
        private val GENERATED_MP4 = Regex("^[A-Za-z0-9_-]{11}-[0-9]{16,20}\\.mp4$")
    }
}
