package iq.scanid.scan_id

import android.app.Activity
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var pending: MethodChannel.Result? = null
    private var source: File? = null
    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger, "iq.scanid/local_documents")
            .setMethodCallHandler { call, result ->
                if (call.method != "save") { result.notImplemented(); return@setMethodCallHandler }
                if (pending != null) { result.error("busy", "A document request is active", null); return@setMethodCallHandler }
                try {
                    val file = File(call.argument<String>("source") ?: "").canonicalFile
                    val allowed = listOf(filesDir.canonicalPath, cacheDir.canonicalPath)
                    require(allowed.any { file.path.startsWith(it + File.separator) } && file.isFile)
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
    @Deprecated("Activity callback used for the system document picker")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
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
