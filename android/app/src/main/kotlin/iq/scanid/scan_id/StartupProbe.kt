package iq.scanid.scan_id

import android.app.Activity
import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.system.Os
import android.system.OsConstants
import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Phone-only startup evidence recorder.
 *
 * The Android build is reported to exit after the splash screen on a physical
 * device, and the person testing it has no computer and therefore no `adb`.
 * This probe makes the app itself the instrument:
 *
 *  * every launch records a timestamped stage mark, so a run that dies between
 *    two marks is located by the missing tails;
 *  * the process-wide uncaught-exception handler records the Java/Kotlin
 *    throwable (type, message and stack) before the process dies, then defers to
 *    the handler Flutter/system installed so the normal crash reporting still
 *    happens;
 *  * the next launch reads `ActivityManager.getHistoricalProcessExitReasons()` for
 *    this package, which is the same data an Android bug report shows under
 *    "Historical Process Exit", and keeps the reason, status, description and
 *    the recorded trace. That covers native deaths (SIGSEGV/SIGABRT) that a Dart
 *    or Java handler can never observe, because the kernel kills the process;
 *  * the ONNX Runtime JNI libraries are loaded explicitly and *before* Flutter
 *    registers plugins, so the failure of `System.loadLibrary` is captured as a
 *    value in the report instead of taking the process down first;
 *  * the report is written to the shared `Download/ScanId` folder through
 *    MediaStore (no storage permission on Android 10+) so it can be shared from
 *    the phone's file manager without a computer.
 *
 * The probe is compiled in only when `BuildConfig.STARTUP_PROBE` is true, which
 * is the `diagnostic` flavor by default. It records device/build identifiers and
 * stage names only: no project data, no image content, no keys and no user text.
 * Records that are paths are app-private paths produced by the exception
 * messages themselves.
 *
 * Limits, stated explicitly: a Dart exception is recorded by [mark]/[failure]
 * calls from `StartupDiagnostics`; it does not by itself kill the process. A
 * native crash cannot run any handler here, which is why the exit-info read on
 * the following launch is the only way to see it from inside the app.
 */
object StartupProbe {
    private const val TAG = "ScanIdProbe"
    private const val FOLDER = "ScanId"
    private const val APP_LOG = "startup-probe.log"
    private const val MAX_TRACE_CHARS = 6000
    private const val MAX_APP_LOG_CHARS = 24000

    private val lock = Any()
    private val marks = ArrayList<String>()
    private var appContext: Context? = null
    private var previousHandler: Thread.UncaughtExceptionHandler? = null
    private var installed = false
    private var sequence = 0

    /** True only in builds that opted in; production stays silent. */
    val enabled: Boolean
        get() = BuildConfig.STARTUP_PROBE

    /** Must run before `super.onCreate` so plugin registration is covered. */
    fun install(activity: Activity) {
        if (!enabled) return
        synchronized(lock) {
            if (installed) return
            val context = activity.applicationContext
            appContext = context
            val previous = Thread.getDefaultUncaughtExceptionHandler()
            previousHandler = previous
            Thread.setDefaultUncaughtExceptionHandler { thread, error ->
                recordUncaught(thread, error)
                val delegate = previousHandler
                if (delegate != null) delegate.uncaughtException(thread, error)
            }
            installed = true
            mark("probe.installed")
            // The previous run is the evidence; publish it before anything in
            // this run can fail.
            runCatching { publish("previous-run", buildReport(context, includeCurrentMarks = false)) }
                .onFailure { Log.w(TAG, "previous-run publish failed: ${it.javaClass.name}") }
            preflightNativeLibraries()
        }
    }

    fun mark(stage: String) {
        if (!enabled) return
        val line = synchronized(lock) {
            sequence += 1
            val entry = String.format(
                Locale.US,
                "%s %04d %s",
                timestamp(),
                sequence,
                stage,
            )
            marks.add(entry)
            entry
        }
        Log.i(TAG, line)
        appendToAppLog(line)
    }

    fun failure(stage: String, error: Throwable) {
        if (!enabled) return
        val detail = buildString {
            append(stage)
            append(" failed type=")
            append(error.javaClass.name)
            if (error is UnsatisfiedLinkError) {
                append(" message=")
                append(error.message.orEmpty())
            }
            val message = error.message
            if (error !is UnsatisfiedLinkError && !message.isNullOrBlank()) {
                append(" message=")
                append(message.lineSequence().first().take(300))
            }
        }
        mark(detail)
    }

    /** Publishes this run so far; safe to call from the UI thread. */
    fun publishCurrentRun() {
        if (!enabled) return
        val context = appContext ?: return
        runCatching { publish("first-frame", buildReport(context, includeCurrentMarks = true)) }
            .onFailure { Log.w(TAG, "current-run publish failed: ${it.javaClass.name}") }
    }

    /**
     * Loads the ONNX Runtime JNI libraries before Flutter's plugin registration
     * does it. Success is recorded as a positive fact; failure is recorded with
     * the exact `UnsatisfiedLinkError` message, which is what distinguishes a
     * missing/unsupported ABI or page-size mismatch from an OEM restriction.
     */
    private fun preflightNativeLibraries() {
        mark(
            "native.preflight.abi abis=${Build.SUPPORTED_ABIS.joinToString(",")}" +
                " pageSize=${pageSize()} bits=${if (Build.SUPPORTED_64_BIT_ABIS.isNotEmpty()) "64" else "32"}",
        )
        for (library in listOf("onnxruntime4j_jni", "onnxruntime")) {
            val startedAt = System.nanoTime()
            try {
                System.loadLibrary(library)
                mark("native.preflight.loaded name=$library ms=${elapsedMs(startedAt)}")
            } catch (error: Throwable) {
                failure("native.preflight.load_failed name=$library ms=${elapsedMs(startedAt)}", error)
            }
        }
        val environment = loadOrtEnvironment()
        if (environment is Throwable) {
            failure("native.preflight.ort_environment", environment)
        }
    }

    /**
     * Creates `ai.onnxruntime.OrtEnvironment` through reflection so the probe
     * keeps compiling when the runtime is absent, and reports whether the
     * environment can be created at all. The created environment is the process
     * singleton the plugin reuses; nothing is closed here.
     */
    private fun loadOrtEnvironment(): Any? {
        val startedAt = System.nanoTime()
        return try {
            val type = Class.forName("ai.onnxruntime.OrtEnvironment")
            val method = type.getMethod("getEnvironment")
            val value = method.invoke(null)
            mark("native.preflight.ort_environment.created ms=${elapsedMs(startedAt)}")
            value ?: error("OrtEnvironment.getEnvironment() returned null")
        } catch (error: ClassNotFoundException) {
            mark("native.preflight.ort_environment.absent")
            null
        } catch (error: Throwable) {
            error.cause ?: error
        }
    }

    private fun recordUncaught(thread: Thread, error: Throwable) {
        if (!enabled) return
        runCatching {
            mark("java.uncaught thread=${thread.name} type=${error.javaClass.name}")
            val context = appContext ?: return@runCatching
            val report = buildReport(context, includeCurrentMarks = true) + buildString {
                appendLine()
                appendLine("== uncaught throwable ==")
                appendLine(describeThrowable(error))
            }
            publish("crash", report)
            appendToAppLog("== uncaught throwable ==\n" + describeThrowable(error))
        }.onFailure { Log.w(TAG, "crash record failed: ${it.javaClass.name}") }
    }

    private fun describeThrowable(error: Throwable): String {
        val builder = StringBuilder()
        var current: Throwable? = error
        var depth = 0
        while (current != null && depth < 4) {
            builder.appendLine("${current.javaClass.name}: ${current.message.orEmpty()}")
            current.stackTrace.take(24).forEach { element ->
                builder.appendLine("    at $element")
            }
            current = current.cause
            if (current != null) builder.appendLine("caused by:")
            depth += 1
        }
        return builder.toString()
    }

    private fun buildReport(context: Context, includeCurrentMarks: Boolean): String = buildString {
        appendLine("Scan-id startup report (diagnostic build)")
        appendLine("generatedAt=${timestamp()}")
        appendLine("package=${context.packageName}")
        appendLine("applicationId=${BuildConfig.APPLICATION_ID}")
        appendLine("versionName=${BuildConfig.VERSION_NAME} versionCode=${BuildConfig.VERSION_CODE}")
        appendLine("buildSha=${BuildConfig.BUILD_SHA}")
        appendLine("debugBuild=${BuildConfig.DEBUG}")
        appendLine("manufacturer=${Build.MANUFACTURER} model=${Build.MODEL} device=${Build.DEVICE}")
        appendLine(
            "androidRelease=${Build.VERSION.RELEASE} sdk=${Build.VERSION.SDK_INT}" +
                " securityPatch=${Build.VERSION.SECURITY_PATCH}",
        )
        appendLine("supportedAbis=${Build.SUPPORTED_ABIS.joinToString(",")}")
        appendLine("abi64=${Build.SUPPORTED_64_BIT_ABIS.joinToString(",")}")
        appendLine("pageSize=${pageSize()}")
        appendLine()
        appendLine("== historical process exits (own package) ==")
        appendLine(describeExits(context))
        appendLine()
        if (includeCurrentMarks) {
            appendLine("== this run ==")
            synchronized(lock) { marks.forEach { appendLine(it) } }
            appendLine()
        }
        val previous = readAppLog()
        if (previous.isNotBlank()) {
            appendLine("== previous recorded runs ==")
            appendLine(previous)
        }
        appendLine("== end ==")
    }

    private fun describeExits(context: Context): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            return "unavailable: requires Android 11 (API 30) for getHistoricalProcessExitReasons"
        }
        val manager = context.getSystemService(ActivityManager::class.java) ?: return "unavailable: no ActivityManager"
        // null package name = this package; pid 0 = any process; 10 = bounded.
        val exits = runCatching { manager.getHistoricalProcessExitReasons(null, 0, 10) }
            .getOrElse { return "read failed: ${it.javaClass.name}" }
        if (exits.isEmpty()) return "none recorded"
        val builder = StringBuilder()
        exits.forEach { info: ApplicationExitInfo ->
            builder.appendLine(
                "at=${formatTime(info.timestamp)} reason=${reasonName(info.reason)}(${info.reason})" +
                    " status=${info.status} importance=${info.importance}" +
                    " process=${info.processName}",
            )
            val description = info.description
            if (!description.isNullOrBlank()) {
                builder.appendLine("  description=${description.take(400)}")
            }
            builder.appendLine("  pssKb=${info.pss} rssKb=${info.rss}")
            val trace = runCatching {
                info.traceInputStream?.bufferedReader()?.use { reader ->
                    reader.readText().take(MAX_TRACE_CHARS)
                }
            }.getOrNull()
            if (!trace.isNullOrBlank()) {
                builder.appendLine("  trace:")
                trace.lineSequence().forEach { builder.appendLine("    $it") }
            }
        }
        return builder.toString().trimEnd()
    }

    private fun reasonName(reason: Int): String = when (reason) {
        ApplicationExitInfo.REASON_EXIT_SELF -> "EXIT_SELF"
        ApplicationExitInfo.REASON_SIGNALED -> "SIGNALED"
        ApplicationExitInfo.REASON_LOW_MEMORY -> "LOW_MEMORY"
        ApplicationExitInfo.REASON_CRASH -> "CRASH"
        ApplicationExitInfo.REASON_CRASH_NATIVE -> "CRASH_NATIVE"
        ApplicationExitInfo.REASON_ANR -> "ANR"
        ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "INITIALIZATION_FAILURE"
        ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "PERMISSION_CHANGE"
        ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "EXCESSIVE_RESOURCE_USAGE"
        ApplicationExitInfo.REASON_USER_REQUESTED -> "USER_REQUESTED"
        ApplicationExitInfo.REASON_USER_STOPPED -> "USER_STOPPED"
        ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "DEPENDENCY_DIED"
        ApplicationExitInfo.REASON_OTHER -> "OTHER"
        ApplicationExitInfo.REASON_FREEZER -> "FREEZER"
        ApplicationExitInfo.REASON_PACKAGE_STATE_CHANGE -> "PACKAGE_STATE_CHANGE"
        else -> "UNKNOWN"
    }

    /**
     * Writes the report to Download/ScanId. On Android 9 and older MediaStore
     * downloads are unavailable, so the app-private copy is the only output and
     * the log line names it.
     */
    private fun publish(kind: String, report: String) {
        val context = appContext ?: return
        val name = "scanid-startup-$kind-${fileStamp()}.txt"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, "text/plain")
                put(
                    MediaStore.MediaColumns.RELATIVE_PATH,
                    Environment.DIRECTORY_DOWNLOADS + File.separator + FOLDER,
                )
            }
            val resolver = context.contentResolver
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            if (uri != null) {
                resolver.openOutputStream(uri)?.use { stream ->
                    stream.write(report.toByteArray())
                }
                Log.i(TAG, "report.published kind=$kind name=$name")
                appendToAppLog("report.published kind=$kind name=Download/$FOLDER/$name")
                return
            }
            Log.w(TAG, "report.publish_failed kind=$kind reason=no-media-store-uri")
        }
        val file = appLogFile(context) ?: return
        val target = File(file.parentFile, name)
        runCatching { target.writeText(report) }
            .onSuccess { Log.i(TAG, "report.published_private kind=$kind name=${target.name}") }
            .onFailure { Log.w(TAG, "report.publish_failed kind=$kind reason=${it.javaClass.name}") }
    }

    private fun appLogFile(context: Context): File? = runCatching {
        val directory = File(context.filesDir, "diagnostics")
        if (!directory.exists() && !directory.mkdirs()) return null
        File(directory, APP_LOG)
    }.getOrNull()

    private fun appendToAppLog(line: String) {
        val context = appContext ?: return
        val file = appLogFile(context) ?: return
        runCatching { file.appendText(line + "\n") }
    }

    private fun readAppLog(): String {
        val context = appContext ?: return ""
        val file = appLogFile(context) ?: return ""
        return runCatching {
            if (!file.isFile) return ""
            val text = file.readText()
            if (text.length <= MAX_APP_LOG_CHARS) text else text.takeLast(MAX_APP_LOG_CHARS)
        }.getOrDefault("")
    }

    private fun pageSize(): Long = runCatching {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            Os.sysconf(OsConstants._SC_PAGESIZE)
        } else {
            0L
        }
    }.getOrDefault(0L)

    private fun elapsedMs(startedAt: Long): Long =
        (System.nanoTime() - startedAt) / 1_000_000L

    private fun timestamp(): String =
        SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US).format(Date())

    private fun formatTime(value: Long): String =
        SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US).format(Date(value))

    private fun fileStamp(): String =
        SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date())
}
