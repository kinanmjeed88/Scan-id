package iq.scanid.scan_id

import android.app.Activity

/**
 * Decides whether a camera EXTRA_OUTPUT file is a photo the app should import.
 *
 * Some manufacturer camera apps write the JPEG then return RESULT_CANCELED.
 * The empty file created before launch is not a photo.
 */
object CaptureOutcome {
    const val MIN_OK_BYTES = 32L
    const val MIN_CANCELED_BYTES = 1024L

    fun shouldImport(resultCode: Int, fileLength: Long): Boolean {
        if (fileLength < MIN_OK_BYTES) return false
        if (resultCode == Activity.RESULT_OK) return true
        return fileLength >= MIN_CANCELED_BYTES
    }
}
