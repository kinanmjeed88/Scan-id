package iq.scanid.scan_id

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest

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
 *
 * A matching digest only says the file arrived as published, because the release
 * feed supplies both the file and the digest. So the package is also checked
 * against an anchor this app does not download: the certificate of the app
 * already installed on this device, plus the fingerprint this build was compiled
 * with when it carries one. A package that fails, or that cannot be checked, is
 * refused here rather than handed to the installer.
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
        // Reading the signer out of a package of tens of megabytes is real work, so
        // it runs off the main thread and the installer is started back on it.
        // Nothing is offered to the system before the publisher check has answered.
        Thread {
            val refusal = publisherRefusal(packageFile)
            activity.runOnUiThread {
                if (refusal != null) {
                    reply.error(
                        "signature",
                        "Update package refused before the installer: $refusal",
                        null,
                    )
                } else {
                    startInstall(packageFile, reply)
                }
            }
        }.start()
    }

    /** The package passed the publisher check; ask the system to install it. */
    private fun startInstall(packageFile: File, reply: MethodChannel.Result) {
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
     * Why this package must not reach the installer, or `null` when it may.
     *
     * Two anchors, neither of them downloaded by the update flow:
     *  * the certificate the app installed on this device is signed with, read from
     *    the system, so an update has to carry the publisher of the app it replaces
     *    — a rotated key included, because Android records that lineage;
     *  * the fingerprint this build was compiled with (`EXPECTED_CERT_SHA256`, the
     *    value the release workflows compare the keystore and the built APK
     *    against), which decides even when the installed app cannot be read.
     *
     * A package that satisfies neither, that carries more than one current signer,
     * that names a different package, or that cannot be read at all, is refused.
     * An unknown answer is a refusal, never a pass.
     */
    private fun publisherRefusal(packageFile: File): String? {
        val archive = archiveInfo(packageFile) ?: return "unreadable package"
        val name = archive.packageName
        if (name != activity.packageName) return "package $name is not this app"
        val signers = currentSigners(archive) ?: return "no signer certificate"
        if (signers.size != 1) return "${signers.size} current signers"
        val fingerprint = fingerprintOf(signers[0]) ?: return "unreadable certificate"
        val pinned = pinnedFingerprint()
        if (pinned.isNotEmpty() && fingerprint != pinned) {
            return "signer $fingerprint is not the pinned release certificate"
        }
        val installed = installedFingerprints()
        if (installed == null) {
            // Nothing installed to compare with: the compiled pin decides.
            return if (pinned.isEmpty()) {
                "no publisher anchor is available to this build"
            } else {
                null
            }
        }
        if (fingerprint in installed) return null
        // A rotated key is legitimate only with the lineage Android recorded for it,
        // naming the certificate this installed app carries.
        if (pinned.isNotEmpty() && rotatedFrom(archive, installed)) return null
        return "signer $fingerprint did not sign the installed app"
    }

    /**
     * The archive read for its signer information only. Only paths inside the
     * update directory ever reach here, and only after [verifiedFile] accepted
     * them, so the file this reads is the file that would be installed.
     */
    private fun archiveInfo(file: File): PackageInfo? = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            activity.packageManager.getPackageArchiveInfo(
                file.path,
                PackageManager.GET_SIGNING_CERTIFICATES,
            )
        } else {
            @Suppress("DEPRECATION")
            activity.packageManager.getPackageArchiveInfo(
                file.path,
                PackageManager.GET_SIGNATURES,
            )
        }
    } catch (error: Exception) {
        null
    }

    /** The certificate that must be verified now, or null when unreadable. */
    private fun currentSigners(info: PackageInfo): Array<Signature>? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.signingInfo?.apkContentsSigners
        } else {
            @Suppress("DEPRECATION") info.signatures
        }

    /** Every certificate that ever signed this package, for a rotated key. */
    private fun pastSigners(info: PackageInfo): Array<Signature>? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.signingInfo?.signingCertificateHistory
        } else {
            null
        }

    private fun rotatedFrom(archive: PackageInfo, installed: Set<String>): Boolean {
        val history = pastSigners(archive) ?: return false
        return history.mapNotNull { fingerprintOf(it) }.any { it in installed }
    }

    /**
     * The fingerprints of the certificate the installed app is signed with. Null
     * when the system cannot answer, which is a missing anchor and not a match.
     */
    private fun installedFingerprints(): Set<String>? = try {
        @Suppress("DEPRECATION")
        val signatures = activity.packageManager.getPackageInfo(
            activity.packageName,
            PackageManager.GET_SIGNATURES,
        ).signatures
        signatures
            ?.mapNotNull { fingerprintOf(it) }
            ?.toSet()
            ?.takeIf { it.isNotEmpty() }
    } catch (error: Exception) {
        null
    }

    /** The pin compiled into this build, empty when this build carries none. */
    private fun pinnedFingerprint(): String =
        BuildConfig.EXPECTED_UPDATE_CERT_SHA256.trim().lowercase()

    /**
     * SHA-256 of the DER certificate — the value `apksigner --print-certs` reports
     * and the value [pinnedFingerprint] holds, so both readings agree.
     */
    private fun fingerprintOf(signature: Signature): String? = try {
        MessageDigest.getInstance("SHA-256")
            .digest(signature.toByteArray())
            .joinToString("") { byte -> "%02x".format(byte.toInt() and 0xff) }
    } catch (error: Exception) {
        null
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
