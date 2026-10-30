package iq.scanid.scan_id

import android.app.Activity
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.os.SystemClock
import android.util.Log
import androidx.test.runner.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** Exercises the production native call and Android's real BitmapRegionDecoder. */
@RunWith(AndroidJUnit4::class)
class NativeLargeJpegScalerInstrumentationTest {
    private lateinit var activity: Activity

    @Before
    fun launchAppActivity() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val intent = Intent(
            instrumentation.targetContext,
            MainActivity::class.java,
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        activity = instrumentation.startActivitySync(intent)
    }

    @After
    fun closeAppActivity() {
        activity.runOnUiThread { activity.finish() }
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
    }

    @Test
    fun exifOrientationsAndRoundedEdgeRegionsMatchPixelOracle() {
        val width = 320
        val height = 240
        val baseJpeg = makePatternJpeg(width, height)
        val requests = listOf(
            CropRequest("full", 0.0, 0.0, 1.0, 1.0),
            CropRequest("fractional", 0.201, 0.127, 0.701, 0.873),
            CropRequest("top-left-edge", 0.0, 0.0, 0.25, 0.25),
            CropRequest("bottom-right-edge", 0.75, 0.75, 1.0, 1.0),
        )

        for (orientation in 1..8) {
            val source = withExifOrientation(baseJpeg, orientation)
            val sourceHash = sha256(source)
            val raw = requireNotNull(
                BitmapFactory.decodeByteArray(source, 0, source.size),
            ) { "raw JPEG decode, EXIF $orientation" }
            assertEquals("raw width, EXIF $orientation", width, raw.width)
            assertEquals("raw height, EXIF $orientation", height, raw.height)
            try {
                for (request in requests) {
                    verifyRegion(
                        caseName = "orientation-$orientation-${request.name}",
                        source = source,
                        raw = raw,
                        sourceWidth = width,
                        sourceHeight = height,
                        orientation = orientation,
                        request = request,
                        expectedSourceHash = sourceHash,
                    )
                }
            } finally {
                raw.recycle()
            }
        }
    }

    @Test
    fun invalidBoundsAndMalformedJpegsReturnNativeErrorsWithoutMutatingInput() {
        val source = makePatternJpeg(320, 240)
        val sourceHash = sha256(source)
        val invalidRequests = listOf(
            CropRequest("negative-left", -0.01, 0.0, 0.5, 0.5),
            CropRequest("right-out-of-range", 0.0, 0.0, 1.01, 0.5),
            CropRequest("inverted-horizontal", 0.7, 0.0, 0.3, 0.5),
            CropRequest("non-finite", 0.0, 0.0, Double.NaN, 0.5),
        )

        for (request in invalidRequests) {
            val result = invokeCrop(
                source,
                320,
                240,
                1,
                request,
            )
            assertEquals(request.name, "crop_failed", result.errorCode)
            assertNull(request.name, result.value)
            assertEquals(request.name, sourceHash, sha256(source))
            recordMetric(
                "case=invalid-${request.name} nativeError=${result.errorCode} " +
                    "sourceUnchanged=${sourceHash == sha256(source)}",
            )
        }

        val malformed = byteArrayOf(0x01, 0x02, 0x03, 0x04)
        val malformedHash = sha256(malformed)
        val malformedResult = invokeCrop(
            malformed,
            320,
            240,
            1,
            CropRequest("full", 0.0, 0.0, 1.0, 1.0),
        )
        assertEquals("crop_failed", malformedResult.errorCode)
        assertNull(malformedResult.value)
        assertEquals(malformedHash, sha256(malformed))

        // A SOF-bearing but scan-data-free JPEG reaches the decoder path and
        // must fail safely rather than returning a plausible-looking bitmap.
        val truncated = jpegSofOnly(320, 240)
        val truncatedHash = sha256(truncated)
        val truncatedResult = invokeCrop(
            truncated,
            320,
            240,
            1,
            CropRequest("full", 0.0, 0.0, 1.0, 1.0),
        )
        assertEquals("crop_failed", truncatedResult.errorCode)
        assertNull(truncatedResult.value)
        assertEquals(truncatedHash, sha256(truncated))
        recordMetric(
            "case=malformed-jpegs errors=${malformedResult.errorCode}," +
                "${truncatedResult.errorCode} sourceBytesUnchanged=true",
        )
    }

    @Test
    fun exactlySixteenMegapixelsRunsAtFullSizeAndOverBudgetRegionIsRefused() {
        val acceptedSource = makeSolidJpeg(4000, 4000)
        val acceptedHash = sha256(acceptedSource)
        val start = SystemClock.elapsedRealtime()
        val accepted = invokeCrop(
            acceptedSource,
            4000,
            4000,
            1,
            CropRequest("full", 0.0, 0.0, 1.0, 1.0),
            timeoutSeconds = 90,
        )
        val elapsedMs = SystemClock.elapsedRealtime() - start
        assertNull(accepted.errorCode)
        val png = requireNotNull(accepted.value as? ByteArray) {
            "16 MP result must be PNG bytes"
        }
        val dimensions = pngDimensions(png)
        assertEquals(4000, dimensions.first)
        assertEquals(4000, dimensions.second)
        assertEquals("source JPEG is immutable", acceptedHash, sha256(acceptedSource))
        recordMetric(
            "case=budget-16000000 source=4000x4000 exif=1 rawDecoder=" +
                "[0,0,4000,4000] output=${dimensions.first}x${dimensions.second} " +
                "pngBytes=${png.size} sourceUnchanged=true elapsedMs=$elapsedMs",
        )

        val refusedSource = makeSolidJpeg(4001, 4000)
        val refusedHash = sha256(refusedSource)
        val refused = invokeCrop(
            refusedSource,
            4001,
            4000,
            1,
            CropRequest("full", 0.0, 0.0, 1.0, 1.0),
        )
        assertEquals("crop_too_large", refused.errorCode)
        assertTrue(refused.errorMessage.orEmpty().contains("pixel budget"))
        assertNull(refused.value)
        assertEquals("over-budget source is immutable", refusedHash, sha256(refusedSource))
        recordMetric(
            "case=budget-16004000 source=4001x4000 exif=1 " +
                "nativeError=${refused.errorCode} sourceUnchanged=true",
        )
    }

    @Test
    fun boundedPngFailureReleasesTheNativePathForTheNextCrop() {
        val noisySource = makeNoiseJpeg(3400, 3000, quality = 70)
        assertTrue(
            "synthetic JPEG fixture must stay inside the native input budget",
            noisySource.size < 20 * 1024 * 1024,
        )
        val sourceHash = sha256(noisySource)
        val start = SystemClock.elapsedRealtime()
        val oversizedPng = invokeCrop(
            noisySource,
            3400,
            3000,
            1,
            CropRequest("full", 0.0, 0.0, 1.0, 1.0),
            timeoutSeconds = 90,
        )
        val elapsedMs = SystemClock.elapsedRealtime() - start
        assertEquals("crop_too_large", oversizedPng.errorCode)
        assertNull(oversizedPng.value)
        assertEquals(sourceHash, sha256(noisySource))
        recordMetric(
            "case=bounded-png-rejection source=3400x3000 sourceBytes=" +
                "${noisySource.size} nativeError=${oversizedPng.errorCode} " +
                "sourceUnchanged=true elapsedMs=$elapsedMs",
        )

        val smallSource = makePatternJpeg(320, 240)
        val smallHash = sha256(smallSource)
        val recovered = invokeCrop(
            smallSource,
            320,
            240,
            1,
            CropRequest("full", 0.0, 0.0, 1.0, 1.0),
        )
        assertNull(recovered.errorCode)
        val recoveredPng = requireNotNull(recovered.value as? ByteArray)
        assertEquals(320 to 240, pngDimensions(recoveredPng))
        assertEquals(smallHash, sha256(smallSource))
        recordMetric(
            "case=success-after-bounded-png-rejection output=320x240 " +
                "sourceUnchanged=true",
        )
    }

    private fun verifyRegion(
        caseName: String,
        source: ByteArray,
        raw: Bitmap,
        sourceWidth: Int,
        sourceHeight: Int,
        orientation: Int,
        request: CropRequest,
        expectedSourceHash: String,
    ) {
        val productionBounds = calculateJpegRegionCropBounds(
            sourceWidth,
            sourceHeight,
            orientation,
            request.left,
            request.top,
            request.right,
            request.bottom,
        )
        val oracleBounds = oracleRawBounds(
            sourceWidth,
            sourceHeight,
            orientation,
            request,
        )
        assertEquals("$caseName raw left", oracleBounds[0], productionBounds.rawLeft)
        assertEquals("$caseName raw top", oracleBounds[1], productionBounds.rawTop)
        assertEquals("$caseName raw right", oracleBounds[2], productionBounds.rawRight)
        assertEquals("$caseName raw bottom", oracleBounds[3], productionBounds.rawBottom)
        assertTrue(productionBounds.rawLeft in 0 until sourceWidth)
        assertTrue(productionBounds.rawTop in 0 until sourceHeight)
        assertTrue(productionBounds.rawRight in 1..sourceWidth)
        assertTrue(productionBounds.rawBottom in 1..sourceHeight)

        val start = SystemClock.elapsedRealtime()
        val result = invokeCrop(
            source,
            sourceWidth,
            sourceHeight,
            orientation,
            request,
        )
        val elapsedMs = SystemClock.elapsedRealtime() - start
        assertNull("$caseName native error: ${result.errorMessage}", result.errorCode)
        val png = requireNotNull(result.value as? ByteArray) {
            "$caseName native result must be PNG"
        }
        val dimensions = pngDimensions(png)
        assertEquals("$caseName output width", productionBounds.outputWidth, dimensions.first)
        assertEquals("$caseName output height", productionBounds.outputHeight, dimensions.second)

        val actual = requireNotNull(BitmapFactory.decodeByteArray(png, 0, png.size)) {
            "$caseName output PNG decodes"
        }
        val expected = oracleCrop(
            raw,
            sourceWidth,
            sourceHeight,
            orientation,
            productionBounds,
        )
        try {
            assertEquals("$caseName pixel width", expected.width, actual.width)
            assertEquals("$caseName pixel height", expected.height, actual.height)
            val alignment = bestPixelAlignment(actual, expected)
            assertEquals(
                "$caseName pixel-boundary deviation X; best reference offset=${alignment.dx}",
                0,
                alignment.dx,
            )
            assertEquals(
                "$caseName pixel-boundary deviation Y; best reference offset=${alignment.dy}",
                0,
                alignment.dy,
            )
            val sourceUnchanged = expectedSourceHash == sha256(source)
            assertTrue("$caseName source bytes must remain immutable", sourceUnchanged)
            recordMetric(
                "case=$caseName source=${sourceWidth}x$sourceHeight exif=$orientation " +
                    "request=[${request.left},${request.top},${request.right},${request.bottom}] " +
                    "oriented=[${productionBounds.orientedLeft},${productionBounds.orientedTop}," +
                    "${productionBounds.orientedRight},${productionBounds.orientedBottom}] " +
                    "decoderRaw=[${productionBounds.rawLeft},${productionBounds.rawTop}," +
                    "${productionBounds.rawRight},${productionBounds.rawBottom}] " +
                    "output=${dimensions.first}x${dimensions.second} " +
                    "boundaryDeviationPx=[${alignment.dx},${alignment.dy}] " +
                    "meanChannelDelta=${alignment.meanChannelDelta} " +
                    "maxChannelDelta=${alignment.maxChannelDelta} " +
                    "sourceUnchanged=$sourceUnchanged elapsedMs=$elapsedMs",
            )
        } finally {
            actual.recycle()
            expected.recycle()
        }
    }

    private fun invokeCrop(
        source: ByteArray,
        width: Int,
        height: Int,
        orientation: Int,
        request: CropRequest,
        timeoutSeconds: Long = 30,
    ): RecordedResult {
        val arguments = mapOf<String, Any>(
            "bytes" to source,
            "sourceWidth" to width,
            "sourceHeight" to height,
            "orientation" to orientation,
            "left" to request.left,
            "top" to request.top,
            "right" to request.right,
            "bottom" to request.bottom,
            "maxPixels" to MAX_CROP_PIXELS,
        )
        val result = RecordedResult()
        NativeLargeJpegScaler(activity).cropCall(
            MethodCall("cropJpegRegion", arguments),
            result,
        )
        assertTrue(
            "native crop call timed out after ${timeoutSeconds}s",
            result.latch.await(timeoutSeconds, TimeUnit.SECONDS),
        )
        return result
    }

    private fun oracleRawBounds(
        sourceWidth: Int,
        sourceHeight: Int,
        orientation: Int,
        request: CropRequest,
    ): List<Int> {
        val orientedWidth = if (orientation in 5..8) sourceHeight else sourceWidth
        val orientedHeight = if (orientation in 5..8) sourceWidth else sourceHeight
        val left = floor(request.left * orientedWidth).toInt()
        val top = floor(request.top * orientedHeight).toInt()
        val right = ceil(request.right * orientedWidth).toInt()
        val bottom = ceil(request.bottom * orientedHeight).toInt()
        val corners = listOf(
            oracleRawEdge(left, top, sourceWidth, sourceHeight, orientation),
            oracleRawEdge(right, top, sourceWidth, sourceHeight, orientation),
            oracleRawEdge(right, bottom, sourceWidth, sourceHeight, orientation),
            oracleRawEdge(left, bottom, sourceWidth, sourceHeight, orientation),
        )
        return listOf(
            floor(corners.minOf { it.first }).toInt(),
            floor(corners.minOf { it.second }).toInt(),
            ceil(corners.maxOf { it.first }).toInt(),
            ceil(corners.maxOf { it.second }).toInt(),
        )
    }

    /** Independent inverse mapping for pixel-edge coordinates. */
    private fun oracleRawEdge(
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        orientation: Int,
    ): Pair<Double, Double> = when (orientation) {
        1 -> x.toDouble() to y.toDouble()
        2 -> (width - x).toDouble() to y.toDouble()
        3 -> (width - x).toDouble() to (height - y).toDouble()
        4 -> x.toDouble() to (height - y).toDouble()
        5 -> y.toDouble() to x.toDouble()
        6 -> y.toDouble() to (height - x).toDouble()
        7 -> (width - y).toDouble() to (height - x).toDouble()
        8 -> (width - y).toDouble() to x.toDouble()
        else -> error("invalid orientation")
    }

    private fun oracleCrop(
        raw: Bitmap,
        sourceWidth: Int,
        sourceHeight: Int,
        orientation: Int,
        bounds: JpegRegionCropBounds,
    ): Bitmap {
        val output = Bitmap.createBitmap(
            bounds.outputWidth,
            bounds.outputHeight,
            Bitmap.Config.ARGB_8888,
        )
        val pixels = IntArray(bounds.outputWidth * bounds.outputHeight)
        for (y in 0 until bounds.outputHeight) {
            for (x in 0 until bounds.outputWidth) {
                val (rawX, rawY) = oracleRawPixel(
                    bounds.orientedLeft + x,
                    bounds.orientedTop + y,
                    sourceWidth,
                    sourceHeight,
                    orientation,
                )
                pixels[y * bounds.outputWidth + x] = raw.getPixel(rawX, rawY)
            }
        }
        output.setPixels(pixels, 0, bounds.outputWidth, 0, 0, bounds.outputWidth, bounds.outputHeight)
        return output
    }

    /** Independent inverse mapping for pixel-center indices. */
    private fun oracleRawPixel(
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        orientation: Int,
    ): Pair<Int, Int> = when (orientation) {
        1 -> x to y
        2 -> width - 1 - x to y
        3 -> width - 1 - x to height - 1 - y
        4 -> x to height - 1 - y
        5 -> y to x
        6 -> y to height - 1 - x
        7 -> width - 1 - y to height - 1 - x
        8 -> width - 1 - y to x
        else -> error("invalid orientation")
    }

    private fun bestPixelAlignment(actual: Bitmap, expected: Bitmap): PixelAlignment {
        assertEquals(expected.width, actual.width)
        assertEquals(expected.height, actual.height)
        var best: PixelAlignment? = null
        for (dy in -2..2) {
            for (dx in -2..2) {
                var channels = 0L
                var maxDelta = 0
                var samples = 0L
                for (y in 0 until actual.height) {
                    val referenceY = y + dy
                    if (referenceY !in 0 until expected.height) continue
                    for (x in 0 until actual.width) {
                        val referenceX = x + dx
                        if (referenceX !in 0 until expected.width) continue
                        val actualColor = actual.getPixel(x, y)
                        val expectedColor = expected.getPixel(referenceX, referenceY)
                        val red = abs(Color.red(actualColor) - Color.red(expectedColor))
                        val green = abs(Color.green(actualColor) - Color.green(expectedColor))
                        val blue = abs(Color.blue(actualColor) - Color.blue(expectedColor))
                        channels += red + green + blue
                        maxDelta = max(maxDelta, max(red, max(green, blue)))
                        samples += 3
                    }
                }
                val candidate = PixelAlignment(
                    dx = dx,
                    dy = dy,
                    meanChannelDelta = channels.toDouble() / samples,
                    maxChannelDelta = maxDelta,
                )
                val previous = best
                if (previous == null ||
                    candidate.meanChannelDelta < previous.meanChannelDelta ||
                    (candidate.meanChannelDelta == previous.meanChannelDelta &&
                        abs(dx) + abs(dy) < abs(previous.dx) + abs(previous.dy))) {
                    best = candidate
                }
            }
        }
        return best ?: error("no pixel-alignment samples")
    }

    private fun makePatternJpeg(width: Int, height: Int): ByteArray {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val pixels = IntArray(width * height)
        for (y in 0 until height) {
            for (x in 0 until width) {
                val value = (24 + (x * 13 + y * 7 + (x * y) % 37) % 216)
                pixels[y * width + x] = Color.rgb(value, value, value)
            }
        }
        bitmap.setPixels(pixels, 0, width, 0, 0, width, height)
        val canvas = Canvas(bitmap)
        val marker = Paint().apply { style = Paint.Style.FILL }
        marker.color = Color.RED
        canvas.drawRect(0f, 0f, 32f, 32f, marker)
        marker.color = Color.GREEN
        canvas.drawRect((width - 32).toFloat(), 0f, width.toFloat(), 32f, marker)
        marker.color = Color.BLUE
        canvas.drawRect(
            (width - 32).toFloat(),
            (height - 32).toFloat(),
            width.toFloat(),
            height.toFloat(),
            marker,
        )
        marker.color = Color.YELLOW
        canvas.drawRect(0f, (height - 32).toFloat(), 32f, height.toFloat(), marker)
        marker.color = Color.MAGENTA
        canvas.drawRect(
            (width / 2 - 4).toFloat(),
            0f,
            (width / 2 + 4).toFloat(),
            height.toFloat(),
            marker,
        )
        val output = ByteArrayOutputStream()
        assertTrue(bitmap.compress(Bitmap.CompressFormat.JPEG, 100, output))
        bitmap.recycle()
        return output.toByteArray()
    }

    private fun makeSolidJpeg(width: Int, height: Int): ByteArray {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.drawColor(Color.rgb(154, 162, 170))
        val marker = Paint().apply { style = Paint.Style.FILL }
        marker.color = Color.RED
        canvas.drawRect(0f, 0f, 128f, 128f, marker)
        marker.color = Color.GREEN
        canvas.drawRect((width - 128).toFloat(), 0f, width.toFloat(), 128f, marker)
        marker.color = Color.BLUE
        canvas.drawRect(
            (width - 128).toFloat(),
            (height - 128).toFloat(),
            width.toFloat(),
            height.toFloat(),
            marker,
        )
        marker.color = Color.YELLOW
        canvas.drawRect(0f, (height - 128).toFloat(), 128f, height.toFloat(), marker)
        val output = ByteArrayOutputStream()
        assertTrue(bitmap.compress(Bitmap.CompressFormat.JPEG, 95, output))
        bitmap.recycle()
        return output.toByteArray()
    }

    private fun makeNoiseJpeg(width: Int, height: Int, quality: Int): ByteArray {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val pixels = IntArray(width * height)
        var state = 0x13579bdf
        for (index in pixels.indices) {
            state = state xor (state shl 13)
            state = state xor (state ushr 17)
            state = state xor (state shl 5)
            pixels[index] = Color.rgb(
                state and 0xff,
                (state ushr 8) and 0xff,
                (state ushr 16) and 0xff,
            )
        }
        bitmap.setPixels(pixels, 0, width, 0, 0, width, height)
        val output = ByteArrayOutputStream()
        assertTrue(bitmap.compress(Bitmap.CompressFormat.JPEG, quality, output))
        bitmap.recycle()
        return output.toByteArray()
    }

    private fun withExifOrientation(jpeg: ByteArray, orientation: Int): ByteArray {
        require(jpeg.size >= 2 && orientation in 1..8)
        val app1 = byteArrayOf(
            0xff.toByte(), 0xe1.toByte(), 0x00, 0x22,
            0x45, 0x78, 0x69, 0x66, 0x00, 0x00,
            0x49, 0x49, 0x2a, 0x00, 0x08, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x12, 0x01, 0x03, 0x00, 0x01, 0x00,
            0x00, 0x00, orientation.toByte(), 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
        )
        return byteArrayOf(jpeg[0], jpeg[1]) + app1 + jpeg.copyOfRange(2, jpeg.size)
    }

    private fun jpegSofOnly(width: Int, height: Int): ByteArray = byteArrayOf(
        0xff.toByte(), 0xd8.toByte(), 0xff.toByte(), 0xc0.toByte(),
        0x00, 0x0b, 0x08,
        ((height shr 8) and 0xff).toByte(), (height and 0xff).toByte(),
        ((width shr 8) and 0xff).toByte(), (width and 0xff).toByte(),
        0x01, 0x01, 0x11, 0x00, 0xff.toByte(), 0xd9.toByte(),
    )

    private fun pngDimensions(bytes: ByteArray): Pair<Int, Int> {
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
        assertEquals("native result must be PNG", "image/png", options.outMimeType)
        return options.outWidth to options.outHeight
    }

    private fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256")
        .digest(bytes)
        .joinToString("") { byte -> "%02x".format(byte) }

    private fun recordMetric(line: String) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val output = File(context.filesDir, METRICS_FILE)
        output.appendText("$line\n")
        Log.i("AndroidCropMetric", line)
        System.out.println("ANDROID_CROP_METRIC $line")
    }

    private data class CropRequest(
        val name: String,
        val left: Double,
        val top: Double,
        val right: Double,
        val bottom: Double,
    )

    private data class PixelAlignment(
        val dx: Int,
        val dy: Int,
        val meanChannelDelta: Double,
        val maxChannelDelta: Int,
    )

    private class RecordedResult : MethodChannel.Result {
        val latch = CountDownLatch(1)

        @Volatile
        var value: Any? = null

        @Volatile
        var errorCode: String? = null

        @Volatile
        var errorMessage: String? = null

        override fun success(result: Any?) {
            value = result
            latch.countDown()
        }

        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
            this.errorCode = errorCode
            this.errorMessage = errorMessage
            latch.countDown()
        }

        override fun notImplemented() {
            errorCode = "notImplemented"
            latch.countDown()
        }
    }

    private companion object {
        const val MAX_CROP_PIXELS = 16_000_000
        const val METRICS_FILE = "native-jpeg-crop-metrics.log"
    }
}
