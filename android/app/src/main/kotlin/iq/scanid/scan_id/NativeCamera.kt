package iq.scanid.scan_id

import android.app.Activity
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.provider.MediaStore
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID

class CaptureFileProvider : FileProvider()

class NativeCamera(private val activity: Activity) {
    private val preferences by lazy { activity.getSharedPreferences("pending_capture", Context.MODE_PRIVATE) }
    private var result: MethodChannel.Result? = null
    private fun file(id: String): File {
        require(Regex("[a-fA-F0-9-]{36}").matches(id))
        val folder = File(activity.filesDir, "captures").canonicalFile
        val file = File(folder, "$id.jpg")
        require(file.canonicalPath == file.absolutePath)
        return file
    }
    private fun describe(): Map<String, String>? {
        val id = preferences.getString("id", null) ?: return null
        val project = preferences.getString("projectId", null) ?: error("Capture journal incomplete")
        return mapOf("id" to id, "projectId" to project, "path" to file(id).path)
    }
    private fun discard(id: String) {
        require(id == preferences.getString("id", null))
        val photo = file(id)
        if (photo.exists()) check(photo.delete())
        check(preferences.edit().clear().commit())
    }
    fun configure(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "iq.scanid/camera").setMethodCallHandler { call, reply ->
            try {
                when (call.method) {
                    "pending" -> reply.success(describe())
                    "discard" -> { require(result == null); discard(call.argument<String>("id")!!); reply.success(null) }
                    "capture" -> {
                        if (preferences.contains("id") || result != null) { reply.error("pending", "Capture pending", null); return@setMethodCallHandler }
                        val project = call.argument<String>("projectId")!!
                        require(Regex("[a-zA-Z0-9_-]{1,80}").matches(project))
                        val intent = Intent(MediaStore.ACTION_IMAGE_CAPTURE)
                        require(intent.resolveActivity(activity.packageManager) != null)
                        require(activity.filesDir.usableSpace > 128L * 1024 * 1024)
                        val id = UUID.randomUUID().toString()
                        val photo = file(id)
                        photo.parentFile!!.mkdirs()
                        check(photo.createNewFile())
                        check(preferences.edit().putString("id", id).putString("projectId", project).commit())
                        val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.capture", photo)
                        intent.putExtra(MediaStore.EXTRA_OUTPUT, uri)
                        intent.clipData = ClipData.newRawUri("Scan ID capture", uri)
                        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                        result = reply
                        activity.startActivityForResult(intent, 7303)
                    }
                    else -> reply.notImplemented()
                }
            } catch (error: Exception) {
                if (result === reply) result = null
                // Keep the private file and durable journal when launch/IO fails.
                reply.error("camera", "Camera operation failed", null)
            }
        }
    }
    fun onResult(request: Int, status: Int): Boolean {
        if (request != 7303) return false
        val reply = result
        result = null
        try {
            val id = preferences.getString("id", null)
            if (id != null) {
                val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.capture", file(id))
                activity.revokeUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                if (status != Activity.RESULT_OK) { discard(id); reply?.success(null) }
                else { reply?.success(describe()) }
            } else { reply?.success(null) }
        } catch (error: Exception) { reply?.error("camera", "Capture could not be completed", null) }
        return true
    }
}
