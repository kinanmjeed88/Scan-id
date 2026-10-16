package iq.scanid.scan_id

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Hands ONE verified update package to the system installer, read-only, and to
 * nothing else. Its scope is a single directory of the internal cache, which is
 * where a downloaded package is written and nowhere a project's images ever live
 * — so an install grant cannot be turned into a read grant on personal data.
 */
class UpdateFileProvider : FileProvider()

/**
 * The install half of the over-the-air update flow (`lib/application/ota_update.dart`).
 *
 * The app never writes to the device by itself. It starts the system
 * `ACTION_VIEW` install for a package whose SHA-256 digest was already verified,
 * and leaves the decision to the installer and to the person using the phone.
 * Android 8 and above refuse that intent unless this app has been allowed to
 * install apps, so a missing allowance opens that setting and answers with an
 * error code instead of failing silently.
 */
class UpdateInstaller(private val activity: Activity) {
    companion object {
        private const val DIRECTORY = "scan-updates"
        private const val PACKAGE_MIME = "application/vnd.android.package-archive"
    }

    fun configure(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "iq.scanid/updates")
            .setMethodCallHandler { call, reply ->
                if (call.method != "install") {
                    reply.notImplemented()
                    return@setMethodCallHandler
                }
                install(call.argument<String>("path") ?: "", reply)
            }
    }

    private fun install(raw: String, reply: MethodChannel.Result) {
        val packageFile = verifiedFile(raw)
        if (packageFile == null) {
            reply.error("missing", "The package is not a file in the update directory", null)
            return
        }
        if (!mayInstallPackages()) {
            openInstallPermissionSettings()
            reply.error("permission", "This app is not allowed to install apps yet", null)
            return
        }
        try {
            val uri = FileProvider.getUriForFile(
                activity,
                "${activity.packageName}.updates",
                packageFile,
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, PACKAGE_MIME)
                // The grant has to reach the installer through the chooser and
                // through anything it forwards, so the URI is also in the clip.
                clipData = ClipData.newUri(activity.contentResolver, "update", uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            activity.startActivity(intent)
            reply.success(true)
        } catch (error: ActivityNotFoundException) {
            reply.error("unavailable", "No package installer is available", null)
        } catch (error: Exception) {
            reply.error("install", "Unable to start the system installer", null)
        }
    }

    /**
     * A real file sitting directly inside the update directory of the internal
     * cache, canonicalised first so neither a symbolic link nor a `..` component
     * escapes it. `getCacheDir()` is the directory Flutter's
     * `getTemporaryDirectory()` returns on Android — the same one
     * `update_paths.xml` declares; anything else is refused, not installed.
     */
    private fun verifiedFile(raw: String): File? = try {
        val directory = File(activity.cacheDir, DIRECTORY).canonicalFile
        val file = File(raw).canonicalFile
        if (file.parentFile?.canonicalPath == directory.path && file.isFile) file else null
    } catch (error: Exception) {
        null
    }

    /** Below Android 8 there is no per-app install allowance to check. */
    private fun mayInstallPackages(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
        return activity.packageManager.canRequestPackageInstalls()
    }

    private fun openInstallPermissionSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        try {
            activity.startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:${activity.packageName}"),
                ),
            )
        } catch (error: Exception) {
            // A device without that screen must not turn a refusal into a crash;
            // the error code already tells the person what is missing.
        }
    }
}
