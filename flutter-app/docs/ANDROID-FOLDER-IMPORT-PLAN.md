# 安卓「添加整个文件夹」不可用 —— 根因与修复方案（路线 A 已落地）

> 状态：**路线 A（原生 Kotlin 通道）已实现并编译通过**，全量测试 1205 通过 / 2 skip，
> release APK 已打包。本机无安卓真机 / 模拟器，原生枚举 / 复制的运行时行为需真机验收（§5）。

## 1. 现象

安卓端抽屉菜单的「添加整个文件夹」导入后，歌没有进列表。单文件多选导入正常。
具体失败表现（选择器不弹 / 选完无反应 / 提示「这个目录里没有可播放的音频文件」/ 报错闪退）
尚待真机复现确认；下述根因基于代码证据。

## 2. 根因链

整条导入链路都假定来源是**本地文件系统路径**（`dart:io` `File` / `Directory`），
而安卓系统给文件夹选择器的是 **SAF `content://` 目录树 URI**，两者不兼容。

1. **选择层用了废弃 API** —— `lib/core/file_picking.dart:42`
   `pickAudioFolder()` 调 `FilePicker.getDirectoryPath()`（file_picker 13.4.0 已标
   `@Deprecated`）。插件注释明确：Android 上这个反解出的路径应用往往读不了，真正可读的是
   `pickDirectory()` 返回的 `content://` tree URI。

2. **扫描器只认本地目录** —— `lib/library/audio_filter.dart:157` `scanAudioDirectory`
   用 `Directory(root).list(recursive: true)` 枚举。`dart:io` 无法枚举 SAF `content://`
   目录树；即便拿到 URI 也会在 `dir.exists()` / `list()` 处落到 `FileSystemException`，
   返回空列表。

3. **导入 / 标签 / 播放 / 落库全链路按本地路径设计**
   - `lib/library/import_service.dart:260` `importDirectory` → `:264` 扫描 → `:269`
     `importPaths`；`:469` `_buildTrack` 恒用 `FilePathHandle(path)`。
   - 标签回填 `hydrateMetadata` 走 `ByteSource.fromFile(path, ...)`（`dart:io` 读字节）；
     时长探测 `MediaKitDurationOpener` 只包 `Media(FilePathHandle(...).uri)`。
   - 封面落盘、存档序列化也都按本地路径走。

4. **为什么单文件能用**：file_picker 内部把选中的 SAF 文档**复制到缓存目录**，再把
   本地缓存路径回传给 Dart；文件夹选择缺「枚举目录 + 逐个复制到本地」这一段，所以断在扫描。

5. **SAF 句柄预留了半成品** —— `lib/playback/track_handle.dart:112` `SafUriHandle`：
   `exists()` 恒 true、`sizeBytes()` 恒 null、`canProbeDuration = false`；ContentResolver
   读字节通道尚未补（注释标注「T22 之后补」）。直读 `content://` 的路径目前走不通。

6. **原生侧无任何通道**：`android/app/src/main/kotlin/.../MainActivity.kt` 是空
   `FlutterActivity()`，全工程无 `MethodChannel`（Kotlin / Dart 侧都没有现成封装）。

## 3. 为什么不能纯 Dart 修

SAF 目录树的枚举（`DocumentFile` 递归）与字节读取（`ContentResolver.openInputStream`）
都必须在原生层完成；`dart:io` 不支持 `content://`。没有现成依赖包做这件事，
需要自建一个 MethodChannel。

## 4. 候选路线

### 路线 A（推荐）原生 Kotlin 通道：SAF 选树 → 枚举音频 → 复制到应用专属目录 → 回本地路径

复用既有本地路径链路（标签 / 时长 / 封面 / 播放 / 落库全部不动），只在导入最前面补一段
「把 SAF 树里的音频复制成本地文件」。

**Dart 侧**
- `lib/core/file_picking.dart`：`pickAudioFolder()` 改调 `FilePicker.pickDirectory()`，
  返回 `Uri?`（Android 为 `content://` tree URI）。
- 新增平台通道封装（如 `lib/core/saf_bridge.dart`）：`copyTreeToLocal(Uri treeUri)`
  调用原生通道，返回复制后的本地文件路径列表；空 / 取消 / 报错归一为空列表。
- `lib/state/library_state.dart`、`lib/library/import_service.dart`：文件夹入口改为先
  走通道复制，再把本地路径列表交给既有 `importPaths`（不再走 `importDirectory` 的
  `Directory.list` 扫描；白名单 / 隐藏段过滤 / 自然排序 / 2000 上限在原生侧或 Dart 侧对齐
  `audio_filter.dart` 现有规则）。

**Kotlin 侧**（`MainActivity.kt` 或新建 `SafChannel.kt`）
- 注册 `MethodChannel`，方法名如 `copyAudioTree`。
- `DocumentFile.fromTreeUri` 递归遍历，按音频白名单扩展名过滤（对齐 `kAudioExtensions`）。
- `ContentResolver.openInputStream` 逐条复制到
  `filesDir/imported/<内容哈希或序号>/<文件名>`；按大小 / 哈希去重，避免重复导入与跨目录重复。
- 复制完成回传本地路径列表；大目录分批 / 限流（对齐 maxFiles 2000）；单个文件失败跳过不中断。
- `contentResolver.takePersistableUriPermission` 持久化对该树的访问（如选择器未自动持久化）。

**测试**
- Dart 侧：通道封装的取消 / 空结果 / 错误归一、复制后路径分流到 `importPaths` 的单测
  （注入假通道，沿用现有 widget/单元测试风格）。
- 原生逻辑本机无法运行验证，需真机验收（见 §5）。

**落地记录（2026-11-18，已实现）**
- Dart：`lib/core/saf_bridge.dart`（新，通道 `com.lightmusic.light_music/saf`，
  方法 `copyAudioTree`，非 Android / 空 URI / 异常归一为空列表）；
  `lib/core/file_picking.dart`（`pickAudioFolder` 改 `pickDirectory()` 返回 `Uri?`）；
  `lib/state/library_state.dart`（新增 `importSafTree`：复制后走既有 `importPaths`）；
  `lib/ui/home_page.dart`（`content://` 走 `importSafTree`，其余平台 file URI 走 `importDirectory`）。
- Kotlin：`MainActivity.kt` 注册通道；`SafTreeImporter.kt`（新，`DocumentsContract`
  递归枚举音频白名单 → 复制到 `filesDir/imported/<树哈希>/<文件名>`，同名加序号，
  上限 2000，单文件失败跳过；`takePersistableUriPermission` 兜底持久化）。
- 测试：`test/core/saf_bridge_test.dart`（新，5 用例）；全量 1205 通过 / 2 skip；
  `flutter build apk --release` 编译通过。
- 说明：枚举用 framework `DocumentsContract`，未引 androidx.documentfile；
  副本按树哈希分目录、同名覆盖，重复导入同树本地路径稳定，曲目 id 天然去重。

**风险**
- 无真机 / 模拟器，Kotlin 代码只能过编译；递归复制的内存、去重、大目录性能、文件名冲突
  等运行时表现需真机调。
- 复制会占应用专属目录空间；需评估是否提供「移除收藏时一并清理导入副本」（现有卸载/清理语义
  另行确认）。

### 路线 B 安卓端最小兜底提示

不做原生枚举：安卓端「添加整个文件夹」点击后提示「请改用多选音频文件导入」，或直接隐藏该入口。
工作量小、无原生风险；但文件夹导入功能仍不可用，只是把静默失败换成明确提示。

### 路线 C 暂不改代码，仅保留本方案文档

等有真机 / 模拟器或排期再落地路线 A。

## 5. 真机验收清单（路线 A 落地后）

- [ ] 选含多个子目录、混合音频 / 非音频文件的文件夹，音频全部进列表，非音频不进。
- [ ] 导入歌曲能正常播放、切歌、后台续播；通知栏封面 / 标题正常。
- [ ] 标签（标题 / 歌手 / 封面）回填正常；时长探测不为 NaN。
- [ ] 重复导入同一目录不产生重复条目；文件名冲突不互相覆盖。
- [ ] 超大目录（>2000 文件）按上限截断且不卡死；单首坏文件不中断整批。
- [ ] 重启 App 后已导入歌曲仍可播放（副本落在应用专属目录，未被清理）。

## 6. 关键代码索引

| 作用 | 文件 / 位置 |
| --- | --- |
| 文件夹选择（废弃 API） | `lib/core/file_picking.dart:42` |
| 文件夹入口（null 静默返回） | `lib/ui/home_page.dart:116` |
| 状态层导入目录 | `lib/state/library_state.dart:347` |
| 导入服务目录扫描 / 落库 | `lib/library/import_service.dart:260`、`:469` |
| 本地目录枚举 | `lib/library/audio_filter.dart:157` |
| 本地 / SAF 句柄 | `lib/playback/track_handle.dart:71`、`:112` |
| 原生 Activity（空，无通道） | `android/app/src/main/kotlin/com/lightmusic/light_music/MainActivity.kt` |
| 现有权限 | `android/app/src/main/AndroidManifest.xml`（无 `MANAGE_EXTERNAL_STORAGE`；SAF 不需要） |
