package com.lightmusic.light_music

import android.net.Uri
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

  private companion object {
    const val CHANNEL = "com.lightmusic.light_music/saf"

    /**
     * 屏幕常亮通道（对应 lib/core/screen_wake_lock.dart）。
     *
     * 播放期间给窗口加 FLAG_KEEP_SCREEN_ON：不需要 WAKE_LOCK 权限，也不会阻止
     * 用户按电源键手动熄屏；暂停 / 停止后撤掉，屏幕恢复按系统设置休眠。
     */
    const val SCREEN_CHANNEL = "com.lightmusic.light_music/screen"
  }

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
      .setMethodCallHandler { call, result ->
        when (call.method) {
          "copyAudioTree" -> {
            val treeUri = call.argument<String>("treeUri")
            if (treeUri.isNullOrEmpty()) {
              result.success(emptyList<String>())
            } else {
              val copied = SafTreeImporter.importTree(
                contentResolver,
                filesDir,
                Uri.parse(treeUri),
              )
              result.success(copied)
            }
          }
          else -> result.notImplemented()
        }
      }

    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SCREEN_CHANNEL)
      .setMethodCallHandler { call, result ->
        when (call.method) {
          "keepAwake" -> {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            result.success(null)
          }
          "allowSleep" -> {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            result.success(null)
          }
          else -> result.notImplemented()
        }
      }
  }
}
