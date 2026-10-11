package iq.scanid.scan_id

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import kotlin.math.min

/** JPEG downsampling before a full-resolution raster is allocated. */
class NativeLargeJpegScaler(private val activity: Activity) {
    fun configure(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "scaleJpeg") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val bytes = call.argument<ByteArray>("bytes")
                val sourceWidth = call.argument<Int>("sourceWidth")
                val sourceHeight = call.argument<Int>("sourceHeight")
                val orientation = call.argument<Int>("orientation")
                val targetWidth = call.argument<Int>("targetWidth")
                val targetHeight = call.argument<Int>("targetHeight")
                val maxPixels = call.argument<Int>("maxPixels")
                if (bytes == null || sourceWidth == null || sourceHeight == null ||
                    orientation == null || targetWidth == null || targetHeight == null ||
                    maxPixels == null) {
                    result.error("invalid_request", "Missing image scaling parameters", null)
                    return@setMethodCallHandler
                }
                Thread {
                    try {
                        val png = scale(
                            bytes, sourceWidth, sourceHeight, orientation,
                            targetWidth, targetHeight, maxPixels,
                        )
                        activity.runOnUiThread { result.success(png) }
                    } catch (_: OutOfMemoryError) {
                        activity.runOnUiThread {
                            result.error(
                                "out_of_memory",
                                "Insufficient memory to process this JPEG safely.",
                                null,
                            )
                        }
                    } catch (_: Exception) {
                        activity.runOnUiThread {
                            result.error(
                                "scale_failed",
                                "The JPEG could not be sampled safely on this device.",
                                null,
                            )
                        }
                    }
                }.start()
            }
    }

    private fun scale(
        bytes: ByteArray,
        expectedWidth: Int,
        expectedHeight: Int,
        orientation: Int,
        targetWidth: Int,
        targetHeight: Int,
        maxPixels: Int,
    ): ByteArray {
        require(bytes.isNotEmpty() && bytes.size <= MAX_INPUT_BYTES)
        require(expectedWidth > 0 && expectedHeight > 0)
        require(expectedWidth.toLong() * expectedHeight <= MAX_SOURCE_PIXELS)
        require(orientation in 1..8)
        require(targetWidth > 0 && targetHeight > 0)
        require(targetWidth.toLong() * targetHeight <= MAX_WORKING_PIXELS)
        require(maxPixels.toLong() == targetWidth.toLong() * targetHeight)

        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        require(bounds.outWidth == expectedWidth && bounds.outHeight == expectedHeight)

        // BitmapFactory's JPEG decoder samples DCT blocks while decoding. Keep
        // that first bitmap <= 8 MP even when an odd aspect ratio means another
        // small resize is needed to meet the stricter 4 MP working cap.
        var sample = 1
        while (ceilDiv(expectedWidth, sample).toLong() *
            ceilDiv(expectedHeight, sample) > MAX_DECODED_PIXELS) {
            sample *= 2
        }
        val decoded = BitmapFactory.decodeByteArray(
            bytes,
            0,
            bytes.size,
            BitmapFactory.Options().apply {
                inSampleSize = sample
                inPreferredConfig = Bitmap.Config.ARGB_8888
                inScaled = false
                inDither = false
            },
        ) ?: error("JPEG decode failed")
        var working = decoded
        try {
            require(working.width.toLong() * working.height <= MAX_DECODED_PIXELS)
            val scaledWidth = min(targetWidth, working.width)
            val scaledHeight = min(targetHeight, working.height)
            if (scaledWidth != working.width || scaledHeight != working.height) {
                val smaller = Bitmap.createScaledBitmap(
                    working, scaledWidth, scaledHeight, true,
                )
                if (smaller !== working) working.recycle()
                working = smaller
            }
            val oriented = orient(working, orientation)
            if (oriented !== working) working.recycle()
            working = oriented
            require(working.width.toLong() * working.height <= maxPixels)
            require(
                previewShortSide(working.width, working.height) >= MIN_PREVIEW_SHORT_SIDE,
            ) { "The sampled JPEG is too small for the analysis preview." }

            val output = ByteArrayOutputStream()
            require(working.compress(Bitmap.CompressFormat.PNG, 100, output))
            val png = output.toByteArray()
            require(png.size <= MAX_OUTPUT_BYTES)
            return png
        } finally {
            if (!working.isRecycled) working.recycle()
        }
    }

    private fun orient(bitmap: Bitmap, orientation: Int): Bitmap {
        if (orientation == 1) return bitmap
        val width = bitmap.width.toFloat()
        val height = bitmap.height.toFloat()
        val values = when (orientation) {
            2 -> floatArrayOf(-1f, 0f, width, 0f, 1f, 0f, 0f, 0f, 1f)
            3 -> floatArrayOf(-1f, 0f, width, 0f, -1f, height, 0f, 0f, 1f)
            4 -> floatArrayOf(1f, 0f, 0f, 0f, -1f, height, 0f, 0f, 1f)
            5 -> floatArrayOf(0f, 1f, 0f, 1f, 0f, 0f, 0f, 0f, 1f)
            6 -> floatArrayOf(0f, -1f, height, 1f, 0f, 0f, 0f, 0f, 1f)
            7 -> floatArrayOf(0f, -1f, height, -1f, 0f, width, 0f, 0f, 1f)
            8 -> floatArrayOf(0f, 1f, 0f, -1f, 0f, width, 0f, 0f, 1f)
            else -> error("Invalid EXIF orientation")
        }
        return Bitmap.createBitmap(
            bitmap, 0, 0, bitmap.width, bitmap.height,
            Matrix().apply { setValues(values) }, true,
        )
    }

    private fun ceilDiv(value: Int, divisor: Int): Int =
        (value + divisor - 1) / divisor

    private fun previewShortSide(width: Int, height: Int): Int {
        val longEdge = maxOf(width, height)
        val shortEdge = minOf(width, height)
        return (shortEdge * min(1.0, MAX_PREVIEW_LONG_EDGE.toDouble() / longEdge))
            .toInt()
    }

    companion object {
        private const val CHANNEL = "iq.scanid/large_jpeg"
        private const val MAX_INPUT_BYTES = 20 * 1024 * 1024
        private const val MAX_OUTPUT_BYTES = 20 * 1024 * 1024
        private const val MAX_SOURCE_PIXELS = 32_000_000L
        private const val MAX_DECODED_PIXELS = 8_000_000L
        private const val MAX_WORKING_PIXELS = 4_000_000L
        private const val MAX_PREVIEW_LONG_EDGE = 1200
        private const val MIN_PREVIEW_SHORT_SIDE = 40
    }
}
