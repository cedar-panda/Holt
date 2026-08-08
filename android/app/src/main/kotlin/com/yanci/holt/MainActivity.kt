package com.yanci.holt

import android.app.Activity
import android.content.Intent
import java.io.File
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val FILE_SAVER_CHANNEL = "com.yanci.holt/file_saver"
        private const val SAVE_FILE_REQUEST = 0x484F
    }

    private var pendingSaveResult: MethodChannel.Result? = null
    private var pendingSaveSource: File? = null

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
    }

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
