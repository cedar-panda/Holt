package com.yanci.holt

import android.Manifest
import android.app.Activity
import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.os.Process
import java.io.File
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    companion object {
        private const val FILE_SAVER_CHANNEL = "com.yanci.holt/file_saver"
        private const val SAVE_FILE_REQUEST = 0x484F
        private const val CRASH_MARKER_PREFS = "holt_native_crash_markers"
        private const val LAST_EXIT_TIMESTAMP = "last_exit_timestamp"
        private const val REPLY_NOTIFICATION_CHANNEL = "holt/reply_notifications"
        private const val CALL_AUDIO_ROUTE_CHANNEL = "com.yanci.holt/call_audio_route"
        private const val BLUETOOTH_CONNECT_REQUEST = 0x4842
        private const val REPLY_CHANNEL_ID = "holt_reply"
        private const val REPLY_CONVERSATION_EXTRA = "holt.reply.conversation_id"
        @Volatile private var crashHandlerInstalled = false
    }

    private var pendingSaveResult: MethodChannel.Result? = null
    private var pendingSaveSource: File? = null
    private var replyNotificationChannel: MethodChannel? = null
    private var pendingReplyConversationId: String? = null
    private var pendingBluetoothPermissionResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        captureHistoricalProcessExits()
        installPrivacySafeCrashJournal()
        super.onCreate(savedInstanceState)
        captureReplyIntent(intent)
    }

    private fun diagnosticFile(): File {
        val directory = File(filesDir, "diagnostics")
        directory.mkdirs()
        return File(directory, "android_native_diagnostics.jsonl")
    }

    private fun appendDiagnostic(row: JSONObject) {
        try {
            diagnosticFile().appendText(row.toString() + "\n", Charsets.UTF_8)
        } catch (_: Throwable) {
            // Diagnostics must never interfere with app startup or crash flow.
        }
    }

    private fun installPrivacySafeCrashJournal() {
        if (crashHandlerInstalled) return
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            try {
                val safeFrames = error.stackTrace
                    .take(40)
                    .joinToString("|") { frame ->
                        "${frame.className}.${frame.methodName}(${frame.fileName ?: "?"}:${frame.lineNumber})"
                    }
                appendDiagnostic(
                    JSONObject()
                        .put("created_at_ms", System.currentTimeMillis())
                        .put("source", "android_uncaught_exception")
                        .put("reason", "java_crash")
                        .put("process", Process.myPid())
                        .put("thread", thread.name.take(80))
                        .put("exception_type", error.javaClass.name)
                        .put("safe_stack", safeFrames),
                )
            } catch (_: Throwable) {
                // Preserve the original crash even if diagnostics fail.
            } finally {
                if (previous != null) {
                    previous.uncaughtException(thread, error)
                } else {
                    Process.killProcess(Process.myPid())
                }
            }
        }
        crashHandlerInstalled = true
    }

    private fun captureHistoricalProcessExits() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        try {
            val manager = getSystemService(ActivityManager::class.java)
            val prefs = getSharedPreferences(CRASH_MARKER_PREFS, MODE_PRIVATE)
            val lastSeen = prefs.getLong(LAST_EXIT_TIMESTAMP, 0L)
            var newestSeen = lastSeen
            manager.getHistoricalProcessExitReasons(null, 0, 10)
                .sortedBy { it.timestamp }
                .forEach { info ->
                    if (info.timestamp <= lastSeen || !isActionableExitReason(info.reason)) {
                        return@forEach
                    }
                    newestSeen = maxOf(newestSeen, info.timestamp)
                    appendDiagnostic(
                        JSONObject()
                            .put("created_at_ms", info.timestamp)
                            .put("source", "android_process_exit")
                            .put("reason", exitReasonName(info.reason))
                            .put("reason_code", info.reason)
                            .put("status", info.status)
                            .put("importance", info.importance)
                            .put("pss_kb", info.pss)
                            .put("rss_kb", info.rss),
                    )
                }
            if (newestSeen > lastSeen) {
                prefs.edit().putLong(LAST_EXIT_TIMESTAMP, newestSeen).apply()
            }
        } catch (_: Throwable) {
            // Older vendor ROMs may expose incomplete exit-history support.
        }
    }

    private fun isActionableExitReason(reason: Int): Boolean = when (reason) {
        ApplicationExitInfo.REASON_CRASH,
        ApplicationExitInfo.REASON_CRASH_NATIVE,
        ApplicationExitInfo.REASON_ANR,
        ApplicationExitInfo.REASON_LOW_MEMORY,
        ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> true
        else -> false
    }

    private fun exitReasonName(reason: Int): String = when (reason) {
        ApplicationExitInfo.REASON_CRASH -> "crash"
        ApplicationExitInfo.REASON_CRASH_NATIVE -> "native_crash"
        ApplicationExitInfo.REASON_ANR -> "anr"
        ApplicationExitInfo.REASON_LOW_MEMORY -> "low_memory"
        ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "excessive_resource"
        else -> "reason_$reason"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            FILE_SAVER_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "saveFile" -> startSaveFile(call, result)
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CALL_AUDIO_ROUTE_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "ensureBluetoothPermission" -> ensureBluetoothPermission(result)
                "activateBluetoothMicrophone" -> activateBluetoothMicrophone(result)
                "releaseBluetoothMicrophone" -> {
                    releaseBluetoothMicrophone()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        replyNotificationChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            REPLY_NOTIFICATION_CHANNEL,
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "notificationHandlerReady" -> {
                        flushPendingReplyConversation()
                        result.success(null)
                    }
                    "showCompletion" -> {
                        showReplyCompletionNotification(call)
                        result.success(null)
                    }
                    "clearConversationNotifications" -> {
                        clearReplyNotifications(call.argument<String>("conversationId").orEmpty())
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    private fun ensureBluetoothPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.BLUETOOTH_CONNECT,
            ) == PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        // Do not ask every phone-mic user for Nearby Devices. AudioManager can
        // expose the currently selected input type without Bluetooth metadata;
        // request CONNECT only when a Bluetooth microphone is actually present.
        if (!hasConnectedBluetoothInput()) {
            result.success(true)
            return
        }
        if (pendingBluetoothPermissionResult != null) {
            result.error("BLUETOOTH_PERMISSION_BUSY", "A Bluetooth permission request is already active.", null)
            return
        }
        pendingBluetoothPermissionResult = result
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.BLUETOOTH_CONNECT),
            BLUETOOTH_CONNECT_REQUEST,
        )
    }

    private fun hasConnectedBluetoothInput(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false
        return try {
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            audioManager.getDevices(AudioManager.GET_DEVICES_INPUTS).any { device ->
                device.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
                    (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                        device.type == AudioDeviceInfo.TYPE_BLE_HEADSET)
            }
        } catch (_: Throwable) {
            false
        }
    }

    private fun activateBluetoothMicrophone(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.BLUETOOTH_CONNECT,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            result.success(false)
            return
        }
        try {
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
            val bluetoothInput = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                audioManager.getDevices(AudioManager.GET_DEVICES_INPUTS).firstOrNull { device ->
                    device.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
                        (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                            device.type == AudioDeviceInfo.TYPE_BLE_HEADSET)
                }
            } else {
                null
            }
            if (bluetoothInput != null) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    audioManager.setCommunicationDevice(bluetoothInput)
                } else {
                    @Suppress("DEPRECATION")
                    audioManager.startBluetoothSco()
                    @Suppress("DEPRECATION")
                    audioManager.isBluetoothScoOn = true
                }
            }
            // No connected Bluetooth input is not an error: the recorder should
            // simply continue through the system-selected phone microphone.
            result.success(true)
        } catch (_: SecurityException) {
            result.success(false)
        } catch (error: Throwable) {
            result.error("BLUETOOTH_ROUTE_FAILED", error.message, null)
        }
    }

    private fun releaseBluetoothMicrophone() {
        try {
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                audioManager.clearCommunicationDevice()
            } else {
                @Suppress("DEPRECATION")
                audioManager.stopBluetoothSco()
                @Suppress("DEPRECATION")
                audioManager.isBluetoothScoOn = false
            }
            audioManager.mode = AudioManager.MODE_NORMAL
        } catch (_: Throwable) {
            // Releasing an optional route must never block call teardown.
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != BLUETOOTH_CONNECT_REQUEST) return
        val result = pendingBluetoothPermissionResult ?: return
        pendingBluetoothPermissionResult = null
        result.success(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureReplyIntent(intent)
    }

    private fun captureReplyIntent(intent: Intent?) {
        val conversationId = intent?.getStringExtra(REPLY_CONVERSATION_EXTRA).orEmpty()
        if (conversationId.isBlank()) return
        intent?.removeExtra(REPLY_CONVERSATION_EXTRA)
        val channel = replyNotificationChannel
        if (channel == null) {
            pendingReplyConversationId = conversationId
        } else {
            channel.invokeMethod("openConversation", conversationId)
        }
    }

    private fun flushPendingReplyConversation() {
        val conversationId = pendingReplyConversationId ?: return
        pendingReplyConversationId = null
        replyNotificationChannel?.invokeMethod("openConversation", conversationId)
    }

    private fun showReplyCompletionNotification(call: MethodCall) {
        val title = call.argument<String>("title").orEmpty()
        val body = call.argument<String>("body").orEmpty()
        val placeholder = call.argument<String>("placeholder").orEmpty()
        val conversationId = call.argument<String>("conversationId").orEmpty()
        if (title.isBlank() || body.isBlank() || placeholder.isBlank() || conversationId.isBlank()) {
            return
        }
        ensureReplyNotificationChannel()
        val notificationId = replyNotificationId(conversationId)
        val tapIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(REPLY_CONVERSATION_EXTRA, conversationId)
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            notificationId,
            tapIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val publicVersion = NotificationCompat.Builder(this, REPLY_CHANNEL_ID)
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle(applicationInfo.loadLabel(packageManager))
            .setContentText(placeholder)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .build()
        val notification = NotificationCompat.Builder(this, REPLY_CHANNEL_ID)
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPublicVersion(publicVersion)
            .setGroup(conversationId)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .build()
        try {
            NotificationManagerCompat.from(this).notify(
                conversationId,
                notificationId,
                notification,
            )
        } catch (_: SecurityException) {
            // Permission denial must not affect the completed chat reply.
        }
    }

    private fun ensureReplyNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                REPLY_CHANNEL_ID,
                "回覆通知",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "你送出的回合完成回覆時顯示"
            },
        )
    }

    private fun clearReplyNotifications(conversationId: String) {
        if (conversationId.isBlank()) return
        NotificationManagerCompat.from(this).cancel(
            conversationId,
            replyNotificationId(conversationId),
        )
    }

    private fun replyNotificationId(conversationId: String): Int =
        conversationId.hashCode() and Int.MAX_VALUE

    private fun startSaveFile(call: MethodCall, result: MethodChannel.Result) {
        if (pendingSaveResult != null) {
            result.error("SAVE_IN_PROGRESS", "Another save dialog is already open.", null)
            return
        }

        val sourcePath = call.argument<String>("sourcePath")
        val suggestedName = call.argument<String>("suggestedName")
        val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
        if (sourcePath.isNullOrBlank() || suggestedName.isNullOrBlank()) {
            result.error("INVALID_ARGUMENT", "sourcePath and suggestedName are required.", null)
            return
        }

        val source = try {
            File(sourcePath).canonicalFile
        } catch (error: Exception) {
            result.error("INVALID_SOURCE", "The source path is invalid.", error.message)
            return
        }
        if (!source.isFile || !isAppOwnedFile(source)) {
            result.error("INVALID_SOURCE", "The source file is outside Holt storage.", null)
            return
        }

        val safeName = File(suggestedName).name.takeIf { it.isNotBlank() } ?: "holt_backup.holt.zip"
        pendingSaveResult = result
        pendingSaveSource = source
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mimeType
            putExtra(Intent.EXTRA_TITLE, safeName)
        }
        try {
            startActivityForResult(intent, SAVE_FILE_REQUEST)
        } catch (error: Exception) {
            clearPendingSave()
            result.error("SAVE_DIALOG_FAILED", "Unable to open the system save dialog.", error.message)
        }
    }

    private fun isAppOwnedFile(file: File): Boolean {
        val roots = listOfNotNull(cacheDir, filesDir, externalCacheDir, getExternalFilesDir(null))
        return roots.any { root ->
            val canonicalRoot = root.canonicalFile
            file.path == canonicalRoot.path || file.path.startsWith(canonicalRoot.path + File.separator)
        }
    }

    @Deprecated("Deprecated in Android; retained for FlutterActivity compatibility.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != SAVE_FILE_REQUEST) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }

        val result = pendingSaveResult
        val source = pendingSaveSource
        clearPendingSave()
        if (result == null || source == null) return
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            result.success(null)
            return
        }

        val destination = data.data!!
        Thread {
            try {
                val output = contentResolver.openOutputStream(destination, "w")
                    ?: throw IllegalStateException("The selected destination cannot be opened.")
                source.inputStream().buffered().use { input ->
                    output.buffered().use { sink ->
                        input.copyTo(sink, bufferSize = 128 * 1024)
                        sink.flush()
                    }
                }
                runOnUiThread { result.success(destination.toString()) }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error("SAVE_FAILED", "Unable to write the selected file.", error.message)
                }
            }
        }.start()
    }

    private fun clearPendingSave() {
        pendingSaveResult = null
        pendingSaveSource = null
    }
}
