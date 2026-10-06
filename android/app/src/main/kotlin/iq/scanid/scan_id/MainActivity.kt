package iq.scanid.scan_id

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
import java.util.UUID
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val camera by lazy { NativeCamera(this) }
    private var pending: MethodChannel.Result? = null
    private var source: File? = null
    private var pickLimit = 20L * 1024 * 1024
    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        camera.configure(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger, "iq.scanid/local_documents")
            .setMethodCallHandler { call, result ->
                if (call.method == "open") {
                    if (pending != null) { result.error("busy", "A document request is active", null); return@setMethodCallHandler }
                    try {
                        pickLimit = call.argument<Number>("maxBytes")!!.toLong()
                        require(pickLimit > 0 && pickLimit <= 64L * 1024 * 1024 * 1024 + 16 * 1024 * 1024 + 64)
                        pending = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = call.argument<String>("mime") ?: "application/octet-stream"
                            putExtra(Intent.EXTRA_LOCAL_ONLY, true)
                            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, call.argument<Boolean>("multiple") ?: false)
                        }
                        startActivityForResult(intent, 7302)
                    } catch (error: Exception) {
                        pending = null
                        result.error("open", "Unable to open local documents", null)
                    }
                    return@setMethodCallHandler
                }
                if (call.method == "share") {
                    try {
                        val sources = (call.argument<List<String>>("sources") ?: emptyList())
                            .map { exportFile(it) }
                        require(sources.isNotEmpty() && sources.size <= 200)
                        val mime = call.argument<String>("mime") ?: "application/octet-stream"
                        val uris = sources.map {
                            FileProvider.getUriForFile(this, "$packageName.exports", it)
                        }
                        val single = uris.size == 1
                        val intent = Intent(if (single) Intent.ACTION_SEND else Intent.ACTION_SEND_MULTIPLE).apply {
                            type = mime
                            putExtra(Intent.EXTRA_STREAM, if (single) uris.first() else ArrayList(uris))
                            putExtra(Intent.EXTRA_LOCAL_ONLY, true)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        // Read permission must cover every handed-over URI, also
                        // when the chooser forwards the intent.
                        val clip = ClipData.newUri(contentResolver, "exports", uris.first())
                        for (uri in uris.drop(1)) clip.addItem(ClipData.Item(uri))
                        intent.clipData = clip
                        val chooser = Intent.createChooser(intent, null)
                        chooser.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        startActivity(chooser)
                        result.success(true)
                    } catch (error: Exception) {
                        result.error("share", "Unable to share generated files", null)
                    }
                    return@setMethodCallHandler
                }
                if (call.method != "save") { result.notImplemented(); return@setMethodCallHandler }
                if (pending != null) { result.error("busy", "A document request is active", null); return@setMethodCallHandler }
                try {
                    val file = privateFile(call.argument<String>("source") ?: "")
                    source = file
                    pending = result
                    val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = call.argument<String>("mime") ?: "application/octet-stream"
                        putExtra(Intent.EXTRA_TITLE, File(call.argument<String>("name") ?: "document").name)
                        putExtra(Intent.EXTRA_LOCAL_ONLY, true)
                    }
                    startActivityForResult(intent, 7301)
                } catch (error: Exception) {
                    pending = null; source = null
                    result.error("save", "Unable to open local document destination", null)
                }
            }
    }
    /** A file the app owns and may read or hand over; anything else is refused. */
    private fun privateFile(raw: String): File {
        val file = File(raw).canonicalFile
        val allowed = listOf(filesDir.canonicalPath, cacheDir.canonicalPath)
        require(allowed.any { file.path.startsWith(it + File.separator) } && file.isFile)
        return file
    }

    /**
     * A generated export inside the dedicated export directory. The share
     * provider is scoped to exactly that directory, so the canonical check here
     * and the provider's declared path agree.
     */
    private fun exportFile(raw: String): File {
        val file = privateFile(raw)
        val exports = File(cacheDir, "scan-exports").canonicalFile
        require(file.path.startsWith(exports.path + File.separator))
        return file
    }

    @Deprecated("Activity callback used for the system document picker")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (camera.onResult(requestCode, resultCode)) return
        if (requestCode == 7302) {
            val result = pending ?: return
            if (resultCode != Activity.RESULT_OK || data == null) { pending = null; result.success(emptyList<Any>()); return }
            val uris = data.clipData?.let { clips -> (0 until clips.itemCount).map { clips.getItemAt(it).uri } } ?: listOfNotNull(data.data)
            if (uris.size > 200) { pending = null; result.error("limit", "Too many files", null); return }
            val limit = pickLimit
            Thread {
                val folder = File(cacheDir, "scan-picked-${UUID.randomUUID()}")
                try {
                    check(folder.mkdirs())
                    val selected = uris.map { uri ->
                        var name = "image"
                        val file = File(folder, UUID.randomUUID().toString())
                        try {
                            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                                if (cursor.moveToFirst()) name = cursor.getString(0) ?: name
                            }
                            name = name.replace("\u0000", "").take(160).ifBlank { "image" }
                            contentResolver.openInputStream(uri).use { input ->
                                require(input != null)
                                file.outputStream().use { output ->
                                    val buffer = ByteArray(65536)
                                    var total = 0L
                                    while (true) {
                                        val count = input.read(buffer)
                                        if (count < 0) break
                                        total += count
                                        require(total <= limit && cacheDir.usableSpace > 64L * 1024 * 1024)
                                        output.write(buffer, 0, count)
                                    }
                                }
                            }
                            mapOf("name" to name, "path" to file.path)
                        } catch (error: Exception) {
                            file.delete()
                            mapOf("name" to name, "error" to "تعذر قراءة الملف أو تجاوزه حد الحجم أو عدم كفاية المساحة.")
                        }
                    }
                    if (folder.listFiles()?.isEmpty() == true) folder.delete()
                    runOnUiThread { pending = null; result.success(selected) }
                } catch (error: Exception) {
                    folder.deleteRecursively()
                    runOnUiThread { pending = null; result.error("read", "Unable to read documents", null) }
                }
            }.start()
            return
        }
        if (requestCode != 7301) return
        val result = pending ?: return
        val file = source
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null || file == null) {
            pending = null; source = null; result.success(false); return
        }
        // Stream to the user-selected document. No broad storage permission or
        // image/PDF-sized MethodChannel byte buffer is needed.
        Thread {
            try {
                contentResolver.openOutputStream(uri, "wt").use { output ->
                    require(output != null)
                    file.inputStream().use { input -> input.copyTo(output) }
                }
                runOnUiThread { pending = null; source = null; result.success(true) }
            } catch (error: Exception) {
                runOnUiThread { pending = null; source = null; result.error("write", "Unable to write document", null) }
            }
        }.start()
    }
}
