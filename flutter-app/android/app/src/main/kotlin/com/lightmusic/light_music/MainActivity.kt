package com.lightmusic.light_music

import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

  private companion object {
    const val CHANNEL = "com.lightmusic.light_music/saf"
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
  }
}
