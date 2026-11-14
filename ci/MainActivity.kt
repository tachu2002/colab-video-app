package com.example.colab_video_app

import android.content.ContentValues
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app/save").setMethodCallHandler { call, result ->
            if (call.method != "saveToDownloads") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val path = call.argument<String>("path") ?: ""
            val name = call.argument<String>("name") ?: "video.mp4"
            Thread {
                try {
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                        throw IllegalStateException("Android 10 以上が必要です")
                    }
                    val src = File(path)
                    if (!src.exists()) throw IllegalStateException("元のファイルがありません")
                    val values = ContentValues().apply {
                        put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                        put(MediaStore.MediaColumns.MIME_TYPE, "video/mp4")
                        put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/ColabVideo")
                        put(MediaStore.MediaColumns.IS_PENDING, 1)
                    }
                    val resolver = applicationContext.contentResolver
                    val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                        ?: throw IllegalStateException("保存先を作れませんでした")
                    resolver.openOutputStream(uri)?.use { out ->
                        src.inputStream().use { it.copyTo(out) }
                    } ?: throw IllegalStateException("書き込みを開けませんでした")
                    val done = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
                    resolver.update(uri, done, null, null)
                    runOnUiThread { result.success(uri.toString()) }
                } catch (e: Exception) {
                    runOnUiThread { result.error("save", e.toString(), null) }
                }
            }.start()
        }
    }
}
