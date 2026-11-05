package iq.scanid.scan_id

import android.content.Intent
import android.content.pm.ApplicationInfo
import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.AndroidJUnit4
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Runs the real Release Dart intake path without a VM service or test plugin. */
@RunWith(AndroidJUnit4::class)
class ReleaseIntakeInstrumentationTest {
    @Test
    fun releaseIntakeReopenAndRetryCompleteWithNativeInference() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        assertFalse(
            "The regression must target a non-debuggable Release APK",
            (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0,
        )

        val results = LinkedBlockingQueue<Map<*, *>>()
        lateinit var engine: FlutterEngine
        var activity: FlutterActivity? = null
        instrumentation.runOnMainSync {
            engine = FlutterEngine(context)
            GeneratedPluginRegistrant.registerWith(engine)
            MethodChannel(
                engine.dartExecutor.binaryMessenger,
                "iq.scanid.scan_id/release_intake_test",
            ).setMethodCallHandler { call, result ->
                if (call.method == "finished") {
                    val arguments = call.arguments as? Map<*, *>
                    if (arguments == null) {
                        result.error("bad_result", "Expected a result map", null)
                    } else {
                        results.put(arguments)
                        result.success(null)
                    }
                } else {
                    result.notImplemented()
                }
            }
            FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        }

        try {
            val intent = FlutterActivity.withCachedEngine(ENGINE_ID)
                .build(context)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            activity = instrumentation.startActivitySync(intent) as FlutterActivity
            instrumentation.runOnMainSync {
                engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
            }
            val result = results.poll(8, TimeUnit.MINUTES)
            assertNotNull("Release Dart intake did not report a result", result)
            assertEquals(result.toString(), "success", result!!["status"])
            val evidence = result["evidence"] as? Map<*, *>
            assertNotNull("Successful result has no evidence", evidence)
            assertEquals(1L, (evidence!!["importedCount"] as Number).toLong())
            assertEquals(1L, (evidence["assetCount"] as Number).toLong())
            assertEquals(1L, (evidence["itemCount"] as Number).toLong())
            assertEquals(true, evidence["originalUnchanged"])
            assertEquals(true, evidence["retryOriginalUnchanged"])
            val phases = evidence["nativePhases"] as List<*>
            assertTrue(phases.containsAll(listOf(
                "docquad-inference", "docaligner-inference", "ocr-inference"
            )))
            assertTrue((evidence["docAlignerRuns"] as Number).toLong() >= 2L)
            Log.i(TAG, "completed status=success evidence=$evidence")
        } finally {
            activity?.let { finished ->
                instrumentation.runOnMainSync { finished.finish() }
            }
            instrumentation.runOnMainSync {
                FlutterEngineCache.getInstance().remove(ENGINE_ID)
                engine.destroy()
            }
        }
    }

    private companion object {
        const val ENGINE_ID = "scan-id-release-intake-test"
        const val TAG = "ScanIdReleaseIntake"
    }
}
