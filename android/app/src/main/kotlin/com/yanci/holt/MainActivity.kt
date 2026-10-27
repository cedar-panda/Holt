package com.yanci.holt

import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.os.Bundle
import java.io.File
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

class MainActivity : FlutterActivity() {
    companion object {
        private const val FILE_SAVER_CHANNEL = "com.yanci.holt/file_saver"
        private const val SAVE_FILE_REQUEST = 0x484F
        private const val REPLY_NOTIFICATION_CHANNEL = "holt/reply_notifications"
        private const val REPLY_CHANNEL_ID = "holt_reply"
        private const val REPLY_CONVERSATION_EXTRA = "holt.reply.conversation_id"
    }

    private var pendingSaveResult: MethodChannel.Result? = null
    private var pendingSaveSource: File? = null
    private var replyNotificationChannel: MethodChannel? = null
    private var pendingReplyConversationId: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        captureReplyIntent(intent)
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
