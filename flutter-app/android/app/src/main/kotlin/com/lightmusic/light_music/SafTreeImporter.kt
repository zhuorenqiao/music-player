package com.lightmusic.light_music

import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import java.io.File
import java.security.MessageDigest

/**
 * 安卓 SAF 目录树导入：递归枚举白名单音频，复制到应用专属目录，回传本地绝对路径。
 *
 * 与 Dart 侧 `lib/core/saf_bridge.dart` 的通道约定对应。枚举目录树、读字节都必须在
 * 原生层完成 —— `dart:io` 打不开 `content://`。复制成本地文件后，标签回填 / 时长
 * 探测 / 封面落盘 / 播放 / 落库整条既有链路按本地路径复用，不需要给 SAF 句柄补
 * ContentResolver 读写能力。
 */
object SafTreeImporter {

  /** 与 Dart 侧 `kAudioExtensions` 对齐的音频扩展名白名单（小写、不含点）。 */
  private val AUDIO_EXTENSIONS = setOf(
    "mp3", "wav", "ogg", "oga", "opus", "m4a", "aac",
    "flac", "webm", "weba", "mp4",
  )

  /** 与 `audio_filter.dart` 的 maxFiles 对齐的硬上限。 */
  private const val MAX_FILES = 2000

  /**
   * 枚举 [treeUri] 这棵目录树，把其中的音频复制到应用专属目录，返回复制成功的
   * 本地绝对路径列表。单个文件读 / 写失败只跳过它，不中断整批。
   */
  fun importTree(resolver: ContentResolver, filesDir: File, treeUri: Uri): List<String> {
    // 持久化对这棵树的读权限。失败不阻断：有些选择器返回的 URI 本就带临时授权。
    try {
      resolver.takePersistableUriPermission(
        treeUri,
        Intent.FLAG_GRANT_READ_URI_PERMISSION,
      )
    } catch (_: Throwable) {
    }

    val rootDocId = DocumentsContract.getTreeDocumentId(treeUri)
    val rootUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, rootDocId)

    val audio = mutableListOf<Pair<Uri, String>>()
    collectChildren(resolver, treeUri, rootUri, rootDocId, audio)
    if (audio.size > MAX_FILES) {
      audio.subList(MAX_FILES, audio.size).clear()
    }

    // 副本按「这棵树的哈希」分目录：重复导入同一棵树落到同一目录、同名覆盖，
    // 本地路径稳定，Dart 侧按来源派生的曲目 id 天然去重。
    val destDir = File(File(filesDir, "imported"), sha1(treeUri.toString()).take(16))
    if (!destDir.exists()) destDir.mkdirs()

    val usedNames = mutableSetOf<String>()
    val out = mutableListOf<String>()
    for ((docUri, displayName) in audio) {
      val dest = uniqueDestination(destDir, usedNames, displayName)
      try {
        resolver.openInputStream(docUri).use { input ->
          if (input == null) return@use
          dest.outputStream().use { output -> input.copyTo(output) }
        }
        if (dest.exists() && dest.length() > 0) {
          usedNames.add(dest.name)
          out.add(dest.absolutePath)
        }
      } catch (_: Throwable) {
        if (dest.exists()) dest.delete()
      }
    }
    return out
  }

  private fun collectChildren(
    resolver: ContentResolver,
    treeUri: Uri,
    parentUri: Uri,
    parentDocId: String,
    out: MutableList<Pair<Uri, String>>,
  ) {
    val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(parentUri, parentDocId)
    val columns = arrayOf(
      DocumentsContract.Document.COLUMN_DOCUMENT_ID,
      DocumentsContract.Document.COLUMN_DISPLAY_NAME,
      DocumentsContract.Document.COLUMN_MIME_TYPE,
    )
    resolver.query(childrenUri, columns, null, null, null)?.use { cursor ->
      val idIdx = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
      val nameIdx = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
      val mimeIdx = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
      while (cursor.moveToNext()) {
        val docId = if (idIdx >= 0) cursor.getString(idIdx) else null ?: continue
        val name = if (nameIdx >= 0) cursor.getString(nameIdx) else null ?: continue
        val mime = if (mimeIdx >= 0) cursor.getString(mimeIdx) else null
        val docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
        if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
          collectChildren(resolver, treeUri, docUri, docId, out)
        } else if (isAudioName(name)) {
          out.add(docUri to name)
        }
      }
    }
  }

  private fun isAudioName(name: String): Boolean {
    val dot = name.lastIndexOf('.')
    if (dot < 0 || dot == name.length - 1) return false
    val ext = name.substring(dot + 1).lowercase()
    return AUDIO_EXTENSIONS.contains(ext)
  }

  private fun uniqueDestination(dir: File, used: Set<String>, displayName: String): File {
    val safe = sanitize(displayName).ifEmpty { "audio" }
    val extDot = safe.lastIndexOf('.')
    var candidate = File(dir, safe)
    var n = 1
    while (candidate.name in used || candidate.exists()) {
      candidate = if (extDot > 0) {
        File(dir, "${safe.substring(0, extDot)}($n)${safe.substring(extDot)}")
      } else {
        File(dir, "$safe($n)")
      }
      n += 1
    }
    return candidate
  }

  private fun sanitize(name: String): String {
    val cleaned = name.trim().replace(Regex("[/\\\\:*?\"<>|]"), "_")
    return if (cleaned.length > 120) cleaned.take(120) else cleaned
  }

  private fun sha1(input: String): String {
    val digest = MessageDigest.getInstance("SHA-1").digest(input.toByteArray())
    return digest.joinToString("") { "%02x".format(it) }
  }
}
