package iq.scanid.scan_id

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapRegionDecoder
import android.graphics.Matrix
import android.graphics.Rect
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import kotlin.math.max
import kotlin.math.min

/** JPEG sampling and bounded full-density region extraction before Dart decodes pixels. */
class NativeLargeJpegScaler(private val activity: Activity) {
    fun configure(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "scaleJpeg" -> scaleCall(call, result)
                    "cropJpegRegion" -> cropCall(call, result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun scaleCall(call: MethodCall, result: MethodChannel.Result) {
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
            return
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

    /**
     * Extracts exactly one measured region from the immutable, full-density JPEG.
     * The rectangle is normalized in the EXIF-oriented coordinate system used by
     * detection. BitmapRegionDecoder avoids handing Dart a complete 16–32 MP
     * source; no sampling is allowed here, so an over-budget region fails.
     */
    internal fun cropCall(call: MethodCall, result: MethodChannel.Result) {
        val bytes = call.argument<ByteArray>("bytes")
        val sourceWidth = call.argument<Int>("sourceWidth")
        val sourceHeight = call.argument<Int>("sourceHeight")
        val orientation = call.argument<Int>("orientation")
        val left = number(call, "left")
        val top = number(call, "top")
        val right = number(call, "right")
        val bottom = number(call, "bottom")
        val maxPixels = call.argument<Int>("maxPixels")
        if (bytes == null || sourceWidth == null || sourceHeight == null ||
            orientation == null || left == null || top == null || right == null ||
            bottom == null || maxPixels == null) {
            result.error("invalid_request", "Missing JPEG crop parameters", null)
            return
        }
        Thread {
            try {
                val png = cropRegion(
                    bytes,
                    sourceWidth,
                    sourceHeight,
                    orientation,
                    left,
                    top,
                    right,
                    bottom,
                    maxPixels,
                )
                activity.runOnUiThread { result.success(png) }
            } catch (_: CropTooLargeException) {
                activity.runOnUiThread {
                    result.error(
                        "crop_too_large",
                        "The full-resolution JPEG region exceeds the pixel budget.",
                        null,
                    )
                }
            } catch (_: OutOfMemoryError) {
                activity.runOnUiThread {
                    result.error(
                        "out_of_memory",
                        "Insufficient memory to extract this JPEG region safely.",
                        null,
                    )
                }
            } catch (_: Exception) {
                activity.runOnUiThread {
                    result.error(
                        "crop_failed",
                        "The JPEG region could not be extracted safely on this device.",
                        null,
                    )
                }
            }
        }.start()
    }

    private fun number(call: MethodCall, key: String): Double? =
        (call.argument<Number>(key))?.toDouble()

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

            return encodePng(working)
        } finally {
            if (!working.isRecycled) working.recycle()
        }
    }

    internal fun cropRegion(
        bytes: ByteArray,
        expectedWidth: Int,
        expectedHeight: Int,
        orientation: Int,
        left: Double,
        top: Double,
        right: Double,
        bottom: Double,
        maxPixels: Int,
    ): ByteArray {
        require(bytes.isNotEmpty() && bytes.size <= MAX_INPUT_BYTES)
        require(expectedWidth > 0 && expectedHeight > 0)
        require(expectedWidth.toLong() * expectedHeight <= MAX_SOURCE_PIXELS)
        require(orientation in 1..8)
        require(maxPixels == MAX_FULL_CROP_PIXELS)
        require(
            left.isFinite() && top.isFinite() && right.isFinite() && bottom.isFinite() &&
                left >= 0.0 && top >= 0.0 && right <= 1.0 && bottom <= 1.0 &&
                left < right && top < bottom,
        )

        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        require(bounds.outWidth == expectedWidth && bounds.outHeight == expectedHeight)
        val cropBounds = calculateJpegRegionCropBounds(
            expectedWidth,
            expectedHeight,
            orientation,
            left,
            top,
            right,
            bottom,
        )
        val area = cropBounds.rawWidth.toLong() * cropBounds.rawHeight
        if (area > maxPixels) throw CropTooLargeException()

        val decoder = BitmapRegionDecoder.newInstance(bytes, 0, bytes.size, false)
            ?: error("JPEG region decoder is unavailable")
        var working: Bitmap? = null
        try {
            require(decoder.width == expectedWidth && decoder.height == expectedHeight)
            working = decoder.decodeRegion(
                Rect(
                    cropBounds.rawLeft,
                    cropBounds.rawTop,
                    cropBounds.rawRight,
                    cropBounds.rawBottom,
                ),
                BitmapFactory.Options().apply {
                    inPreferredConfig = Bitmap.Config.ARGB_8888
                    inScaled = false
                    inDither = false
                },
            ) ?: error("JPEG region decode failed")
            require(working.width.toLong() * working.height <= maxPixels)
            val oriented = orient(working, orientation)
            if (oriented !== working) working.recycle()
            working = oriented
            require(working.width.toLong() * working.height <= maxPixels)
            return encodePng(working, rejectOversizeAsCrop = true)
        } finally {
            decoder.recycle()
            if (working != null && !working.isRecycled) working.recycle()
        }
    }

    private fun encodePng(
        bitmap: Bitmap,
        rejectOversizeAsCrop: Boolean = false,
    ): ByteArray {
        // Bitmap.compress writes incrementally. Bound its sink instead of
        // discovering a noisy 16 MP PNG exceeded transport after allocating an
        // unbounded byte array.
        val output = BoundedPngOutputStream(MAX_OUTPUT_BYTES)
        val compressed = try {
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)
        } catch (exception: Exception) {
            if (output.exceededLimit) {
                throwPngOutputTooLarge(rejectOversizeAsCrop)
            }
            throw exception
        }
        if (!compressed) {
            if (output.exceededLimit) {
                throwPngOutputTooLarge(rejectOversizeAsCrop)
            }
            throw IllegalArgumentException("PNG compression failed.")
        }
        return output.toByteArray()
    }

    private fun throwPngOutputTooLarge(rejectOversizeAsCrop: Boolean): Nothing {
        if (rejectOversizeAsCrop) throw CropTooLargeException()
        throw IllegalArgumentException("PNG output exceeds the transfer budget.")
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
        val longEdge = max(width, height)
        val shortEdge = min(width, height)
        return (shortEdge * min(1.0, MAX_PREVIEW_LONG_EDGE.toDouble() / longEdge))
            .toInt()
    }

    private class CropTooLargeException : IllegalArgumentException()

    private class PngOutputTooLargeException : IllegalArgumentException()

    private class BoundedPngOutputStream(private val limit: Int) : ByteArrayOutputStream() {
        var exceededLimit = false
            private set

        override fun write(oneByte: Int) {
            ensureCapacity(1)
            super.write(oneByte)
        }

        override fun write(bytes: ByteArray, offset: Int, length: Int) {
            ensureCapacity(length)
            super.write(bytes, offset, length)
        }

        private fun ensureCapacity(incoming: Int) {
            if (incoming < 0 || size() > limit - incoming) {
                exceededLimit = true
                throw PngOutputTooLargeException()
            }
        }
    }

    companion object {
        private const val CHANNEL = "iq.scanid/large_jpeg"
        private const val MAX_INPUT_BYTES = 20 * 1024 * 1024
        private const val MAX_OUTPUT_BYTES = 20 * 1024 * 1024
        private const val MAX_SOURCE_PIXELS = 32_000_000L
        private const val MAX_DECODED_PIXELS = 8_000_000L
        private const val MAX_WORKING_PIXELS = 4_000_000L
        private const val MAX_FULL_CROP_PIXELS = 16_000_000
        private const val MAX_PREVIEW_LONG_EDGE = 1200
        private const val MIN_PREVIEW_SHORT_SIDE = 40
    }
}
