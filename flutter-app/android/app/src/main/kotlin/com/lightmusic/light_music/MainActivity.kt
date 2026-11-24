package com.lightmusic.light_music

import android.net.Uri
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {

  /**
   * SAF 目录树导入的单线程队列。
   *
   * 为什么必须离开主线程：`SafTreeImporter.importTree` 会对整棵树做
   * `ContentResolver.query` 递归枚举，并把白名单内的音频**逐个复制**到应用
   * 专属目录。选一个大文件夹（几百首 / 上千首）时这是几十秒到几分钟的阻塞
   * IO，跑在主线程就是安卓的 ANR（界面卡死 → 系统弹「无响应」→ 进程被杀）。
   * 单线程而不是线程池：复制本身是 IO 密集且会写同一个目标目录，并发复制
   * 只会抢磁盘、放大内存峰值，也不会更快。
   */
  private val safImportExecutor: ExecutorService =
    Executors.newSingleThreadExecutor()

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
              // 先把 Activity 侧的引用取好：复制的几十秒里页面可能被切走。
              val resolver = applicationContext.contentResolver
              val filesDir = applicationContext.filesDir
              safImportExecutor.execute {
                val copied = try {
                  SafTreeImporter.importTree(resolver, filesDir, Uri.parse(treeUri))
                } catch (_: Throwable) {
                  // 原生枚举 / 复制整体失败：按空结果交给 Dart，那边会给
                  // 「这个目录里没有可播放的音频文件」一类提示，不闪退。
                  emptyList<String>()
                }
                runOnUiThread {
                  try {
                    result.success(copied)
                  } catch (_: Throwable) {
                    // 页面已经销毁、通道已拆：结果没人接了，忽略即可。
                  }
                }
              }
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

  override fun onDestroy() {
    // 允许已经排队的复制跑完再退场（shutdownNow 会中断 IO，Dart 侧那个
    // await 就再也收不到结果了）；shutdown 不再接新任务，旧任务结束后线程自然退出。
    safImportExecutor.shutdown()
    super.onDestroy()
  }
}
