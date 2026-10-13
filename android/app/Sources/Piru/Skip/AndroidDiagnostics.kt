// The problem report (Android/Views/ReportProblem+Android.swift, and the launcher shortcut's
// ReportProblemActivity): one text file with the app and device details, how Piru's recent
// processes ended (ApplicationExitInfo, Android 11+, with the decoded tombstone of a native
// crash and the trace of an ANR), the stack of the last uncaught JVM exception, and the app's
// own logcat. Swift code runs natively under Skip Fuse, so a Swift trap is a native crash and
// its tombstone carries the abort message and the stack. The file stays on the phone until
// the user sends it from the share chooser.
package piru.module

import android.app.Activity
import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Process
import android.os.SystemClock
import androidx.annotation.RequiresApi
import java.io.File
import java.io.InputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

class AndroidDiagnostics {
    companion object {
        private const val EXIT_COUNT = 10
        private const val LOG_LINES = 6000
        private const val LOG_BYTES = 1_500_000
        private const val ANR_BYTES = 256_000
        private const val FRAMES_PER_THREAD = 64
        private const val PREFS = "piru.diagnostics"
        private const val SEEN_KEY = "lastSeenProblemExit"
        private const val JVM_CRASH_FILE = "last-jvm-crash.txt"

        private var appContext: Context? = null

        /// Keeps the stack of an uncaught JVM exception in the app's files, so the report made
        /// after the crash can carry it once logcat has rotated past it. The previous handler
        /// still runs, so the process dies as before. Runs from Application.onCreate.
        @JvmStatic
        fun install(context: Context) {
            val app = context.applicationContext
            appContext = app
            val previous = Thread.getDefaultUncaughtExceptionHandler()
            Thread.setDefaultUncaughtExceptionHandler { thread, error ->
                try {
                    val folder = File(app.filesDir, "diagnostics").apply { mkdirs() }
                    val stack = android.util.Log.getStackTraceString(error)
                    File(folder, JVM_CRASH_FILE).writeText("${timestamp(System.currentTimeMillis())} thread \"${thread.name}\"\n$stack")
                } catch (_: Throwable) {
                }
                previous?.uncaughtException(thread, error)
            }
        }

        /// Writes the report into the cache's reports folder and returns its path, or `null`
        /// when it could not be written. Runs on the caller's thread; Swift calls it off the
        /// main one.
        @JvmStatic
        fun writeReport(): String? = appContext?.let(::writeReportFor)

        /// Whether a crash, native crash or ANR ended a Piru process since the last report or
        /// the last time the user was asked about one.
        @JvmStatic
        fun hasUnseenProblem(): Boolean {
            val context = appContext ?: return false
            val newest = problemExits(context).maxOfOrNull { it.timestamp } ?: return false
            return newest > prefs(context).getLong(SEEN_KEY, 0)
        }

        /// Records every problem exit so far as seen.
        @JvmStatic
        fun markSeen() {
            appContext?.let(::markSeenFor)
        }

        fun writeReportFor(context: Context): String? = try {
            val folder = File(context.cacheDir, "reports").apply { mkdirs() }
            folder.listFiles()?.forEach { it.delete() }
            val stamp = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date())
            val file = File(folder, "piru-report-$stamp.txt")
            file.writeText(report(context))
            markSeenFor(context)
            file.absolutePath
        } catch (error: Throwable) {
            android.util.Log.e("Piru", "report failed", error)
            null
        }

        private fun markSeenFor(context: Context) {
            val newest = problemExits(context).maxOfOrNull { it.timestamp } ?: return
            prefs(context).edit().putLong(SEEN_KEY, newest).apply()
        }

        private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        private fun problemExits(context: Context): List<ApplicationExitInfo> {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return emptyList()
            val manager = context.getSystemService(ActivityManager::class.java) ?: return emptyList()
            return manager.getHistoricalProcessExitReasons(context.packageName, 0, EXIT_COUNT).filter {
                it.reason == ApplicationExitInfo.REASON_CRASH ||
                    it.reason == ApplicationExitInfo.REASON_CRASH_NATIVE ||
                    it.reason == ApplicationExitInfo.REASON_ANR
            }
        }

        // MARK: - The report

        private fun report(context: Context): String {
            val out = StringBuilder()
            out.appendLine("Piru problem report")
            out.appendLine("Written ${timestamp(System.currentTimeMillis())}. It holds device details, how Piru's recent")
            out.appendLine("processes ended, crash stacks and Piru's own log; nothing from the journal.")
            out.appendLine()
            section(out, "App and device") { appendDevice(context, out) }
            section(out, "How recent processes ended") { appendExits(context, out) }
            section(out, "Last uncaught JVM exception") { appendJvmCrash(context, out) }
            section(out, "Logcat (this app only, oldest first)") { appendLogcat(out) }
            return out.toString()
        }

        private fun section(out: StringBuilder, title: String, body: () -> Unit) {
            out.appendLine("== $title ==")
            try {
                body()
            } catch (error: Throwable) {
                out.appendLine("(could not be read: $error)")
            }
            out.appendLine()
        }

        private fun appendDevice(context: Context, out: StringBuilder) {
            val packageInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                context.packageManager.getPackageInfo(context.packageName, PackageManager.PackageInfoFlags.of(0))
            } else {
                @Suppress("DEPRECATION")
                context.packageManager.getPackageInfo(context.packageName, 0)
            }
            val versionCode = packageInfo.longVersionCode
            val debuggable = (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
            val manager = context.getSystemService(ActivityManager::class.java)
            val memory = ActivityManager.MemoryInfo().also { manager?.getMemoryInfo(it) }
            val mb = { bytes: Long -> "${bytes / (1024 * 1024)} MB" }
            out.appendLine("App: ${context.packageName} ${packageInfo.versionName} (versionCode $versionCode)${if (debuggable) ", debug build" else ""}")
            out.appendLine("Installed: ${timestamp(packageInfo.firstInstallTime)}; updated ${timestamp(packageInfo.lastUpdateTime)}")
            out.appendLine("Android: ${Build.VERSION.RELEASE} (SDK ${Build.VERSION.SDK_INT}), security patch ${Build.VERSION.SECURITY_PATCH}")
            out.appendLine("Device: ${Build.MANUFACTURER} ${Build.MODEL} (${Build.DEVICE}), ABIs ${Build.SUPPORTED_ABIS.joinToString()}")
            out.appendLine("Build: ${Build.FINGERPRINT}")
            out.appendLine("Locale: ${Locale.getDefault().toLanguageTag()}; languages ${AndroidPlatform.languageTags()}")
            out.appendLine("Time zone: ${TimeZone.getDefault().id}")
            out.appendLine("Device uptime: ${duration(SystemClock.elapsedRealtime())}; this process: ${duration(SystemClock.elapsedRealtime() - Process.getStartElapsedRealtime())}")
            out.appendLine("Memory: ${mb(memory.availMem)} free of ${mb(memory.totalMem)}${if (memory.lowMemory) ", low" else ""}${if (manager?.isLowRamDevice == true) ", low-RAM device" else ""}")
            out.appendLine("Storage: ${mb(context.filesDir.usableSpace)} free")
        }

        private fun appendExits(context: Context, out: StringBuilder) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
                out.appendLine("Android ${Build.VERSION.RELEASE} keeps no exit reasons (Android 11 and later do).")
                return
            }
            val manager = context.getSystemService(ActivityManager::class.java) ?: return
            val exits = manager.getHistoricalProcessExitReasons(context.packageName, 0, EXIT_COUNT)
            if (exits.isEmpty()) {
                out.appendLine("None recorded.")
                return
            }
            exits.forEachIndexed { index, exit ->
                out.appendLine("#$index ${timestamp(exit.timestamp)}  ${reasonName(exit.reason)}  status ${exit.status}  importance ${importanceName(exit.importance)}")
                out.appendLine("    process ${exit.processName} pid ${exit.pid}; pss ${exit.pss / 1024} MB, rss ${exit.rss / 1024} MB")
                exit.description?.takeIf { it.isNotBlank() }?.let { out.appendLine("    description: $it") }
                when (exit.reason) {
                    ApplicationExitInfo.REASON_CRASH_NATIVE -> appendTrace(exit, out) { appendTombstone(it, out) }
                    ApplicationExitInfo.REASON_ANR -> appendTrace(exit, out) { appendText(it, ANR_BYTES, out) }
                }
            }
        }

        @RequiresApi(Build.VERSION_CODES.R)
        private fun appendTrace(exit: ApplicationExitInfo, out: StringBuilder, decode: (InputStream) -> Unit) {
            val stream = try {
                exit.traceInputStream
            } catch (error: Throwable) {
                out.appendLine("    trace: unreadable ($error)")
                return
            }
            if (stream == null) {
                out.appendLine("    trace: none kept")
                return
            }
            stream.use {
                try {
                    decode(it)
                } catch (error: Throwable) {
                    out.appendLine("    trace: could not be decoded ($error)")
                }
            }
        }

        private fun appendText(stream: InputStream, limit: Int, out: StringBuilder) {
            val bytes = stream.readBytes()
            val text = String(bytes, 0, minOf(bytes.size, limit), Charsets.UTF_8)
            out.appendLine("    trace:")
            text.lineSequence().forEach { out.appendLine("      $it") }
            if (bytes.size > limit) out.appendLine("      … ${bytes.size - limit} more bytes")
        }

        private fun appendJvmCrash(context: Context, out: StringBuilder) {
            val file = File(File(context.filesDir, "diagnostics"), JVM_CRASH_FILE)
            if (!file.exists()) {
                out.appendLine("None recorded.")
                return
            }
            out.append(file.readText().take(ANR_BYTES))
            out.appendLine()
        }

        private fun appendLogcat(out: StringBuilder) {
            val process = ProcessBuilder("logcat", "-d", "-v", "threadtime", "-t", LOG_LINES.toString())
                .redirectErrorStream(true)
                .start()
            val bytes = process.inputStream.use { it.readBytes() }
            process.waitFor()
            val start = maxOf(0, bytes.size - LOG_BYTES)
            if (start > 0) out.appendLine("(the first ${start} bytes are left out)")
            out.append(String(bytes, start, bytes.size - start, Charsets.UTF_8))
        }

        // MARK: - Tombstone (system/core/debuggerd/proto/tombstone.proto)

        /// The tombstone's signal, abort message and causes, and every thread's backtrace,
        /// crashing thread first. Memory dumps, maps, open files and log buffers stay out: they
        /// can hold the journal's text, and logcat is in the report already.
        private fun appendTombstone(stream: InputStream, out: StringBuilder) {
            val tombstone = Proto(stream.readBytes())
            var tid = 0L
            var abort: String? = null
            var signal: String? = null
            val causes = mutableListOf<String>()
            val threads = mutableListOf<Pair<Long, Proto>>()
            while (tombstone.hasMore()) {
                val (field, wire) = tombstone.key()
                when {
                    field == 6 && wire == 0 -> tid = tombstone.varint()
                    field == 10 && wire == 2 -> signal = signalLine(tombstone.message())
                    field == 14 && wire == 2 -> abort = tombstone.string()
                    field == 15 && wire == 2 -> causeLine(tombstone.message())?.let(causes::add)
                    field == 16 && wire == 2 -> {
                        val entry = tombstone.message()
                        var key = 0L
                        var value: Proto? = null
                        while (entry.hasMore()) {
                            val (f, w) = entry.key()
                            when {
                                f == 1 && w == 0 -> key = entry.varint()
                                f == 2 && w == 2 -> value = entry.message()
                                else -> entry.skip(w)
                            }
                        }
                        value?.let { threads.add(Pair(key, it)) }
                    }
                    else -> tombstone.skip(wire)
                }
            }
            out.appendLine("    tombstone:")
            signal?.let { out.appendLine("      $it") }
            abort?.let { out.appendLine("      Abort message: '$it'") }
            causes.forEach { out.appendLine("      Cause: $it") }
            threads.sortedBy { if (it.first == tid) 0 else 1 }.forEach { (id, thread) ->
                appendThread(thread, id == tid, out)
            }
        }

        private fun signalLine(signal: Proto): String {
            var number = 0L
            var name = ""
            var code = 0L
            var codeName = ""
            var hasFault = false
            var fault = 0L
            while (signal.hasMore()) {
                val (field, wire) = signal.key()
                when {
                    field == 1 && wire == 0 -> number = signal.varint()
                    field == 2 && wire == 2 -> name = signal.string()
                    field == 3 && wire == 0 -> code = signal.varint().toInt().toLong()
                    field == 4 && wire == 2 -> codeName = signal.string()
                    field == 8 && wire == 0 -> hasFault = signal.varint() != 0L
                    field == 9 && wire == 0 -> fault = signal.varint()
                    else -> signal.skip(wire)
                }
            }
            val address = if (hasFault) "0x%016x".format(fault) else "--------"
            return "signal $number ($name), code $code ($codeName), fault addr $address"
        }

        private fun causeLine(cause: Proto): String? {
            while (cause.hasMore()) {
                val (field, wire) = cause.key()
                if (field == 1 && wire == 2) return cause.string()
                cause.skip(wire)
            }
            return null
        }

        private fun appendThread(thread: Proto, crashing: Boolean, out: StringBuilder) {
            var id = 0L
            var name = ""
            val notes = mutableListOf<String>()
            val frames = mutableListOf<String>()
            while (thread.hasMore()) {
                val (field, wire) = thread.key()
                when {
                    field == 1 && wire == 0 -> id = thread.varint()
                    field == 2 && wire == 2 -> name = thread.string()
                    field == 4 && wire == 2 -> frames.add(frameLine(frames.size, thread.message()))
                    field == 7 && wire == 2 -> notes.add(thread.string())
                    else -> thread.skip(wire)
                }
            }
            out.appendLine("      thread $id \"$name\"${if (crashing) " (crashing)" else ""}:")
            notes.forEach { out.appendLine("        note: $it") }
            frames.take(FRAMES_PER_THREAD).forEach { out.appendLine("        $it") }
            if (frames.size > FRAMES_PER_THREAD) out.appendLine("        … ${frames.size - FRAMES_PER_THREAD} more frames")
        }

        private fun frameLine(index: Int, frame: Proto): String {
            var relPc = 0L
            var function = ""
            var offset = 0L
            var file = ""
            var buildId = ""
            while (frame.hasMore()) {
                val (field, wire) = frame.key()
                when {
                    field == 1 && wire == 0 -> relPc = frame.varint()
                    field == 4 && wire == 2 -> function = frame.string()
                    field == 5 && wire == 0 -> offset = frame.varint()
                    field == 6 && wire == 2 -> file = frame.string()
                    field == 8 && wire == 2 -> buildId = frame.string()
                    else -> frame.skip(wire)
                }
            }
            val symbol = if (function.isEmpty()) "" else " ($function+$offset)"
            val build = if (buildId.isEmpty()) "" else " (BuildId: $buildId)"
            return "#%02d pc %016x  %s%s%s".format(index, relPc, file, symbol, build)
        }

        // MARK: - Formatting

        private fun timestamp(millis: Long): String =
            SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS Z", Locale.US).format(Date(millis))

        private fun duration(millis: Long): String {
            val seconds = millis / 1000
            return "%dd %02d:%02d:%02d".format(seconds / 86400, seconds / 3600 % 24, seconds / 60 % 60, seconds % 60)
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
            ApplicationExitInfo.REASON_PACKAGE_UPDATED -> "PACKAGE_UPDATED"
            else -> "UNKNOWN($reason)"
        }

        private fun importanceName(importance: Int): String = when (importance) {
            ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND -> "foreground"
            ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND_SERVICE -> "foreground service"
            ActivityManager.RunningAppProcessInfo.IMPORTANCE_VISIBLE -> "visible"
            ActivityManager.RunningAppProcessInfo.IMPORTANCE_PERCEPTIBLE -> "perceptible"
            ActivityManager.RunningAppProcessInfo.IMPORTANCE_SERVICE -> "service"
            ActivityManager.RunningAppProcessInfo.IMPORTANCE_TOP_SLEEPING -> "top sleeping"
            ActivityManager.RunningAppProcessInfo.IMPORTANCE_CANT_SAVE_STATE -> "can't save state"
            ActivityManager.RunningAppProcessInfo.IMPORTANCE_CACHED -> "cached"
            ActivityManager.RunningAppProcessInfo.IMPORTANCE_GONE -> "gone"
            else -> importance.toString()
        }
    }

    /// The protobuf wire format, as far as reading a tombstone needs: varints, length-delimited
    /// fields, and skipping the fixed-width ones.
    private class Proto(private val bytes: ByteArray, private var position: Int = 0, private val end: Int = bytes.size) {
        fun hasMore() = position < end

        fun key(): Pair<Int, Int> {
            val key = varint()
            return Pair((key ushr 3).toInt(), (key and 7).toInt())
        }

        fun varint(): Long {
            var result = 0L
            var shift = 0
            while (shift < 64) {
                check(position < end) { "truncated varint" }
                val byte = bytes[position++].toInt() and 0xff
                result = result or ((byte and 0x7f).toLong() shl shift)
                if (byte and 0x80 == 0) return result
                shift += 7
            }
            error("varint longer than 64 bits")
        }

        fun message(): Proto {
            val length = varint().toInt()
            check(length >= 0 && position + length <= end) { "field runs past its message" }
            val inner = Proto(bytes, position, position + length)
            position += length
            return inner
        }

        fun string(): String {
            val inner = message()
            return String(bytes, inner.position, inner.end - inner.position, Charsets.UTF_8)
        }

        fun skip(wire: Int) {
            when (wire) {
                0 -> varint()
                1 -> position += 8
                2 -> message()
                5 -> position += 4
                else -> error("wire type $wire")
            }
            check(position <= end) { "field runs past its message" }
        }
    }
}

/// The launcher shortcut's target: writes the report and opens the share chooser without
/// starting the app's UI, so a report can be made while the app crashes as it launches.
class ReportProblemActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Thread {
            val path = AndroidDiagnostics.writeReportFor(this)
            runOnUiThread {
                if (path == null || !AndroidDocuments.shareFileFrom(this, path, "text/plain")) {
                    // Looked up by name: the string lives in the app module's resources.
                    val message = resources.getIdentifier("report_failed", "string", packageName)
                    if (message != 0) android.widget.Toast.makeText(this, message, android.widget.Toast.LENGTH_LONG).show()
                }
                finish()
            }
        }.start()
    }
}
