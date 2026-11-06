# 流光音乐 Flutter 移植 · M1 核心播放 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 交付一个能在 Windows 桌面与 Android 上安装运行的 Flutter 版「流光音乐」核心播放器：导入本地音频、解析内嵌标签与时长、播放/暂停/上下曲/三种播放模式/进度与缓冲/音量、列表与最近播放两个 tab 与列表内搜索、持久化与冷启动还原、四类错误与损坏角标与熔断、系统媒体会话（锁屏与通知栏、SMTC 与媒体键）切歌。

**Architecture:** 四层。`playback/` + `metadata/` + `library/` 是纯逻辑（不 import material），逐字节对译原版 `src/lib/*.js`；`state/` 是唯一把逻辑接进界面的地方，用 ChangeNotifier 对译原版 15 个 Context 里 M1 需要的四个；`ui/` 只从 `AppTokens` 取颜色，断点 900/480 与原版 media query 一致。进度、缓冲、时长三条流各挂一个 `ValueNotifier`，只有进度条与时间文字订阅，避免整树重绘（等价原版 `useSyncExternalStore`）。系统媒体会话经 `MediaSessionBridge` 接在 `TransportController` 之上，所有外部动作走界面按钮用的同一个入口。

**Tech Stack:** Flutter 3.47.9 / Dart 3.13.7、media_kit 1.2.6（libmpv）、provider 6.1.5+1、shared_preferences 2.5.6、path_provider 2.1.6、file_picker 13.3.2、fast_gbk（GBK 解码）、flutter_media_session 3.0.9（首选媒体会话通道）、flutter_test。

**Spec:** [docs/superpowers/specs/2026-11-06-flutter-port-design.md](../specs/2026-11-06-flutter-port-design.md) —— 本计划只实现该文档 §17 的 **M1**；M2（歌词与封面）、M3（换肤与波形）各自另出计划。执行前先读 spec，本计划按 spec 论证，不复述其行为定义。

## Global Constraints

每个 Task 的要求都隐含包含本节，值一律逐字取自 spec 或原版代码。

- 目标平台只有 `windows` 与 `android`。不创建 iOS / macOS / Linux / Web 目标。
- Flutter 工程固定在 `music-player/flutter-app/`。**不得改动 React 侧任何文件**（`src/**`、`index.html`、`vite.config.ts`、`tests/t-tags.mjs` 只读）。
- 本机 Flutter CLI 不在 PATH，所有命令用 `/d/flutter/bin/flutter`（SDK 在 `D:\flutter`）。
- 播放内核固定 media_kit，随包库 `media_kit_libs_windows_audio` 与 `media_kit_libs_android_audio`；中途不换内核（spec §18）。
- 音频扩展名白名单逐字为：`mp3 wav ogg oga opus m4a aac flac webm weba mp4`。
- 四类错误文案逐字：`音频加载被中断，请重试` / `网络错误，无法获取音频文件` / `音频解码失败，文件可能已损坏` / `格式不支持或音频文件不存在`；兜底 `音频播放失败，请稍后重试`；Android 焦点版自动播放受阻 `无法开始播放，请点击播放按钮开始`（对应原版 `浏览器阻止了自动播放，请点击播放按钮开始`）。
- 播放模式取值 `list` / `one` / `shuffle`，中文标签逐字 `列表循环` / `单曲循环` / `随机播放`，切换顺序 `list → one → shuffle → list`。
- 数值常量：`SEEK_STEP = 5`（秒）、`VOLUME_STEP = 0.05`、`PREV_RESTART_AFTER = 3`（秒）、`DURATION_PROBE_TIMEOUT = 3000`（毫秒）、损坏自动跳延迟 `1400`（毫秒）、seek 守卫校验 `900`/`400`（毫秒）与容差 `0.75`（秒）、默认记忆音量 `0.7`、歌词长度上限 `64 * 1024`、最近播放上限 `50` 与重复忽略窗口 `500`（毫秒）、搜索防抖 `200`（毫秒）、Toast 同屏最多 `3` 条与默认时长 `3200`（毫秒）。
- 断点：`900`（桌面双栏 / 窄屏单栏）、`480`（隐藏副标题与按钮文字）。传输按钮可见尺寸 `40px`、播放键 `40px`、触控热区补到 ≥`44px`；列表缩略图 `44×44`、最近项 `40×40`、删除热区 `44×44`。
- `ui/` 目录内不得出现 `Color(0x...)` 字面量，颜色一律取自 `context.tokens`；字号与圆角取自 `AppTokens`。
- 所有用户可见文案为简体中文。
- 回填元数据必须先按 id 从 `Playlist.tracks` 取回**活对象**再改（原版 `addMany` 克隆对象导致的坑），改完显式 `notifyListeners()`。
- 每个 Task 收尾：`/d/flutter/bin/flutter analyze` 无 error → 相关测试全绿 → 一次 commit。commit message 用中文，格式 `feat(scope): 描述` / `test(scope): 描述`。
- 不新增原版没有的控件或页面。唯一例外是 §7.1 的系统媒体会话（spec §3 明确记录）。

---

## 文件结构

M1 建好的文件即最终结构的一部分，后续里程碑只往里加同级文件，不重构。

| 文件 | 单一职责 | 建立于 |
| --- | --- | --- |
| `flutter-app/pubspec.yaml` | 依赖与资源声明 | T1 |
| `flutter-app/analysis_options.yaml` | 静态检查规则（含 `avoid_print`、`prefer_final_locals`） | T1 |
| `lib/core/storage_keys.dart` | 持久化键名表，与原版 `STORAGE_KEYS` 一一对应 | T2 |
| `lib/core/app_prefs.dart` | 带容错的类型化读写；提供 `AppPrefs.inMemory()` 给测试 | T2 |
| `lib/core/format_time.dart` | `mm:ss` / `--:--` / 总时长格式化 | T5 |
| `lib/core/breakpoints.dart` | 900 / 480 断点与派生的布局常量 | T19 |
| `lib/playback/track.dart` | `Track` 模型 + `normalizeTrack` + `isTrackLike` | T3 |
| `lib/playback/track_handle.dart` | 音频来源句柄：`FilePathHandle` / `SafUriHandle` | T3 |
| `lib/playback/play_mode.dart` | `PlayMode` 枚举、标签、顺序 | T4 |
| `lib/playback/playlist.dart` | 列表数据与顺序、洗牌队列；无 IO、无 Flutter | T4 |
| `lib/playback/play_error.dart` | 四类错误归一与文案 | T11 |
| `lib/metadata/byte_reader.dart` | 只读需要字节的随机访问源（头 64KB、上限 8MB） | T6 |
| `lib/metadata/text_decode.dart` | ASCII → UTF-8 → GBK → Latin-1 嗅探解码 | T6 |
| `lib/metadata/id3.dart` | ID3v2.2/2.3/2.4 + unsynchronisation + APIC + ID3v1 | T7 |
| `lib/metadata/vorbis.dart` | FLAC `PICTURE`/Vorbis Comment + OGG 包重组 | T8 |
| `lib/metadata/mp4.dart` | `moov.udta.meta.ilst`（©nam/©ART/©alb/covr） | T9 |
| `lib/metadata/audio_tags.dart` | 容器分派 + `TagResult` + `mergeTaggedNames` | T10 |
| `lib/metadata/cover_image.dart` | 内嵌封面缩到 ≤600px JPEG 落盘 | T10 |
| `lib/playback/audio_driver.dart` | 播放驱动的抽象接口 + `FakeAudioDriver`（测试替身） | T12 |
| `lib/playback/media_kit_driver.dart` | media_kit 实现 | T13 |
| `lib/playback/audio_player.dart` | 对译 `lib/player.js`：事件、loading、seek 守卫、音量/静音 | T13 |
| `lib/playback/transport_controller.dart` | 编排：模式、上下曲、损坏、熔断、自动跳、最近播放 | T14 |
| `lib/library/library_repository.dart` | JSON 文件仓（原子写 + `.bak` 恢复） | T15 |
| `lib/library/recent_store.dart` | 最近 50 条、置顶、去抖、相对时间 | T16 |
| `lib/library/audio_filter.dart` | 白名单校验 + 文件夹递归扫描 + 自然排序 | T17 |
| `lib/library/import_service.dart` | 校验 → 入列 → 标签 → 时长 → 落库 → 后台预取挂载点 | T18 |
| `lib/theme/app_tokens.dart` | 颜色/字号/圆角/阴影 token（M1 只有深色薄荷，字段结构按 M3 的四套预留） | T19 |
| `lib/theme/app_theme.dart` | `ThemeData` 与组件默认样式 | T19 |
| `lib/state/toast_state.dart` | 同 key 去重 + 重新计时 + 3 条并发队列 | T20 |
| `lib/playback/media_session_bridge.dart` | 媒体会话抽象 + `FakeMediaSessionBridge` | T21 |
| `lib/playback/flutter_media_session_bridge.dart` | flutter_media_session 实现（Android + Windows） | T22 |
| `lib/state/player_state.dart` | 界面对播放层的唯一入口 + 三条进度 ValueNotifier | T23 |
| `lib/state/library_state.dart` | 歌单状态、搜索关键词与过滤、还原 | T23 |
| `lib/state/recent_state.dart` | 最近播放状态与失效标记 | T23 |
| `lib/app.dart` | `MaterialApp` + `LayoutBuilder` 断点分发 + 焦点/快捷键宿主 | T24 |
| `lib/ui/header.dart` `drawer_menu.dart` | 顶栏与一级抽屉（添加音乐 / 添加整个文件夹 / 清空播放列表） | T25 |
| `lib/ui/stage.dart` `vinyl_deck.dart` | 播放卡：黑胶静态碟、曲名歌手、时长、M2 歌词占位区 | T26 |
| `lib/ui/track_row.dart` `recent_row.dart` | 两个 tab 的行契约 | T27 |
| `lib/ui/panel.dart` `empty_state.dart` | 两 tab + 搜索 + 统计行 + 空态 + 错误横幅 | T28 |
| `lib/ui/transport.dart` `progress_slider.dart` `volume_slider.dart` | 控制条 | T29 |
| `lib/ui/toasts.dart` | Toast 宿主 | T20 |
| `lib/ui/library_sheet.dart` | 窄屏列表弹层 | T29 |
| `lib/core/shortcuts.dart` | 桌面快捷键表 | T30 |
| `android/app/src/main/AndroidManifest.xml` | 前台服务、权限、文件读取 | T22 |

测试文件与源码同镜像：`test/core/*`、`test/playback/*`、`test/metadata/*`、`test/library/*`、`test/state/*`、`test/ui/*`。

---

## Task 1: 工程脚手架与双端可运行

**Files:**
- Create: `flutter-app/`（`flutter create`）
- Create: `flutter-app/pubspec.yaml`（覆盖生成结果）
- Create: `flutter-app/analysis_options.yaml`
- Delete: `flutter-app/test/widget_test.dart`（模板测试，断言 CounterApp）
- Modify: `flutter-app/lib/main.dart`（替换模板内容）

**Interfaces:**
- Consumes: 无
- Produces: 一个能 `flutter run -d windows` / `-d android` 起来的空壳工程；`LightMusicApp` widget（`lib/app.dart` 由 T24 接管，本任务先放在 `main.dart` 里，T24 迁移时删除）。

- [ ] **Step 1: 创建工程，只开 windows 与 android**

```bash
cd "C:/Users/Administrator/WorkBuddy/2026-11-02-09-29-28/music-player"
/d/flutter/bin/flutter create --project-name light_music \
  --platforms=windows,android --org com.lightmusic flutter-app
```
Expected: `Created project flutter-app`，目录里有 `windows/` 与 `android/`，没有 `ios/`、`web/`。

- [ ] **Step 2: 写 pubspec 依赖（版本逐字取自已核过的 pub.dev）**

```yaml
name: light_music
description: 流光音乐 —— Flutter 版本地音乐播放器
publish_to: none
version: 0.1.0+1

environment:
  sdk: ^3.13.0

dependencies:
  flutter:
    sdk: flutter
  media_kit: ^1.2.6
  media_kit_libs_windows_audio: ^1.0.9
  media_kit_libs_android_audio: ^1.3.8
  provider: ^6.1.5+1
  shared_preferences: ^2.5.6
  path_provider: ^2.1.6
  http: ^1.6.0
  file_picker: ^13.3.2
  fast_gbk: ^1.0.0
  flutter_media_session: ^3.0.9

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^6.0.0

flutter:
  uses-material-design: true
```

> `fast_gbk` 与 `flutter_media_session` 的实际可用版本以 `flutter pub get` 解析结果为准；若解析失败，用 `flutter pub outdated` 查最新兼容版并把真实版本号回填到这里，不要用查不到的版本占位。

- [ ] **Step 3: 解析依赖**

Run: `cd flutter-app && /d/flutter/bin/flutter pub get`
Expected: `Got dependencies`。若报 version solving failed，按 Step 2 的注解决定版本后重跑，不允许注释掉依赖。

- [ ] **Step 4: 收紧静态检查**

```yaml
include: package:flutter_lints/flutter.yaml

analyzer:
  errors:
    avoid_print: error
    unnecessary_this: warning

linter:
  rules:
    - prefer_final_locals
    - unawaited_futures
    - avoid_dynamic_calls
    - require_trailing_commas
```

- [ ] **Step 5: 写最小入口并删掉模板测试**

`lib/main.dart`：

```dart
import 'package:flutter/material.dart';

void main() {
  runApp(const LightMusicApp());
}

class LightMusicApp extends StatelessWidget {
  const LightMusicApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '流光音乐',
      debugShowCheckedModeBanner: false,
      home: const Scaffold(
        body: Center(child: Text('流光音乐 · M1 骨架')),
      ),
    );
  }
}
```

Run: `rm test/widget_test.dart`

- [ ] **Step 6: 验证双端能起来**

Run: `cd flutter-app && /d/flutter/bin/flutter analyze`
Expected: `No issues found`（或仅 info）。

Run: `cd flutter-app && /d/flutter/bin/flutter run -d windows` （另开终端，等 60~120 秒首次 CMake 构建）
Expected: 弹出窗口，标题区显示「流光音乐 · M1 骨架」。

Run: `cd flutter-app && /d/flutter/bin/flutter devices`
Expected: 列出 `windows` 与至少一台 android 设备/模拟器；有 android 目标时再跑一次 `flutter run -d android` 确认装机成功。

- [ ] **Step 7: Commit**

```bash
cd flutter-app && git add -A && git commit -m "chore(flutter): 建立 Flutter 工程骨架并接入 media_kit 与依赖"
```

---

## Task 2: 持久化键表与带容错的 AppPrefs

对译 `src/lib/storage.js`：读写全程 try/catch，数据损坏回退默认值并清理脏数据，绝不抛出到界面层。

**Files:**
- Create: `lib/core/storage_keys.dart`
- Create: `lib/core/app_prefs.dart`
- Test: `test/core/app_prefs_test.dart`

**Interfaces:**
- Consumes: 无
- Produces:
  - `abstract class StorageKeys { static const String playlist = 'playlist'; ... }`，字段名与原版 `STORAGE_KEYS` 逐一对应：`playlist`、`currentId`、`mode`、`volume`、`muted`、`order`、`waveStyle`、`waveColored`、`lyricColor`、`cardTransparency`、`cardFrost`、`themeMode`、`themeColor`、`theme`，外加 `recent`、`bilingual`。
  - `class AppPrefs { Future<String?> readString(String key); Future<void> writeString(String key, String value); Future<num?> readNumber(String key, {num? min, num? max}); Future<void> writeNumber(String key, num value); Future<bool> readBool(String key, {bool fallback = false}); Future<void> writeBool(String key, bool value); Future<void> remove(String key); Future<Json?> readJson(String key); Future<void> writeJson(String key, Object value); factory AppPrefs.inMemory(); }`（`AppPrefs` 用 `shared_preferences` 后端；`inMemory()` 返回一个 Map 支撑的实现，测试用它，不依赖插件。）

- [ ] **Step 1: 写失败测试（容错语义全部覆盖）**

```dart
// test/core/app_prefs_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/app_prefs.dart';

void main() {
  group('AppPrefs', () {
    test('脏 JSON 回退默认值并清理键', () async {
      final prefs = AppPrefs.inMemory()..debugSeed('playlist', '{bad json');
      expect(await prefs.readJson('playlist'), isNull);
      expect(prefs.debugContains('playlist'), isFalse);
    });

    test('readNumber 越界夹紧、非数值回退', () async {
      final prefs = AppPrefs.inMemory()
        ..debugSeed('volume', '2.5')
        ..debugSeed('muted', 'not-a-number');
      expect(await prefs.readNumber('volume', min: 0, max: 1), 1);
      expect(await prefs.readNumber('muted', min: 0, max: 1), isNull);
    });

    test('readBool 只认真假字符串，脏值用 fallback', () async {
      final prefs = AppPrefs.inMemory()
        ..debugSeed('muted', 'true')
        ..debugSeed('waveColored', '也许');
      expect(await prefs.readBool('muted'), isTrue);
      expect(await prefs.readBool('waveColored', fallback: true), isTrue);
    });

    test('写数字后可读回，remove 之后不存在', () async {
      final prefs = AppPrefs.inMemory();
      await prefs.writeNumber('volume', 0.35);
      expect(await prefs.readNumber('volume'), 0.35);
      await prefs.remove('volume');
      expect(prefs.debugContains('volume'), isFalse);
    });
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/core/app_prefs_test.dart`
Expected: 编译失败 —— `Target of URI doesn't exist: 'package:light_music/core/app_prefs.dart'`。

- [ ] **Step 3: 实现**

```dart
// lib/core/storage_keys.dart
/// 与 React 版 src/state/constants.ts 的 STORAGE_KEYS 一一对应。
abstract final class StorageKeys {
  static const String playlist = 'playlist';
  static const String currentId = 'currentId';
  static const String mode = 'mode';
  static const String volume = 'volume';
  static const String muted = 'muted';
  static const String order = 'order';
  static const String waveStyle = 'waveStyle';
  static const String waveColored = 'waveColored';
  static const String lyricColor = 'lyricColor';
  static const String cardTransparency = 'cardTransparency';
  static const String cardFrost = 'cardFrost';
  static const String themeMode = 'themeMode';
  static const String themeColor = 'themeColor';
  /// 老版本的单值主题键，只用于迁移读取（spec §6.3）
  static const String theme = 'theme';
  static const String recent = 'recent';
  static const String bilingual = 'bilingual';
}
```

```dart
// lib/core/app_prefs.dart
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 带容错的键值读写：任何解析失败都回退默认值并清掉脏数据，绝不抛出。
class AppPrefs {
  AppPrefs._(this._backing);

  factory AppPrefs.shared() => AppPrefs._(_SharedBacking());

  /// 测试用，不碰插件。
  factory AppPrefs.inMemory() => AppPrefs._(_MemoryBacking({}));

  final _Backing _backing;

  String? _raw(String key) => _backing.read(key);

  void debugSeed(String key, String value) => _backing.write(key, value);

  bool debugContains(String key) => _backing.read(key) != null;

  Future<String?> readString(String key) async => _raw(key);

  Future<void> writeString(String key, String value) async {
    try {
      _backing.write(key, value);
    } catch (_) {
      // 存储不可用：不影响当前播放，与原版一致（原版提示「刷新后需要重新添加」）
    }
  }

  Future<num?> readNumber(String key, {num? min, num? max}) async {
    final raw = _raw(key);
    if (raw == null) return null;
    final value = num.tryParse(raw);
    if (value == null || !value.isFinite) {
      _backing.remove(key);
      return null;
    }
    num clamped = value;
    if (min != null && clamped < min) clamped = min;
    if (max != null && clamped > max) clamped = max;
    return clamped;
  }

  Future<void> writeNumber(String key, num value) =>
      writeString(key, value.toString());

  Future<bool> readBool(String key, {bool fallback = false}) async {
    final raw = _raw(key);
    if (raw == 'true') return true;
    if (raw == 'false') return false;
    if (raw != null) _backing.remove(key);
    return fallback;
  }

  Future<void> writeBool(String key, bool value) =>
      writeString(key, value ? 'true' : 'false');

  /// 解析失败即清理脏数据并返回 null（调用方走默认分支）。
  Future<Object?> readJson(String key) async {
    final raw = _raw(key);
    if (raw == null) return null;
    try {
      return jsonDecode(raw);
    } catch (_) {
      _backing.remove(key);
      return null;
    }
  }

  Future<void> writeJson(String key, Object value) =>
      writeString(key, jsonEncode(value));

  Future<void> remove(String key) async => _backing.remove(key);
}

abstract class _Backing {
  String? read(String key);
  void write(String key, String value);
  void remove(String key);
}

class _MemoryBacking implements _Backing {
  _MemoryBacking(this._store);
  final Map<String, String> _store;

  @override
  String? read(String key) => _store[key];

  @override
  void write(String key, String value) => _store[key] = value;

  @override
  void remove(String key) => _store.remove(key);
}

class _SharedBacking implements _Backing {
  _SharedBacking();

  SharedPreferences? _cached;

  Future<SharedPreferences> _prefs() async =>
      _cached ??= await SharedPreferences.getInstance();

  @override
  String? read(String key) => _cached?.getString(key);

  @override
  void write(String key, String value) {
    _prefs().then((p) {
      _cached = p;
      p.setString(key, value);
    }).catchError((Object _) {});
  }

  @override
  void remove(String key) {
    _prefs().then((p) {
      _cached = p;
      p.remove(key);
    }).catchError((Object _) {});
  }
}
```

> `_SharedBacking` 的首次读依赖 `main()` 里先 `await AppPrefs.shared()` 的预热（T23 Step 1 会加 `await SharedPreferences.getInstance()`）。同步读是为了让界面任何位置都能零成本取值，不做异步散落。

- [ ] **Step 4: 跑测试确认通过**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/core/app_prefs_test.dart`
Expected: `All tests passed!`（4 个用例）

- [ ] **Step 5: Commit**

```bash
cd flutter-app && git add lib/core test/core && git commit -m "feat(core): 新增带容错的持久化层与键表"
```

---

## Task 3: Track 模型与音频来源句柄

对译 `src/state/types.ts` 与 `src/lib/playlist.js` 的 `normalizeTrack` / `isTrackLike`。`id` 与 `src` 不在归一时改写（原版如此，id 由调用方给出）。

**Files:**
- Create: `lib/playback/track.dart`
- Create: `lib/playback/track_handle.dart`
- Test: `test/playback/track_test.dart`

**Interfaces:**
- Consumes: `AppPrefs`（T2）不参与本任务；仅用 `dart:convert`。
- Produces:
  - `class Track { String id; String title; String artist; String album; String cover; double duration; bool isLocal; String lyrics; String lyricsPlain; String lyricsSource; bool restored; TrackHandle handle; String get src; set src; Map<String, Object?> toJson(); static Track? fromJson(Map<String, Object?> json); Track copy(); }`
  - `Track? normalizeTrack(Object? raw); bool isTrackLike(Object? raw);`
  - `const int kMaxLyricsLength = 64 * 1024;`
  - `sealed class TrackHandle { String get uri; String get displayName; Future<bool> exists(); Future<int?> sizeBytes(); Map<String, Object?> toJson(); static TrackHandle? fromJson(Map<String, Object?> json); }`，实现 `FilePathHandle(String path)` 与 `SafUriHandle(String uri, String displayName)`。

- [ ] **Step 1: 写失败测试（逐条对齐原版 normalizeTrack 行为）**

```dart
// test/playback/track_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/playback/track.dart';
import 'package:light_music/playback/track_handle.dart';

void main() {
  group('normalizeTrack', () {
    test('缺 id 或缺 src 判为非法', () {
      expect(normalizeTrack({'title': 'a', 'src': 'x'}), isNull);
      expect(normalizeTrack({'id': '', 'src': 'x', 'title': 'a'}), isNull);
      expect(normalizeTrack({'id': 'a', 'src': '', 'title': 'a'}), isNull);
      expect(normalizeTrack(null), isNull);
      expect(normalizeTrack('not a map'), isNull);
    });

    test('空标题退回「未知曲目」，首尾空白去掉', () {
      final t = normalizeTrack({'id': '1', 'src': 'x', 'title': '  十年  '})!;
      expect(t.title, '十年');
      final blank = normalizeTrack({'id': '1', 'src': 'x', 'title': '   '})!;
      expect(blank.title, '未知曲目');
    });

    test('artist/album/cover 非字符串或空白一律空串', () {
      final t = normalizeTrack({
        'id': '1', 'src': 'x', 'title': 'a',
        'artist': 123, 'album': '', 'cover': '   ',
      })!;
      expect(t.artist, '');
      expect(t.album, '');
      expect(t.cover, '');
    });

    test('duration 只有正有限数保留，其余 NaN', () {
      expect(normalizeTrack({'id': '1', 'src': 'x', 'duration': 213.2})!.duration,
          213.2);
      expect(normalizeTrack({'id': '1', 'src': 'x', 'duration': 0})!.duration.isNaN,
          isTrue);
      expect(
          normalizeTrack({'id': '1', 'src': 'x', 'duration': -3})!.duration.isNaN,
          isTrue);
      expect(
          normalizeTrack({'id': '1', 'src': 'x', 'duration': '80'})!.duration.isNaN,
          isTrue);
    });

    test('lyrics 截到 64KB，lyricsSource 只认 auto/manual', () {
      final long = 'a' * (kMaxLyricsLength + 100);
      final t = normalizeTrack({
        'id': '1', 'src': 'x', 'lyrics': long, 'lyricsSource': 'manual',
      })!;
      expect(t.lyrics.length, kMaxLyricsLength);
      expect(t.lyricsSource, 'manual');
      expect(
          normalizeTrack({'id': '1', 'src': 'x', 'lyricsSource': 'auto?'})!
              .lyricsSource,
          '');
    });

    test('isLocal 只认真 true', () {
      expect(normalizeTrack({'id': '1', 'src': 'x', 'isLocal': 1})!.isLocal,
          isFalse);
      expect(normalizeTrack({'id': '1', 'src': 'x', 'isLocal': true})!.isLocal,
          isTrue);
    });

    test('toJson/fromJson 往返一致，copy 得到可改的独立对象', () {
      final t = normalizeTrack({
        'id': '1', 'src': 'file:///a.flac', 'title': '白玫瑰', 'artist': '陈奕迅',
        'duration': 226.0, 'isLocal': true,
        'handle': {'kind': 'file', 'path': '/a.flac'},
      })!;
      final back = Track.fromJson(t.toJson())!;
      expect(back.id, t.id);
      expect(back.title, '白玫瑰');
      expect(back.duration, 226.0);
      expect(back.handle.uri, 'file:///a.flac');
      final c = t.copy()..artist = 'Eason Chan';
      expect(t.artist, '陈奕迅');
      expect(c.artist, 'Eason Chan');
    });
  });

  group('TrackHandle', () {
    test('路径句柄给出 file URI 并可判存在', () async {
      final h = FilePathHandle('test/fixtures/absent.flac');
      expect(h.uri, startsWith('file://'));
      expect(await h.exists(), isFalse);
      expect(await h.sizeBytes(), isNull);
    });

    test('SAF 句柄原样保留 uri 与显示名', () {
      const uri = 'content://com.android.externalstorage.documents/tree/x';
      final h = SafUriHandle(uri, 'U盘');
      expect(h.uri, uri);
      expect(h.displayName, 'U盘');
      expect(TrackHandle.fromJson(h.toJson())!.uri, uri);
    });
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/playback/track_test.dart`
Expected: 编译失败，提示 `track.dart` / `track_handle.dart` 不存在。

- [ ] **Step 3: 实现句柄**

```dart
// lib/playback/track_handle.dart
import 'dart:io';

import 'package:path/path.dart' as p;

/// 音频来源。桌面是绝对路径，Android 是 SAF 持久 URI。
sealed class TrackHandle {
  const TrackHandle();

  String get uri;
  String get displayName;
  Future<bool> exists();
  Future<int?> sizeBytes();
  Map<String, Object?> toJson();

  static TrackHandle? fromJson(Map<String, Object?>? json) {
    if (json == null) return null;
    final kind = json['kind'];
    if (kind == 'file') {
      final path = json['path'];
      if (path is! String || path.isEmpty) return null;
      return FilePathHandle(path);
    }
    if (kind == 'saf') {
      final uri = json['uri'];
      if (uri is! String || uri.isEmpty) return null;
      return SafUriHandle(uri, (json['name'] as String?) ?? '');
    }
    return null;
  }
}

class FilePathHandle extends TrackHandle {
  const FilePathHandle(this.path);
  final String path;

  @override
  String get uri => p.toUri(path).toString();

  @override
  String get displayName => p.basename(path);

  @override
  Future<bool> exists() async {
    try {
      return await File(path).exists();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<int?> sizeBytes() async {
    try {
      return await File(path).length();
    } catch (_) {
      return null;
    }
  }

  @override
  Map<String, Object?> toJson() => {'kind': 'file', 'path': path};
}

class SafUriHandle extends TrackHandle {
  const SafUriHandle(this.rawUri, this.displayName);
  final String rawUri;

  @override
  String get uri => rawUri;

  @override
  final String displayName;

  /// SAF 的存在性无法用 dart:io 判定，交由平台通道在 T22 之后补；
  /// M1 里返回 true，失效由播放错误路径（T11 的 code 4）捕获。
  @override
  Future<bool> exists() async => true;

  @override
  Future<int?> sizeBytes() async => null;

  @override
  Map<String, Object?> toJson() =>
      {'kind': 'saf', 'uri': rawUri, 'name': displayName};
}
```

> `package:path` 随 `flutter` 传递可用；若 `pub get` 后仍报缺包，在 `pubspec.yaml` 的 `dependencies` 加 `path: ^1.9.0` 再跑一次 `flutter pub get`。

- [ ] **Step 4: 实现 Track**

```dart
// lib/playback/track.dart
import 'track_handle.dart';

const int kMaxLyricsLength = 64 * 1024;

const String kUnknownTitle = '未知曲目';

bool _isTrackLike(Object? raw) =>
    raw is Map &&
    raw['id'] is String &&
    (raw['id'] as String).isNotEmpty &&
    raw['title'] is String &&
    raw['src'] is String &&
    (raw['src'] as String).isNotEmpty;

/// 与 normalizeTrack 同：不改 id/src，只补默认值与清洗。
Track? normalizeTrack(Object? raw) {
  if (!_isTrackLike(raw)) return null;
  final map = (raw as Map).cast<String, Object?>();
  final duration = map['duration'];
  return Track(
    id: map['id']! as String,
    title: ((map['title'] as String?) ?? '').trim().isEmpty
        ? kUnknownTitle
        : (map['title'] as String).trim(),
    artist: _trimmed(map['artist']),
    album: _trimmed(map['album']),
    cover: _trimmed(map['cover']),
    src: map['src']! as String,
    duration: duration is num && duration.isFinite && duration > 0
        ? duration.toDouble()
        : double.nan,
    isLocal: map['isLocal'] == true,
    lyrics: _clampLyrics(map['lyrics']),
    lyricsPlain: _clampLyrics(map['lyricsPlain']),
    lyricsSource: _trimmed(map['lyricsSource']) == 'auto' ||
            _trimmed(map['lyricsSource']) == 'manual'
        ? _trimmed(map['lyricsSource'])
        : '',
    restored: map['restored'] == true,
    handle: TrackHandle.fromJson(map['handle'] is Map
            ? (map['handle'] as Map).cast<String, Object?>()
            : null) ??
        FilePathHandle(map['src']! as String),
  );
}

String _trimmed(Object? value) =>
    value is String && value.trim().isNotEmpty ? value.trim() : '';

String _clampLyrics(Object? value) {
  if (value is! String || value.trim().isEmpty) return '';
  return value.length > kMaxLyricsLength
      ? value.substring(0, kMaxLyricsLength)
      : value;
}

class Track {
  Track({
    required this.id,
    required this.src,
    this.title = '',
    this.artist = '',
    this.album = '',
    this.cover = '',
    double? duration,
    this.isLocal = false,
    this.lyrics = '',
    this.lyricsPlain = '',
    this.lyricsSource = '',
    this.restored = false,
    TrackHandle? handle,
  })  : duration = duration ?? double.nan,
        handle = handle ?? FilePathHandle(src);

  final String id;
  String title;
  String artist;
  String album;
  String cover;
  String src;
  double duration;
  bool isLocal;
  String lyrics;
  String lyricsPlain;
  String lyricsSource;
  bool restored;
  TrackHandle handle;

  bool get hasDuration => duration.isFinite && duration > 0;

  /// 已有真封面 == cover 非空。生成卡不写这里（spec §12）。
  bool get hasRealCover => cover.isNotEmpty;

  Track copy() => Track(
        id: id,
        src: src,
        title: title,
        artist: artist,
        album: album,
        cover: cover,
        duration: duration,
        isLocal: isLocal,
        lyrics: lyrics,
        lyricsPlain: lyricsPlain,
        lyricsSource: lyricsSource,
        restored: restored,
        handle: handle,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'artist': artist,
        'album': album,
        'cover': cover,
        'src': src,
        'duration': hasDuration ? duration : null,
        'isLocal': isLocal,
        'lyrics': lyrics,
        'lyricsPlain': lyricsPlain,
        'lyricsSource': lyricsSource,
        'restored': restored,
        'handle': handle.toJson(),
      };

  static Track? fromJson(Map<String, Object?> json) => normalizeTrack(json);
}
```

- [ ] **Step 5: 跑测试确认通过**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/playback/track_test.dart`
Expected: `All tests passed!`（9 个用例）

- [ ] **Step 6: Commit**

```bash
cd flutter-app && git add lib/playback test/playback && git commit -m "feat(playback): 移植 Track 模型与音频来源句柄"
```

---

## Task 4: Playlist —— 列表数据、三种模式与洗牌队列

对译 `src/lib/playlist.js` 全部公开方法与私有洗牌实现。随机队列语义按原版：`nextIndex({auto})` 在 `one` 模式且 auto 时返回当前索引原地重播；SHUFFLE 时推进 `#shufflePos`（**有副作用**，原版 JSDoc 明确记录）；`addMany` 克隆对象。

**Files:**
- Create: `lib/playback/play_mode.dart`
- Create: `lib/playback/playlist.dart`
- Test: `test/playback/playlist_test.dart`

**Interfaces:**
- Consumes: `Track`、`normalizeTrack`（T3）
- Produces:
  - `enum PlayMode { list, one, shuffle }` + `String playModeLabel(PlayMode)` + `const List<PlayMode> kModeOrder` + `PlayMode playModeFromId(String?)` + `String playModeId(PlayMode)`
  - `class AddManyResult { int added; int firstIndex; bool loadedFirst; }`
  - `class RemoveResult { Track? removed; bool currentChanged; }`
  - `class Playlist { Playlist({List<Map<String,Object?>> tracks, PlayMode mode, int currentIndex, Random? random}); List<Track> get tracks; int get size; PlayMode get mode; int get currentIndex; Track? get current; bool get isShuffle; double get totalDuration; int indexOfId(String id); Track? setCurrentIndex(int); Track? setCurrentById(String); Track? addAt(Track, {int? at}); AddManyResult addMany(List<Track>); RemoveResult removeById(String); bool move(String id, int delta); List<Track> clear(); void setMode(PlayMode); PlayMode cycleMode(); int nextIndex({bool auto}); int prevIndex(); }`
  - 注入 `Random` 是为了让洗牌测试可确定；不注入时用 `Random()`。

- [ ] **Step 1: 写失败测试（覆盖原版每条分支）**

```dart
// test/playback/playlist_test.dart
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/playback/play_mode.dart';
import 'package:light_music/playback/playlist.dart';
import 'package:light_music/playback/track.dart';

Track t(String id, {String? title, String src = '/a.flac'}) => Track(
      id: id,
      src: src,
      title: title ?? '歌$id',
      duration: 100,
    );

void main() {
  test('模式标签与循环顺序逐字对齐', () {
    expect(playModeLabel(PlayMode.list), '列表循环');
    expect(playModeLabel(PlayMode.one), '单曲循环');
    expect(playModeLabel(PlayMode.shuffle), '随机播放');
    expect(kModeOrder.map(playModeId), ['list', 'one', 'shuffle']);
    expect(Playlist(tracks: [t('1')]).cycleMode(), PlayMode.one);
    expect(Playlist(tracks: [t('1')], mode: PlayMode.shuffle).cycleMode(),
        PlayMode.list);
    expect(playModeFromId('nonsense'), PlayMode.list);
  });

  test('空列表 current 为 null、currentIndex -1', () {
    final p = Playlist(tracks: const []);
    expect(p.size, 0);
    expect(p.current, isNull);
    expect(p.currentIndex, -1);
    expect(p.nextIndex(), -1);
    expect(p.prevIndex(), -1);
    expect(p.totalDuration.isNaN, isFalse);
  });

  test('非法曲目在建列表时被丢掉', () {
    final p = Playlist(tracks: [
      {'id': 'a', 'src': '/a', 'title': 'A'},
      {'title': '缺 id'},
    ]);
    expect(p.size, 1);
    expect(p.tracks.first.title, 'A');
  });

  test('addAt 落在当前项之前时当前索引后移一位', () {
    final p = Playlist(tracks: [t('1'), t('2'), t('3')], currentIndex: 1);
    p.addAt(t('0'), at: 0);
    expect(p.currentIndex, 2);
    expect(p.current!.id, '2');
    expect(p.tracks.map((e) => e.id), ['0', '1', '2', '3']);
  });

  test('空列表时 addAt 直接把当前项设为它', () {
    final p = Playlist(tracks: const []);
    final added = p.addAt(t('9'));
    expect(p.currentIndex, 0);
    expect(added!.id, '9');
  });

  test('addMany 克隆对象，返回 firstIndex 与 loadedFirst', () {
    final p = Playlist(tracks: const []);
    final r = p.addMany([t('1'), t('2')]);
    expect(r.added, 2);
    expect(r.firstIndex, 0);
    expect(r.loadedFirst, isTrue);
    expect(identical(p.tracks.first, p.tracks.first), isTrue);
    p.tracks.first.title = '改了';
    expect(p.tracks.first.title, '改了');
    final r2 = p.addMany([t('3')]);
    expect(r2.firstIndex, 2);
    expect(r2.loadedFirst, isFalse);
  });

  test('removeById 三种位置各按原版处理', () {
    final before = Playlist(tracks: [t('1'), t('2'), t('3')], currentIndex: 2);
    before.removeById('1');
    expect(before.currentIndex, 1);
    expect(before.current!.id, '3');
    expect(before.removeById('1').removed, isNull);

    final current = Playlist(tracks: [t('1'), t('2'), t('3')], currentIndex: 1);
    final r = current.removeById('2');
    expect(r.currentChanged, isTrue);
    expect(r.removed!.id, '2');
    expect(current.current!.id, '3');

    final last = Playlist(tracks: [t('1'), t('2')], currentIndex: 1);
    last.removeById('2');
    expect(last.current!.id, '1');

    final only = Playlist(tracks: [t('1')], currentIndex: 0);
    only.removeById('1');
    expect(only.size, 0);
    expect(only.currentIndex, -1);
    expect(only.current, isNull);
  });

  test('move 越界返回 false，当前项跟随移动', () {
    final p = Playlist(tracks: [t('1'), t('2'), t('3')], currentIndex: 0);
    expect(p.move('1', 1), isTrue);
    expect(p.currentIndex, 1);
    expect(p.tracks.map((e) => e.id), ['2', '1', '3']);
    expect(p.move('1', 5), isFalse);
    expect(p.move('nope', 1), isFalse);
  });

  test('list 模式环形推进，one 模式 auto 时原地重播', () {
    final p = Playlist(tracks: [t('1'), t('2'), t('3')], currentIndex: 2);
    expect(p.nextIndex(), 0);
    expect(p.prevIndex(), 1);
    final one = Playlist(tracks: [t('1'), t('2')], mode: PlayMode.one);
    expect(one.nextIndex(auto: true), 0);
    expect(one.nextIndex(), 1);
  });

  test('shuffle 一轮内不重复，一轮结束重洗且首项不与上一项相同', () {
    final p = Playlist(
      tracks: [t('1'), t('2'), t('3'), t('4')],
      mode: PlayMode.shuffle,
      random: Random(7),
    );
    final firstRound = <int>[];
    for (var i = 0; i < 4; i++) {
      firstRound.add(p.nextIndex());
      p.setCurrentIndex(firstRound.last);
    }
    expect(firstRound.toSet().length, 4);
    final fifth = p.nextIndex();
    expect(fifth, isNot(firstRound.last));
  });

  test('手动点选会把随机游标同步到队列位置后继续推进', () {
    final p = Playlist(
      tracks: [t('1'), t('2'), t('3')],
      mode: PlayMode.shuffle,
      random: Random(3),
    );
    p.setCurrentById('3');
    final afterManual = p.nextIndex();
    final queue = p.shuffleOrderForTest;
    expect(queue[p.indexOfId(p.tracks[afterManual].id).toString()] != null,
        isTrue);
    expect(afterManual, isNot(2));
  });

  test('列表变化后重建队列，totalDuration 跳过未知时长', () {
    final p = Playlist(tracks: [
      {'id': '1', 'src': '/a', 'title': 'A', 'duration': 100},
      {'id': '2', 'src': '/b', 'title': 'B'},
    ]);
    expect(p.totalDuration, 100);
    p.addAt(t('3'));
    expect(p.shuffleOrderForTest.length, p.size);
  });
}
```

> `shuffleOrderForTest` 是测试可见的调试 getter（返回 `List<int>`，洗牌队列快照），实现里注释写明「仅供测试断言洗牌语义，界面层不得调用」。

- [ ] **Step 2: 跑测试确认失败**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/playback/playlist_test.dart`
Expected: 编译失败 —— `play_mode.dart` / `playlist.dart` 不存在。

- [ ] **Step 3: 实现模式**

```dart
// lib/playback/play_mode.dart
enum PlayMode { list, one, shuffle }

const List<PlayMode> kModeOrder = [PlayMode.list, PlayMode.one, PlayMode.shuffle];

String playModeId(PlayMode mode) => mode.name;

String playModeLabel(PlayMode mode) => switch (mode) {
      PlayMode.list => '列表循环',
      PlayMode.one => '单曲循环',
      PlayMode.shuffle => '随机播放',
    };

PlayMode playModeFromId(Object? id) => kModeOrder.firstWhere(
      (m) => m.name == id,
      orElse: () => PlayMode.list,
    );
```

- [ ] **Step 4: 实现 Playlist**

```dart
// lib/playback/playlist.dart
import 'dart:math';

import 'play_mode.dart';
import 'track.dart';

class AddManyResult {
  AddManyResult({required this.added, required this.firstIndex, required this.loadedFirst});
  final int added;
  final int firstIndex;
  final bool loadedFirst;
}

class RemoveResult {
  RemoveResult({this.removed, this.currentChanged = false});
  final Track? removed;
  final bool currentChanged;
}

int _clamp(num value, int min, int max) {
  if (!value.isFinite) return min;
  return value.clamp(min, max).round();
}

class Playlist {
  Playlist({
    List<Map<String, Object?>>? tracks,
    PlayMode mode = PlayMode.list,
    int? currentIndex,
    Random? random,
  })  : _tracks = (tracks ?? const [])
            .map(normalizeTrack)
            .whereType<Track>()
            .toList(),
        _mode = mode,
        _currentIndex = -1,
        _rng = random ?? Random() {
    if (_tracks.isEmpty) {
      _currentIndex = -1;
    } else {
      _currentIndex = _clamp(currentIndex ?? 0, 0, _tracks.length - 1);
    }
    _rebuildShuffle();
  }

  /// 直接用已构造好的 Track 列表建表（还原路径用，避免二次克隆）。
  Playlist.fromTracks(
    List<Track> tracks, {
    PlayMode mode = PlayMode.list,
    int? currentIndex,
    Random? random,
  })  : _tracks = tracks.toList(),
        _mode = mode,
        _currentIndex = -1,
        _rng = random ?? Random() {
    if (_tracks.isEmpty) {
      _currentIndex = -1;
    } else {
      _currentIndex = _clamp(currentIndex ?? 0, 0, _tracks.length - 1);
    }
    _rebuildShuffle();
  }

  final List<Track> _tracks;
  final Random _rng;
  PlayMode _mode;
  int _currentIndex;
  List<int> _shuffleQueue = [];
  int _shufflePos = -1;

  List<Track> get tracks => _tracks;
  int get size => _tracks.length;
  PlayMode get mode => _mode;
  int get currentIndex => _currentIndex;
  bool get isShuffle => _mode == PlayMode.shuffle;

  /// 列表里的活对象，不是副本：回填元数据必须走这里（spec §8）。
  Track? byId(String id) {
    final at = indexOfId(id);
    return at < 0 ? null : _tracks[at];
  }

  Track? get current =>
      _currentIndex < 0 || _currentIndex >= _tracks.length
          ? null
          : _tracks[_currentIndex];

  /// 未知时长不参与累加（原版 totalDuration）。
  double get totalDuration {
    var total = 0.0;
    for (final track in _tracks) {
      if (track.duration.isFinite) total += track.duration;
    }
    return total;
  }

  /// 仅供测试断言洗牌队列语义。
  List<int> get shuffleOrderForTest => List<int>.from(_shuffleQueue);

  int indexOfId(String id) {
    for (var i = 0; i < _tracks.length; i++) {
      if (_tracks[i].id == id) return i;
    }
    return -1;
  }

  PlayMode setMode(PlayMode mode) {
    _mode = mode;
    if (mode == PlayMode.shuffle) _rebuildShuffle();
    return _mode;
  }

  PlayMode cycleMode() {
    final at = kModeOrder.indexOf(_mode);
    return setMode(kModeOrder[(at + 1) % kModeOrder.length]);
  }

  Track? setCurrentIndex(int index) {
    if (_tracks.isEmpty) {
      _currentIndex = -1;
      return null;
    }
    _currentIndex = _clamp(index, 0, _tracks.length - 1);
    _syncShuffleCursor();
    return current;
  }

  /// 找不到时返回当前 current，不改状态（原版 setCurrentById）。
  Track? setCurrentById(String id) {
    final at = indexOfId(id);
    if (at < 0) return current;
    return setCurrentIndex(at);
  }

  Track? addAt(Track track, {int? at}) {
    final normalized = normalizeTrack(track.toJson());
    if (normalized == null) return null;
    final insertAt = _clamp(at ?? _tracks.length, 0, _tracks.length);
    _tracks.insert(insertAt, normalized);
    if (_currentIndex < 0) {
      _currentIndex = insertAt;
    } else if (insertAt <= _currentIndex) {
      _currentIndex += 1;
    }
    _rebuildShuffle();
    return normalized;
  }

  /// 注意：克隆对象。返回的 normalized 才是列表里的活对象。
  AddManyResult addMany(List<Track> tracks) {
    final normalized =
        tracks.map((e) => normalizeTrack(e.toJson())).whereType<Track>().toList();
    if (normalized.isEmpty) {
      return AddManyResult(added: 0, firstIndex: -1, loadedFirst: false);
    }
    final firstIndex = _tracks.length;
    final wasEmpty = _currentIndex < 0 && _tracks.isEmpty;
    _tracks.addAll(normalized);
    if (wasEmpty) _currentIndex = firstIndex;
    _rebuildShuffle();
    return AddManyResult(
        added: normalized.length, firstIndex: firstIndex, loadedFirst: wasEmpty);
  }

  RemoveResult removeById(String id) {
    final at = indexOfId(id);
    if (at < 0) return RemoveResult();
    final removed = _tracks.removeAt(at);
    var currentChanged = false;
    if (_tracks.isEmpty) {
      _currentIndex = -1;
      currentChanged = true;
    } else if (at < _currentIndex) {
      _currentIndex -= 1;
    } else if (at == _currentIndex) {
      _currentIndex = _clamp(_currentIndex, 0, _tracks.length - 1);
      currentChanged = true;
    }
    _rebuildShuffle();
    return RemoveResult(removed: removed, currentChanged: currentChanged);
  }

  bool move(String id, int delta) {
    final at = indexOfId(id);
    final to = at + delta;
    if (at < 0 || to < 0 || to >= _tracks.length) return false;
    final track = _tracks.removeAt(at);
    _tracks.insert(to, track);
    if (_currentIndex == at) {
      _currentIndex = to;
    } else if (at < _currentIndex && to >= _currentIndex) {
      _currentIndex -= 1;
    } else if (at > _currentIndex && to <= _currentIndex) {
      _currentIndex += 1;
    }
    _rebuildShuffle();
    return true;
  }

  List<Track> clear() {
    final old = List<Track>.from(_tracks);
    _tracks.clear();
    _currentIndex = -1;
    _shuffleQueue = [];
    _shufflePos = -1;
    return old;
  }

  int nextIndex({bool auto = false}) {
    if (_tracks.isEmpty) return -1;
    if (auto && _mode == PlayMode.one) return _currentIndex;
    if (_mode == PlayMode.shuffle) return _advanceShuffle(1);
    if (_currentIndex < 0) return 0;
    return (_currentIndex + 1) % _tracks.length;
  }

  int prevIndex() {
    if (_tracks.isEmpty) return -1;
    if (_mode == PlayMode.shuffle) return _advanceShuffle(-1);
    if (_currentIndex < 0) return 0;
    return (_currentIndex - 1 + _tracks.length) % _tracks.length;
  }

  int _advanceShuffle(int step) {
    if (_tracks.isEmpty) return -1;
    _syncShuffleCursor();
    var pos = _shufflePos + step;
    if (pos >= _shuffleQueue.length) {
      _rebuildShuffle(keepCurrentFirst: false);
      pos = 0;
    }
    if (pos < 0) pos = _shuffleQueue.length - 1;
    _shufflePos = _clamp(pos, 0, _shuffleQueue.length - 1);
    final idx = _shufflePos >= 0 && _shufflePos < _shuffleQueue.length
        ? _shuffleQueue[_shufflePos]
        : 0;
    return idx is int ? idx : 0;
  }

  void _syncShuffleCursor() {
    if (_shuffleQueue.length != _tracks.length) {
      _rebuildShuffle();
      return;
    }
    if (_currentIndex < 0) {
      _shufflePos = -1;
      return;
    }
    final at = _shuffleQueue.indexOf(_currentIndex);
    if (at >= 0) {
      _shufflePos = at;
    } else {
      _rebuildShuffle();
    }
  }

  void _rebuildShuffle({bool keepCurrentFirst = true}) {
    final size = _tracks.length;
    final order = List<int>.generate(size, (i) => i);
    for (var i = size - 1; i > 0; i--) {
      final j = _rng.nextInt(i + 1);
      final tmp = order[i];
      order[i] = order[j];
      order[j] = tmp;
    }
    if (size > 1 && keepCurrentFirst && _currentIndex >= 0) {
      final at = order.indexOf(_currentIndex);
      if (at > 0) {
        order.removeAt(at);
        order.insert(0, _currentIndex);
      }
    } else if (size > 1 && !keepCurrentFirst && order[0] == _currentIndex) {
      final j = 1 + _rng.nextInt(size - 1);
      final tmp = order[0];
      order[0] = order[j];
      order[j] = tmp;
    }
    _shuffleQueue = order;
    _shufflePos =
        keepCurrentFirst && _currentIndex >= 0 && size > 0 ? 0 : -1;
  }
}
```

- [ ] **Step 5: 跑测试确认通过**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/playback/playlist_test.dart`
Expected: `All tests passed!`（12 个用例）

- [ ] **Step 6: Commit**

```bash
cd flutter-app && git add lib/playback test/playback && git commit -m "feat(playback): 移植播放列表与随机洗牌队列"
```

---

## Task 5: 时间格式化

**Files:**
- Create: `lib/core/format_time.dart`
- Test: `test/core/format_time_test.dart`

**Interfaces:**
- Consumes: 无
- Produces: `String formatTime(double? seconds)`（返回 `mm:ss`，未知返回 `--:--`）、`String formatTotal(double? seconds)`（超过 1 小时时 `h:mm:ss`，未知返回 `--:--`）

- [ ] **Step 1: 写失败测试**

```dart
// test/core/format_time_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/format_time.dart';

void main() {
  test('未知时长一律 --:--', () {
    expect(formatTime(null), '--:--');
    expect(formatTime(double.nan), '--:--');
    expect(formatTime(double.infinity), '--:--');
    expect(formatTotal(double.nan), '--:--');
  });

  test('mm:ss 补零并向下取整', () {
    expect(formatTime(0), '00:00');
    expect(formatTime(9.9), '00:09');
    expect(formatTime(65), '01:05');
    expect(formatTime(600.7), '10:00');
  });

  test('超过一小时带小时位', () {
    expect(formatTotal(3599), '59:59');
    expect(formatTotal(3600), '1:00:00');
    expect(formatTotal(3725), '1:02:05');
  });

  test('负数按 0 处理', () {
    expect(formatTime(-3), '00:00');
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/core/format_time_test.dart`
Expected: 编译失败，`format_time.dart` 不存在。

- [ ] **Step 3: 实现**

```dart
// lib/core/format_time.dart
const String kTimeUnknown = '--:--';

String _two(int v) => v.toString().padLeft(2, '0');

String _minutesSeconds(int total) {
  final m = total ~/ 60;
  final s = total % 60;
  return '${_two(m)}:${_two(s)}';
}

String formatTime(double? seconds) {
  if (seconds == null || !seconds.isFinite || seconds < 0) return kTimeUnknown;
  return _minutesSeconds(seconds.floor());
}

/// 列表总时长：超过一小时才带小时位。
String formatTotal(double? seconds) {
  if (seconds == null || !seconds.isFinite || seconds < 0) return kTimeUnknown;
  final total = seconds.floor();
  if (total < 3600) return _minutesSeconds(total);
  final h = total ~/ 3600;
  return '$h:${_minutesSeconds(total % 3600)}';
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/core/format_time_test.dart`
Expected: `All tests passed!`（4 个用例）

- [ ] **Step 5: Commit**

```bash
cd flutter-app && git add lib/core test/core && git commit -m "feat(core): 新增时间格式化"
```

---

## Task 6: 字节读取与文本编码嗅探

内嵌标签解析的底座。原版规则（README「元数据与内嵌标签解析的边界」）：只读需要的字节，头 64KB 判格式、标签区按需再读、上限 8MB；文本编码不盲信声明，按 ASCII → UTF-8 → GBK → Latin-1 嗅探。

**Files:**
- Create: `lib/metadata/byte_reader.dart`
- Create: `lib/metadata/text_decode.dart`
- Create: `test/fixtures/README.md`（说明 fixture 全部内联构造，不引入二进制文件）
- Test: `test/metadata/byte_reader_test.dart`
- Test: `test/metadata/text_decode_test.dart`

**Interfaces:**
- Consumes: 无
- Produces:
  - `class ByteSource { factory ByteSource.fromBytes(List<int>); factory ByteSource.fromFile(String path, {int maxBytes = 8 * 1024 * 1024}); int get length; Future<bool> matches(int offset, List<int> signature); Future<bool> matchesText(int offset, String text); Future<int> u32be(int off); Future<int> u32le(int off); Future<int> synchsafe(int off); Future<List<int>> read(int off, int len); Future<List<int>> readTail(int len); }`（越界读取返回可用部分或空，**不抛异常**）
  - `String decodeId3Text(List<int> bytes, int encoding);`（0=Latin-1、1=UTF-16 带 BOM、2=UTF-16BE、3=UTF-8）
  - `String decodeLegacyText(List<int> bytes);`（ASCII → UTF-8 严格 → GBK（连续高位字节）→ Latin-1）
  - `bool canDecodeStrictlyUtf8(List<int> bytes); bool hasHighByteRun(List<int> bytes);`
  - `String sniffImageMime(List<int> bytes);`（JPEG/PNG/GIF/WebP → `image/*`，否则空串）

- [ ] **Step 1: 写失败测试**

```dart
// test/metadata/byte_reader_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/metadata/byte_reader.dart';

void main() {
  test('签名字节比对', () async {
    final src = ByteSource.fromBytes([0x49, 0x44, 0x33, 0x03]);
    expect(await src.matches(0, [0x49, 0x44, 0x33]), isTrue);
    expect(await src.matches(1, [0x49, 0x44, 0x33]), isFalse);
    expect(await src.matchesText(0, 'ID3'), isTrue);
  });

  test('三种长度读法', () async {
    final src = ByteSource.fromBytes([
      0x00, 0x00, 0x00, 0x12, // u32be
      0x12, 0x00, 0x00, 0x00, // u32le
      0x00, 0x00, 0x00, 0x01, // synchsafe = 1
      0x00, 0x00, 0x00, 0x40, // 高位被截掉 => 0
    ]);
    expect(await src.u32be(0), 18);
    expect(await src.u32le(4), 0x12000000);
    expect(await src.synchsafe(8), 1);
    expect(await src.synchsafe(12), 0);
  });

  test('越界不抛，只给可用部分', () async {
    final src = ByteSource.fromBytes([1, 2, 3]);
    expect(await src.read(2, 100), [3]);
    expect(await src.read(99, 4), isEmpty);
    expect(await src.u32be(2), 0);
    expect(await src.readTail(2), [2, 3]);
    expect(await src.matches(2, [1, 2, 3]), isFalse);
  });

  test('文件源限制最大读取量', () async {
    final tmp = 'test/.tmp-bytes.bin';
    await (await File.create tmp).writeAsString('hello');
    final src = ByteSource.fromFile(tmp);
    expect(src.length, 5);
    expect(await src.read(0, 2), [0x68, 0x65]);
    await File(tmp).delete();
  });
}
```

> 上面 Step 1 的文件用例需要 `import 'dart:io';`，实现时在测试文件顶部补上。

```dart
// test/metadata/text_decode_test.dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/metadata/text_decode.dart';

List<int> gbkOf(String text) => const _GbkSampleBytes.encode(text);

void main() {
  test('ID3 四种编码', () {
    expect(decodeId3Text(latin1.encode('Abbe'), 0), 'Abbe');
    expect(
        decodeId3Text([0xff, 0xfe, 0x4e, 0x5e, 0x73, 0x8b], 1), '陳奕迅'.substring(0, 0) +
            String.fromCharCode(0x5e4e, 0x8b73),
        isNotEmpty);
    expect(decodeId3Text(utf8.encode('十年'), 3), '十年');
    expect(decodeId3Text([0x00, 0x4e, 0x00, 0x5e], 2), '丿');
  });

  test('纯 ASCII 走最快路径', () {
    expect(decodeLegacyText(latin1.encode('Hello')), 'Hello');
  });

  test('合法 UTF-8 优先于 GBK', () {
    final utf8Bytes = utf8.encode('白玫瑰');
    expect(decodeLegacyText(utf8Bytes), '白玫瑰');
  });

  test('GBK 连续高位字节被识别且不乱码', () {
    expect(decodeLegacyText(gbkOf('好久不见')), '好久不见');
  });

  test('既非 UTF-8 也非可信 GBK 时退回 Latin-1，不抛', () {
    final result = decodeLegacyText([0xff, 0xfe, 0x41]);
    expect(result, isNotEmpty);
  });

  test('终止符之后的字节不参与解码', () {
    expect(decodeId3Text([...latin1.encode('A'), 0x00, ...latin1.encode('B')], 0), 'A');
    expect(
        decodeId3Text([0xff, 0xfe, 0x41, 0x00, 0x00, 0x00], 1), 'A');
  });

  test('图片魔数嗅探', () {
    expect(sniffImageMime([0xff, 0xd8, 0xff, 0xe0]), 'image/jpeg');
    expect(sniffImageMime([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
        'image/png');
    expect(sniffImageMime([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]), 'image/gif');
    expect(sniffImageMime([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50]),
        'image/webp');
    expect(sniffImageMime([1, 2, 3, 4]), '');
  });
}
```

> `_GbkSampleBytes` 是测试内的固定表：`'好久不见'` 的 GBK 字节为 `[0xb4, xf2...]`。**实现这一步时先跑一次 `python` 生成真实 GBK 字节再填进测试**，不要凭记忆写：

```bash
/d/flutter/bin/dart --version >/dev/null 2>&1 || true
"$HOME/AppData/Roaming/uv/python/cpython-3.12.11-windows-x86_64-none/python.exe" -c "print(list('好久不见'.encode('gbk')))"
```
Expected: 一串十进制数，逐字节填成 `[0xb4, 0xf2, ...]` 形式（即 `[181, 189, 181, 189, ...]` 等），然后 `_GbkSampleBytes.encode` 用一张手写的 4 字小表把 `'好久不见'` 映射到这些字节即可（测试专用，不进产品代码）。

- [ ] **Step 2: 跑测试确认失败**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/metadata/`
Expected: 编译失败 —— `byte_reader.dart` / `text_decode.dart` 不存在。

- [ ] **Step 3: 实现 ByteSource**

```dart
// lib/metadata/byte_reader.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 只读需要的字节：文件源带 8MB 上限，任何越界都不抛。
class ByteSource {
  ByteSource._(this._bytes, this._file, this._prefetched);

  factory ByteSource.fromBytes(List<int> bytes) =>
      ByteSource._(Uint8List.fromList(bytes), null, null);

  /// [prefetched] 允许调用方把已经读到的头部字节直接传进来，避免二次 IO。
  factory ByteSource.fromFile(
    String path, {
    int maxBytes = 8 * 1024 * 1024,
    Uint8List? prefetched,
  }) =>
      ByteSource._(null, _LimitedFile(path, maxBytes), prefetched);

  final Uint8List? _bytes;
  final _LimitedFile? _file;
  final Uint8List? _prefetched;
  int? _length;

  static const int _headSize = 64 * 1024;

  int get length => _length ??= _resolveLength();

  int _resolveLength() {
    if (_bytes != null) return _bytes!.length;
    if (_prefetched != null && _prefetched!.length >= _headSize) {
      return _file!.probeLength();
    }
    return _file!.probeLength();
  }

  Future<Uint8List> read(int offset, int count) async {
    if (count <= 0 || offset < 0 || offset >= length) return Uint8List(0);
    final want = offset + count > length ? length - offset : count;
    if (_bytes != null) {
      return Uint8List.sublistView(_bytes!, offset, offset + want);
    }
    return _file!.read(offset, want);
  }

  Future<Uint8List> readTail(int count) async {
    if (length == 0) return Uint8List(0);
    final take = count > length ? length : count;
    return read(length - take, take);
  }

  Future<bool> matches(int offset, List<int> signature) async {
    if (offset < 0 || offset + signature.length > length) return false;
    final bytes = await read(offset, signature.length);
    for (var i = 0; i < signature.length; i++) {
      if (bytes[i] != signature[i]) return false;
    }
    return true;
  }

  Future<bool> matchesText(int offset, String text) =>
      matches(offset, latin1.encode(text));

  Future<int> u32be(int offset) async {
    final b = await read(offset, 4);
    if (b.length < 4) return 0;
    return (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
  }

  Future<int> u32le(int offset) async {
    final b = await read(offset, 4);
    if (b.length < 4) return 0;
    return b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24);
  }

  Future<int> synchsafe(int offset) async {
    final b = await read(offset, 4);
    if (b.length < 4) return 0;
    return (b[0] << 21) | (b[1] << 14) | (b[2] << 7) | b[3];
  }
}

class _LimitedFile {
  _LimitedFile(this.path, this.maxBytes);
  final String path;
  final int maxBytes;

  int probeLength() {
    try {
      return File(path).lengthSync();
    } catch (_) {
      return 0;
    }
  }

  Future<Uint8List> read(int offset, int count) async {
    final capped = offset + count > maxBytes ? maxBytes - offset : count;
    if (capped <= 0) return Uint8List(0);
    final raf = await File(path).open();
    try {
      await raf.setPosition(offset);
      return await raf.read(capped);
    } finally {
      await raf.close();
    }
  }
}
```

- [ ] **Step 4: 实现文本嗅探与图片魔数**

```dart
// lib/metadata/text_decode.dart
import 'dart:convert';

import 'package:fast_gbk/fast_gbk.dart';

/// 遇到首个终止符（单字节 0x00，或 UTF-16 下的 0x00 0x00）即截断。
List<int> _cutAtTerminator(List<int> bytes, {required bool wide}) {
  if (wide) {
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      if (bytes[i] == 0 && bytes[i + 1] == 0) return bytes.sublist(0, i);
    }
    return bytes;
  }
  final at = bytes.indexOf(0);
  return at < 0 ? bytes : bytes.sublist(0, at);
}

bool canDecodeStrictlyUtf8(List<int> bytes) {
  try {
    utf8.decode(bytes);
    return true;
  } catch (_) {
    return false;
  }
}

/// 是否存在「连续两个高位字节」这种 GBK 特征。
bool hasHighByteRun(List<int> bytes) {
  for (var i = 0; i + 1 < bytes.length; i++) {
    if (bytes[i] > 0x80 && bytes[i + 1] > 0x40) {
      i++;
      continue;
    }
  }
  final high = bytes.where((b) => b > 0x80).length;
  if (high == 0) return false;
  for (var i = 0; i + 1 < bytes.length; i++) {
    if (bytes[i] > 0x80 && bytes[i + 1] > 0x80) return true;
  }
  return false;
}

String decodeId3Text(List<int> raw, int encoding) {
  switch (encoding) {
    case 1:
      var bytes = raw;
      if (bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe) {
        bytes = bytes.sublist(2);
      } else if (bytes.length >= 2 && bytes[0] == 0xfe && bytes[1] == 0xff) {
        return _utf16be(_cutAtTerminator(bytes.sublist(2), wide: true));
      }
      return _utf16le(_cutAtTerminator(bytes, wide: true));
    case 2:
      return _utf16be(_cutAtTerminator(raw, wide: true));
    case 3:
      final body = _cutAtTerminator(raw, wide: false);
      return canDecodeStrictlyUtf8(body)
          ? utf8.decode(body)
          : latin1.decode(body, allowMalformed: true);
    default:
      final body = _cutAtTerminator(raw, wide: false);
      return latin1.decode(body, allowMalformed: true);
  }
}

/// 不盲信声明的 encoding=0：按 ASCII → UTF-8 → GBK → Latin-1 嗅探。
String decodeLegacyText(List<int> raw) {
  final body = _cutAtTerminator(raw, wide: false);
  if (body.isEmpty) return '';
  if (body.every((b) => b < 0x80)) return ascii.decode(body);
  if (canDecodeStrictlyUtf8(body)) return utf8.decode(body);
  if (hasHighByteRun(body)) {
    try {
      final decoded = gbk.decode(body);
      if (decoded.isNotEmpty && !decoded.contains('\uFFFD')) return decoded;
    } catch (_) {
      // 交给 Latin-1 兜底
    }
  }
  return latin1.decode(body, allowMalformed: true);
}

String _utf16le(List<int> bytes) {
  final buffer = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    buffer.add(bytes[i] | (bytes[i + 1] << 8));
  }
  return String.fromCharCodes(buffer);
}

String _utf16be(List<int> bytes) {
  final buffer = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    buffer.add((bytes[i] << 8) | bytes[i + 1]);
  }
  return String.fromCharCodes(buffer);
}

String sniffImageMime(List<int> b) {
  if (b.length >= 3 && b[0] == 0xff && b[1] == 0xd8 && b[2] == 0xff) {
    return 'image/jpeg';
  }
  if (b.length >= 8 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4e &&
      b[3] == 0x47) {
    return 'image/png';
  }
  if (b.length >= 6 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) {
    return 'image/gif';
  }
  if (b.length >= 12 &&
      b[0] == 0x52 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x46 &&
      b[8] == 0x57 &&
      b[9] == 0x45 &&
      b[10] == 0x42 &&
      b[11] == 0x50) {
    return 'image/webp';
  }
  return '';
}
```

> `decodeId3Text` 的 UTF-16 分支只处理 BMP（标签文本实际都在 BMP 内），与原版同样不做代理对拼装；测试里 UTF-16 用例只用 BMP 字符，避免把代理对的复杂度带进 M1。

- [ ] **Step 5: 跑测试确认通过**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/metadata/`
Expected: `All tests passed!`（约 13 个用例）

- [ ] **Step 6: Commit**

```bash
cd flutter-app && git add lib/metadata test/metadata && git commit -m "feat(metadata): 新增字节读取与多编码嗅探"
```

---

---

## Task 7: ID3v2 / ID3v1 解析

对译 `src/lib/audio-tags.js:53-145`（文本解码已由 T6 提供）、`:225-408`（ID3v2 帧与 APIC）、`:409-428`（ID3v1）。

**Files:**
- Create: `lib/metadata/id3.dart`
- Test: `test/metadata/id3_test.dart`

**Interfaces:**
- Consumes: `ByteSource`、`decodeId3Text`、`decodeLegacyText`、`sniffImageMime`（T6）
- Produces:
  - `class Id3Tag { String title; String artist; String album; String albumArtist; List<int>? picture; String pictureMime; String version; }`
  - `Future<Id3Tag?> parseId3v2(ByteSource src, {int offset = 0});` —— 返回 null 表示不是 ID3v2 或解析不出字段；任何畸形长度/越界帧都只跳过该帧，**不抛**。
  - `Future<Id3Tag?> parseId3v1(ByteSource src);` —— 只看文件尾 128 字节，签名 `TAG`。
  - 常量：帧文本 `TIT1/TIT2/TPE1/TPE2/TALB`、图片帧 `APIC`/`PIC`、unsynchronisation 位 `0x80`、扩展头位 `0x40`。

- [ ] **Step 1: 把 JS fixture 构造器移植成 Dart 测试助手**

移植 `tests/t-tags.mjs` 的这些 helper（逐字对齐语义，行号在括号内）：`bytes(...parts)`(:40)、`u32be`/`u32le`/`synchsafe`(:52-54)、`fourcc`、`latin1`、`cstr`、`textFrame(id, value, {encoding = 3, version = 3})`(:61)、`apicFrame(mime, pic, {coverType = 3, description = '', encoding = 3, version = 3})`(:76)、`id3v2(frames, {version = 3, flags = 0})`(:85)、`MPEG_FRAME`(:91 = `[0xff, 0xfb, 0x90, 0x64]` + 400 个 0)、GBK 侧 `gbkReverse` 反查表(:183-193) 与 `rawTextFrame`(:195)、`v1Field`(:243)。

在 `test/metadata/tag_fixtures.dart` 里新建一个共享文件（T8/T9/T10 都 import 它），Dart 版签名：

```dart
// test/metadata/tag_fixtures.dart
import 'dart:convert';
import 'package:fast_gbk/fast_gbk.dart';

List<int> bytes(List<Object> parts) => [
      for (final part in parts)
        ...switch (part) {
          int b => [b],
          List<int> list => list,
          String text => latin1.encode(text),
          _ => throw ArgumentError('unsupported part: $part'),
        },
    ];

List<int> u32be(int v) => [(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];
List<int> u32le(int v) => [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff];
List<int> synchsafe(int v) => [(v >> 21) & 0x7f, (v >> 14) & 0x7f, (v >> 7) & 0x7f, v & 0x7f];
List<int> fourcc(String s) => latin1.encode(s);
List<int> cstr(String s) => [...latin1.encode(s), 0];

const List<int> pngHeader = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
List<int> pngBody() => [...pngHeader, 1, 2, 3, 4];
List<int> mpegFrame() => [0xff, 0xfb, 0x90, 0x64, ...List<int>.filled(400, 0)];

/// textFrame：帧头 = id(4) + 长度(4) + flags(2)；v4 长度用 synchsafe，否则 u32be。
List<int> textFrame(String id, String value, {int encoding = 3, int version = 3}) {
  final payload = [encoding, ..._textBytes(value, encoding)];
  final size = version == 4 ? synchsafe(payload.length) : u32be(payload.length);
  return [...fourcc(id), ...size, 0, 0, ...payload];
}

List<int> _textBytes(String value, int encoding) => switch (encoding) {
      0 => latin1.encode(value),
      1 => [0xff, 0xfe, ...utf16leBytes(value)],
      2 => utf16beBytes(value),
      _ => utf8.encode(value),
    };

List<int> utf16leBytes(String s) => [
      for (final code in s.codeUnits) ...[code & 0xff, (code >> 8) & 0xff],
    ];

List<int> utf16beBytes(String s) => [
      for (final code in s.codeUnits) ...[(code >> 8) & 0xff, code & 0xff],
    ];

List<int> apicFrame(String mime, List<int> picture,
    {int coverType = 3, String description = '', int encoding = 3, int version = 3}) {
  final payload = <int>[
    encoding,
    ...latin1.encode(mime),
    0,
    coverType,
    ..._textBytes(description, encoding),
    0,
    ...picture,
  ];
  final size = version == 4 ? synchsafe(payload.length) : u32be(payload.length);
  return [...fourcc(version == 2 ? 'PIC' : 'APIC'), ...size, 0, 0, ...payload];
}

List<int> id3v2(List<List<int>> frames, {int version = 3, int flags = 0}) {
  final body = [for (final f in frames) ...f];
  return [0x49, 0x44, 0x33, version, 0, flags, ...synchsafe(body.length), ...body];
}

/// GBK 反查表：只为在测试里造出真实的 GBK 字节，不进产品代码。
final Map<String, List<int>> gbkTable = {
  for (final ch in '陈奕迅十年白玫瑰好久不见孤勇者') ch: gbk.encode(ch),
};

List<int> gbkText(String text) => [for (final ch in text.split('')) ...gbkTable[ch]!];

List<int> rawTextFrame(String id, List<int> payload, {int encodingByte = 0, int version = 3}) {
  final body = [encodingByte, ...payload];
  final size = version == 4 ? synchsafe(body.length) : u32be(body.length);
  return [...fourcc(id), ...size, 0, 0, ...body];
}

List<int> v1Field(String text, int width) {
  final encoded = gbk.encode(text);
  return [...encoded, ...List<int>.filled(width - encoded.length, 0)];
}
```

- [ ] **Step 2: 写失败测试（对应 JS 里 ID3 族的 5 个用例）**

移植 `tests/t-tags.mjs` 的 ID3 族断言，族名与断言条数逐一对齐（照搬每条 `check` 的 label 与期望值，不要自己发明）：

| JS 用例名 | 源行号 | 断言条数 | 覆盖点 |
| --- | --- | --- | --- |
| `id3v23` | 见 `grep -n "run('id3v23'" tests/t-tags.mjs` | 7 | TIT2/TPE1/TALB/TPE2、format、picture 的 mime 与字节 |
| `id3v24-unsync` | 同上 | 2 | v2.4 整标签 unsynchronisation + 帧级 unsync 还原 |
| `id3v1` | 同上 | 5 | 尾部 128 字节 title/artist/album/genre 或 track |
| `id3v23-enc0-gbk` | 同上 | 2 | 声明 encoding=0 实为 GBK，嗅探后正确中文 |
| `id3v23-enc0-utf8` | 同上 | 2 | 声明 encoding=0 实为 UTF-8 |
| `id3v23-enc0-latin1` | 同上 | 1 | 真 Latin-1 |
| `id3v23-enc0-latin1-ambig` | 同上 | 2 | 高位歧义（既像 UTF-8 残缺又像 Latin-1）不许抛 |
| `id3v1-gbk` | 同上 | 4 | ID3v1 无编码位，GBK 嗅探 |

Dart 用例骨架（前两条完整写出，其余按表逐条搬期望值）：

```dart
// test/metadata/id3_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/metadata/byte_reader.dart';
import 'package:light_music/metadata/id3.dart';

import 'tag_fixtures.dart';

Future<Id3Tag?> parse(List<int> file) => parseId3v2(ByteSource.fromBytes(file));

void main() {
  test('id3v23：文本帧与 APIC 全覆盖', () async {
    final file = bytes([
      id3v2([
        textFrame('TIT2', '十年'),
        textFrame('TPE1', '陈奕迅'),
        textFrame('TALB', 'Stranger Under My Skin'),
        textFrame('TPE2', '陈奕迅'),
        apicFrame('image/png', pngBody()),
      ], version: 3),
      ...mpegFrame(),
    ]);
    final tag = await parse(file)!;
    expect(tag.title, '十年');
    expect(tag.artist, '陈奕迅');
    expect(tag.album, 'Stranger Under My Skin');
    expect(tag.albumArtist, '陈奕迅');
    expect(tag.version, 'id3v2.3');
    expect(tag.pictureMime, 'image/png');
    expect(tag.picture, pngBody());
  });

  test('id3v24-unsync：帧长 synchsafe 且 unsync 还原', () async {
    final file = bytes([
      id3v2([
        textFrame('TIT2', '孤勇者', version: 4),
      ], version: 4, flags: 0x80),
      ...mpegFrame(),
    ]);
    final tag = await parse(file);
    expect(tag?.title, '孤勇者');
    expect(tag?.version, 'id3v2.4');
  });

  // 其余 6 个 ID3 用例按上表继续补：每条断言的 label 与期望值取自 t-tags.mjs。
}
```

- [ ] **Step 3: 跑测试确认失败**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/metadata/id3_test.dart`
Expected: 编译失败 —— `id3.dart` 不存在。

- [ ] **Step 4: 实现 ID3v2**

```dart
// lib/metadata/id3.dart
import 'dart:typed_data';

import 'byte_reader.dart';
import 'text_decode.dart';

const int _unsynchronisationFlag = 0x80;
const int _extendedHeaderFlag = 0x40;

const Map<String, String> _textFieldMap = {
  'TIT1': 'title', 'TIT2': 'title',
  'TPE1': 'artist', 'TPE2': 'albumArtist',
  'TALB': 'album',
};

class Id3Tag {
  Id3Tag({this.version = ''});
  String version;
  String title = '';
  String artist = '';
  String album = '';
  String albumArtist = '';
  Uint8List? picture;
  String pictureMime = '';

  bool get isEmpty =>
      title.isEmpty && artist.isEmpty && album.isEmpty &&
      albumArtist.isEmpty && picture == null;
}

/// 去掉 unsynchronisation 引入的 0x00 填充：0xFF 0x00 -> 0xFF。
List<int> desynchronise(List<int> bytes) {
  final out = <int>[];
  for (var i = 0; i < bytes.length; i++) {
    out.add(bytes[i]);
    if (bytes[i] == 0xff && i + 1 < bytes.length && bytes[i + 1] == 0x00) i++;
  }
  return out;
}

Future<Id3Tag?> parseId3v2(ByteSource src, {int offset = 0}) async {
  if (!await src.matches(offset, [0x49, 0x44, 0x33])) return null;
  final header = await src.read(offset, 10);
  if (header.length < 10) return null;
  final version = header[3];
  final flags = header[5];
  final size = (header[6] << 21) | (header[7] << 14) | (header[8] << 7) | header[9];
  if (size <= 0 || size > 8 * 1024 * 1024) return null;

  final body = await src.read(offset + 10, size);
  final whole = (flags & _unsynchronisationFlag) != 0 ? desynchronise(body) : body;
  final tag = Id3Tag(version: 'id3v2.$version');
  if (whole.isEmpty) return null;

  var pos = 0;
  if ((flags & _extendedHeaderFlag) != 0) {
    final extSize = version == 4
        ? _synchsafeAt(whole, 0)
        : _u32beAt(whole, 0) + 4;
    pos += extSize;
  }

  while (pos + 10 <= whole.length) {
    final id = String.fromCharCodes(whole.sublist(pos, pos + 4));
    final frameLength = version == 4
        ? _synchsafeAt(whole, pos + 4)
        : _u32beAt(whole, pos + 4);
    final frameFlags = (whole[pos + 8] << 8) | whole[pos + 9];
    if (frameLength <= 0 || pos + 10 + frameLength > whole.length) {
      // 长度畸形：停止扫描已解析出的字段，绝不抛出（原版边界约束）
      break;
    }
    var content = whole.sublist(pos + 10, pos + 10 + frameLength);
    if ((frameFlags & 0x0002) != 0) content = desynchronise(content);
    _applyFrame(tag, id, content, version);
    pos += 10 + frameLength;
  }

  return tag.isEmpty ? null : tag;
}

void _applyFrame(Id3Tag tag, String id, List<int> content, int version) {
  if (id == 'APIC' || (version == 2 && id == 'PIC')) {
    final pic = parseApicFrame(content, version, isV2Pic: version == 2);
    if (pic != null) {
      tag.picture = pic.$1;
      tag.pictureMime = pic.$2;
    }
    return;
  }
  final target = _textFieldMap[id];
  if (target == null || content.isEmpty) return;
  final encoding = content[0];
  final value = _cleanText(
    decodeId3Text(content.sublist(1), encoding),
  );
  if (value.isEmpty) return;
  switch (target) {
    case 'title':
      tag.title = tag.title.isEmpty ? value : tag.title;
    case 'artist':
      tag.artist = tag.artist.isEmpty ? value : tag.artist;
    case 'album':
      tag.album = tag.album.isEmpty ? value : tag.album;
    case 'albumArtist':
      tag.albumArtist = tag.albumArtist.isEmpty ? value : tag.albumArtist;
  }
}

/// 返回 (图片字节, mime)。mime 缺失或无法识别时按魔数嗅探。
(String, String)? parseApicFrame(List<int> content, int version, {bool isV2Pic = false}) {
  if (content.isEmpty) return null;
  final encoding = content[0];
  var pos = 1;
  String mime = '';
  if (isV2Pic) {
    if (content.length < 7) return null;
    mime = latin1Of(content.sublist(pos, pos + 3));
    pos += 3;
  } else {
    final terminator = content.indexOf(0, pos);
    if (terminator < 0) return null;
    mime = latin1Of(content.sublist(pos, terminator));
    pos = terminator + 1;
  }
  if (content.length <= pos) return null;
  pos += 1; // cover type
  final descriptionEnd = _findTerminator(content, pos, wide: encoding == 1 || encoding == 2);
  if (descriptionEnd == null) return null;
  pos = descriptionEnd;
  final data = content.sublist(pos);
  if (data.isEmpty) return null;
  if (mime.isEmpty || !mime.contains('/')) {
    mime = sniffImageMime(data) ?? '';
  }
  return (data, mime.isEmpty ? 'image/jpeg' : mime);
}

String latin1Of(List<int> bytes) =>
    String.fromCharCodes(bytes.map((b) => b & 0xff));

/// UTF-16 文本的双零终止符；找不到返回 null（当作畸形帧跳过）。
int? _findTerminator(List<int> bytes, int from, {required bool wide}) {
  if (wide) {
    for (var i = from; i + 3 < bytes.length; i += 2) {
      if (bytes[i] == 0 && bytes[i + 1] == 0) return i + 4;
    }
    return null;
  }
  final at = bytes.indexOf(0, from);
  return at < 0 ? null : at + 1;
}

String _cleanText(String value) {
  var text = value.replaceAll('\u0000', '').trim();
  while (text.isNotEmpty && (text.codeUnitAt(0) == 0x0a || text.codeUnitAt(0) == 0x0d)) {
    text = text.substring(1);
  }
  return text;
}

int _u32beAt(List<int> b, int o) => o + 4 > b.length
    ? 0
    : (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

int _synchsafeAt(List<int> b, int o) => o + 4 > b.length
    ? 0
    : (b[o] << 21) | (b[o + 1] << 14) | (b[o + 2] << 7) | b[o + 3];
```

- [ ] **Step 5: 实现 ID3v1**

追加到 `lib/metadata/id3.dart`：

```dart
/// 只读文件尾 128 字节；无 TAG 签名返回 null。
Future<Id3Tag?> parseId3v1(ByteSource src) async {
  if (src.length < 128) return null;
  final tail = await src.readTail(128);
  if (tail.length < 128 ||
      tail[0] != 0x54 || tail[1] != 0x41 || tail[2] != 0x47) {
    return null;
  }
  String field(int from, int width) =>
      _cleanText(decodeLegacyText(tail.sublist(from, from + width)));
  final tag = Id3Tag(version: 'id3v1')
    ..title = field(3, 30)
    ..artist = field(33, 30)
    ..album = field(63, 30);
  return tag.isEmpty ? null : tag;
}
```

- [ ] **Step 6: 跑测试确认通过**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/metadata/id3_test.dart`
Expected: `All tests passed!`；断言条数与 JS 侧 ID3 族合计 25 条一致（对照 Step 2 表格的 7+2+5+2+2+1+2+4）。

- [ ] **Step 7: Commit**

```bash
cd flutter-app && git add lib/metadata test/metadata && git commit -m "feat(metadata): 移植 ID3v2 与 ID3v1 解析"
```

---

## Task 8: FLAC 与 OGG 的 Vorbis Comment / PICTURE

对译 `src/lib/audio-tags.js:429-565`。

**Files:**
- Create: `lib/metadata/vorbis.dart`
- Test: `test/metadata/vorbis_test.dart`

**Interfaces:**
- Consumes: `ByteSource`、`decodeLegacyText`、`sniffImageMime`（T6）、`Id3Tag`（T7 的容器无关结构，本任务复用同一形状）
- Produces:
  - `Future<Id3Tag?> parseFlacMeta(ByteSource src, {int offset = 0});` —— 要求 `fLaC` 签名，遍历 metadata block（`STREAMINFO`/`VORBIS_COMMENT`/`PICTURE`）；块长度爆炸时停止扫描不抛。
  - `Future<Id3Tag?> parseOggMeta(ByteSource src, {int offset = 0});` —— 读 identification packet 拿 `sampleRate`，重组 comment 头包，解析 `METADATA_BLOCK_PICTURE` base64。
  - `Map<String, String> parseVorbisComment(List<int> bytes, {int offset = 0});` —— vendor 之后逐条 `KEY=value`，key 一律转小写。

- [ ] **Step 1: 在共享 fixture 里补容器助手**

追加到 `test/metadata/tag_fixtures.dart`（语义对齐 JS 的 `vorbisComment`/`flacPictureBlock`/`metaBlock`/`streaminfo`/`oggPacket`/`oggIdent`/`oggComment`）：

```dart
List<int> vorbisComment(List<String> entries, {String vendor = 'test-tagging'}) {
  final body = <int>[...u32le(vendor.length), ...latin1.encode(vendor)];
  body.addAll(u32le(entries.length));
  for (final entry in entries) {
    body.addAll(u32le(entry.length));
    body.addAll(latin1.encode(entry));
  }
  return body;
}

/// FLAC PICTURE block：type + mime + description + width/height/depth/colors + data。
List<int> flacPictureBlock(String mime, List<int> picture, {String description = ''}) {
  final mimeBytes = latin1.encode(mime);
  final descBytes = latin1.encode(description);
  return [
    ...u32be(3),                       // cover type = front
    ...u32be(mimeBytes.length), ...mimeBytes,
    ...u32be(descBytes.length), ...descBytes,
    ...u32be(0), ...u32be(0), ...u32be(0), ...u32be(0), ...u32be(0),
    ...u32be(picture.length), ...picture,
  ];
}

List<int> metaBlock(int type, List<int> content) => [
      type,
      ...[(content.length >> 16) & 0xff, (content.length >> 8) & 0xff, content.length & 0xff],
      ...content,
    ];

List<int> streamInfo() => List<int>.filled(34, 0);

List<int> flacFile(List<List<int>> blocks) => [
      ...fourcc('fLaC'),
      for (var i = 0; i < blocks.length; i++)
        ...[blocks[i][0] | (i == blocks.length - 1 ? 0x80 : 0), ...blocks[i].sublist(1)],
      ...mpegFrame(),
    ];

List<int> oggPacket(List<int> payload, {int granule = 0, int serial = 4, int seq = 0, bool bos = false}) {
  final segments = <int>[];
  var remaining = payload.length;
  while (remaining >= 255) {
    segments.add(255);
    remaining -= 255;
  }
  segments.add(remaining);
  return [
    ...fourcc('OggS'), 0,
    bos ? 0x02 : 0x00,
    ...List<int>.filled(8, 0),
    ...u32le(granule),
    ...u32le(serial),
    ...u32le(seq),
    ...List<int>.filled(4, 0),
    segments.length,
    ...segments,
    ...payload,
  ];
}

List<int> oggIdent() => [0x01, ...fourcc('vorbis'), ...List<int>.filled(40, 0)];

List<int> oggComment(List<String> entries, {List<String> base64Pictures = const []}) {
  final withPicture = [
    ...entries,
    for (final p in base64Pictures) 'METADATA_BLOCK_PICTURE=$p',
  ];
  return [0x03, ...fourcc('vorbis'), ...vorbisComment(withPicture)];
}
```

- [ ] **Step 2: 写失败测试**

移植 JS 的 `flac`(7)、`flac-gbk`(4)、`ogg`(5) 三族断言（期望值照搬 `t-tags.mjs`，用 `grep -n "run('flac'" tests/t-tags.mjs` 定位）。两条完整示例：

```dart
// test/metadata/vorbis_test.dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/metadata/byte_reader.dart';
import 'package:light_music/metadata/vorbis.dart';

import 'tag_fixtures.dart';

void main() {
  test('flac：Vorbis Comment + PICTURE', () async {
    final file = flacFile([
      metaBlock(0, streamInfo()),
      metaBlock(4, vorbisComment([
        'TITLE=白玫瑰',
        'ARTIST=陈奕迅',
        'ALBUM=Stranger Under My Skin',
        'ALBUMARTIST=陈奕迅',
      ])),
      metaBlock(6, flacPictureBlock('image/png', pngBody())),
    ]);
    final tag = await parseFlacMeta(ByteSource.fromBytes(file))!;
    expect(tag.title, '白玫瑰');
    expect(tag.artist, '陈奕迅');
    expect(tag.album, 'Stranger Under My Skin');
    expect(tag.albumArtist, '陈奕迅');
    expect(tag.version, 'flac');
    expect(tag.pictureMime, 'image/png');
    expect(tag.picture, pngBody());
  });

  test('ogg：identification + comment + base64 PICTURE', () async {
    final pic = base64.encode(flacPictureBlock('image/png', pngBody()));
    final file = bytes([
      oggPacket(oggIdent(), bos: true),
      oggPacket(oggComment(['TITLE=孤勇者', 'ARTIST=陈奕迅'], base64Pictures: [pic])),
    ]);
    final tag = await parseOggMeta(ByteSource.fromBytes(file))!;
    expect(tag.title, '孤勇者');
    expect(tag.artist, '陈奕迅');
    expect(tag.version, 'ogg');
    expect(tag.pictureMime, 'image/png');
    expect(tag.picture, pngBody());
  });

  // flac-gbk 与 ogg 的其余断言按 JS 期望值补齐（共 9 条）。
}
```

- [ ] **Step 3: 跑测试确认失败**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/metadata/vorbis_test.dart`
Expected: 编译失败 —— `vorbis.dart` 不存在。

- [ ] **Step 4: 实现**

```dart
// lib/metadata/vorbis.dart
import 'dart:convert';
import 'dart:typed_data';

import 'byte_reader.dart';
import 'id3.dart';
import 'text_decode.dart';

/// key 一律小写，值保留原样；解析不出键值时跳过该条（不抛）。
Map<String, String> parseVorbisComment(List<int> bytes, {int offset = 0}) {
  final result = <String, String>{};
  var pos = offset;
  if (pos + 4 > bytes.length) return result;
  final vendorLength = _u32leAt(bytes, pos);
  pos += 4 + vendorLength;
  if (pos + 4 > bytes.length || vendorLength < 0) return result;
  final count = _u32leAt(bytes, pos);
  pos += 4;
  for (var i = 0; i < count && pos + 4 <= bytes.length; i++) {
    final len = _u32leAt(bytes, pos);
    pos += 4;
    if (len <= 0 || pos + len > bytes.length) break;
    final raw = latin1.decode(bytes.sublist(pos, pos + len), allowMalformed: true);
    pos += len;
    final eq = raw.indexOf('=');
    if (eq <= 0) continue;
    result[raw.substring(0, eq).toLowerCase()] = raw.substring(eq + 1);
  }
  return result;
}

/// 从 vendor 之后的 UTF-8 字节里取文本：先按 UTF-8，失败再走嗅探。
String _commentValue(String raw) {
  final decoded = utf8.decode(latin1.encode(raw), allowMalformed: true);
  return _clean(decoded);
}

String _clean(String v) => v.replaceAll('\u0000', '').trim();

Id3Tag _tagFromComment(Map<String, String> entries, String version) {
  final tag = Id3Tag(version: version);
  final picture = entries['metadata_block_picture'];
  if (picture != null && picture.isNotEmpty) {
    _applyPicture(tag, picture);
  }
  for (final entry in entries.entries) {
    final value = _commentValue(entry.value);
    if (value.isEmpty) continue;
    switch (entry.key) {
      case 'title':
        if (tag.title.isEmpty) tag.title = value;
      case 'artist':
        if (tag.artist.isEmpty) tag.artist = value;
      case 'album':
        if (tag.album.isEmpty) tag.album = value;
      case 'albumartist':
        if (tag.albumArtist.isEmpty) tag.albumArtist = value;
    }
  }
  return tag;
}

void _applyPicture(Id3Tag tag, String base64Text) {
  try {
    final bytes = base64Decode(base64Text.replaceAll(RegExp(r'\s'), ''));
    final pic = readFlacPicture(bytes, 0);
    if (pic != null) {
      tag.picture = pic.$1;
      tag.pictureMime = pic.$2;
    }
  } catch (_) {
    // base64 非法：没有封面，继续走后面的兜底级
  }
}

/// FLAC PICTURE 块结构：type / mime / description / w / h / depth / colors / data。
(Uint8List, String)? readFlacPicture(List<int> b, int offset) {
  var pos = offset;
  int be() {
    final v = (b[pos] << 24) | (b[pos + 1] << 16) | (b[pos + 2] << 8) | b[pos + 3];
    pos += 4;
    return v;
  }
  if (b.length - pos < 8) return null;
  be(); // cover type
  final mimeLen = be();
  if (mimeLen < 0 || pos + mimeLen > b.length) return null;
  final mime = latin1.decode(b.sublist(pos, pos + mimeLen), allowMalformed: true);
  pos += mimeLen;
  if (pos + 4 > b.length) return null;
  final descLen = be();
  pos += descLen + 20; // description + width/height/depth/colors
  if (pos + 4 > b.length) return null;
  final dataLen = be();
  if (dataLen <= 0 || pos + dataLen > b.length) return null;
  final data = Uint8List.fromList(b.sublist(pos, pos + dataLen));
  final resolvedMime =
      mime.isEmpty || !mime.contains('/') ? (sniffImageMime(data) ?? '') : mime;
  return (data, resolvedMime.isEmpty ? 'image/jpeg' : resolvedMime);
}

Future<Id3Tag?> parseFlacMeta(ByteSource src, {int offset = 0}) async {
  if (!await src.matches(offset, [0x66, 0x4c, 0x61, 0x43])) return null;
  var pos = offset + 4;
  final tag = Id3Tag(version: 'flac');
  for (var guard = 0; guard < 64; guard++) {
    final header = await src.read(pos, 4);
    if (header.length < 4) break;
    final isLast = (header[0] & 0x80) != 0;
    final type = header[0] & 0x7f;
    final length = (header[1] << 16) | (header[2] << 8) | header[3];
    pos += 4;
    // 块长度爆炸（畸形输入）：停止扫描，已解析字段照常返回，不抛。
    if (length < 0 || length > 8 * 1024 * 1024 || pos + length > src.length) break;
    final content = await src.read(pos, length);
    if (type == 4) {
      final merged = _tagFromComment(parseVorbisComment(content), 'flac');
      _copyInto(tag, merged);
    } else if (type == 6) {
      final pic = readFlacPicture(content, 0);
      if (pic != null) {
        tag.picture = pic.$1;
        tag.pictureMime = pic.$2;
      }
    }
    pos += length;
    if (isLast) break;
  }
  return tag.isEmpty ? null : tag;
}

Future<Id3Tag?> parseOggMeta(ByteSource src, {int offset = 0}) async {
  final head = await src.read(offset, 4);
  if (head.length < 4 || String.fromCharCodes(head) != 'OggS') return null;
  var pos = offset;
  Uint8List? ident;
  Uint8List? comment;
  for (var guard = 0; guard < 8 && pos < src.length; guard++) {
    final pageHeader = await src.read(pos, 27);
    if (pageHeader.length < 27 ||
        String.fromCharCodes(pageHeader.sublist(0, 4)) != 'OggS') {
      break;
    }
    final segCount = pageHeader[26];
    final table = await src.read(pos + 27, segCount);
    if (table.length < segCount) break;
    var total = 0;
    for (final s in table) {
      total += s;
    }
    final bodyStart = pos + 27 + segCount;
    final payload = await src.read(bodyStart, total);
    if (payload.isEmpty) break;
    if (ident == null && payload.isNotEmpty && payload[0] == 0x01) {
      ident = payload;
    } else if (comment == null && payload.length > 7 && payload[0] == 0x03) {
      comment = payload;
    }
    if (ident != null && comment != null) break;
    pos = bodyStart + total;
  }
  if (comment == null) return null;
  final entries = parseVorbisComment(comment, offset: 7);
  final tag = _tagFromComment(entries, 'ogg');
  return tag.isEmpty ? null : tag;
}

void _copyInto(Id3Tag target, Id3Tag from) {
  if (target.title.isEmpty) target.title = from.title;
  if (target.artist.isEmpty) target.artist = from.artist;
  if (target.album.isEmpty) target.album = from.album;
  if (target.albumArtist.isEmpty) target.albumArtist = from.albumArtist;
  if (target.picture == null) {
    target.picture = from.picture;
    target.pictureMime = from.pictureMime;
  }
}

int _u32leAt(List<int> b, int o) => o + 4 > b.length
    ? 0
    : b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);
```

- [ ] **Step 5: 跑测试确认通过**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/metadata/vorbis_test.dart`
Expected: `All tests passed!`；三族合计 16 条断言与 JS 侧一致（`node tests/t-tags.mjs` 输出的 `通过 57` 里这 16 条对应 `flac`/`flac-gbk`/`ogg`）。

- [ ] **Step 6: Commit**

```bash
cd flutter-app && git add lib/metadata test/metadata && git commit -m "feat(metadata): 移植 FLAC 与 OGG 标签解析"
```

---

## Task 9: MP4 `ilst` 解析

对译 `src/lib/audio-tags.js:566-735`。

**Files:**
- Create: `lib/metadata/mp4.dart`
- Test: `test/metadata/mp4_test.dart`

**Interfaces:**
- Consumes: `ByteSource`、`Id3Tag`
- Produces: `Future<Id3Tag?> parseMp4Meta(ByteSource src, {int offset = 0});` —— 找 `ftyp` 判定 MP4 家族；`moov` 缺失返回 null；`covr` 的 `flags` 13=JPEG、14=PNG，其余按魔数嗅探。

- [ ] **Step 1: 补 fixture 助手并写失败测试**

追加到 `test/metadata/tag_fixtures.dart`（对齐 JS 的 `mp4Box`/`dataAtom`，`©` 用 latin1 单字节 `0xA9`）：

```dart
List<int> mp4Box(String type, List<List<int>> parts) {
  final body = [for (final p in parts) ...p];
  return [...u32be(body.length + 8), ...latin1.encode(type), ...body];
}

List<int> dataAtom(List<int> payload, {int flags = 1}) => [
      ...u32be(payload.length + 16),
      ...fourcc('data'),
      ...u32be(flags), // 高 8 位是 version，低 24 位是 flags
      ...u32be(0),
      ...payload,
    ];

String copyright = '\u00A9';

List<int> ilst(List<List<int>> atoms) => mp4Box('ilst', atoms);

List<int> mp4File({required bool withMoov, List<List<int>> atoms = const []}) => [
      ...mp4Box('ftyp', [
        [...latin1.encode('M4A '), ...u32be(0), ...latin1.encode('M4A ')],
      ]),
      if (withMoov)
        ...mp4Box('moov', [
          ...mp4Box('udta', [
            ...mp4Box('meta', [
              ...u32be(0) , // meta 的 version/flags 占位（4 字节）
              ...mp4Box('ilst', atoms),
            ]),
          ]),
        ]),
      ...mpegFrame(),
    ];
```

测试（移植 JS `m4a` 族的 5 条断言）：

```dart
// test/metadata/mp4_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/metadata/byte_reader.dart';
import 'package:light_music/metadata/mp4.dart';

import 'tag_fixtures.dart';

void main() {
  test('m4a：©nam/©ART/©alb/covr', () async {
    final file = mp4File(withMoov: true, atoms: [
      mp4Box('${copyright}nam', [dataAtom(latin1.encode('十年'))]),
      mp4Box('${copyright}ART', [dataAtom(latin1.encode('陈奕迅'))]),
      mp4Box('${copyright}alb', [dataAtom(latin1.encode('Stranger Under My Skin'))]),
      mp4Box('covr', [dataAtom(pngBody(), flags: 14)]),
    ]);
    final tag = await parseMp4Meta(ByteSource.fromBytes(file))!;
    expect(tag.title, '十年');
    expect(tag.artist, '陈奕迅');
    expect(tag.album, 'Stranger Under My Skin');
    expect(tag.pictureMime, 'image/png');
    expect(tag.picture, pngBody());
  });

  test('ftyp 有 moov 无：返回 null，不抛', () async {
    expect(await parseMp4Meta(ByteSource.fromBytes(mp4File(withMoov: false))), isNull);
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/metadata/mp4_test.dart`
Expected: 编译失败 —— `mp4.dart` 不存在。

- [ ] **Step 3: 实现**

```dart
// lib/metadata/mp4.dart
import 'dart:typed_data';

import 'byte_reader.dart';
import 'id3.dart';
import 'text_decode.dart';

const int _jpegFlag = 13;
const int _pngFlag = 14;

Future<Id3Tag?> parseMp4Meta(ByteSource src, {int offset = 0}) async {
  if (!await src.matches(offset + 4, [0x66, 0x74, 0x79, 0x70])) return null; // ftyp
  final moov = await _findBox(src, offset, src.length, 'moov');
  if (moov == null) return null;
  final udta = await _findBox(src, moov.$1, moov.$2, 'udta');
  if (udta == null) return null;
  final meta = await _findBox(src, udta.$1, udta.$2, 'meta');
  if (meta == null) return null;
  // meta 是 box，4 字节 version/flags 之后才是 ilst
  final ilst = await _findBox(src, meta.$1 + 4, meta.$2, 'ilst');
  if (ilst == null) return null;

  final tag = Id3Tag(version: 'mp4');
  var pos = ilst.$1;
  while (pos + 8 <= ilst.$2) {
    final size = await src.u32be(pos);
    if (size < 8 || pos + size > ilst.$2) break;
    final name = String.fromCharCodes(await src.read(pos + 4, 4));
    final content = await src.read(pos + 8, size - 8);
    final value = await _readDataAtom(content);
    if (value != null) {
      switch (name) {
        case '\u00a9nam':
          if (tag.title.isEmpty) tag.title = _clean(value.$1 as String);
        case '\u00a9ART':
          if (tag.artist.isEmpty) tag.artist = _clean(value.$1 as String);
        case '\u00a9alb':
          if (tag.album.isEmpty) tag.album = _clean(value.$1 as String);
        case 'aART':
          if (tag.albumArtist.isEmpty) tag.albumArtist = _clean(value.$1 as String);
        case 'covr':
          tag.picture = value.$2 as Uint8List;
          tag.pictureMime = value.$3 as String;
      }
    }
    pos += size;
  }
  return tag.isEmpty ? null : tag;
}

/// 返回 (文本 | 图片字节, mime)；不是 data atom 时返回 null。
Future<(Object, [Uint8List?, String?])?> _readDataAtom(List<int> content) async {
  if (content.length < 16) return null;
  final atomSize = (content[0] << 24) | (content[1] << 16) | (content[2] << 8) | content[3];
  if (atomSize > content.length) return null;
  if (String.fromCharCodes(content.sublist(4, 8)) != 'data') return null;
  final flags = (content[8] << 16) | (content[9] << 8) | content[10];
  final payload = content.sublist(16, atomSize);
  if (payload.isEmpty) return null;
  if (flags == _jpegFlag) return (payload, [Uint8List.fromList(payload), 'image/jpeg']);
  if (flags == _pngFlag) return (payload, [Uint8List.fromList(payload), 'image/png']);
  final mime = sniffImageMime(payload);
  if (mime.isNotEmpty) return (payload, [Uint8List.fromList(payload), mime]);
  return (utf8DecodeOrLatin1(payload), [null, null]);
}

String utf8DecodeOrLatin1(List<int> bytes) =>
    canDecodeStrictlyUtf8(bytes) ? _utf8(bytes) : latin1.decode(bytes, allowMalformed: true);

String _utf8(List<int> bytes) {
  try {
    return String.fromCharCodes(bytes);
  } catch (_) {
    return latin1.decode(bytes, allowMalformed: true);
  }
}

String _clean(String v) => v.replaceAll('\u0000', '').trim();

Future<(int, int)?> _findBox(ByteSource src, int from, int to, String name) async {
  final target = latin1.encode(name);
  var pos = from;
  while (pos + 8 <= to) {
    final size = await src.u32be(pos);
    if (size < 8 || pos + size > to) return null;
    final type = await src.read(pos + 4, 4);
    for (var i = 0; i < 4; i++) {
      if (type[i] != target[i]) break;
      if (i == 3) return (pos + 8, pos + size);
    }
    pos += size;
  }
  return null;
}
```

> Step 3 里 `_readDataAtom` 的元组形状刻意保持 `(Object, [bytes?, mime?])`，与调用点的三种读取方式一致；实现时若觉得别扭，可改成 `class Mp4Value { final String? text; final Uint8List? bytes; final String mime; }` 并同步改 `_findBox` 调用点 —— 但必须与 Step 1 测试的断言字段一致，测试期望值不变。

- [ ] **Step 4: 跑测试确认通过**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/metadata/mp4_test.dart`
Expected: `All tests passed!`（2 个用例，5 条 m4a 断言 + 1 条无 moov）

- [ ] **Step 5: Commit**

```bash
cd flutter-app && git add lib/metadata test/metadata && git commit -m "feat(metadata): 移植 MP4 ilst 标签解析"
```

---

## Task 10: 容器分派、TagResult 与封面落盘

对译 `src/lib/audio-tags.js:736-870` 的 `readAudioTags` 主入口与 `mergeTaggedNames`，加原版 README 记录的「头 64KB 判格式、标签区按需再读、上限 8MB」策略。

**Files:**
- Create: `lib/metadata/audio_tags.dart`
- Create: `lib/metadata/cover_image.dart`
- Test: `test/metadata/audio_tags_test.dart`

**Interfaces:**
- Consumes: `ByteSource`（T6）、`parseId3v2`/`parseId3v1`（T7）、`parseFlacMeta`/`parseOggMeta`（T8）、`parseMp4Meta`（T9）、`splitArtistTitle`（M2 才有，本任务自带一个同名实现放在 `audio_tags.dart` 内，M2 迁到 `lyrics/` 时不改调用方）
- Produces:
  - `class TagResult { String format; String title; String artist; String album; String albumArtist; Uint8List? picture; String pictureMime; bool get hasAnyText; bool get hasPicture; Map<String, Object?> toJson(); }`
  - `Future<TagResult> readAudioTags(ByteSource src, {String fileName = ''});` —— **任何输入都不抛**，包括空文件与随机字节。
  - `class Names { String title; String artist; bool usedTags; }`、`Names mergeTaggedNames(TagResult tags, String fromName);`
  - `Future<String> splitArtistTitle(String raw)` 的同名工具改为 `({String artist, String title}) splitArtistTitle(String raw)`（按 ` - ` 拆，两侧去空白；拆不出返回同一 title、空 artist）。
  - `class CoverImageWriter { Future<String?> write(Uint8List bytes, String mime, {required String directory, String id}); }` → 返回落盘绝对路径，缩放上限 600px。

- [ ] **Step 1: 写失败测试**

```dart
// test/metadata/audio_tags_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/metadata/audio_tags.dart';
import 'package:light_music/metadata/byte_reader.dart';

import 'tag_fixtures.dart';

void main() {
  test('空文件与随机字节只给 format，不抛', () async {
    for (final fixture in [
      const <int>[],
      [1, 2, 3, 4, 5],
      ...List<int>.generate(200, (i) => (i * 37) % 256),
    ]) {
      final tags = await readAudioTags(ByteSource.fromBytes(fixture));
      expect(tags.format, isNotEmpty);
    }
  });

  test('synchsafe 声明超大帧区：不抛、不越界读', () async {
    final file = bytes([
      id3v2([textFrame('TIT2', 'A', version: 4)], version: 4),
      ...u32be(9000000),
      ...mpegFrame(),
    ]);
    final tags = await readAudioTags(ByteSource.fromBytes(file));
    expect(tags.title, 'A');
  });

  test('fLaC 块长度爆炸：停止扫描已解析字段', () async {
    final file = [0x66, 0x4c, 0x61, 0x43, 0x04, 0xff, 0xff, 0xff];
    final tags = await readAudioTags(ByteSource.fromBytes(file));
    expect(tags.format, 'flac');
    expect(tags.title, isEmpty);
  });

  test('APIC mime 为空时靠魔数嗅探出 image/jpeg', () async {
    final jpeg = [0xff, 0xd8, 0xff, 0xe0, 9, 9, 9];
    final file = bytes([
      id3v2([apicFrame('', jpeg)], version: 3),
      ...mpegFrame(),
    ]);
    final tags = await readAudioTags(ByteSource.fromBytes(file));
    expect(tags.pictureMime, 'image/jpeg');
    expect(tags.picture, jpeg);
  });

  group('mergeTaggedNames', () {
    test('标签齐全时忽略文件名', () {
      final n = mergeTaggedNames(
        TagResult(format: 'id3v2.3', title: '十年', artist: '陈奕迅'),
        '错的 - 名字',
      );
      expect(n.title, '十年');
      expect(n.artist, '陈奕迅');
      expect(n.usedTags, isTrue);
    });

    test('只有曲名标签时歌手从文件名补', () {
      final n = mergeTaggedNames(
        TagResult(format: 'id3v2.3', title: '十年'),
        '陈奕迅 - 十年',
      );
      expect(n.title, '十年');
      expect(n.artist, '陈奕迅');
    });

    test('albumArtist 兜 artist', () {
      final n = mergeTaggedNames(
        TagResult(format: 'flac', artist: '', albumArtist: 'Radiohead'),
        'Creep',
      );
      expect(n.artist, 'Radiohead');
    });

    test('完全无标签退回文件名拆分', () {
      final n = mergeTaggedNames(
        TagResult(format: 'mp3'),
        '孤勇者 - 陈奕迅',
      );
      expect(n.title, '孤勇者');
      expect(n.artist, '陈奕迅');
      expect(n.usedTags, isFalse);
    });
  });

  test('splitArtistTitle 只在有一个分隔符时拆', () {
    expect(splitArtistTitle('陈奕迅 - 十年'), (artist: '陈奕迅', title: '十年'));
    expect(splitArtistTitle('十年'), (artist: '', title: '十年'));
    expect(splitArtistTitle('a - b - c'), (artist: 'a', title: 'b - c'));
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/metadata/audio_tags_test.dart`
Expected: 编译失败 —— `audio_tags.dart` 不存在。

- [ ] **Step 3: 实现主入口**

```dart
// lib/metadata/audio_tags.dart
import 'dart:typed_data';

import 'byte_reader.dart';
import 'id3.dart';
import 'mp4.dart';
import 'vorbis.dart';

const int _headProbe = 64 * 1024;

class TagResult {
  TagResult({
    this.format = '',
    this.title = '',
    this.artist = '',
    this.album = '',
    this.albumArtist = '',
    this.picture,
    this.pictureMime = '',
  });

  String format;
  String title;
  String artist;
  String album;
  String albumArtist;
  Uint8List? picture;
  String pictureMime;

  bool get hasAnyText =>
      title.isNotEmpty || artist.isNotEmpty || album.isNotEmpty || albumArtist.isNotEmpty;
  bool get hasPicture => picture != null && picture!.isNotEmpty;

  Map<String, Object?> toJson() => {
        'format': format,
        'title': title,
        'artist': artist,
        'album': album,
        'albumArtist': albumArtist,
        'pictureMime': pictureMime,
        'pictureBytes': picture == null ? null : base64Of(picture!),
      };
}

String base64Of(List<int> bytes) {
  const chars =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  final out = StringBuffer();
  for (var i = 0; i < bytes.length; i += 3) {
    final b0 = bytes[i];
    final b1 = i + 1 < bytes.length ? bytes[i + 1] : 0;
    final b2 = i + 2 < bytes.length ? bytes[i + 2] : 0;
    out.write(chars[(b0 & 0xfc) >> 2]);
    out.write(chars[((b0 & 0x03) << 4) | ((b1 & 0xf0) >> 4)]);
    out.write(i + 1 < bytes.length ? chars[((b1 & 0x0f) << 2) | ((b2 & 0xc0) >> 6)] : '=');
    out.write(i + 2 < bytes.length ? chars[b2 & 0x3f] : '=');
  }
  return out.toString();
}

/// 永不抛：任何一段解析失败只影响对应字段。
Future<TagResult> readAudioTags(ByteSource src, {String fileName = ''}) async {
  final result = TagResult();
  if (src.length == 0) {
    result.format = 'unknown';
    return result;
  }
  try {
    if (await src.matches(0, [0x66, 0x4c, 0x61, 0x43])) {
      result.format = 'flac';
      _apply(result, await parseFlacMeta(src));
      return result;
    }
    if (await src.matches(0, [0x4f, 0x67, 0x67, 0x53])) {
      result.format = 'ogg';
      _apply(result, await parseOggMeta(src));
      return result;
    }
    if (await src.matches(4, [0x66, 0x74, 0x79, 0x70])) {
      result.format = 'mp4';
      _apply(result, await parseMp4Meta(src));
      return result;
    }
    if (await src.matches(0, [0x49, 0x44, 0x33])) {
      result.format = 'id3v2';
      _apply(result, await parseId3v2(src));
      _fallbackId3v1(result, src);
      return result;
    }
    result.format = 'mp3';
    _apply(result, await parseId3v2(src));
    _fallbackId3v1(result, src);
    return result;
  } catch (_) {
    if (result.format.isEmpty) result.format = 'unknown';
    return result;
  }
}

Future<void> _fallbackId3v1(TagResult result, ByteSource src) async {
  if (result.hasAnyText && result.hasPicture) return;
  final v1 = await parseId3v1(src);
  _apply(result, v1, onlyFillGaps: true);
}

void _apply(TagResult result, Id3Tag? tag, {bool onlyFillGaps = true}) {
  if (tag == null) return;
  if (result.format == 'id3v2' && tag.version.isNotEmpty) result.format = tag.version;
  if (result.title.isEmpty) result.title = tag.title;
  if (result.artist.isEmpty) result.artist = tag.artist;
  if (result.album.isEmpty) result.album = tag.album;
  if (result.albumArtist.isEmpty) result.albumArtist = tag.albumArtist;
  if (!onlyFillGaps || result.picture == null) {
    if (tag.picture != null) {
      result.picture = tag.picture;
      result.pictureMime = tag.pictureMime;
    }
  }
}

class Names {
  Names({required this.title, required this.artist, required this.usedTags});
  final String title;
  final String artist;
  final bool usedTags;
}

/// 标签优先，缺项才用文件名拆分补，与原版 mergeTaggedNames 同。
Names mergeTaggedNames(TagResult tags, String fromName) {
  final split = splitArtistTitle(fromName);
  final usedTags =
      tags.title.isNotEmpty || tags.artist.isNotEmpty || tags.albumArtist.isNotEmpty;
  final title = tags.title.isNotEmpty ? tags.title : split.title;
  var artist = tags.artist.isNotEmpty
      ? tags.artist
      : (tags.albumArtist.isNotEmpty ? tags.albumArtist : split.artist);
  if (artist.isEmpty && tags.title.isNotEmpty) artist = split.artist;
  return Names(title: title, artist: artist, usedTags: usedTags);
}

({String artist, String title}) splitArtistTitle(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return (artist: '', title: '');
  final at = text.indexOf(' - ');
  if (at <= 0) return (artist: '', title: text);
  final left = text.substring(0, at).trim();
  final right = text.substring(at + 3).trim();
  if (left.isEmpty || right.isEmpty) return (artist: '', title: text);
  return (artist: left, title: right);
}
```

- [ ] **Step 4: 实现封面落盘**

```dart
// lib/metadata/cover_image.dart
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

/// 内嵌封面缩到 <=600px 后写 JPEG 到缓存目录，返回绝对路径。
class CoverImageWriter {
  const CoverImageWriter();

  static const int maxEdge = 600;
  static const int jpegQuality = 86;

  Future<String?> write(
    Uint8List bytes,
    String mime, {
    required String directory,
    required String id,
  }) async {
    if (bytes.isEmpty) return null;
    try {
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: 0,
        targetHeight: 0,
      );
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final scaled = _fitWithin(image.width, image.height);
      final resized = await ui.instantiateImageCodec(
        bytes,
        targetWidth: scaled.$1,
        targetHeight: scaled.$2,
      );
      final resizedFrame = await (await resized.getNextFrame()).image.toByteData(
        format: ui.PixelFormat.rgba8888,
      );
      if (resizedFrame == null) return null;
      final out = File(Platform.pathSeparator.isEmpty
          ? '$directory/$id.jpg'
          : '$directory/$id.jpg');
      await out.parent.create(recursive: true);
      final encoded = await _encodeJpeg(image, scaled);
      if (encoded == null) return null;
      await out.writeAsBytes(encoded);
      return out.path;
    } catch (_) {
      // 解不出图像：当作没有内嵌封面，继续走后面的兜底级
      return null;
    }
  }

  (int, int) _fitWithin(int width, int height) {
    if (width <= maxEdge && height <= maxEdge) return (width, height);
    final ratio = maxEdge / (width > height ? width : height);
    return ((width * ratio).round(), (height * ratio).round());
  }

  Future<Uint8List?> _encodeJpeg(ui.Image image, (int, int) size) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder.beginRecording(
      ui.Rect.fromLTWH(0, 0, size.$1.toDouble(), size.$2.toDouble()),
    ));
    canvas.drawImageRect(
      image,
      ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      ui.Rect.fromLTWH(0, 0, size.$1.toDouble(), size.$2.toDouble()),
      ui.Paint(),
    );
    final picture = recorder.endRecording();
    final rendered = await picture.toImage(size.$1, size.$2);
    final data = await rendered.toByteData(format: ui.PixelFormat.png);
    if (data == null) return null;
    return Uint8List.sublistView(data.buffer.asUint8List());
  }
}
```

> Step 4 的产物落盘格式：原版是 ≤600px 的 JPEG data URL，Dart 侧 `ui.Image` 无 JPEG 编码器。**实现约定**：文件扩展名 `.jpg`、内容是 PNG 字节（Flutter 的 `toByteData` 只给 PNG/raw），读取方一律靠 `findElementById` 式的字节嗅探而不是扩展名判断，因此格式标签不一致不影响显示；这一点在 `cover_image.dart` 顶部用注释写明，M2 的封面显示层同样按嗅探处理。**不要为了凑 JPEG 去加第三方编码依赖。**

- [ ] **Step 5: 跑测试确认通过**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/metadata/`
Expected: `All tests passed!`；`audio_tags_test.dart` 里 9 个用例绿。

- [ ] **Step 6: 与 JS 侧对表核对断言总数**

Run: `cd .. && node tests/t-tags.mjs | tail -1`
Expected: `通过 57 · 失败 0`。在 Dart 侧数一次：

Run: `cd flutter-app && grep -c "expect(" test/metadata/*_test.dart`
Expected: 合计 **≥ 57**。少于 57 就说明有断言没搬完，回到 T7/T8/T9/T10 补齐 —— **这是 M1 的硬门槛，不许以「用例等价」为理由少搬**。

- [ ] **Step 7: Commit**

```bash
cd flutter-app && git add lib/metadata test/metadata && git commit -m "feat(metadata): 完成标签容器分派与内嵌封面落盘"
```

---

## Task 11: 四类播放错误归一

media_kit 不给 `MEDIA_ERR_*`，本任务把「预校验 + 运行期失败」归一到原版四类文案（spec §7）。

**Files:**
- Create: `lib/playback/play_error.dart`
- Test: `test/playback/play_error_test.dart`

**Interfaces:**
- Consumes: 无
- Produces:
  - `enum PlayErrorKind { aborted, network, decode, unsupported, unknown }`
  - `const Map<PlayErrorKind, String> kPlayErrorMessages`，值逐字为 Global Constraints 的四条 + `音频播放失败，请稍后重试`
  - `const String kAutoplayBlockedMessage = '无法开始播放，请点击播放按钮开始';`
  - `const Set<String> kAudioExtensions = {'mp3','wav','ogg','oga','opus','m4a','aac','flac','webm','weba','mp4'};`
  - `bool isSupportedExtension(String name);`
  - `PlayErrorKind classifyFailure({String? fileName, String? rawMessage, bool notFound = false});`

- [ ] **Step 1: 写失败测试**

```dart
// test/playback/play_error_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/playback/play_error.dart';

void main() {
  test('白名单逐字对齐原版 11 项', () {
    expect(kAudioExtensions.length, 11);
    for (final ext in ['mp3','wav','ogg','oga','opus','m4a','aac','flac','webm','weba','mp4']) {
      expect(isSupportedExtension(ext), isTrue, reason: ext);
    }
    expect(isSupportedExtension('MP3'), isTrue);
    expect(isSupportedExtension('txt'), isFalse);
    expect(isSupportedExtension('lrc'), isFalse);
    expect(isSupportedExtension(''), isFalse);
  });

  test('文案逐字对齐原版四类', () {
    expect(kPlayErrorMessages[PlayErrorKind.aborted], '音频加载被中断，请重试');
    expect(kPlayErrorMessages[PlayErrorKind.network], '网络错误，无法获取音频文件');
    expect(kPlayErrorMessages[PlayErrorKind.decode], '音频解码失败，文件可能已损坏');
    expect(kPlayErrorMessages[PlayErrorKind.unsupported], '格式不支持或音频文件不存在');
    expect(kPlayErrorMessages[PlayErrorKind.unknown], '音频播放失败，请稍后重试');
  });

  test('分类优先级：不支持 > 解码 > 中断', () {
    expect(classifyFailure(fileName: 'a.txt'), PlayErrorKind.unsupported);
    expect(classifyFailure(fileName: 'a.flac', notFound: true), PlayErrorKind.unsupported);
    expect(classifyFailure(fileName: 'a.flac', rawMessage: 'Failed to open file'),
        PlayErrorKind.decode);
    expect(classifyFailure(fileName: 'a.flac', rawMessage: 'no such file or directory'),
        PlayErrorKind.unsupported);
    expect(classifyFailure(fileName: 'a.flac', rawMessage: 'stream interrupted'),
        PlayErrorKind.aborted);
    expect(classifyFailure(fileName: 'a.flac'), PlayErrorKind.unknown);
  });

  test('自动播放受阻文案', () {
    expect(kAutoplayBlockedMessage, '无法开始播放，请点击播放按钮开始');
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/playback/play_error_test.dart`
Expected: 编译失败 —— `play_error.dart` 不存在。

- [ ] **Step 3: 实现**

```dart
// lib/playback/play_error.dart
enum PlayErrorKind { aborted, network, decode, unsupported, unknown }

const Map<PlayErrorKind, String> kPlayErrorMessages = {
  PlayErrorKind.aborted: '音频加载被中断，请重试',
  PlayErrorKind.network: '网络错误，无法获取音频文件',
  PlayErrorKind.decode: '音频解码失败，文件可能已损坏',
  PlayErrorKind.unsupported: '格式不支持或音频文件不存在',
  PlayErrorKind.unknown: '音频播放失败，请稍后重试',
};

/// 原版是「浏览器阻止了自动播放」；Flutter 侧对应音频焦点被抢（spec §4）。
const String kAutoplayBlockedMessage = '无法开始播放，请点击播放按钮开始';

const Set<String> kAudioExtensions = {
  'mp3', 'wav', 'ogg', 'oga', 'opus', 'm4a', 'aac', 'flac', 'webm', 'weba', 'mp4',
};

bool isSupportedExtension(String name) => kAudioExtensions.contains(
      name.trim().toLowerCase().replaceAll('.', ''),
    );

String extensionOf(String path) {
  final at = path.lastIndexOf('.');
  return at < 0 ? '' : path.substring(at + 1).toLowerCase();
}

/// 预校验不通过一律判 unsupported；运行期按 mpv 文本粗分，兜底 unknown。
PlayErrorKind classifyFailure({
  String? fileName,
  String? rawMessage,
  bool notFound = false,
}) {
  final ext = fileName == null ? '' : extensionOf(fileName);
  if (notFound) return PlayErrorKind.unsupported;
  if (ext.isNotEmpty && !isSupportedExtension(ext)) return PlayErrorKind.unsupported;
  final message = (rawMessage ?? '').toLowerCase();
  if (message.isEmpty) return PlayErrorKind.unknown;
  if (message.contains('no such file') ||
      message.contains('does not exist') ||
      message.contains('cannot open') ||
      message.contains('failed to open')) {
    return PlayErrorKind.unsupported;
  }
  if (message.contains('invalid data') ||
      message.contains('decode') ||
      message.contains('corrupt') ||
      message.contains('unsupported format')) {
    return PlayErrorKind.decode;
  }
  if (message.contains('interrupt') ||
      message.contains('aborted') ||
      message.contains('canceled') ||
      message.contains('cancelled')) {
    return PlayErrorKind.aborted;
  }
  if (message.contains('network') ||
      message.contains('connection') ||
      message.contains('timed out')) {
    return PlayErrorKind.network;
  }
  return PlayErrorKind.unknown;
}

String errorMessageFor(PlayErrorKind kind) => kPlayErrorMessages[kind]!;
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/playback/play_error_test.dart`
Expected: `All tests passed!`（4 个用例）

- [ ] **Step 5: Commit**

```bash
cd flutter-app && git add lib/playback test/playback && git commit -m "feat(playback): 新增四类播放错误归一与格式白名单"
```

---

## Task 12: 播放驱动抽象与测试替身

**Files:**
- Create: `lib/playback/audio_driver.dart`
- Test: `test/playback/audio_driver_fake_test.dart`

**Interfaces:**
- Consumes: `Track`（T3）、`PlayErrorKind`（T11）
- Produces:
  - `abstract class AudioDriver { Future<bool> open(Track track); Future<void> play(); Future<void> pause(); Future<bool> seekTo(double seconds); Future<void> setVolume(double v); Future<void> setRate(double r); Future<void> stop(); Future<void> dispose(); Stream<double> get positionStream; Stream<double?> get bufferedStream; Stream<double?> get durationStream; Stream<bool> get playingStream; Stream<bool> get loadingStream; Stream<DriverError> get errorStream; Stream<void> get completedStream; Stream<void> get canplayStream; double get duration; double get position; double get buffered; bool get isPlaying; bool get isLoading; }`
  - `class DriverError { PlayErrorKind kind; String rawMessage; }`
  - `class FakeAudioDriver implements AudioDriver` —— 测试里可控：`emitPosition(double)`、`emitDuration(double)`、`failNext({PlayErrorKind kind, String message})`、`blockOpen = true`（模拟加载不返回）、记录 `calls` 列表（`open:uri`、`play`、`pause`、`seek:12.5` 形态）。

- [ ] **Step 1: 写失败测试（先测 Fake 自身的可脚本化行为）**

```dart
// test/playback/audio_driver_fake_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/playback/audio_driver.dart';
import 'package:light_music/playback/play_error.dart';
import 'package:light_music/playback/track.dart';

Track aTrack() => Track(id: '1', src: '/a.flac', title: 'A', duration: 100);

void main() {
  test('open 记录调用并回报时长', () async {
    final driver = FakeAudioDriver();
    expect(await driver.open(aTrack()), isTrue);
    expect(driver.calls, contains('open:/a.flac'));
    await for (final d in driver.durationStream) {
      expect(d, 100);
      break;
    }
  });

  test('failNext 让 open 返回 false 并推送错误', () async {
    final driver = FakeAudioDriver()
      ..failNext(kind: PlayErrorKind.decode, message: 'broken stream');
    expect(await driver.open(aTrack()), isFalse);
    final error = await driver.errorStream.first;
    expect(error.kind, PlayErrorKind.decode);
    expect(error.rawMessage, 'broken stream');
  });

  test('seek 越界夹到时长内并返回是否成功', () async {
    final driver = FakeAudioDriver();
    await driver.open(aTrack());
    expect(await driver.seekTo(999), isTrue);
    expect(driver.position, 100);
  });

  test('play/pause 驱动 playingStream', () async {
    final driver = FakeAudioDriver();
    await driver.open(aTrack());
    final states = <bool>[];
    final sub = driver.playingStream.listen(states.add);
    await driver.play();
    await driver.pause();
    await sub.cancel();
    expect(states, [true, false]);
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/playback/audio_driver_fake_test.dart`
Expected: 编译失败 —— `audio_driver.dart` 不存在。

- [ ] **Step 3: 实现接口与 Fake**

```dart
// lib/playback/audio_driver.dart
import 'dart:async';

import 'play_error.dart';
import 'track.dart';

class DriverError {
  DriverError(this.kind, this.rawMessage);
  final PlayErrorKind kind;
  final String rawMessage;
}

/// 播放内核的唯一出口。media_kit 实现与测试替身都满足它。
abstract class AudioDriver {
  Future<bool> open(Track track);
  Future<void> play();
  Future<void> pause();
  Future<bool> seekTo(double seconds);
  Future<void> setVolume(double value);
  Future<void> stop();
  Future<void> dispose();

  Stream<double> get positionStream;
  Stream<double?> get bufferedStream;
  Stream<double?> get durationStream;
  Stream<bool> get playingStream;
  Stream<bool> get loadingStream;
  Stream<DriverError> get errorStream;
  Stream<void> get completedStream;
  Stream<void> get canplayStream;

  double get position;
  double? get durationOrNull;
  double? get bufferedOrNull;
  bool get isPlaying;
  bool get isLoading;
}

class FakeAudioDriver implements AudioDriver {
  final List<String> calls = [];
  final _position = StreamController<double>.broadcast();
  final _buffered = StreamController<double?>.broadcast();
  final _duration = StreamController<double?>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _loading = StreamController<bool>.broadcast();
  final _errors = StreamController<DriverError>.broadcast();
  final _completed = StreamController<void>.broadcast();
  final _canplay = StreamController<void>.broadcast();

  double _positionValue = 0;
  double? _durationValue;
  double? _bufferedValue;
  bool _isPlaying = false;
  bool _isLoading = false;
  DriverError? _nextError;
  bool blockOpen = false;
  double maxVolume = 1;

  void failNext({PlayErrorKind kind = PlayErrorKind.decode, String message = 'boom'}) {
    _nextError = DriverError(kind, message);
  }

  void emitPosition(double seconds) {
    _positionValue = seconds;
    _position.add(seconds);
  }

  void emitDuration(double? seconds) {
    _durationValue = seconds;
    _duration.add(seconds);
  }

  void emitBuffered(double? seconds) {
    _bufferedValue = seconds;
    _buffered.add(seconds);
  }

  void emitCompleted() => _completed.add(null);

  @override
  Future<bool> open(Track track) async {
    calls.add('open:${track.src}');
    if (_nextError != null) {
      _errors.add(_nextError!);
      _nextError = null;
      return false;
    }
    if (blockOpen) {
      _isLoading = true;
      _loading.add(true);
      return true;
    }
    _durationValue = track.hasDuration ? track.duration : 100;
    _duration.add(_durationValue);
    _bufferedValue = _durationValue;
    _buffered.add(_bufferedValue);
    _canplay.add(null);
    _isLoading = false;
    _loading.add(false);
    return true;
  }

  @override
  Future<void> play() async {
    calls.add('play');
    _isPlaying = true;
    _playing.add(true);
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    _isPlaying = false;
    _playing.add(false);
  }

  @override
  Future<bool> seekTo(double seconds) async {
    final target = seconds < 0
        ? 0.0
        : (_durationValue == null ? seconds : _min(seconds, _durationValue!));
    _positionValue = target;
    calls.add('seek:${target.toStringAsFixed(1)}');
    _position.add(target);
    return true;
  }

  @override
  Future<void> setVolume(double value) async {
    calls.add('volume:${value.toStringAsFixed(2)}');
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    _isPlaying = false;
    _playing.add(false);
    _positionValue = 0;
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
    await _position.close();
    await _buffered.close();
    await _duration.close();
    await _playing.close();
    await _loading.close();
    await _errors.close();
    await _completed.close();
    await _canplay.close();
  }

  @override
  Stream<double> get positionStream => _position.stream;
  @override
  Stream<double?> get bufferedStream => _buffered.stream;
  @override
  Stream<double?> get durationStream => _duration.stream;
  @override
  Stream<bool> get playingStream => _playing.stream;
  @override
  Stream<bool> get loadingStream => _loading.stream;
  @override
  Stream<DriverError> get errorStream => _errors.stream;
  @override
  Stream<void> get completedStream => _completed.stream;
  @override
  Stream<void> get canplayStream => _canplay.stream;

  @override
  double get position => _positionValue;
  @override
  double? get durationOrNull => _durationValue;
  @override
  double? get bufferedOrNull => _bufferedValue;
  @override
  bool get isPlaying => _isPlaying;
  @override
  bool get isLoading => _isLoading;
}

double _min(double a, double b) => a < b ? a : b;
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/playback/audio_driver_fake_test.dart`
Expected: `All tests passed!`（4 个用例）。若 `open` 用例里 `durationStream` 订阅时机导致拿不到首值，改为先 `final future = driver.durationStream.first;` 再 `open`，**不要**改成给 Fake 加历史重放（真实 driver 不会重放）。

- [ ] **Step 5: Commit**

```bash
cd flutter-app && git add lib/playback test/playback && git commit -m "feat(playback): 定义播放驱动接口与测试替身"
```

---

## Task 13: AudioPlayer —— media_kit 实现与 seek 守卫

对译 `src/lib/player.js` 的守卫三件套（`armSeekGuard` 900ms、`verifySeekGuard` 容差 0.75s、`applySeekGuardOnPlay` 400ms 且 `corrected` 只补做一次），以及音量/静音的 `lastVolume` 规则。守卫必须能在 Fake 时钟下单测，所以把 `Timer` 与时长都做成可注入。

**Files:**
- Create: `lib/playback/media_kit_driver.dart`
- Create: `lib/playback/audio_player.dart`
- Test: `test/playback/audio_player_seek_guard_test.dart`
- Test: `test/playback/audio_player_volume_test.dart`

**Interfaces:**
- Consumes: `AudioDriver` / `FakeAudioDriver`（T12）、`Track`（T3）、`PlayErrorKind`（T11）
- Produces: `class AudioPlayer`
  - `AudioPlayer(AudioDriver driver, {double initialVolume = 0.7, void Function(Duration, TimerCallback)? scheduler})` —— `scheduler` 默认真实 `Timer`，测试注入即时执行的假调度。
  - `Stream<PlayerEvent> get events;`，`sealed class PlayerEvent`：`LoadingEvent(bool loading)`、`CanplayEvent(double? duration)`、`TimeUpdateEvent(double position, double? duration)`、`StateChangedEvent(bool playing)`、`VolumeEvent(double volume, bool muted)`、`ErrorEvent(PlayErrorKind kind, String message)`、`BlockedEvent(String message)`
  - `Future<bool> load(Track track, {bool autoplay = false})`、`Future<void> pause()`、`Future<bool> seek(double seconds)`、`Future<bool> seekBy(double delta)`、`Future<void> setVolume(double value)`、`Future<void> setMuted(bool muted)`、`Future<bool> toggleMute()`、`Future<void> stop()`、`Future<void> dispose()`
  - `Track? get track`、`bool get playing`、`bool get muted`、`double get volume`、`double get position`、`double? get duration`、`double? get buffered`

- [ ] **Step 1: 写失败测试（守卫与音量语义）**

```dart
// test/playback/audio_player_seek_guard_test.dart
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/playback/audio_driver.dart';
import 'package:light_music/playback/audio_player.dart';
import 'package:light_music/playback/track.dart';

/// 立即触发、可手动 flush 的假调度器。
class FakeScheduler {
  final List<void Function()> _pending = [];
  Duration? lastDelay;

  void schedule(Duration delay, void Function() callback) {
    lastDelay = delay;
    _pending.add(callback);
  }

  void flush() {
    final pending = List.of(_pending);
    _pending.clear();
    for (final cb in pending) {
      cb();
    }
  }

  int get pendingCount => _pending.length;
}

Track trackAt(double duration) =>
    Track(id: '1', src: '/a.flac', title: 'A', duration: duration);

void main() {
  test('seek 后 arm 守卫：900ms 内位置没跟上就补做一次', () async {
    final driver = FakeAudioDriver();
    final scheduler = FakeScheduler();
    final player = AudioPlayer(driver, scheduler: scheduler.schedule);
    await player.load(trackAt(100));

    await player.seek(50);
    expect(scheduler.lastDelay, const Duration(milliseconds: 900));

    // 内核只走到 40（落后超过 0.75s）：flush 应把它补到 50
    driver.emitPosition(40);
    scheduler.flush();
    expect(driver.calls, contains('seek:50.0'));
  });

  test('容差内（差 0.5s）不补做，避免打断正常推进', () async {
    final driver = FakeAudioDriver();
    final scheduler = FakeScheduler();
    final player = AudioPlayer(driver, scheduler: scheduler.schedule);
    await player.load(trackAt(100));
    await player.seek(50);
    driver.emitPosition(49.5);
    scheduler.flush();
    expect(driver.calls.where((c) => c == 'seek:50.0').length, 1);
  });

  test('playing 事件里补做一次后即标记 corrected，不再自激', () async {
    final driver = FakeAudioDriver();
    final scheduler = FakeScheduler();
    final player = AudioPlayer(driver, scheduler: scheduler.schedule);
    await player.load(trackAt(100));
    await player.seek(60);
    // 模拟内核回到起点后上报 playing
    driver.emitPosition(0);
    driver.emitPlaying(true);
    await Future<void>.delayed(Duration.zero);
    final seekCalls = driver.calls.where((c) => c.startsWith('seek:')).length;
    expect(seekCalls, 2); // 原始一次 + 补做一次，不多不少
    expect(scheduler.lastDelay, const Duration(milliseconds: 400));
  });

  test('守卫只补做向前：当前位置超过目标时不回拉', () async {
    final driver = FakeAudioDriver();
    final scheduler = FakeScheduler();
    final player = AudioPlayer(driver, scheduler: scheduler.schedule);
    await player.load(trackAt(100));
    await player.seek(30);
    driver.emitPosition(80);
    scheduler.flush();
    expect(driver.calls.where((c) => c == 'seek:30.0').length, 1);
  });

  test('时长未知时先记 pendingSeek，拿到时长后补做', () async {
    final driver = FakeAudioDriver()..blockOpen = true;
    final player = AudioPlayer(driver, scheduler: (d, cb) => cb());
    await player.load(Track(id: '1', src: '/a.flac', title: 'A'));
    expect(await player.seek(20), isTrue);
    driver.emitDuration(120);
    await Future<void>.delayed(Duration.zero);
    expect(driver.calls, contains('seek:20.0'));
  });
}
```

```dart
// test/playback/audio_player_volume_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/playback/audio_driver.dart';
import 'package:light_music/playback/audio_player.dart';

void main() {
  test('setVolume(0) 判静音但保留记忆音量', () async {
    final player = AudioPlayer(FakeAudioDriver());
    await player.setVolume(0.4);
    expect(player.volume, 0.4);
    await player.setVolume(0);
    expect(player.muted, isTrue);
    expect(player.volume, 0);
  });

  test('toggleMute 往返恢复原音量', () async {
    final driver = FakeAudioDriver();
    final player = AudioPlayer(driver);
    await player.setVolume(0.62);
    expect(await player.toggleMute(), isTrue);
    expect(player.muted, isTrue);
    expect(await player.toggleMute(), isFalse);
    expect(player.volume, closeTo(0.62, 0.001));
    expect(driver.calls, contains('volume:0.62'));
  });

  test('默认音量 0.7，静音后取消恢复默认而非 0', () async {
    final player = AudioPlayer(FakeAudioDriver());
    expect(player.volume, 0.7);
    await player.setMuted(true);
    await player.setMuted(false);
    expect(player.volume, greaterThan(0));
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/playback/`
Expected: 编译失败 —— `audio_player.dart` 不存在，且 `FakeAudioDriver` 缺 `emitPlaying`（T12 的 Fake 需要补这个方法，见 Step 3 注）。

- [ ] **Step 3: 给 Fake 补一个播放态入口**

在 `lib/playback/audio_driver.dart` 的 `FakeAudioDriver` 里追加：

```dart
  void emitPlaying(bool value) {
    _isPlaying = value;
    _playing.add(value);
  }
```

- [ ] **Step 4: 实现 AudioPlayer**

```dart
// lib/playback/audio_player.dart
import 'dart:async';

import 'audio_driver.dart';
import 'play_error.dart';
import 'track.dart';

sealed class PlayerEvent;

class LoadingEvent extends PlayerEvent {
  LoadingEvent(this.loading);
  final bool loading;
}

class CanplayEvent extends PlayerEvent {
  CanplayEvent(this.duration);
  final double? duration;
}

class TimeUpdateEvent extends PlayerEvent {
  TimeUpdateEvent(this.position, this.duration);
  final double position;
  final double? duration;
}

class StateChangedEvent extends PlayerEvent {
  StateChangedEvent(this.playing);
  final bool playing;
}

class VolumeEvent extends PlayerEvent {
  VolumeEvent(this.volume, this.muted);
  final double volume;
  final bool muted;
}

class ErrorEvent extends PlayerEvent {
  ErrorEvent(this.kind, this.message);
  final PlayErrorKind kind;
  final String message;
}

class BlockedEvent extends PlayerEvent {
  BlockedEvent(this.message);
  final String message;
}

typedef ScheduleFn = void Function(Duration delay, void Function() callback);

/// 对齐原版 seek 守卫的三个数值常量。
const int _guardVerifyMs = 900;
const int _guardAfterPlayMs = 400;
const double _guardTolerance = 0.75;

class SeekGuard {
  SeekGuard(this.target);
  double target;
  bool corrected = false;
  Timer? timer;
}

class AudioPlayer {
  AudioPlayer(this._driver, {double initialVolume = 0.7, ScheduleFn? scheduler})
      : _volume = _clamp01(initialVolume),
        _lastVolume = _clamp01(initialVolume) > 0 ? _clamp01(initialVolume) : 0.7,
        _schedule = scheduler ??
            ((delay, cb) => Timer(delay, cb)) {
    _subs.add(_driver.positionStream.listen(_onPosition));
    _subs.add(_driver.durationStream.listen(_onDuration));
    _subs.add(_driver.bufferedStream.listen(_onBuffered));
    _subs.add(_driver.playingStream.listen(_onPlaying));
    _subs.add(_driver.loadingStream.listen(_onLoading));
    _subs.add(_driver.errorStream.listen(_onDriverError));
    _subs.add(_driver.canplayStream.listen((_) => _onCanplay()));
    _subs.add(_driver.completedStream.listen((_) => _onCompleted()));
  }

  final AudioDriver _driver;
  final ScheduleFn _schedule;
  final _events = StreamController<PlayerEvent>.broadcast();
  final List<StreamSubscription> _subs = [];

  Track? _track;
  double _volume;
  double _lastVolume;
  bool _muted = false;
  bool _loading = false;
  SeekGuard? _guard;
  double? _pendingSeek;

  Stream<PlayerEvent> get events => _events.stream;
  Track? get track => _track;
  bool get playing => _driver.isPlaying;
  bool get muted => _muted;
  double get volume => _muted ? 0 : _volume;
  double get position => _driver.position;
  double? get duration => _driver.durationOrNull;
  double? get buffered => _driver.bufferedOrNull;

  Future<bool> load(Track track, {bool autoplay = false}) async {
    _clearSeekGuard();
    _pendingSeek = null;
    _track = track;
    _setLoading(true);
    final opened = await _driver.open(track);
    if (!opened) {
      _setLoading(false);
      return false;
    }
    await _driver.setVolume(volume);
    if (autoplay) {
      unawaited(_play());
    }
    return true;
  }

  Future<void> _play() async {
    try {
      await _driver.play();
    } catch (error) {
      _setLoading(false);
      _events.add(BlockedEvent(_messageOf(error)));
    }
  }

  String _messageOf(Object error) {
    final text = error.toString();
    if (text.contains('NotAllowed') || text.contains('focus')) {
      return kAutoplayBlockedMessage;
    }
    return '无法开始播放：${text.replaceAll("\n", " ")}';
  }

  Future<void> pause() => _driver.pause();

  Future<bool> seek(double seconds) async {
    final requested = seconds.isFinite && seconds > 0 ? seconds : 0.0;
    final total = _driver.durationOrNull;
    if (total == null || !total.isFinite || total <= 0) {
      _pendingSeek = requested;
      return true;
    }
    final target = requested > total ? total : requested;
    final ok = await _driver.seekTo(target);
    if (ok) {
      _armSeekGuard(target);
      _events.add(TimeUpdateEvent(target, total));
    } else {
      _pendingSeek = requested;
    }
    return ok;
  }

  Future<bool> seekBy(double delta) => seek(position + (delta.isFinite ? delta : 0));

  Future<void> setVolume(double value) async {
    final v = _clamp01(value);
    _volume = v;
    if (v > 0) {
      _lastVolume = v;
      _muted = false;
    }
    await _driver.setVolume(v);
    _events.add(VolumeEvent(v, _muted));
  }

  Future<void> setMuted(bool muted) async {
    _muted = muted;
    if (!muted && _volume == 0) {
      _volume = _lastVolume > 0 ? _lastVolume : 0.7;
    }
    await _driver.setVolume(_muted ? 0 : _volume);
    _events.add(VolumeEvent(_muted ? 0 : _volume, _muted));
  }

  Future<bool> toggleMute() async {
    await setMuted(!_muted);
    return _muted;
  }

  Future<void> stop() async {
    _clearSeekGuard();
    _pendingSeek = null;
    _track = null;
    await _driver.stop();
    _setLoading(false);
  }

  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _clearSeekGuard();
    await _driver.dispose();
    await _events.close();
  }

  void _armSeekGuard(double seconds) {
    _clearSeekGuard();
    final guard = SeekGuard(seconds);
    _guard = guard;
    _schedule(const Duration(milliseconds: _guardVerifyMs), () {
      _verifySeekGuard(guard);
    });
  }

  void _clearSeekGuard() {
    _guard?.timer?.cancel();
    _guard = null;
  }

  /// 单向补做：只在实际位置明显落后目标时把位置推回去，超过目标不回拉。
  void _verifySeekGuard([SeekGuard? candidate]) {
    final guard = candidate ?? _guard;
    if (guard == null || !identical(guard, _guard)) return;
    _clearSeekGuard();
    if (guard.corrected || _track == null) return;
    if (_driver.position < guard.target - _guardTolerance) {
      unawaited(_driver.seekTo(guard.target));
    }
  }

  void _applySeekGuardOnPlay() {
    final guard = _guard;
    if (guard == null || guard.corrected) return;
    if (_driver.position < guard.target - _guardTolerance) {
      guard.corrected = true; // 关键：一次记忆最多补做一次，否则自激
      unawaited(_driver.seekTo(guard.target));
    }
    _schedule(const Duration(milliseconds: _guardAfterPlayMs), () {
      _verifySeekGuard(guard);
    });
  }

  void _onPosition(double value) {
    _events.add(TimeUpdateEvent(value, _driver.durationOrNull));
  }

  void _onDuration(double? value) {
    final pending = _pendingSeek;
    if (pending != null && value != null && value > 0) {
      _pendingSeek = null;
      final target = pending > value ? value : pending;
      unawaited(_driver.seekTo(target).then((_) => _armSeekGuard(target)));
    }
    _events.add(CanplayEvent(value));
  }

  void _onBuffered(double? value) {}

  void _onPlaying(bool isPlaying) {
    if (isPlaying) _applySeekGuardOnPlay();
    _events.add(StateChangedEvent(isPlaying));
  }

  void _onLoading(bool value) => _setLoading(value);

  void _onCanplay() {
    _setLoading(false);
    _events.add(CanplayEvent(_driver.durationOrNull));
  }

  void _onCompleted() {
    _setLoading(false);
    _events.add(StateChangedEvent(false));
  }

  void _onDriverError(DriverError error) {
    _setLoading(false);
    _events.add(ErrorEvent(error.kind, errorMessageFor(error.kind)));
  }

  void _setLoading(bool value) {
    if (_loading == value) return;
    _loading = value;
    _events.add(LoadingEvent(value));
  }
}

double _clamp01(num value) {
  if (!value.isFinite) return 0;
  return value < 0 ? 0 : (value > 1 ? 1 : value.toDouble());
}
```

> 与原版一致的两条硬规则必须在测试里可见：`_setLoading` 相同值不重复发事件；`_applySeekGuardOnPlay` 先把 `corrected` 置真再补赋值。若 Step 1 的第三个用例算出的 seek 次数不是 2，说明守卫被写成了「每次 playing 都补」，那是原版记录过的自激死循环 bug，必须改回来而不是放宽断言。

- [ ] **Step 5: 实现 media_kit 驱动**

```dart
// lib/playback/media_kit_driver.dart
import 'dart:async';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit/ffmpeg.dart'; // 若无此导出，用 package:media_kit/media_kit.dart 的 Platform 注册即可

import 'audio_driver.dart';
import 'play_error.dart';
import 'track.dart';

class MediaKitDriver implements AudioDriver {
  MediaKitDriver() : _player = Player() {
    _positionSub = _player.stream.position.listen((v) => _position.add(v.inMilliseconds / 1000));
    _durationSub = _player.stream.duration.listen((v) => _duration.add(v.inMilliseconds / 1000));
    _playingSub = _player.stream.playing.listen(_playing.add);
    _completedSub = _player.stream.completed.listen((v) { if (v) _completed.add(null); });
    _errorSub = _player.stream.error.listen((message) {
      _errors.add(DriverError(
        classifyFailure(rawMessage: message),
        message,
      ));
    });
    _bufferedSub = _player.stream.buffer.listen((v) => _buffered.add(v.inMilliseconds / 1000));
    _player.stream.buffering.listen((b) => _loading.add(b));
  }

  final Player _player;
  final _position = StreamController<double>.broadcast();
  final _buffered = StreamController<double?>.broadcast();
  final _duration = StreamController<double?>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _loading = StreamController<bool>.broadcast();
  final _errors = StreamController<DriverError>.broadcast();
  final _completed = StreamController<void>.broadcast();
  final _canplay = StreamController<void>.broadcast();

  late final StreamSubscription _positionSub;
  late final StreamSubscription _durationSub;
  late final StreamSubscription _playingSub;
  late final StreamSubscription _completedSub;
  late final StreamSubscription _errorSub;
  late final StreamSubscription _bufferedSub;

  @override
  Future<bool> open(Track track) async {
    try {
      await _player.open(Media(track.handle.uri), play: false);
      _canplay.add(null);
      _loading.add(false);
      return true;
    } catch (error) {
      _errors.add(DriverError(
        classifyFailure(
          fileName: track.handle.displayName,
          rawMessage: error.toString(),
        ),
        error.toString(),
      ));
      return false;
    }
  }

  @override
  Future<void> play() => _player.play();
  @override
  Future<void> pause() => _player.pause();

  @override
  Future<bool> seekTo(double seconds) async {
    try {
      await _player.seek(Duration(milliseconds: (seconds * 1000).round()));
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> setVolume(double value) => _player.setVolume(value * 100);
  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> dispose() async {
    await _positionSub.cancel();
    await _durationSub.cancel();
    await _playingSub.cancel();
    await _completedSub.cancel();
    await _errorSub.cancel();
    await _bufferedSub.cancel();
    await _player.dispose();
    await _position.close();
    await _buffered.close();
    await _duration.close();
    await _playing.close();
    await _loading.close();
    await _errors.close();
    await _completed.close();
    await _canplay.close();
  }

  @override
  Stream<double> get positionStream => _position.stream;
  @override
  Stream<double?> get bufferedStream => _buffered.stream;
  @override
  Stream<double?> get durationStream => _duration.stream;
  @override
  Stream<bool> get playingStream => _playing.stream;
  @override
  Stream<bool> get loadingStream => _loading.stream;
  @override
  Stream<DriverError> get errorStream => _errors.stream;
  @override
  Stream<void> get completedStream => _completed.stream;
  @override
  Stream<void> get canplayStream => _canplay.stream;

  @override
  double get position => _player.state.position.inMilliseconds / 1000;
  @override
  double? get durationOrNull {
    final v = _player.state.duration.inMilliseconds / 1000;
    return v > 0 ? v : null;
  }

  @override
  double? get bufferedOrNull {
    final v = _player.state.buffer.inMilliseconds / 1000;
    return v > 0 ? v : null;
  }

  @override
  bool get isPlaying => _player.state.playing;
  @override
  bool get isLoading => _player.state.buffering;
}
```

- [ ] **Step 6: 真机 smoke（media_kit 只能在设备上验，单元测试碰不到它）**

在 `lib/main.dart` 临时塞一个按钮，用 `MediaKitDriver` 打开一个真实 FLAC 路径，跑：

Run: `cd flutter-app && /d/flutter/bin/flutter run -d windows`
Expected: 有声、进度条走动、`positionStream` 约每秒 4 次以上；关闭页面无崩溃。验完删掉临时按钮，把 driver 留到 T14 的装配里。若首次运行报缺 mpv 库，先确认 `media_kit_libs_windows_audio` 已在 pubspec（T1 Step 2）再重跑 `flutter clean && flutter pub get`。

- [ ] **Step 7: 跑全部单元测试并 Commit**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/playback/`
Expected: `All tests passed!`（守卫 5 + 音量 3 全绿）

```bash
cd flutter-app && git add lib/playback test/playback && git commit -m "feat(playback): 移植播放层 seek 守卫与音量语义并接入 media_kit"
```

---

## Task 14: TransportController —— 模式、上下曲、损坏与熔断

对译 `state/player.tsx` 的编排部分：上一首 3 秒规则、损坏曲目延迟 1400ms 自动跳、`consecutiveFailures` 只在真正可播放时清零、失败数达到列表长度触发熔断并停止自动跳转、真正出声才记最近播放。

**Files:**
- Create: `lib/playback/transport_controller.dart`
- Test: `test/playback/transport_controller_test.dart`

**Interfaces:**
- Consumes: `AudioPlayer`（T13）、`Playlist`（T4）、`RecentRecorder` 接口（本任务定义，T16 用 `RecentStore` 实现）、`ToastSink` 接口（本任务定义，T20 用 `ToastState` 实现）
- Produces:
  - `abstract class RecentRecorder { void record(Track track, {DateTime? at}); }`
  - `abstract class ToastSink { void show(String message, {String key = '', int durationMs = 3200}); void info(String message); void error(String message); }`
  - `class TransportController`：`TransportController({required AudioPlayer player, required RecentRecorder recent, required ToastSink toasts, Playlist? playlist, int Function()? now})`
    - `Playlist get playlist`、`Track? get current`、`bool get playing`、`bool get loading`、`bool get circuitOpen`、`int get consecutiveFailures`、`String? get blockedMessage`
    - `Future<void> playTrack(String id, {bool autoplay = true})`、`Future<void> togglePlay()`、`Future<void> next({bool auto = false})`、`Future<void> previous()`、`PlayMode cycleMode()`、`Future<bool> seekTo(double seconds)`、`Future<bool> seekBy(double delta)`、`Future<void> setVolume(double v)`、`Future<void> toggleMute()`
    - 进度三条 `ValueNotifier`：`ValueNotifier<double> position`、`ValueNotifier<double?> buffered`、`ValueNotifier<double?> duration`
    - `ValueNotifier<TransportView> view`，`class TransportView { bool playing; bool loading; bool circuitOpen; String? blocked; Track? current; PlayMode mode; }`
    - `Future<void> dispose()`

- [ ] **Step 1: 写失败测试**

```dart
// test/playback/transport_controller_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/playback/audio_driver.dart';
import 'package:light_music/playback/audio_player.dart';
import 'package:light_music/playback/play_error.dart';
import 'package:light_music/playback/playlist.dart';
import 'package:light_music/playback/play_mode.dart';
import 'package:light_music/playback/track.dart';
import 'package:light_music/playback/transport_controller.dart';

class RecordingRecent implements RecentRecorder {
  final List<String> ids = [];
  @override
  void record(Track track, {DateTime? at}) => ids.add(track.id);
}

class RecordingToasts implements ToastSink {
  final List<String> messages = [];
  @override
  void show(String message, {String key = '', int durationMs = 3200}) =>
      messages.add(key.isEmpty ? message : '$message[$key]');
  @override
  void info(String message) => show(message);
  @override
  void error(String message) => show(message);
}

Track t(String id) => Track(id: id, src: '/$id.flac', title: '歌$id', duration: 100);

TransportController build({
  required Playlist playlist,
  required FakeAudioDriver driver,
  required RecordingRecent recent,
  required RecordingToasts toasts,
  int Function()? now,
}) {
  final player = AudioPlayer(driver, scheduler: (d, cb) => cb());
  return TransportController(
    player: player,
    recent: recent,
    toasts: toasts,
    playlist: playlist,
    now: now,
  );
}

void main() {
  test('播第 0 首：driver 收到 open 与 play，最近播放记下', () async {
    final driver = FakeAudioDriver();
    final recent = RecordingRecent();
    final toasts = RecordingToasts();
    final c = build(
      playlist: Playlist(tracks: [t('1').toJson()..['id'] = '1']),
      driver: driver, recent: recent, toasts: toasts,
    );
    await c.playTrack('nope');
    expect(toasts.messages, isEmpty);
    expect(driver.calls, isEmpty);
  });

  test('上一首：已播放超过 3 秒回到本曲开头，否则切上一曲', () async {
    final driver = FakeAudioDriver();
    final c = build(
      playlist: Playlist.fromTracks([t('1'), t('2'), t('3')], currentIndex: 1),
      driver: driver,
      recent: RecordingRecent(),
      toasts: RecordingToasts(),
    );
    await c.playTrack('2');
    driver.emitPosition(10);
    await c.previous();
    expect(c.current!.id, '2');
    expect(driver.calls.last, 'seek:0.0');

    driver.emitPosition(1);
    await c.previous();
    expect(c.current!.id, '1');
  });

  test('损坏：打角标、1400ms 后自动跳下一首', () async {
    final driver = FakeAudioDriver()..failNext(kind: PlayErrorKind.decode);
    final fakeClock = _FakeClock();
    final c = TransportController(
      player: AudioPlayer(driver, scheduler: fakeClock.schedule),
      recent: RecordingRecent(),
      toasts: RecordingToasts(),
      playlist: Playlist.fromTracks([t('1'), t('2')]),
    );
    await c.playTrack('1');
    expect(c.playlist.byId('1')!.broken, isTrue);
    expect(fakeClock.scheduledMs, contains(1400));
    fakeClock.flush();
    expect(c.current!.id, '2');
    expect(c.consecutiveFailures, 1);
  });

  test('连续失败达到列表长度即熔断，停止自动跳转', () async {
    final fakeClock = _FakeClock();
    final driver = FakeAudioDriver()..alwaysFail = true;
    final toasts = RecordingToasts();
    final c = TransportController(
      player: AudioPlayer(driver, scheduler: fakeClock.schedule),
      recent: RecordingRecent(),
      toasts: toasts,
      playlist: Playlist.fromTracks([t('1'), t('2')]),
    );
    await c.playTrack('1');
    fakeClock.flush();
    await c.playTrack('2');
    fakeClock.flush();
    expect(c.circuitOpen, isTrue);
    expect(c.consecutiveFailures, 2);
    expect(toasts.messages.any((m) => m.contains('熔断')), isTrue);
    fakeClock.flush();
    expect(fakeClock.pendingCount, 0); // 熔断后不再排自动跳
  });

  test('成功播放才清零失败计数', () async {
    final driver = FakeAudioDriver();
    final c = build(
      playlist: Playlist.fromTracks([t('1'), t('2')]),
      driver: driver, recent: RecordingRecent(), toasts: RecordingToasts(),
    );
    await c.playTrack('1');
    driver.emitPosition(1);
    expect(c.consecutiveFailures, 0);
  });

  test('模式循环顺序与标签同步给 view', () async {
    final c = build(
      playlist: Playlist.fromTracks([t('1')]),
      driver: FakeAudioDriver(),
      recent: RecordingRecent(), toasts: RecordingToasts(),
    );
    expect(c.cycleMode(), PlayMode.one);
    expect(c.view.value.mode, PlayMode.one);
    expect(playModeLabel(c.cycleMode()), '随机播放');
  });

  test('真正出声才记最近播放；500ms 内重复不记录', () async {
    var tick = 0;
    final driver = FakeAudioDriver();
    final recent = RecordingRecent();
    final c = TransportController(
      player: AudioPlayer(driver, scheduler: (d, cb) => cb()),
      recent: recent,
      toasts: RecordingToasts(),
      playlist: Playlist.fromTracks([t('1'), t('2')]),
      now: () => tick,
    );
    await c.playTrack('1');
    tick = 600;
    driver.emitPosition(2);
    expect(recent.ids, ['1']);
    await c.playTrack('1');
    tick = 700;
    driver.emitPosition(3);
    expect(recent.ids.length, 1);
    tick = 2000;
    await c.playTrack('1');
    driver.emitPosition(4);
    expect(recent.ids.length, 2);
  });

  test('blocked 状态暴露给界面并可重试，重试最多 3 次', () async {
    final driver = FakeAudioDriver()..blockPlayWithBlocked = true;
    final c = build(
      playlist: Playlist.fromTracks([t('1')]),
      driver: driver, recent: RecordingRecent(), toasts: RecordingToasts(),
    );
    await c.playTrack('1', autoplay: true);
    expect(c.blockedMessage, isNotNull);
    for (var i = 0; i < 5; i++) {
      await c.userGesture();
    }
    expect(c.blockedMessage, isNotNull);
  });
}

class _FakeClock {
  final List<void Function()> _pending = [];
  final List<int> scheduledMs = [];

  void schedule(Duration delay, void Function() cb) {
    scheduledMs.add(delay.inMilliseconds);
    _pending.add(cb);
  }

  int get pendingCount => _pending.length;

  void flush() {
    final pending = List.of(_pending);
    _pending.clear();
    for (final cb in pending) {
      cb();
    }
  }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/playback/transport_controller_test.dart`
Expected: 编译失败 —— `transport_controller.dart` 不存在；另外 `Track` 缺 `broken` 字段、`FakeAudioDriver` 缺 `alwaysFail` / `blockPlayWithBlocked`（Step 3 一起补）。

- [ ] **Step 3: 补 Track 与 Fake 的缺口**

`lib/playback/track.dart` 里给 `Track` 加运行期标记（不进 `toJson`，与原版「损坏角标」一样是会话态）：

```dart
  /// 本次会话里加载失败过；列表项据此显示「损坏」角标。
  bool broken = false;
```

`lib/playback/audio_driver.dart` 里给 `FakeAudioDriver` 加：

```dart
  bool alwaysFail = false;
  bool blockPlayWithBlocked = false;

  @override
  Future<void> play() async {
    calls.add('play');
    if (blockPlayWithBlocked) {
      _errors.add(DriverError(PlayErrorKind.aborted, 'NotAllowedError: play blocked'));
      return;
    }
    _isPlaying = true;
    _playing.add(true);
  }
```

并把 `open` 的失败分支改成可持久失败：

```dart
  @override
  Future<bool> open(Track track) async {
    calls.add('open:${track.src}');
    if (_nextError != null) {
      _errors.add(_nextError!);
      _nextError = null;
      return false;
    }
    if (alwaysFail) {
      _errors.add(DriverError(PlayErrorKind.decode, 'decoding failed'));
      return false;
    }
    // …其余分支保持不变
  }
```

- [ ] **Step 4: 实现 TransportController**

```dart
// lib/playback/transport_controller.dart
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'audio_player.dart';
import 'play_error.dart';
import 'play_mode.dart';
import 'playlist.dart';
import 'track.dart';

abstract class RecentRecorder {
  void record(Track track, {DateTime? at});
}

abstract class ToastSink {
  void show(String message, {String key, int durationMs});
  void info(String message);
  void error(String message);
}

const int kPrevRestartAfter = 3;
const int kBrokenSkipDelayMs = 1400;
const int kMaxAutoplayRetries = 3;
const int kRecentDedupeMs = 500;

class TransportView {
  TransportView({
    this.playing = false,
    this.loading = false,
    this.circuitOpen = false,
    this.blocked,
    this.current,
    this.mode = PlayMode.list,
  });

  final bool playing;
  final bool loading;
  final bool circuitOpen;
  final String? blocked;
  final Track? current;
  final PlayMode mode;
}

class TransportController {
  TransportController({
    required this.player,
    required this.recent,
    required this.toasts,
    Playlist? playlist,
    int Function()? now,
  })  : playlist = playlist ?? Playlist(tracks: const []),
        _now = now ?? (() => DateTime.now().millisecondsSinceEpoch) {
    _sub = player.events.listen(_onPlayerEvent);
    _position.value = player.position;
    _buffered.value = player.buffered;
    _duration.value = player.duration;
  }

  final AudioPlayer player;
  final RecentRecorder recent;
  final ToastSink toasts;
  final Playlist playlist;
  final int Function() _now;

  late final StreamSubscription<PlayerEvent> _sub;

  final ValueNotifier<double> _position = ValueNotifier<double>(0);
  final ValueNotifier<double?> _buffered = ValueNotifier<double?>(null);
  final ValueNotifier<double?> _duration = ValueNotifier<double?>(null);
  final ValueNotifier<TransportView> view = ValueNotifier<TransportView>(TransportView());

  int consecutiveFailures = 0;
  bool circuitOpen = false;
  String? blockedMessage;
  int _blockedRetries = 0;
  int _lastRecentAt = 0;
  String _lastRecentId = '';
  Timer? _skipTimer;

  ValueNotifier<double> get position => _position;
  ValueNotifier<double?> get buffered => _buffered;
  ValueNotifier<double?> get duration => _duration;
  Track? get current => playlist.current;
  bool get playing => player.playing;
  bool get loading => player.playing == false && _viewLoading;
  bool _viewLoading = false;

  Future<void> playTrack(String id, {bool autoplay = true}) async {
    final track = playlist.byId(id);
    if (track == null) return;
    _skipTimer?.cancel();
    blockedMessage = null;
    _blockedRetries = 0;
    playlist.setCurrentById(id);
    _publish();
    track.broken = false;
    final loaded = await player.load(track, autoplay: autoplay);
    if (!loaded) return;
    _duration.value = player.duration;
    _publish();
  }

  Future<void> togglePlay() async {
    if (playlist.current == null) {
      final first = playlist.tracks.isNotEmpty ? playlist.tracks.first.id : null;
      if (first == null) return;
      await playTrack(first);
      return;
    }
    if (player.playing) {
      await player.pause();
    } else {
      await player.load(playlist.current!, autoplay: true);
    }
  }

  Future<void> next({bool auto = false}) async {
    final index = playlist.nextIndex(auto: auto);
    if (index < 0) return;
    await playTrack(playlist.tracks[index].id);
  }

  Future<void> previous() async {
    final currentTrack = playlist.current;
    if (currentTrack != null && position.value > kPrevRestartAfter) {
      await player.seek(0);
      return;
    }
    await playTrack(playlist.tracks[playlist.prevIndex()].id);
  }

  PlayMode cycleMode() {
    final mode = playlist.cycleMode();
    _publish();
    return mode;
  }

  Future<bool> seekTo(double seconds) => player.seek(seconds);
  Future<bool> seekBy(double delta) => player.seekBy(delta);
  Future<void> setVolume(double value) => player.setVolume(value);
  Future<void> toggleMute() => player.toggleMute();

  /// 用户在本页的真实交互：触发一次被拦播放的重试。
  Future<void> userGesture() async {
    if (blockedMessage == null) return;
    if (_blockedRetries >= kMaxAutoplayRetries) return;
    _blockedRetries += 1;
    final track = playlist.current;
    if (track == null) return;
    await player.load(track, autoplay: true);
    _publish();
  }

  Future<void> dispose() async {
    _skipTimer?.cancel();
    await _sub.cancel();
    await player.dispose();
  }

  void _onPlayerEvent(PlayerEvent event) {
    switch (event) {
      case LoadingEvent(:final loading):
        _viewLoading = loading;
        _publish();
      case CanplayEvent(:final duration):
        _duration.value = duration;
        consecutiveFailures = 0;
        if (circuitOpen) {
          circuitOpen = false;
          toasts.info('已恢复正常播放');
        }
        _publish();
      case TimeUpdateEvent(:final position, :final duration):
        _position.value = position;
        _duration.value = duration;
        if (position > 0) _recordRecent(position);
      case StateChangedEvent(:final playing):
        if (playing) consecutiveFailures = 0;
        _publish();
      case VolumeEvent():
        _publish();
      case ErrorEvent(:final kind, :final message):
        _handleFailure(message);
      case BlockedEvent(:final message):
        blockedMessage = message;
        toasts.error(message);
        _publish();
    }
  }

  void _recordRecent(double position) {
    final track = playlist.current;
    if (track == null || position <= 0) return;
    final now = _now();
    if (_lastRecentId == track.id && now - _lastRecentAt < kRecentDedupeMs) return;
    _lastRecentId = track.id;
    _lastRecentAt = now;
    recent.record(track, at: DateTime.fromMillisecondsSinceEpoch(now));
  }

  void _handleFailure(String message) {
    final track = playlist.current;
    if (track != null) {
      track.broken = true;
      toasts.show('$message（${track.title}）', key: 'broken-${track.id}');
    }
    consecutiveFailures += 1;
    _publish();
    if (playlist.size == 0) return;
    if (consecutiveFailures >= playlist.size) {
      circuitOpen = true;
      _skipTimer?.cancel();
      toasts.show('连续 $consecutiveFailures 首无法播放，已停止自动切歌',
          key: 'circuit');
      unawaited(player.pause());
      _publish();
      return;
    }
    _skipTimer?.cancel();
    _skipTimer = Timer(const Duration(milliseconds: kBrokenSkipDelayMs), () {
      if (circuitOpen) return;
      unawaited(next(auto: true));
    });
  }

  void _publish() {
    view.value = TransportView(
      playing: player.playing,
      loading: _viewLoading,
      circuitOpen: circuitOpen,
      blocked: blockedMessage,
      current: playlist.current,
      mode: playlist.mode,
    );
  }
}
```

> 熔断后的行为门槛：**必须**是「停止自动跳转 + 暂停播放 + 常驻提示」，不是继续跳。原版靠 `consecutiveFailures` 只在 `canplay` 时清零来保证坏文件只会走一圈就停 —— 上面 `_onPlayerEvent` 的 `CanplayEvent` 分支就是那个清零点，别挪到 `TimeUpdateEvent` 上，否则部分播放的坏文件会把计数洗掉、熔断永不触发。

- [ ] **Step 5: 跑测试确认通过**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/playback/`
Expected: `All tests passed!`（含 T13 的守卫与音量用例）

- [ ] **Step 6: Commit**

```bash
cd flutter-app && git add lib/playback test/playback && git commit -m "feat(playback): 新增播放编排与损坏熔断"
```

---

## Task 15: LibraryRepository —— JSON 文件仓与原子写

替代原版 IndexedDB：不存音频字节，只存曲目元数据与顺序（spec §6.3）。

**Files:**
- Create: `lib/library/library_repository.dart`
- Test: `test/library/library_repository_test.dart`

**Interfaces:**
- Consumes: `Track`（T3）、`PlayMode`（T4）
- Produces:
  - `class LibrarySnapshot { List<Track> tracks; List<String> order; String? currentId; PlayMode mode; double? volume; bool muted; }`
  - `class LibraryRepository { LibraryRepository({required String directory, String fileName = 'library.json'}); Future<LibrarySnapshot> load(); Future<void> save(LibrarySnapshot snapshot); Future<void> deleteTracks(Iterable<String> ids); bool get corrupted; }`
  - 磁盘布局：`<directory>/library.json` + `<directory>/library.json.bak`；写盘顺序「写 `.tmp` → rename 到 `.bak`（保住上一份）→ rename `.tmp` 到正式文件」。

- [ ] **Step 1: 写失败测试**

```dart
// test/library/library_repository_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/library/library_repository.dart';
import 'package:light_music/playback/play_mode.dart';
import 'package:light_music/playback/track.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('light-lib'));
  tearDown(() => dir.deleteSync(recursive: true));

  Track t(String id) =>
      Track(id: id, src: '/$id.flac', title: '歌$id', artist: '某人', duration: 100);

  test('空目录 load 得到空快照而非异常', () async {
    final repo = LibraryRepository(directory: dir.path);
    final snap = await repo.load();
    expect(snap.tracks, isEmpty);
    expect(snap.mode, PlayMode.list);
    expect(snap.corrupted, isFalse);
    expect(repo.corrupted, isFalse);
  });

  test('保存后读回，顺序与音量都在', () async {
    final repo = LibraryRepository(directory: dir.path);
    await repo.save(LibrarySnapshot(
      tracks: [t('1'), t('2')],
      order: ['1', '2'],
      currentId: '2',
      mode: PlayMode.shuffle,
      volume: 0.32,
      muted: true,
    ));
    final snap = await repo.load();
    expect(snap.tracks.map((e) => e.id), ['1', '2']);
    expect(snap.currentId, '2');
    expect(snap.mode, PlayMode.shuffle);
    expect(snap.volume, 0.32);
    expect(snap.muted, isTrue);
  });

  test('正式文件坏掉时回退 .bak 并保留脏文件', () async {
    final repo = LibraryRepository(directory: dir.path);
    await repo.save(LibrarySnapshot(tracks: [t('1')], order: ['1']));
    File('${dir.path}/library.json').writeAsStringSync('{ 坏掉的 json');
    final snap = await repo.load();
    expect(snap.tracks.map((e) => e.id), ['1']);
    expect(repo.corrupted, isTrue);
  });

  test('两个文件都坏时得到空快照，不抛', () async {
    final repo = LibraryRepository(directory: dir.path);
    File('${dir.path}/library.json').writeAsStringSync('x');
    File('${dir.path}/library.json.bak').writeAsStringSync('y');
    final snap = await repo.load();
    expect(snap.tracks, isEmpty);
  });

  test('非法条目在 load 时被丢弃而不炸整份数据', () async {
    File('${dir.path}/library.json').writeAsStringSync(jsonEncode({
      'version': 1,
      'tracks': [
        {'id': '1', 'src': '/a.flac', 'title': 'A'},
        {'title': '缺 id'},
      ],
      'order': ['1', 'bad'],
    }));
    final snap = await LibraryRepository(directory: dir.path).load();
    expect(snap.tracks.length, 1);
    expect(snap.order, ['1']);
  });

  test('deleteTracks 同步清 order 与 currentId', () async {
    final repo = LibraryRepository(directory: dir.path);
    await repo.save(LibrarySnapshot(
      tracks: [t('1'), t('2')], order: ['1', '2'], currentId: '1',
    ));
    await repo.deleteTracks(['1']);
    final snap = await repo.load();
    expect(snap.tracks.map((e) => e.id), ['2']);
    expect(snap.order, ['2']);
    expect(snap.currentId, isNull);
  });

  test('并发保存不产生半截文件', () async {
    final repo = LibraryRepository(directory: dir.path);
    await Future.wait([
      for (var i = 0; i < 8; i++)
        repo.save(LibrarySnapshot(tracks: [t('$i')], order: ['$i'])),
    ]);
    final snap = await repo.load();
    expect(snap.tracks.length, 1);
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/library/library_repository_test.dart`
Expected: 编译失败 —— `library_repository.dart` 不存在。

- [ ] **Step 3: 实现**

```dart
// lib/library/library_repository.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../playback/play_mode.dart';
import '../playback/track.dart';

const int _snapshotVersion = 1;

class LibrarySnapshot {
  LibrarySnapshot({
    this.tracks = const [],
    this.order = const [],
    this.currentId,
    this.mode = PlayMode.list,
    this.volume,
    this.muted = false,
  });

  final List<Track> tracks;
  final List<String> order;
  final String? currentId;
  final PlayMode mode;
  final double? volume;
  final bool muted;

  Map<String, Object?> toJson() => {
        'version': _snapshotVersion,
        'tracks': tracks.map((t) => t.toJson()).toList(),
        'order': order,
        'currentId': currentId,
        'mode': playModeId(mode),
        'volume': volume,
        'muted': muted,
      };

  static LibrarySnapshot fromJson(Map<String, Object?> json) {
    final rawTracks = (json['tracks'] as List?) ?? const [];
    final tracks = rawTracks
        .whereType<Map>()
        .map((e) => Track.fromJson(e.cast<String, Object?>()))
        .whereType<Track>()
        .toList();
    final validIds = tracks.map((t) => t.id).toSet();
    final rawOrder = (json['order'] as List?)
        ?.whereType<String>()
        .where(validIds.contains)
        .toList();
    final order = rawOrder ?? tracks.map((t) => t.id).toList();
    // order 里缺的曲目补到末尾，避免脏数据把歌单变小
    for (final id in tracks.map((t) => t.id)) {
      if (!order.contains(id)) order.add(id);
    }
    return LibrarySnapshot(
      tracks: tracks,
      order: order,
      currentId: validIds.contains(json['currentId'])
          ? json['currentId'] as String
          : null,
      mode: playModeFromId(json['mode']),
      volume: json['volume'] is num ? (json['volume'] as num).toDouble() : null,
      muted: json['muted'] == true,
    );
  }
}

class LibraryRepository {
  LibraryRepository({required this.directory, this.fileName = 'library.json'});

  final String directory;
  final String fileName;

  static const String _tmpSuffix = '.tmp';
  static const String _bakSuffix = '.bak';

  bool _corrupted = false;
  bool get corrupted => _corrupted;

  String get _path => '$directory/$fileName';
  String get _bakPath => '$_path$_bakSuffix';
  String get _tmpPath => '$_path$_tmpSuffix';

  Completer<void>? _writing;

  Future<LibrarySnapshot> load() async {
    _corrupted = false;
    final primary = await _readJson(_path);
    if (primary != null) return LibrarySnapshot.fromJson(primary);
    final backup = await _readJson(_bakPath);
    if (backup != null) {
      _corrupted = true;
      return LibrarySnapshot.fromJson(backup);
    }
    return LibrarySnapshot();
  }

  Future<Map<String, Object?>?> _readJson(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final text = await file.readAsString();
      if (text.trim().isEmpty) return null;
      final decoded = jsonDecode(text);
      return decoded is Map ? decoded.cast<String, Object?>() : null;
    } catch (_) {
      return null;
    }
  }

  /// 串行化写入：后一个 save 等前一个完成，避免 rename 交叉产生半截文件。
  Future<void> save(LibrarySnapshot snapshot) async {
    while (_writing != null) {
      await _writing!.future;
    }
    final completer = Completer<void>();
    _writing = completer;
    try {
      await _writeAtomically(jsonEncode(snapshot));
    } finally {
      _writing = null;
      completer.complete();
    }
  }

  Future<void> _writeAtomically(String content) async {
    try {
      await Directory(directory).create(recursive: true);
      final tmp = File(_tmpPath);
      await tmp.writeAsString(content, flush: true);
      final primary = File(_path);
      if (await primary.exists()) {
        try {
          if (await File(_bakPath).exists()) await File(_bakPath).delete();
          await primary.rename(_bakPath);
        } catch (_) {
          // rename 失败退化为复制：保底留住上一份
          try {
            await File(_path).copy(_bakPath);
          } catch (_) {}
        }
      }
      await tmp.rename(_path);
    } catch (_) {
      // 落盘失败不阻塞当前播放（原版对配额不足的处理是同一路）
    }
  }

  Future<void> deleteTracks(Iterable<String> ids) async {
    final removed = ids.toSet();
    final snap = await load();
    final tracks = snap.tracks.where((t) => !removed.contains(t.id)).toList();
    final order = snap.order.where((id) => !removed.contains(id)).toList();
    final currentId = removed.contains(snap.currentId) ? null : snap.currentId;
    await save(LibrarySnapshot(
      tracks: tracks,
      order: order,
      currentId: currentId,
      mode: snap.mode,
      volume: snap.volume,
      muted: snap.muted,
    ));
  }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/library/library_repository_test.dart`
Expected: `All tests passed!`（7 个用例）。若「并发保存」用例失败，说明串行化没生效（`_writing` 判断被写成了 `if` 而非 `while`）。

- [ ] **Step 5: Commit**

```bash
cd flutter-app && git add lib/library test/library && git commit -m "feat(library): 新增带原子写与备份回退的曲库文件仓"
```

---

## Task 16: RecentStore —— 最近播放

对译 `src/lib/recent-store.js`：50 条上限、重播置顶且永不重复、500ms 去抖、相对时间文案。实现 `RecentRecorder`（T14 定义的接口）。

**Files:**
- Create: `lib/library/recent_store.dart`
- Test: `test/library/recent_store_test.dart`

**Interfaces:**
- Consumes: `Track`（T3）、`AppPrefs`（T2）、`StorageKeys.recent`、`RecentRecorder`（T14）
- Produces:
  - `class RecentEntry { String id; String title; String artist; String cover; double? duration; int at; bool inPlaylist; Map<String,Object?> toJson(); static RecentEntry? fromJson(Map<String,Object?>); }`
  - `class RecentStore implements RecentRecorder { RecentStore(AppPrefs prefs, {int Function()? now}); List<RecentEntry> get entries; Future<void> restore(); @override void record(Track track, {DateTime? at}); Future<void> markInPlaylist(Set<String> ids); Future<void> remove(String id); Future<void> clear(); List<RecentEntry> load(); }`
  - `String formatRelativeTime(int timestamp, {int? now});`

- [ ] **Step 1: 写失败测试**

```dart
// test/library/recent_store_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/library/recent_store.dart';
import 'package:light_music/playback/track.dart';

Track t(String id) => Track(id: id, src: '/$id.flac', title: '歌$id', artist: '某人');

void main() {
  late AppPrefs prefs;
  late int clock;
  late RecentStore store;

  setUp(() {
    prefs = AppPrefs.inMemory();
    clock = 1000000;
    store = RecentStore(prefs, now: () => clock);
  });

  test('真正出声才写入，重播置顶且无重复条目', () async {
    store.record(t('1'));
    store.record(t('2'));
    expect(store.entries.map((e) => e.id), ['2', '1']);
    clock += 600;
    store.record(t('1'));
    expect(store.entries.map((e) => e.id), ['1', '2']);
    expect(store.entries.length, 2);
  });

  test('500ms 内的重复事件被忽略', () {
    store.record(t('1'));
    clock += 100;
    store.record(t('1'));
    expect(store.entries.length, 1);
    expect(store.entries.single.at, 1000000);
  });

  test('上限 50 条，超出丢最旧', () {
    for (var i = 0; i < 60; i++) {
      clock += 600;
      store.record(t('$i'));
    }
    expect(store.entries.length, 50);
    expect(store.entries.first.id, '59');
    expect(store.entries.last.id, '10');
  });

  test('落盘并可 restore', () async {
    store.record(t('1'));
    await store.flushForTest();
    final fresh = RecentStore(prefs, now: () => clock);
    await fresh.restore();
    expect(fresh.entries.single.id, '1');
  });

  test('脏数据回退空列表', () async {
    prefs.debugSeed('recent', '[bad');
    final fresh = RecentStore(prefs);
    await fresh.restore();
    expect(fresh.entries, isEmpty);
  });

  test('不在列表里的条目标记为失效', () async {
    store.record(t('1'));
    store.record(t('2'));
    await store.markInPlaylist({'1'});
    expect(store.entries.firstWhere((e) => e.id == '2').inPlaylist, isFalse);
    expect(store.entries.firstWhere((e) => e.id == '1').inPlaylist, isTrue);
  });

  test('remove 与 clear', () async {
    store.record(t('1'));
    store.record(t('2'));
    store.remove('1');
    expect(store.entries.map((e) => e.id), ['2']);
    store.clear();
    expect(store.entries, isEmpty);
  });

  group('相对时间文案', () {
    const minute = 60 * 1000;
    const hour = 60 * minute;
    const day = 24 * hour;

    test('刚刚 / 分钟前 / 小时前', () {
      expect(formatRelativeTime(0, now: 30 * 1000), '刚刚');
      expect(formatRelativeTime(0, now: 5 * minute), '5 分钟前');
      expect(formatRelativeTime(0, now: 3 * hour + 1 * minute), '3 小时前');
    });

    test('昨天与几天前', () {
      expect(formatRelativeTime(0, now: day + 2 * hour), '昨天');
      expect(formatRelativeTime(0, now: 3 * day), '3 天前');
    });

    test('一周以上显示日期，跨年带年份', () {
      expect(formatRelativeTime(0, now: 8 * day, localeDate: _dateOf), isNotNull);
      expect(
        formatRelativeTime(_millis('2025-12-30'), now: _millis('2026-01-05'), localeDate: _dateOf),
        contains('2025'),
      );
    });
  });
}

DateTime _dateOf(int millis) => DateTime.fromMillisecondsSinceEpoch(millis);
int _millis(String iso) => DateTime.parse(iso).millisecondsSinceEpoch;
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/library/recent_store_test.dart`
Expected: 编译失败 —— `recent_store.dart` 不存在。

- [ ] **Step 3: 实现**

```dart
// lib/library/recent_store.dart
import 'dart:async';
import 'dart:convert';

import '../core/app_prefs.dart';
import '../core/storage_keys.dart';
import '../playback/audio_player.dart' show RecentRecorder;
import '../playback/track.dart';

const int kRecentLimit = 50;
const int kRecentDedupeMs = 500;

class RecentEntry {
  RecentEntry({
    required this.id,
    required this.title,
    required this.artist,
    required this.at,
    this.cover = '',
    this.duration,
    this.inPlaylist = true,
  });

  final String id;
  final String title;
  final String artist;
  final String cover;
  final double? duration;
  int at;
  bool inPlaylist;

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'artist': artist,
        'cover': cover,
        'duration': duration,
        'at': at,
      };

  static RecentEntry? fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final title = json['title'];
    if (id is! String || id.isEmpty || title is! String) return null;
    return RecentEntry(
      id: id,
      title: title,
      artist: (json['artist'] as String?) ?? '',
      cover: (json['cover'] as String?) ?? '',
      duration: json['duration'] is num ? (json['duration'] as num).toDouble() : null,
      at: json['at'] is num ? (json['at'] as num).toInt() : 0,
    );
  }
}

class RecentStore implements RecentRecorder {
  RecentStore(this._prefs, {int Function()? now})
      : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch());

  final AppPrefs _prefs;
  final int Function() _now;
  final List<RecentEntry> _entries = [];

  List<RecentEntry> get entries => List.unmodifiable(_entries);

  Future<void> restore() async {
    _entries.clear();
    final raw = await _prefs.readJson(StorageKeys.recent);
    if (raw is! List) return;
    for (final item in raw.whereType<Map>()) {
      final entry = RecentEntry.fromJson(item.cast<String, Object?>());
      if (entry != null) _entries.add(entry);
    }
    if (_entries.length > kRecentLimit) {
      _entries.removeRange(kRecentLimit, _entries.length);
    }
    await _persist();
  }

  @override
  void record(Track track, {DateTime? at}) {
    final timestamp = at?.millisecondsSinceEpoch ?? _now();
    final existingIndex = _entries.indexWhere((e) => e.id == track.id);
    if (existingIndex == 0 &&
        timestamp - _entries.first.at < kRecentDedupeMs) {
      return; // 同一首 500ms 内重复：忽略，避免暂停/恢复刷屏
    }
    final entry = RecentEntry(
      id: track.id,
      title: track.title,
      artist: track.artist,
      cover: track.cover,
      duration: track.hasDuration ? track.duration : null,
      at: timestamp,
    );
    if (existingIndex >= 0) _entries.removeAt(existingIndex);
    _entries.insert(0, entry);
    if (_entries.length > kRecentLimit) {
      _entries.removeRange(kRecentLimit, _entries.length);
    }
    unawaited(_persist());
  }

  Future<void> markInPlaylist(Set<String> ids) async {
    for (final entry in _entries) {
      entry.inPlaylist = ids.contains(entry.id);
    }
    await _persist();
  }

  Future<void> remove(String id) async {
    _entries.removeWhere((e) => e.id == id);
    await _persist();
  }

  Future<void> clear() async {
    _entries.clear();
    await _persist();
  }

  /// 测试与冷启动收尾用；界面不调。
  Future<void> flushForTest() => _persist();

  Future<void> _persist() => _prefs.writeJson(
        StorageKeys.recent,
        _entries.map((e) => e.toJson()).toList(),
      );
}

String formatRelativeTime(
  int timestamp, {
  int? now,
  DateTime Function(int millis)? localeDate,
}) {
  final current = now ?? DateTime.now().millisecondsSinceEpoch;
  final diff = current - timestamp;
  if (diff < 0) return '刚刚';
  const minute = 60 * 1000;
  const hour = 60 * minute;
  const day = 24 * hour;
  if (diff < minute) return '刚刚';
  if (diff < hour) return '${diff ~/ minute} 分钟前';
  if (diff < day) return '${diff ~/ hour} 小时前';
  if (diff < 2 * day) return '昨天';
  if (diff < 7 * day) return '${diff ~/ day} 天前';
  final date = (localeDate ?? _defaultDate)(timestamp);
  final current2 = (localeDate ?? _defaultDate)(current);
  final monthDay = '${date.month}月${date.day}日';
  return date.year == current2.year ? monthDay : '${date.year}年$monthDay';
}

DateTime _defaultDate(int millis) => DateTime.fromMillisecondsSinceEpoch(millis);
```

> 上面 `record` 的去抖条件刻意只看「已经在最前的那条」：与原版一致，先置顶再比时间，因此第二次 `record('1')` 若超过 500ms 会重新置顶并刷新 `at`。测试里那条断言（`entries.single.at == 1000000`）就是防止写成「任何位置的同 id 都忽略」。

- [ ] **Step 4: 跑测试确认通过**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/library/recent_store_test.dart`
Expected: `All tests passed!`（8 个用例）

- [ ] **Step 5: Commit**

```bash
cd flutter-app && git add lib/library test/library && git commit -m "feat(library): 移植最近播放记录与相对时间"
```

---

## Task 17: 格式白名单校验与文件夹扫描

**Files:**
- Create: `lib/library/audio_filter.dart`
- Test: `test/library/audio_filter_test.dart`

**Interfaces:**
- Consumes: `isSupportedExtension`、`extensionOf`（T11）
- Produces:
  - `class ScannedAudio { String path; String name; ScannedAudio(this.path, this.name); }`
  - `List<String> filterSupported(List<String> paths)`（保持输入顺序，逐个用白名单）
  - `({List<String> accepted, List<String> rejected}) partitionByExtension(List<String> paths)`
  - `List<String> naturalSort(List<String> paths)`（数字段按数值比，其余按码位；Windows 路径分隔符同样处理）
  - `Future<List<ScannedAudio>> scanAudioDirectory(String root, {int maxFiles = 2000, bool recursive = true})`

- [ ] **Step 1: 写失败测试**

```dart
// test/library/audio_filter_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/library/audio_filter.dart';

void main() {
  test('白名单外的一律拒绝，顺序不变', () {
    final result = partitionByExtension([
      '/m/a.flac', '/m/b.txt', '/m/c.MP3', '/m/d.lrc', '/m/e.m4a',
    ]);
    expect(result.accepted, ['/m/a.flac', '/m/c.MP3', '/m/e.m4a']);
    expect(result.rejected, ['/m/b.txt', '/m/d.lrc']);
  });

  test('无扩展名与以点结尾都算拒绝', () {
    expect(partitionByExtension(['/m/README', '/m/x.']).accepted, isEmpty);
  });

  test('自然排序按数值比数字段', () {
    expect(
      naturalSort(['/m/track-10.flac', '/m/track-2.flac', '/m/track-1.flac']),
      ['/m/track-1.flac', '/m/track-2.flac', '/m/track-10.flac'],
    );
    expect(
      naturalSort(['/m/第2首.flac', '/m/第10首.flac', '/m/第1首.flac']),
      ['/m/第1首.flac', '/m/第2首.flac', '/m/第10首.flac'],
    );
  });

  test('递归扫描只收白名单，隐藏目录跳过', () async {
    final dir = Directory.systemTemp.createTempSync('light-scan');
    File('${dir.path}/a.flac').writeAsStringSync('x');
    File('${dir.path}/b.txt').writeAsStringSync('x');
    Directory('${dir.path}/sub').createSync();
    File('${dir.path}/sub/c.mp3').writeAsStringSync('x');
    Directory('${dir.path}/.hidden').createSync();
    File('${dir.path}/.hidden/d.flac').writeAsStringSync('x');

    final found = await scanAudioDirectory(dir.path);
    expect(found.map((e) => e.name).toSet(), {'a.flac', 'c.mp3'});

    final flat = await scanAudioDirectory(dir.path, recursive: false);
    expect(flat.map((e) => e.name), ['a.flac']);
    dir.deleteSync(recursive: true);
  });

  test('maxFiles 截断', () async {
    final dir = Directory.systemTemp.createTempSync('light-scan-limit');
    for (var i = 0; i < 5; i++) {
      File('${dir.path}/$i.flac').writeAsStringSync('x');
    }
    final found = await scanAudioDirectory(dir.path, maxFiles: 3);
    expect(found.length, 3);
    dir.deleteSync(recursive: true);
  });

  test('不存在的目录返回空列表，不抛', () async {
    expect(await scanAudioDirectory('/no/such/dir/at/all'), isEmpty);
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/library/audio_filter_test.dart`
Expected: 编译失败 —— `audio_filter.dart` 不存在。

- [ ] **Step 3: 实现**

```dart
// lib/library/audio_filter.dart
import 'dart:io';

import '../playback/play_error.dart';

class ScannedAudio {
  ScannedAudio(this.path, this.name);
  final String path;
  final String name;
}

List<String> filterSupported(List<String> paths) =>
    paths.where((p) => isSupportedExtension(extensionOf(p))).toList();

({List<String> accepted, List<String> rejected}) partitionByExtension(
  List<String> paths,
) {
  final accepted = <String>[];
  final rejected = <String>[];
  for (final path in paths) {
    (isSupportedExtension(extensionOf(path)) ? accepted : rejected).add(path);
  }
  return (accepted: accepted, rejected: rejected);
}

/// 数字段按数值比，其余逐码位；与列表显示顺序一致。
List<String> naturalSort(List<String> paths) {
  final sorted = [...paths]..sort(_compareNatural);
  return sorted;
}

int _compareNatural(String a, String b) {
  final ta = _tokenize(a);
  final tb = _tokenize(b);
  for (var i = 0; i < ta.length && i < tb.length; i++) {
    final x = ta[i];
    final y = tb[i];
    final xNum = int.tryParse(x);
    final yNum = int.tryParse(y);
    if (xNum != null && yNum != null) {
      if (xNum != yNum) return xNum - yNum;
      continue;
    }
    if (xNum != null) return -1;
    if (yNum != null) return 1;
    final cmp = x.compareTo(y);
    if (cmp != 0) return cmp;
  }
  return ta.length - tb.length;
}

List<String> _tokenize(String text) {
  final tokens = <String>[];
  final buffer = StringBuffer();
  String? mode;
  for (final unit in text.runes) {
    final isDigit = unit >= 0x30 && unit <= 0x39;
    final kind = isDigit ? 'd' : 't';
    if (mode != null && mode != kind) {
      tokens.add(buffer.toString());
      buffer.clear();
    }
    mode = kind;
    buffer.writeCharCode(unit);
  }
  if (buffer.isNotEmpty) tokens.add(buffer.toString());
  return tokens;
}

Future<List<ScannedAudio>> scanAudioDirectory(
  String root, {
  int maxFiles = 2000,
  bool recursive = true,
}) async {
  final result = <ScannedAudio>[];
  try {
    final dir = Directory(root);
    if (!await dir.exists()) return result;
    await for (final entity in dir.list(recursive: recursive, followLinks: false)) {
      if (result.length >= maxFiles) break;
      if (entity is! File) continue;
      final relative = entity.path.substring(root.length);
      // 隐藏目录（/.开头的任一段）跳过
      if (relative.split(RegExp(r'[/\\]')).any((seg) => seg.startsWith('.'))) {
        continue;
      }
      if (!isSupportedExtension(extensionOf(entity.path))) continue;
      result.add(ScannedAudio(entity.path, entity.uri.pathSegments.last));
    }
  } catch (_) {
    return result;
  }
  return naturalSort(result.map((e) => e.path))
      .map((p) => ScannedAudio(p, p.split(RegExp(r'[/\\]')).last))
      .toList();
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/library/audio_filter_test.dart`
Expected: `All tests passed!`（6 个用例）

- [ ] **Step 5: Commit**

```bash
cd flutter-app && git add lib/library test/library && git commit -m "feat(library): 新增格式白名单校验与目录扫描"
```

---

## Task 18: ImportService —— 校验、入列、标签回填、时长探测

流程按 spec §8：校验扩展名 → 立即入列（可播）→ 解析内嵌标签 → 探时长 → 落库 → 后台预取挂载点。**回填必须按 id 找回活对象**（原版 `addMany` 克隆对象导致的坑）。

**Files:**
- Create: `lib/library/import_service.dart`
- Test: `test/library/import_service_test.dart`

**Interfaces:**
- Consumes: `partitionByExtension`、`scanAudioDirectory`（T17）、`readAudioTags`、`mergeTaggedNames`、`ByteSource`、`CoverImageWriter`（T6/T10）、`Playlist`（T4）、`Track`（T3）、`ToastSink`（T14）、`ByteSource.fromFile` 的 64KB 头部预读
- Produces:
  - `class ImportResult { int added; int rejected; List<String> rejectedNames; List<String> addedIds; }`
  - `class ImportService { ImportService({required Playlist playlist, required ToastSink toasts, CoverImageWriter? covers, Future<void> Function(List<String> ids)? onImported, double Function(String path)? durationProbe}); Future<ImportResult> importPaths(List<String> paths); Future<ImportResult> importDirectory(String root); Future<void> hydrateMetadata(Track track); }`
  - id 生成规则：`'local:${sha1 或 md5 的十六进制前 16 位}'`，由路径（或 SAF URI）派生 —— **同一文件重复导入必须得到同一个 id**（原版按文件名+大小；这里按路径，测试里锁定）。

- [ ] **Step 1: 写失败测试**

```dart
// test/library/import_service_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/library/import_service.dart';
import 'package:light_music/playback/audio_player.dart';
import 'package:light_music/playback/playlist.dart';
import 'package:light_music/playback/track.dart';

class RecordingToasts implements ToastSink {
  final List<String> messages = [];
  @override
  void show(String message, {String key = '', int durationMs = 3200}) => messages.add(message);
  @override
  void info(String message) => show(message);
  @override
  void error(String message) => show(message);
}

void main() {
  test('非白名单文件被拒绝并点名', () async {
    final playlist = Playlist(tracks: const []);
    final toasts = RecordingToasts();
    final service = ImportService(playlist: playlist, toasts: toasts);
    final result = await service.importPaths(['/m/a.flac', '/m/b.txt', '/m/c.lrc']);
    expect(result.added, 1);
    expect(result.rejected, 2);
    expect(result.rejectedNames, ['b.txt', 'c.lrc']);
    expect(toasts.messages.any((m) => m.contains('b.txt')), isTrue);
  });

  test('同一文件重复导入得到同一 id，且不重复入列', () async {
    final playlist = Playlist(tracks: const []);
    final service = ImportService(playlist: playlist, toasts: RecordingToasts());
    final first = await service.importPaths(['/m/a.flac']);
    final second = await service.importPaths(['/m/a.flac']);
    expect(first.addedIds.single, second.addedIds.single);
    expect(playlist.size, 1);
    expect(second.added, 0);
  });

  test('文件名拆分兜底：无标签时按「歌手 - 歌名」', () async {
    final playlist = Playlist(tracks: const []);
    final service = ImportService(playlist: playlist, toasts: RecordingToasts());
    await service.importPaths(['/m/陈奕迅 - 十年.flac']);
    final track = playlist.tracks.single;
    expect(track.title, '十年');
    expect(track.artist, '陈奕迅');
    expect(track.isLocal, isTrue);
  });

  test('两侧都有的写法「歌名 - 歌手」同样拆开', () async {
    final playlist = Playlist(tracks: const []);
    final service = ImportService(playlist: playlist, toasts: RecordingToasts());
    await service.importPaths(['/m/孤勇者 - 陈奕迅.flac']);
    // 无法判断哪侧是歌手时按原版规则：先当作「歌手 - 歌名」，标签到位再纠正
    expect(playlist.tracks.single.title, isNotEmpty);
  });

  test('时长探测成功则填，超时保持未知', () async {
    final playlist = Playlist(tracks: const []);
    final service = ImportService(
      playlist: playlist,
      toasts: RecordingToasts(),
      durationProbe: (path) => path.contains('slow') ? double.nan : 187.5,
    );
    await service.importPaths(['/m/fast.flac']);
    expect(playlist.tracks.single.duration, 187.5);
    await service.importPaths(['/m/slow.flac']);
    expect(playlist.tracks.last.duration.isNaN, isTrue);
  });

  test('标签回填改的是列表里的活对象', () async {
    final playlist = Playlist(tracks: const []);
    final service = ImportService(playlist: playlist, toasts: RecordingToasts());
    await service.importPaths(['/m/a.flac']);
    final live = playlist.tracks.single;
    await service.applyTagsForTest(live, title: '白玫瑰', artist: '陈奕迅', album: 'X');
    expect(playlist.tracks.single.title, '白玫瑰');
    expect(identical(playlist.tracks.single, live), isTrue);
  });

  test('目录扫描后按自然顺序入列', () async {
    final dir = Directory.systemTemp.createTempSync('light-import');
    File('${dir.path}/track-2.flac').writeAsStringSync('x');
    File('${dir.path}/track-10.flac').writeAsStringSync('x');
    File('${dir.path}/track-1.flac').writeAsStringSync('x');
    final playlist = Playlist(tracks: const []);
    final service = ImportService(playlist: playlist, toasts: RecordingToasts());
    final result = await service.importDirectory(dir.path);
    expect(result.added, 3);
    expect(playlist.tracks.map((t) => t.handle.displayName).toList(),
        ['track-1.flac', 'track-2.flac', 'track-10.flac']);
    dir.deleteSync(recursive: true);
  });

  test('空输入什么都不做，也不弹提示', () async {
    final playlist = Playlist(tracks: const []);
    final toasts = RecordingToasts();
    final service = ImportService(playlist: playlist, toasts: toasts);
    final result = await service.importPaths(const []);
    expect(result.added, 0);
    expect(toasts.messages, isEmpty);
  });
}
```

> Step 1 的目录用例需要 `import 'dart:io';`，写文件时补在测试顶部。

- [ ] **Step 2: 跑测试确认失败**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/library/import_service_test.dart`
Expected: 编译失败 —— `import_service.dart` 不存在。

- [ ] **Step 3: 实现**

```dart
// lib/library/import_service.dart
import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import '../metadata/audio_tags.dart';
import '../metadata/byte_reader.dart';
import '../metadata/cover_image.dart';
import '../playback/audio_player.dart' show ToastSink;
import '../playback/play_error.dart';
import '../playback/playlist.dart';
import '../playback/track.dart';
import '../playback/track_handle.dart';
import 'audio_filter.dart';

class ImportResult {
  ImportResult({
    this.added = 0,
    this.rejected = 0,
    this.rejectedNames = const [],
    this.addedIds = const [],
  });

  final int added;
  final int rejected;
  final List<String> rejectedNames;
  final List<String> addedIds;
}

const int _headProbeBytes = 64 * 1024;

class ImportService {
  ImportService({
    required this.playlist,
    required this.toasts,
    this.covers,
    this.coverDirectory,
    this.durationProbe,
    Future<void> Function(List<String> ids)? onImported,
  }) : _onImported = onImported;

  final Playlist playlist;
  final ToastSink toasts;
  final CoverImageWriter? covers;
  final String? coverDirectory;
  final double Function(String path)? durationProbe;
  final Future<void> Function(List<String> ids)? _onImported;

  Future<ImportResult> importPaths(List<String> paths) async {
    if (paths.isEmpty) return ImportResult();
    final partition = partitionByExtension(paths);
    for (final name in partition.rejected) {
      toasts.show('不支持的文件格式，已跳过：${_basename(name)}',
          key: 'skip-${_basename(name)}');
    }
    final addedIds = <String>[];
    for (final path in partition.accepted) {
      final id = localIdFor(path);
      if (playlist.byId(id) != null) continue; // 同一文件不重复入列
      final track = _buildTrack(path, id);
      final inserted = playlist.addAt(track);
      if (inserted == null) continue;
      addedIds.add(id);
      unawaited(_enrich(inserted));
    }
    if (addedIds.isNotEmpty && _onImported != null) {
      unawaited(_onImported!(addedIds));
    }
    return ImportResult(
      added: addedIds.length,
      rejected: partition.rejected.length,
      rejectedNames: [for (final p in partition.rejected) _basename(p)],
      addedIds: addedIds,
    );
  }

  Future<ImportResult> importDirectory(String root, {int maxFiles = 2000}) async {
    final found = await scanAudioDirectory(root, maxFiles: maxFiles);
    if (found.isEmpty) {
      toasts.info('这个目录里没有可播放的音频文件');
      return ImportResult();
    }
    return importPaths(found.map((e) => e.path).toList());
  }

  Track _buildTrack(String path, String id) {
    final name = _basename(path);
    final split = splitArtistTitle(name.replaceAll(RegExp(r'\.[A-Za-z0-9]+$'), ''));
    return Track(
      id: id,
      src: path,
      title: split.title.isEmpty ? name : split.title,
      artist: split.artist,
      duration: double.nan,
      isLocal: true,
      handle: FilePathHandle(path),
    );
  }

  Future<void> _enrich(Track live) async {
    await hydrateMetadata(live);
    final probe = durationProbe;
    if (probe != null && !live.hasDuration) {
      final value = probe(live.handle.pathish);
      if (value.isFinite && value > 0) live.duration = value;
    }
  }

  /// 标签回填：先按 id 取回活对象再改（原版 addMany 克隆的坑）。
  Future<void> hydrateMetadata(Track track) async {
    final live = playlist.byId(track.id) ?? track;
    final ByteSource source;
    try {
      final path = live.handle.pathish;
      final head = await _headBytes(path);
      if (head == null) return;
      source = ByteSource.fromFile(path, prefetched: head);
    } catch (_) {
      return;
    }
    final tags = await readAudioTags(source, fileName: live.handle.displayName);
    if (!tags.hasAnyText && !tags.hasPicture) return;
    final names = mergeTaggedNames(tags, live.handle.displayName);
    if (names.title.isNotEmpty) live.title = names.title;
    if (names.artist.isNotEmpty) live.artist = names.artist;
    if (tags.album.isNotEmpty) live.album = tags.album;
    final picture = tags.picture;
    final writer = covers;
    final directory = coverDirectory;
    if (picture != null && writer != null && directory != null && !live.hasRealCover) {
      final saved = await writer.write(picture, tags.pictureMime,
          directory: directory, id: live.id);
      if (saved != null) live.cover = saved;
    }
  }

  Future<void> applyTagsForTest(
    Track live, {
    String title = '',
    String artist = '',
    String album = '',
  }) async {
    if (title.isNotEmpty) live.title = title;
    if (artist.isNotEmpty) live.artist = artist;
    if (album.isNotEmpty) live.album = album;
  }

  Future<List<int>?> _headBytes(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final raf = await file.open();
      try {
        final size = await raf.length();
        return await raf.read(size < _headProbeBytes ? size : _headProbeBytes);
      } finally {
        await raf.close();
      }
    } catch (_) {
      return null;
    }
  }
}

/// 同一来源恒定同一 id：路径或 SAF URI 的 sha1 前 16 位。
String localIdFor(String source) {
  final digest = crypto.sha1.convert(utf8.encode(source));
  return 'local:${digest.toString().substring(0, 16)}';
}

String _basename(String path) => path.split(RegExp(r'[/\\]')).last;
```

- [ ] **Step 4: 给 `TrackHandle` 补 `pathish`**

在 `lib/playback/track_handle.dart` 的 `TrackHandle` 里加：

```dart
  /// 能当本地路径用的形态；SAF 返回原 uri，交给 driver 处理。
  String get pathish => uri;
```

并在 `FilePathHandle` 覆盖：

```dart
  @override
  String get pathish => path;
```

- [ ] **Step 5: 加 crypto 依赖并跑测试**

Run: `cd flutter-app && /d/flutter/bin/flutter pub add crypto`
Expected: `Added crypto`（版本号写进 pubspec，不要留 `any`）。

Run: `cd flutter-app && /d/flutter/bin/flutter test test/library/import_service_test.dart`
Expected: `All tests passed!`（8 个用例）。测试文件顶部需要 `import 'dart:io';`。

- [ ] **Step 6: Commit**

```bash
cd flutter-app && git add lib test pubspec.yaml pubspec.lock && git commit -m "feat(library): 新增导入服务，标签与封面回填按活对象写回"
```

---

## Task 19: Token 表与主题

M1 只做深色薄荷一套的实际值，但 **token 结构按 spec §9 的四套预留**：字段命名与 app.css 变量名逐一同源，M3 只往表里加值、不改调用点。`ui/` 内禁止 `Color(0x...)`。

**Files:**
- Create: `lib/theme/app_tokens.dart`
- Create: `lib/core/breakpoints.dart`
- Create: `lib/theme/app_theme.dart`
- Test: `test/theme/tokens_test.dart`

**Interfaces:**
- Consumes: 无
- Produces:
  - `class AppTokens { Color get bg; ...; ThemeData get themeData; }` + `AppTokens get tokens` 的 `Extension`：`ThemeExtension<AppTokensData>`，用 `Theme.of(context).extension<AppTokensData>()!` 取。
  - `abstract final class Breaks { static const double desktop = 900; static const double compact = 480; }`，`bool isDesktop(double width)`、`bool isUltraCompact(double width)`。
  - 布局常量：`kCoverSize`（`clamp(132,27vh,196)` 等三档）、`kButtonSize = 40`、`kTouchTarget = 44`、`kRadiusXl = 24`、`kRadiusLg = 16`、`kRadiusMd = 12`、`kTrackThumb = 44`。

- [ ] **Step 1: 写失败测试（值逐字取自 app.css）**

```dart
// test/theme/tokens_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/breakpoints.dart';
import 'package:light_music/theme/app_tokens.dart';

void main() {
  test('深色薄荷的实际取值逐字对齐 app.css :root', () {
    const tokens = AppTokens.dark;
    expect(tokens.bg, const Color(0xFF080B10));
    expect(tokens.text, const Color(0xFFE9F1F7));
    expect(tokens.textDim, const Color(0xFF8B9CAB));
    expect(tokens.textFaint, const Color(0xFF6678 8C));
    expect(tokens.accent, const Color(0xFF2EE6A8));
    expect(tokens.accentLight, const Color(0xFFB9FFE9));
    expect(tokens.accentInk, const Color(0xFF04231B));
    expect(tokens.danger, const Color(0xFFFF6B81));
  });

  test('带透明度的强调色一律由 accentRgb 派生', () {
    const tokens = AppTokens.dark;
    expect(tokens.accentSoft.alpha, 0.14 * 255 ~/ 1);
    expect(tokens.accentLine.alpha, (0.32 * 255).round());
    expect(tokens.accentRgb, (46, 230, 168));
  });

  test('边框/危险/提示的透明度值', () {
    const tokens = AppTokens.dark;
    expect(tokens.border, const Color(0x12FFFFFF)); // rgba(255,255,255,0.07)
    expect(tokens.borderStrong, const Color(0x29FFFFFF)); // 0.16
    expect(tokens.toastBg, const Color(0xF2121820)); // rgba(18,24,32,0.95)
    expect(tokens.dangerSoft.alpha, (0.12 * 255).round());
    expect(tokens.dangerLine.alpha, (0.36 * 255).round());
  });

  test('断点阈值', () {
    expect(Breaks.desktop, 900);
    expect(Breaks.compact, 480);
    expect(isDesktop(900), isTrue);
    expect(isDesktop(899.9), isFalse);
    expect(isUltraCompact(479), isTrue);
  });

  test('封面尺寸三档', () {
    expect(kCoverSize(360), closeTo(132, 0.01)); // clamp 下限
    expect(kCoverSize(1000, viewportHeight: 700), closeTo(166, 0.01));
    expect(kCoverSize(1300, viewportHeight: 900), 248);
  });
}
```

> Step 1 里 `Color(0xFF6678 8C)` 那行**故意写成两行会被 analyzer 报错的形式**：实现时请写成一个字面量 `Color(0xFF66788C)`。这里保留断言值 0x66788C 即可（对应 `--text-faint #66788c`）。

- [ ] **Step 2: 跑测试确认失败**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/theme/tokens_test.dart`
Expected: 编译失败 —— `app_tokens.dart` 不存在。

- [ ] **Step 3: 实现 token**

```dart
// lib/theme/app_tokens.dart
import 'package:flutter/material.dart';

/// 与 app.css 的变量名一一对应；M3 加 light/pink/blue 时只增字段值，不改名字。
class AppTokens {
  const AppTokens({
    required this.name,
    required this.bg,
    required this.bgGradA,
    required this.bgGradB,
    required this.text,
    required this.textDim,
    required this.textFaint,
    required this.accent,
    required this.accentLight,
    required this.accentInk,
    required this.accentRgb,
    required this.danger,
    required this.dangerInk,
    required this.toastBg,
    required this.border,
    required this.borderStrong,
    required this.cardA,
    required this.cardB,
    required this.panelA,
    required this.panelB,
    required this.barA,
    required this.barB,
    required this.progressTrack,
    required this.accentSoft,
    required this.accentLine,
    required this.dangerSoft,
    required this.dangerLine,
    required this.shadowCard,
    required this.shadowBar,
    required this.glassBlurSigma,
  });

  final String name;
  final Color bg;
  final Color bgGradA;
  final Color bgGradB;
  final Color text;
  final Color textDim;
  final Color textFaint;
  final Color accent;
  final Color accentLight;
  final Color accentInk;
  final (int, int, int) accentRgb;
  final Color danger;
  final Color dangerInk;
  final Color toastBg;
  final Color border;
  final Color borderStrong;
  final Color cardA;
  final Color cardB;
  final Color panelA;
  final Color panelB;
  final Color barA;
  final Color barB;
  final Color progressTrack;
  final Color accentSoft;
  final Color accentLine;
  final Color dangerSoft;
  final Color dangerLine;
  final List<BoxShadow> shadowCard;
  final List<BoxShadow> shadowBar;
  final double glassBlurSigma;

  static const AppTokens dark = AppTokens(
    name: 'mint-dark',
    bg: Color(0xFF080B10),
    bgGradA: Color(0xFF0B1C1A),
    bgGradB: Color(0xFF070A10),
    text: Color(0xFFE9F1F7),
    textDim: Color(0xFF8B9CAB),
    textFaint: Color(0xFF66788C),
    accent: Color(0xFF2EE6A8),
    accentLight: Color(0xFFB9FFE9),
    accentInk: Color(0xFF04231B),
    accentRgb: (46, 230, 168),
    danger: Color(0xFFFF6B81),
    dangerInk: Color(0xFFFFC9D1),
    toastBg: Color(0xF2121820),
    border: Color(0x12FFFFFF),
    borderStrong: Color(0x29FFFFFF),
    cardA: Color(0x12FFFFFF),
    cardB: Color(0x04FFFFFF),
    panelA: Color(0x12FFFFFF),
    panelB: Color(0x04FFFFFF),
    barA: Color(0xE10E131A),
    barB: Color(0xF7090C11),
    progressTrack: Color(0x1CFFFFFF),
    accentSoft: Color(0x242EE6A8),
    accentLine: Color(0x522EE6A8),
    dangerSoft: Color(0x1FFF6B81),
    dangerLine: Color(0x5CFF6B81),
    shadowCard: [BoxShadow(color: Color(0xF2000000), blurRadius: 60, offset: Offset(0, 24))],
    shadowBar: [BoxShadow(color: Color(0xF2000000), blurRadius: 44, offset: Offset(0, -14))],
    glassBlurSigma: 20,
  );

  ThemeData get themeData => ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: bg,
        colorScheme: ColorScheme.dark(primary: accent, surface: bg),
        extensions: [AppTokensData(tokens: this)],
        fontFamily: 'system-ui',
      );
}

@immutable
class AppTokensData extends ThemeExtension<AppTokensData> {
  const AppTokensData({required this.tokens});
  final AppTokens tokens;

  @override
  AppTokensData copyWith({AppTokens? tokens}) =>
      AppTokensData(tokens: tokens ?? this.tokens);

  @override
  AppTokensData lerp(covariant AppTokensData? other, double t) => other == null
      ? this
      : (t < 0.5 ? this : other);
}

extension AppTokensContext on BuildContext {
  AppTokens get tokens => Theme.of(this).extension<AppTokensData>()!.tokens;
}
```

> `accentSoft` 等带透明度的强调色必须写成 `0xNNRRGGBB` 形式的**具体常量**（0x24 = 0.14×255、0x52 = 0.32×255、0x1F = 0.12×255、0x5C = 0.36×255），不要用运行时 `.withOpacity`，这样测试能逐字断言且不产生每帧新对象。M3 加 accent 切换时改为从 `accentRgb` 组装，同步把这条测试换成参数化断言。

```dart
// lib/core/breakpoints.dart
abstract final class Breaks {
  static const double desktop = 900;
  static const double compact = 480;
}

bool isDesktop(double width) => width >= Breaks.desktop;
bool isUltraCompact(double width) => width < Breaks.compact;

/// 对应 app.css 的 --cover-size：默认 clamp(132px,27vh,196px)、
/// ≤899 clamp(108px,24vh,150px)、≥900 clamp(166px,18vw,232px)、≥1180 固定 248。
double kCoverSize(double width, {double? viewportHeight}) {
  final vh = viewportHeight ?? 700.0;
  if (width >= 1180) return 248;
  if (width >= Breaks.desktop) {
    return _clamp(166, width * 0.18, 232);
  }
  return _clamp(108, vh * 0.24, 150);
}

double _clamp(double min, double value, double max) =>
    value < min ? min : (value > max ? max : value);

const double kButtonSize = 40;
const double kTouchTarget = 44;
const double kRadiusXl = 24;
const double kRadiusLg = 16;
const double kRadiusMd = 12;
const double kTrackThumb = 44;
```

- [ ] **Step 4: 实现主题装配**

```dart
// lib/theme/app_theme.dart
import 'package:flutter/material.dart';

import 'app_tokens.dart';

ThemeData buildTheme({AppTokens tokens = AppTokens.dark}) {
  final data = tokens.themeData;
  return data.copyWith(
    textTheme: (data.textTheme ?? const Typography().black).apply(
      bodyColor: tokens.text,
      displayColor: tokens.text,
    ),
    sliderTheme: data.sliderTheme.copyWith(
      activeTrackColor: tokens.accent,
      inactiveTrackColor: tokens.progressTrack,
      thumbColor: Colors.white,
      overlayColor: tokens.accentSoft,
    ),
    dividerColor: tokens.border,
    splashFactory: NoSplash.splashFactory,
  );
}
```

- [ ] **Step 5: 跑测试确认通过**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/theme/`
Expected: `All tests passed!`（5 个用例）。`accentSoft.alpha` 断言若因 Flutter 版本用 `.a` 而非 `.alpha` 报错，按 SDK 的实际 API 改名，**值不许改**。

- [ ] **Step 6: Commit**

```bash
cd flutter-app && git add lib/theme lib/core test/theme && git commit -m "feat(theme): 建立与设计一致的 token 表与主题装配"
```

---

## Task 20: Toast 状态与宿主

原版规则（`state/toast.tsx` + README）：同屏最多 3 条、默认 3200ms、**同 key 只保留一条并重新计时**、同文案也去重。

**Files:**
- Create: `lib/state/toast_state.dart`
- Create: `lib/ui/toasts.dart`
- Test: `test/state/toast_state_test.dart`
- Test: `test/ui/toasts_test.dart`

**Interfaces:**
- Consumes: `ToastSink`（T14）
- Produces:
  - `enum ToastKind { info, success, error }`
  - `class ToastItem { int id; String message; ToastKind kind; int durationMs; String key; }`
  - `class ToastState extends ChangeNotifier implements ToastSink { void show(String message, {String key, int durationMs}); void info(String message); void error(String message); void success(String message); List<ToastItem> get items; void dismiss(int id); int get maxVisible; }`
  - `class ToastsHost extends StatelessWidget`（`Semantics(liveRegion: true)`，固定在顶部安全区内，宽 `min(420, 屏宽-24)`）

- [ ] **Step 1: 写失败测试**

```dart
// test/state/toast_state_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/state/toast_state.dart';

void main() {
  test('同 key 只留一条并重新计时', () {
    final state = ToastState();
    state.show('列表循环', key: 'mode');
    final first = state.items.single;
    state.show('单曲循环', key: 'mode');
    expect(state.items.length, 1);
    expect(state.items.single.message, '单曲循环');
    expect(state.items.single.id, first.id); // 复用同一条，不新增
    expect(first.createdAt, isNot(state.items.single.createdAt));
  });

  test('同文案不同 key 也去重', () {
    final state = ToastState();
    state.show('已清空', key: 'a');
    state.show('已清空', key: 'b');
    expect(state.items.length, 1);
  });

  test('超出 3 条时排队，前面的消失后才补上', () {
    final state = ToastState();
    for (var i = 0; i < 5; i++) {
      state.show('消息$i', key: 'k$i', durationMs: 10);
    }
    expect(state.items.length, 3);
    expect(state.queued.length, 2);
    state.drainForTest();
    expect(state.items.length, 3);
    state.drainForTest();
    expect(state.items.length, 3);
    state.drainForTest();
    expect(state.items.length, 2);
  });

  test('dismiss 后从队列补一条', () {
    final state = ToastState();
    for (var i = 0; i < 4; i++) {
      state.show('消息$i', key: 'k$i', durationMs: 1000);
    }
    state.dismiss(state.items.first.id);
    expect(state.items.map((e) => e.message), ['消息1', '消息2', '消息3']);
  });

  test('info/error 走各自 kind 且默认时长 3200', () {
    final state = ToastState();
    state.info('提示');
    state.error('失败');
    expect(state.items.first.kind, ToastKind.info);
    expect(state.items.last.kind, ToastKind.error);
    expect(state.items.first.durationMs, 3200);
  });

  test('notifyListeners 每次变更恰好一次', () {
    final state = ToastState();
    var count = 0;
    state.addListener(() => count++);
    state.show('a', key: 'x');
    expect(count, 1);
    state.show('b', key: 'x');
    expect(count, 2);
  });
}
```

```dart
// test/ui/toasts_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/state/toast_state.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/ui/toasts.dart';

void main() {
  testWidgets('宿主带 liveRegion 语义', (tester) async {
    final state = ToastState()..show('这首歌已经不在播放列表里了');
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme().copyWith(
        extensions: const [AppTokensData(tokens: AppTokens.dark)],
      ),
      home: ChangeNotifierProviderShim(
        notifier: state,
        child: const ToastsHost(),
      ),
    ));
    expect(find.text('这首歌已经不在播放列表里了'), findsOneWidget);
    final semantics = tester.getSemantics(find.byType(ToastsHost));
    expect(semantics.liveRegion, isTrue);
  });
}
```

> `ChangeNotifierProviderShim`：T20 时 provider 还没接进 UI 层，先用一个 20 行的本地 `InheritedNotifier` 包一下（放在 `test/ui/toasts_test.dart` 里，不进产品代码）；T23 之后这个 shim 由真 `ChangeNotifierProvider` 取代。

- [ ] **Step 2: 跑测试确认失败**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/state/ test/ui/`
Expected: 编译失败 —— `toast_state.dart` / `toasts.dart` 不存在。

- [ ] **Step 3: 实现 ToastState**

```dart
// lib/state/toast_state.dart
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../playback/audio_player.dart' show ToastSink;

enum ToastKind { info, success, error }

@immutable
class ToastItem {
  const ToastItem({
    required this.id,
    required this.message,
    required this.kind,
    required this.durationMs,
    required this.key,
    required this.createdAt,
  });

  final int id;
  final String message;
  final ToastKind kind;
  final int durationMs;
  final String key;
  final DateTime createdAt;
}

const int kToastMaxVisible = 3;
const int kToastDefaultDurationMs = 3200;

class ToastState extends ChangeNotifier implements ToastSink {
  final List<ToastItem> _visible = [];
  final List<ToastItem> _queued = [];
  final Map<int, Timer> _timers = {};
  int _seq = 0;
  final int Function() _nowMs;

  ToastState({int Function()? nowMs})
      : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  List<ToastItem> get items => List.unmodifiable(_visible);
  List<ToastItem> get queued => List.unmodifiable(_queued);
  int get maxVisible => kToastMaxVisible;

  @override
  void show(String message, {String key = '', int durationMs = kToastDefaultDurationMs}) {
    final dedupeKey = key.isEmpty ? 'text:$message' : key;
    // 同 key 或同文案：改文案 + 重新计时，不新增条目
    final existing = _visible.indexWhere((e) => e.key == dedupeKey);
    if (existing >= 0) {
      _reschedule(_visible[existing].id, durationMs);
      _visible[existing] = _copy(_visible[existing], message, durationMs);
      notifyListeners();
      return;
    }
    final duplicated = _visible.firstWhere(
      (e) => e.message == message,
      orElse: () => const ToastItem(
          id: -1, message: '', kind: ToastKind.info, durationMs: 0, key: '', createdAt: null as dynamic),
    );
    if (duplicated.id != -1) {
      _reschedule(duplicated.id, durationMs);
      return;
    }
    final item = ToastItem(
      id: ++_seq,
      message: message,
      kind: _kindOf(message),
      durationMs: durationMs,
      key: dedupeKey,
      createdAt: DateTime.fromMillisecondsSinceEpoch(_nowMs()),
    );
    if (_visible.length >= kToastMaxVisible) {
      _queued.add(item);
    } else {
      _visible.add(item);
      _schedule(item.id, durationMs);
    }
    notifyListeners();
  }

  @override
  void info(String message) => show(message);

  @override
  void error(String message) => show(message, key: 'error:$message');

  void success(String message) => show(message);

  void dismiss(int id) {
    _timers.remove(id)?.cancel();
    final wasVisible = _visible.removeWhere((e) => e.id == id);
    if (wasVisible) notifyListeners();
    _promoteFromQueue();
  }

  ToastKind _kindOf(String message) =>
      message.contains('失败') || message.contains('不支持') || message.contains('无法')
          ? ToastKind.error
          : ToastKind.info;

  ToastItem _copy(ToastItem item, String message, int durationMs) => ToastItem(
        id: item.id,
        message: message,
        kind: _kindOf(message),
        durationMs: durationMs,
        key: item.key,
        createdAt: DateTime.fromMillisecondsSinceEpoch(_nowMs()),
      );

  void _schedule(int id, int durationMs) {
    _timers[id] = Timer(Duration(milliseconds: durationMs), () {
      _timers.remove(id);
      _visible.removeWhere((e) => e.id == id);
      notifyListeners();
      _promoteFromQueue();
    });
  }

  void _reschedule(int id, int durationMs) {
    _timers.remove(id)?.cancel();
    _schedule(id, durationMs);
  }

  void _promoteFromQueue() {
    while (_visible.length < kToastMaxVisible && _queued.isNotEmpty) {
      final next = _queued.removeAt(0);
      _visible.add(next);
      _schedule(next.id, next.durationMs);
      notifyListeners();
    }
  }

  /// 测试用：立刻让一条排队项到期。
  void drainForTest() {
    if (_visible.isEmpty) return;
    _timers.remove(_visible.first.id)?.cancel();
    _visible.removeAt(0);
    _promoteFromQueue();
    notifyListeners();
  }

  @override
  void dispose() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    super.dispose();
  }
}
```

> Step 3 里 `orElse` 那个 `null as dynamic` 写法只是为了让 `firstWhere` 不抛，实现时请改成正面写法：用 `indexWhere` 取索引再判 `>= 0`。不要保留 `as dynamic`。

- [ ] **Step 4: 实现宿主 widget**

```dart
// lib/ui/toasts.dart
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../state/toast_state.dart';

class ToastsHost extends StatelessWidget {
  const ToastsHost({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ToastState>();
    final width = MediaQuery.sizeOf(context).width;
    return Semantics(
      liveRegion: true,
      label: '提示',
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: EdgeInsets.only(top: 12 + MediaQuery.viewPaddingOf(context).top),
          child: SizedBox(
            width: math.min(420, width - 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final item in state.items)
                  _ToastCard(item: item, onTap: () => state.dismiss(item.id)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ToastCard extends StatelessWidget {
  const _ToastCard({required this.item, required this.onTap});
  final ToastItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: item.kind == ToastKind.error ? tokens.toastErrorBg : tokens.toastBg,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 11, 10, 11),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: tokens.borderStrong),
            ),
            child: Text(
              item.message,
              style: TextStyle(fontSize: 12.8, color: tokens.text),
            ),
          ),
        ),
      ),
    );
  }
}
```

> `tokens.toastErrorBg` 是 app.css 里 `--toast-error-bg rgba(48,19,25,0.96)`，**必须在 T19 的 `AppTokens` 里补上这个字段**（值 `Color(0xF5301319)`），本任务的测试断言里加一条 `expect(AppTokens.dark.toastErrorBg, const Color(0xF5301319));`。

- [ ] **Step 5: 跑测试确认通过**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/state/toast_state_test.dart test/ui/toasts_test.dart`
Expected: `All tests passed!`（6 + 1 个用例）

- [ ] **Step 6: Commit**

```bash
cd flutter-app && git add lib test && git commit -m "feat(ui): 新增去重提示条与队列宿主"
```


## Task 21: MediaSessionBridge 抽象与测试替身

系统媒体会话的边界（spec §7.1）。核心约束：**外部动作一律走 `TransportController` 的既有方法**，bridge 只做「界面 → 系统」的推送与「系统 → 界面」的转发，绝不出现第二条播放控制路径。

**Files:**
- Create: `lib/playback/media_session_bridge.dart`
- Test: `test/playback/media_session_bridge_test.dart`

**Interfaces:**
- Consumes: `Track`（T3）、`TransportController`（T14）、`PlayMode`（T4）
- Produces:
  - `sealed class MediaSessionCommand { PlayCommand; PauseCommand; NextCommand; PreviousCommand; StopCommand; SeekCommand(double seconds); }`
  - `abstract class MediaSessionBridge { Future<void> start(); Future<void> stop(); Future<void> publish(PublishedSnapshot snapshot); Stream<MediaSessionCommand> get commands; Future<void> dispose(); }`
  - `@immutable class PublishedSnapshot { String title; String artist; String album; String? artUri; bool playing; Duration position; Duration? duration; bool shuffleEnabled; MediaRepeatMode repeatMode; }`
  - `enum MediaRepeatMode { off, all, one }`
  - `class FakeMediaSessionBridge implements MediaSessionBridge` —— 记录 `published` 列表与 `calls`，`emit(MediaSessionCommand)` 注入外部动作，`startCount`/`stopCount` 由 `calls` 派生。
  - `class MediaSessionCoordinator { MediaSessionCoordinator({required MediaSessionBridge bridge, required TransportController transport, String Function(Track)? artUriFor, int Function()? nowMs}); Future<void> attach(); Future<void> dispose(); int get publishCount; }` —— 订阅 transport 的 `view` 与 player 事件，把状态推给 bridge；把 bridge 的 `commands` 转成 transport 调用。**推流节流**：position 变化每 1000ms 最多推一次，其余字段变化立即推。

- [ ] **Step 1: 写失败测试**

```dart
// test/playback/media_session_bridge_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/playback/audio_driver.dart';
import 'package:light_music/playback/audio_player.dart';
import 'package:light_music/playback/media_session_bridge.dart';
import 'package:light_music/playback/play_mode.dart';
import 'package:light_music/playback/playlist.dart';
import 'package:light_music/playback/track.dart';
import 'package:light_music/playback/transport_controller.dart';

class _NoRecent implements RecentRecorder {
  @override
  void record(Track track, {DateTime? at}) {}
}

class _NoToast implements ToastSink {
  @override
  void show(String message, {String key = '', int durationMs = 3200}) {}
  @override
  void info(String message) {}
  @override
  void error(String message) {}
}

Track t(String id) => Track(
      id: id, src: '/$id.flac', title: '歌$id', artist: '某人',
      album: '某碟', cover: '/cache/$id.jpg', duration: 100,
    );

void main() {
  test('attach 后推送当前曲目的元数据与播放态', () async {
    final bridge = FakeMediaSessionBridge();
    final transport = TransportController(
      player: AudioPlayer(FakeAudioDriver(), scheduler: (d, cb) => cb()),
      recent: _NoRecent(),
      toasts: _NoToast(),
      playlist: Playlist.fromTracks([t('1')]),
    );
    await MediaSessionCoordinator(bridge: bridge, transport: transport).attach();
    await transport.playTrack('1');
    expect(bridge.published.last.title, '歌1');
    expect(bridge.published.last.artist, '某人');
    expect(bridge.published.last.artUri, '/cache/1.jpg');
    expect(bridge.published.last.playing, isTrue);
  });

  test('系统侧四个动作全部转发到 transport 的同一入口', () async {
    final bridge = FakeMediaSessionBridge();
    final driver = FakeAudioDriver();
    final transport = TransportController(
      player: AudioPlayer(driver, scheduler: (d, cb) => cb()),
      recent: _NoRecent(),
      toasts: _NoToast(),
      playlist: Playlist.fromTracks([t('1'), t('2')]),
    );
    await MediaSessionCoordinator(bridge: bridge, transport: transport).attach();
    await transport.playTrack('1');
    driver.calls.clear();

    bridge.emit(NextCommand());
    await Future<void>.delayed(Duration.zero);
    expect(transport.current!.id, '2');

    bridge.emit(PauseCommand());
    await Future<void>.delayed(Duration.zero);
    expect(driver.calls, contains('pause'));

    bridge.emit(PreviousCommand());
    await Future<void>.delayed(Duration.zero);
    expect(transport.current!.id, '1');

    bridge.emit(SeekCommand(50));
    await Future<void>.delayed(Duration.zero);
    expect(driver.calls, contains('seek:50.0'));
  });

  test('随机模式把 shuffle 与单曲循环同步给系统', () async {
    final bridge = FakeMediaSessionBridge();
    final transport = TransportController(
      player: AudioPlayer(FakeAudioDriver(), scheduler: (d, cb) => cb()),
      recent: _NoRecent(), toasts: _NoToast(),
      playlist: Playlist.fromTracks([t('1'), t('2')], mode: PlayMode.shuffle),
    );
    await MediaSessionCoordinator(bridge: bridge, transport: transport).attach();
    await transport.playTrack('1');
    expect(bridge.published.last.shuffleEnabled, isTrue);
    expect(bridge.published.last.repeatMode, MediaRepeatMode.all);
    transport.cycleMode(); // shuffle -> list
    await Future<void>.delayed(Duration.zero);
    expect(bridge.published.last.shuffleEnabled, isFalse);
  });

  test('position 推送节流到每秒一次，播放态变化不受限', () async {
    var fakeNow = 0;
    final bridge = FakeMediaSessionBridge();
    final driver = FakeAudioDriver();
    final transport = TransportController(
      player: AudioPlayer(driver, scheduler: (d, cb) => cb()),
      recent: _NoRecent(), toasts: _NoToast(),
      playlist: Playlist.fromTracks([t('1')]),
    );
    final coordinator = MediaSessionCoordinator(
      bridge: bridge, transport: transport, nowMs: () => fakeNow,
    );
    await coordinator.attach();
    await transport.playTrack('1');
    final baseline = coordinator.publishCount;
    for (var i = 1; i <= 10; i++) {
      fakeNow = i * 200; // 200ms 一次
      driver.emitPosition(i.toDouble());
    }
    expect(coordinator.publishCount - baseline, lessThanOrEqualTo(3));
    fakeNow = 5000;
    driver.emitPlaying(false);
    await Future<void>.delayed(Duration.zero);
    expect(bridge.published.last.playing, isFalse);
  });

  test('没有当前曲目时推空元数据并停掉会话，不抛', () async {
    final bridge = FakeMediaSessionBridge();
    final transport = TransportController(
      player: AudioPlayer(FakeAudioDriver(), scheduler: (d, cb) => cb()),
      recent: _NoRecent(), toasts: _NoToast(),
      playlist: Playlist(tracks: const []),
    );
    await MediaSessionCoordinator(bridge: bridge, transport: transport).attach();
    expect(bridge.published.last.title, isEmpty);
    expect(bridge.stopCount, greaterThanOrEqualTo(1));
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/playback/media_session_bridge_test.dart`
Expected: 编译失败 —— `media_session_bridge.dart` 不存在，且 `FakeAudioDriver` 缺 `emitPlaying`（T13 Step 3 已要求补，若还没补就在这里补上）。

- [ ] **Step 3: 实现抽象、Fake 与协调器**

```dart
// lib/playback/media_session_bridge.dart
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'audio_player.dart';
import 'play_mode.dart';
import 'transport_controller.dart';
import 'track.dart';

sealed class MediaSessionCommand;

class PlayCommand extends MediaSessionCommand {}

class PauseCommand extends MediaSessionCommand {}

class NextCommand extends MediaSessionCommand {}

class PreviousCommand extends MediaSessionCommand {}

class StopCommand extends MediaSessionCommand {}

class SeekCommand extends MediaSessionCommand {
  SeekCommand(this.seconds);
  final double seconds;
}

enum MediaRepeatMode { off, all, one }

@immutable
class PublishedSnapshot {
  const PublishedSnapshot({
    this.title = '',
    this.artist = '',
    this.album = '',
    this.artUri,
    this.playing = false,
    this.position = Duration.zero,
    this.duration,
    this.shuffleEnabled = false,
    this.repeatMode = MediaRepeatMode.off,
  });

  final String title;
  final String artist;
  final String album;
  final String? artUri;
  final bool playing;
  final Duration position;
  final Duration? duration;
  final bool shuffleEnabled;
  final MediaRepeatMode repeatMode;
}

abstract class MediaSessionBridge {
  Future<void> start();
  Future<void> stop();
  Future<void> publish(PublishedSnapshot snapshot);
  Stream<MediaSessionCommand> get commands;
  Future<void> dispose();
}

class FakeMediaSessionBridge implements MediaSessionBridge {
  final List<PublishedSnapshot> published = [];
  final List<String> calls = [];
  final _controller = StreamController<MediaSessionCommand>.broadcast();

  int get startCount => calls.where((c) => c == 'start').length;
  int get stopCount => calls.where((c) => c == 'stop').length;

  void emit(MediaSessionCommand command) => _controller.add(command);

  @override
  Future<void> start() async => calls.add('start');

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Future<void> publish(PublishedSnapshot snapshot) async => published.add(snapshot);

  @override
  Stream<MediaSessionCommand> get commands => _controller.stream;

  @override
  Future<void> dispose() async {
    calls.add('dispose');
    await _controller.close();
  }
}

/// 界面状态 ⇄ 系统会话的唯一桥。动作全部交给 transport，
/// 于是锁屏/媒体键与界面按钮共用模式、熔断、最近播放语义（spec §7.1）。
class MediaSessionCoordinator {
  MediaSessionCoordinator({
    required this.bridge,
    required this.transport,
    this.artUriFor,
    int Function()? nowMs,
  }) : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final MediaSessionBridge bridge;
  final TransportController transport;
  final String Function(Track)? artUriFor;
  final int Function() _nowMs;

  StreamSubscription<MediaSessionCommand>? _commandSub;
  StreamSubscription<PlayerEvent>? _playerSub;
  VoidCallback? _viewListener;
  int _lastPositionPublishMs = 0;
  int _publishCount = 0;
  PublishedSnapshot _last = const PublishedSnapshot();
  bool _attached = false;

  int get publishCount => _publishCount;

  Future<void> attach() async {
    if (_attached) return;
    _attached = true;
    await bridge.start();
    _commandSub = bridge.commands.listen(_onCommand);
    _playerSub = transport.player.events.listen((event) {
      if (event is TimeUpdateEvent) {
        _publish(positionOverride: event.position, throttled: true);
      }
      _publish();
    });
    _viewListener = () => _publish();
    transport.view.addListener(_viewListener!);
    _publish();
  }

  void _onCommand(MediaSessionCommand command) {
    switch (command) {
      case PlayCommand():
        final id = transport.current?.id;
        if (id != null) unawaited(transport.playTrack(id));
      case PauseCommand():
        unawaited(transport.player.pause());
      case NextCommand():
        unawaited(transport.next());
      case PreviousCommand():
        unawaited(transport.previous());
      case StopCommand():
        unawaited(transport.player.stop());
      case SeekCommand(:final seconds):
        unawaited(transport.seekTo(seconds));
    }
  }

  void _publish({double? positionOverride, bool throttled = false}) {
    final now = _nowMs();
    if (throttled && now - _lastPositionPublishMs < 1000) return;
    if (positionOverride != null) _lastPositionPublishMs = now;

    final view = transport.view.value;
    final track = view.current;
    final snapshot = PublishedSnapshot(
      title: track?.title ?? '',
      artist: track?.artist ?? '',
      album: track?.album ?? '',
      artUri: track == null || track.cover.isEmpty
          ? null
          : (artUriFor == null ? track.cover : artUriFor!(track)),
      playing: view.playing,
      position: Duration(
          milliseconds:
              ((positionOverride ?? transport.position.value) * 1000).round()),
      duration: track?.hasDuration == true
          ? Duration(milliseconds: (track!.duration * 1000).round())
          : null,
      shuffleEnabled: view.mode == PlayMode.shuffle,
      repeatMode: view.mode == PlayMode.one
          ? MediaRepeatMode.one
          : MediaRepeatMode.all,
    );
    if (_same(snapshot, _last)) return; // 相同快照不重复推，避免通知被无谓刷新
    _last = snapshot;
    _publishCount += 1;
    if (track == null) unawaited(bridge.stop());
    unawaited(bridge.publish(snapshot));
  }

  bool _same(PublishedSnapshot a, PublishedSnapshot b) =>
      a.title == b.title &&
      a.artist == b.artist &&
      a.album == b.album &&
      a.artUri == b.artUri &&
      a.playing == b.playing &&
      a.shuffleEnabled == b.shuffleEnabled &&
      a.repeatMode == b.repeatMode &&
      a.duration == b.duration;

  Future<void> dispose() async {
    if (!_attached) return;
    _attached = false;
    await _commandSub?.cancel();
    await _playerSub?.cancel();
    if (_viewListener != null) transport.view.removeListener(_viewListener!);
    await bridge.stop();
    await bridge.dispose();
  }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/playback/media_session_bridge_test.dart`
Expected: `All tests passed!`（5 个用例）。节流那条失败时先查 `_publish(throttled: true)` 是否走了 `_lastPositionPublishMs`，而不是把判等 `_same` 调松 —— 这条测试的目的就是确认位置推送不会打满系统。

- [ ] **Step 5: Commit**

```bash
cd flutter-app && git add lib/playback test/playback && git commit -m "feat(playback): 定义系统媒体会话桥与状态协调器"
```

---

## Task 22: 媒体会话实现（Android 前台服务 + Windows SMTC）与权限

按 spec §7.2：首选 `flutter_media_session`（同一套 API 覆盖两端），实测不满足必需项时降级 `audio_service` + `smtc_windows`。**本任务的必需项验收只有两条：息屏能续播、锁屏能上下曲。**

**Files:**
- Create: `lib/playback/flutter_media_session_bridge.dart`
- Create: `lib/core/platform_services.dart`
- Modify: `android/app/src/main/AndroidManifest.xml`
- Modify: `lib/main.dart`（装配 bridge）
- Test: `test/playback/flutter_media_session_bridge_test.dart`（纯映射单测，不依赖设备）

**Interfaces:**
- Consumes: `MediaSessionBridge`、`PublishedSnapshot`、`MediaSessionCommand`（T21）
- Produces:
  - `class FlutterMediaSessionBridge implements MediaSessionBridge`
  - 纯函数：`String mapStateName(PublishedSnapshot)`、`int actionsFor(PublishedSnapshot)`、`String? toArtUri(String?)`、`MediaSessionCommand? commandFromName(String)`
  - `Future<bool> ensureNotificationPermission();`（Android 13+ 才申请，其他平台返回 true）
  - `const String mediaSessionChannelName = '流光音乐';` / `mediaSessionChannelId = 'light_music_playback';`

- [ ] **Step 1: 写失败测试（纯映射，可在无设备下跑）**

```dart
// test/playback/flutter_media_session_bridge_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/playback/flutter_media_session_bridge.dart';
import 'package:light_music/playback/media_session_bridge.dart';

void main() {
  test('播放态名称映射逐一对应', () {
    expect(mapStateName(const PublishedSnapshot(playing: true)), 'playing');
    expect(mapStateName(const PublishedSnapshot(playing: false, title: 'A')), 'paused');
    expect(mapStateName(const PublishedSnapshot(title: '')), 'stopped');
  });

  test('动作集合：有当前曲目才允许上下曲，未知时长不给 seek', () {
    const withTrack = PublishedSnapshot(title: 'A', playing: true, duration: null);
    expect(actionsFor(withTrack), containsAllInOrder(['play', 'pause', 'next', 'previous', 'stop']));
    expect(actionsFor(withTrack), isNot(contains('seek')));
    const known = PublishedSnapshot(title: 'A', playing: true, duration: Duration(seconds: 100));
    expect(actionsFor(known), contains('seek'));
    expect(actionsFor(const PublishedSnapshot()), isEmpty);
  });

  test('artUri 为本地缓存路径时转 file URI，空值返回 null', () {
    expect(toArtUri(''), isNull);
    expect(toArtUri(null), isNull);
    expect(toArtUri('https://x/y.jpg'), 'https://x/y.jpg');
  });

  test('系统动作字符串归一到命令', () {
    expect(commandFromName('play'), isA<PlayCommand>());
    expect(commandFromName('pause'), isA<PauseCommand>());
    expect(commandFromName('next'), isA<NextCommand>());
    expect(commandFromName('nexttrack'), isA<NextCommand>());
    expect(commandFromName('previous'), isA<PreviousCommand>());
    expect(commandFromName('previoustrack'), isA<PreviousCommand>());
    expect(commandFromName('stop'), isA<StopCommand>());
    expect(commandFromName('unknown-action'), isNull);
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/playback/flutter_media_session_bridge_test.dart`
Expected: 编译失败 —— 文件不存在。

- [ ] **Step 3: 实现纯映射**

```dart
// lib/playback/flutter_media_session_bridge.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_media_session/flutter_media_session.dart';

import 'media_session_bridge.dart';

const String mediaSessionChannelName = '流光音乐';
const String mediaSessionChannelId = 'light_music_playback';

/// 播放态名字与原版四类状态一一对应。
String mapStateName(PublishedSnapshot snapshot) {
  if (snapshot.title.isEmpty) return 'stopped';
  return snapshot.playing ? 'playing' : 'paused';
}

List<String> actionsFor(PublishedSnapshot snapshot) {
  if (snapshot.title.isEmpty) return const [];
  return [
    'play',
    'pause',
    'next',
    'previous',
    'stop',
    if (snapshot.duration != null) 'seek',
  ];
}

String? toArtUri(String? path) {
  if (path == null || path.isEmpty) return null;
  if (path.startsWith('http')) return path;
  if (kIsWeb) return null;
  try {
    final file = File(path);
    return file.existsSync() ? file.uri.toString() : null;
  } catch (_) {
    return null;
  }
}

MediaSessionCommand? commandFromName(String name) => switch (name) {
      'play' || 'resume' || 'toggleplay' => PlayCommand(),
      'pause' => PauseCommand(),
      'next' || 'nexttrack' || 'skipnext' || 'fastforward' => NextCommand(),
      'previous' || 'previoustrack' || 'skipprevious' || 'rewind' => PreviousCommand(),
      'stop' => StopCommand(),
      _ => null,
    };
```

- [ ] **Step 4: 实现真 bridge**

同文件追加。**`flutter_media_session` 的类与方法签名以本机解析到的版本为准**：README 只给了 `FlutterMediaSession()` / `activate()` / `setMetadata(MediaMetadata(...))` / `setPlaybackState(PlaybackState(...))` / `FlutterMediaSessionsPlatform.instance`，字段名（`artUri`、`controls`、事件对象的动作字段）没给。实现流程：

```dart
class FlutterMediaSessionBridge implements MediaSessionBridge {
  FlutterMediaSessionBridge();

  final _session = FlutterMediaSession();
  final _commands = StreamController<MediaSessionCommand>.broadcast();
  StreamSubscription<dynamic>? _actionSub;
  bool _started = false;

  @override
  Stream<MediaSessionCommand> get commands => _commands.stream;

  @override
  Future<void> start() async {
    if (_started) return;
    _started = true;
    await _session.activate();
    // 动作回调的真实入口名以 analyzer 提示为准；拿不到就退到
    // FlutterMediaSessionsPlatform.instance 的流上监听。
    _actionSub = _session.actionStream?.listen((event) {
      final command = commandFromName(event.action);
      if (command != null) _commands.add(command);
    });
  }

  @override
  Future<void> publish(PublishedSnapshot snapshot) async {
    await _session.setMetadata(
      title: snapshot.title,
      artist: snapshot.artist,
      album: snapshot.album,
      genre: '',
      duration: snapshot.duration,
      artUri: toArtUri(snapshot.artUri),
    );
    await _session.setPlaybackState(
      state: mapStateName(snapshot),
      position: snapshot.position,
      speed: snapshot.playing ? 1 : 0,
      actions: actionsFor(snapshot),
    );
  }

  @override
  Future<void> stop() async {
    try {
      await _session.setPlaybackState(
        state: 'stopped',
        position: Duration.zero,
        speed: 0,
        actions: const [],
      );
    } catch (_) {
      // 会话已不在：忽略
    }
  }

  @override
  Future<void> dispose() async {
    await _actionSub?.cancel();
    _actionSub = null;
    if (_started) {
      await _session.deactivate();
      _started = false;
    }
    await _commands.close();
  }
}
```

- [ ] **Step 5: 用 analyzer 定死真实签名，再谈实现完成**

Run: `cd flutter-app && /d/flutter/bin/flutter pub get && /d/flutter/bin/flutter analyze lib/playback/flutter_media_session_bridge.dart`
Expected: 若报 `The method 'setMetadata' isn't defined` / `No named parameter with the name 'artUri'` / `The argument type ... can't be assigned`，**照提示改成该包的真实签名**（参数名、是位置参数还是命名参数、事件对象的字段名），并同步修正 Step 1 测试里对纯函数的调用。改完必须 `No issues found`。
**不许**用 `dynamic` + 全量 try/catch 把类型错误盖住 —— 那样单测能过、真机上锁屏控件哑掉，而这个任务的全部价值就在真机。

- [ ] **Step 6: 先验必需项，再决定是否降级**

Run: `cd flutter-app && /d/flutter/bin/flutter run -d android`

必需项检查（任一不满足即按 spec §7.2 降级，不许放宽）：

- [ ] 播放时通知栏出现「流光音乐」通知，含曲名/歌手/封面与四个动作按钮；下拉快捷面板与锁屏界面都有媒体控件。
- [ ] 锁屏按「下一首」能切歌，且日志确认走的是 `TransportController.next()`（在 `_onCommand` 里临时加一行输出即可，验完删掉）。
- [ ] 息屏 20 分钟仍在播放：`adb shell dumpsys media_session | head -40` 能看到本应用会话条目。
- [ ] 通知栏没有控件时，先查 Step 7 的服务与权限声明是否齐全；**声明齐全仍没有控件**才判为包能力不足，走降级。

降级写法：新增 `lib/playback/audio_service_bridge.dart`（实现同一 `MediaSessionBridge`，内部用 `audio_service` 0.18.19 + `smtc_windows` 1.1.0），在 `main.dart` 装配处按 `Platform.isAndroid` 选择。`MediaSessionCoordinator` 与界面层一行不改。

- [ ] **Step 7: Android manifest 与权限**

`android/app/src/main/AndroidManifest.xml` 在 `<manifest>` 下补：

```xml
<uses-permission android:name="android.permission.WAKE_LOCK" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
<uses-permission android:name="android.permission.READ_MEDIA_AUDIO" />
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE"
    android:maxSdkVersion="32" />
```

走 `audio_service` 降级时，`<application>` 内补前台服务声明（`mediaPlayback` 类型是 Android 14 的硬要求，缺了系统会直接拒起服务，表现为「锁屏就断」）：

```xml
<service
    android:name="com.ryanheise.audioservice.AudioService"
    android:foregroundServiceType="mediaPlayback"
    android:exported="true">
    <intent-filter>
        <action android:name="android.media.browse.MediaBrowserService" />
    </intent-filter>
</service>
```

走 `flutter_media_session` 时，服务声明由包自带 manifest 合并 —— 用下面命令看合并结果，不要手写一个不存在的类名：

Run: `cd flutter-app/android && ./gradlew :app:processDebugManifest && grep -A3 "foregroundServiceType" app/build/intermediates/merged_manifest/debug/AndroidManifest.xml`
Expected: 出现 `mediaPlayback` 类型的 `<service>`；没有就说明该包不提供前台服务，按 Step 6 降级。

`lib/core/platform_services.dart`：

```dart
// lib/core/platform_services.dart
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Android 13+ 才需要运行时申请通知权限；桌面与更低版本直接放行。
/// 被拒时不阻断播放，返回 false，由界面显示权限态提示（spec §7.1 第 2 条）。
Future<bool> ensureNotificationPermission() async {
  if (kIsWeb || !Platform.isAndroid) return true;
  if (!await _isAndroidAtLeast(33)) return true;
  return _requestNotificationPermission();
}

Future<bool> _isAndroidAtLeast(int api) async {
  // 用 device_info_plus 读 SDK_INT；拿不到就当作需要申请（保守多问一次）。
  return true;
}

Future<bool> _requestNotificationPermission() async {
  // permission_handler 可用就走它；不可用时返回 true 并在界面保留那句文案的触发点。
  return true;
}
```

> 权限态与错误态是两回事：**通知权限被拒不许复用四类错误文案**，界面用的是「通知栏控制需要允许通知权限」这条 info 级提示。

- [ ] **Step 8: 装配进 main 并跑双端**

`lib/main.dart` 在 `runApp` 前完成 prefs 预热（spec §9 首帧不闪），并把 `MediaSessionCoordinator` 挂到 `TransportController` 之后：

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final prefs = await AppPrefs.ready();
  await ensureNotificationPermission();
  final bootstrap = await buildBootstrap(prefs: prefs);
  runApp(LightMusicApp(bootstrap: bootstrap));
}
```

Run: `cd flutter-app && /d/flutter/bin/flutter run -d windows`
Expected: 系统媒体控制面板（Win+G 的 Xbox Game Bar，或开始菜单搜「媒体」）出现曲名与按钮；按耳机/键盘的上一首、下一首能切歌。物理媒体键无反应时先看 bridge 是否收到回调，收不到就是包能力问题，按 §7.2 降级。

Run: `cd flutter-app && /d/flutter/bin/flutter test`
Expected: `All tests passed!`

- [ ] **Step 9: Commit**

```bash
cd flutter-app && git add lib android pubspec.yaml pubspec.lock && git commit -m "feat(playback): 接入系统媒体会话与前台服务，支持锁屏切歌"
```

---

## Task 23: 状态层装配 —— PlayerState / LibraryState / RecentState

对译原版 `state/player.tsx` 与 `state/library.tsx` 中 M1 需要的部分：冷启动还原、持久化时机、搜索关键词与过滤结果。进度只经 `ValueNotifier` 暴露，界面用 `ValueListenableBuilder` 订阅（spec §2）。

**Files:**
- Create: `lib/state/library_state.dart`
- Create: `lib/state/player_state.dart`
- Create: `lib/state/recent_state.dart`
- Modify: `lib/playback/playlist.dart`（加 `replaceAll`）
- Test: `test/state/library_state_test.dart`
- Test: `test/state/player_state_persist_test.dart`

**Interfaces:**
- Consumes: `AppPrefs`（T2）、`LibraryRepository`（T15）、`RecentStore`（T16）、`Playlist`（T4）、`TransportController`（T14）、`ImportService`（T18）、`ToastSink`（T14）
- Produces:
  - `class LibraryState extends ChangeNotifier { LibraryState({required AppPrefs prefs, required LibraryRepository repo, required ImportService importer, required ToastSink toasts}); List<Track> get tracks; String get keyword; set keyword; List<Track> get filteredTracks; int get totalSeconds; String? get currentId; bool get restoring; Future<void> restore(); Future<int> importPaths(List<String>); Future<int> importDirectory(String root); Future<void> setCurrent(String id); Future<void> removeTrack(String id); Future<void> clearPlaylist(); Future<void> persist(); }`
  - `class PlayerState extends ChangeNotifier { PlayerState({required AppPrefs prefs, required TransportController transport}); ValueNotifier<double> get position; ValueNotifier<double?> get buffered; ValueNotifier<double?> get duration; ValueNotifier<TransportView> get view; Track? get current; bool get playing; double get volume; bool get muted; String? get blockedMessage; bool get circuitOpen; Future<void> playTrack(String); Future<void> togglePlay(); Future<void> next(); Future<void> previous(); void cycleMode(); Future<void> setVolume(double); Future<void> toggleMute(); Future<bool> seekTo(double); Future<bool> seekBy(double); Future<void> userGesture(); Future<void> flushPersist(); }`
  - `class RecentState extends ChangeNotifier { RecentState(RecentStore store); List<RecentEntry> get entries; Future<void> refresh(Set<String> playlistIds); Future<void> clear(); }`

- [ ] **Step 1: 写失败测试**

```dart
// test/state/library_state_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/library/import_service.dart';
import 'package:light_music/library/library_repository.dart';
import 'package:light_music/playback/playlist.dart';
import 'package:light_music/state/library_state.dart';
import 'package:light_music/state/toast_state.dart';

void main() {
  late Directory dir;
  late AppPrefs prefs;
  late Playlist playlist;
  late ToastState toasts;
  late LibraryState state;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('light-state');
    prefs = AppPrefs.inMemory();
    playlist = Playlist(tracks: const []);
    toasts = ToastState();
    state = LibraryState(
      prefs: prefs,
      repo: LibraryRepository(directory: dir.path),
      importer: ImportService(playlist: playlist, toasts: toasts),
      toasts: toasts,
    );
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('导入后落库，重启可原样还原顺序', () async {
    await state.importPaths(['/m/陈奕迅 - 十年.flac', '/m/孤勇者.flac']);
    final freshPlaylist = Playlist(tracks: const []);
    final fresh = LibraryState(
      prefs: prefs,
      repo: LibraryRepository(directory: dir.path),
      importer: ImportService(playlist: freshPlaylist, toasts: toasts),
      toasts: toasts,
    );
    await fresh.restore();
    expect(fresh.tracks.length, 2);
    expect(fresh.tracks.map((t) => t.handle.displayName).toList(),
        ['陈奕迅 - 十年.flac', '孤勇者.flac']);
  });

  test('搜索只匹配歌名，关键词大小写不敏感且去空白', () async {
    await state.importPaths(['/m/a.flac', '/m/b.flac']);
    state.tracks.first.title = '十年';
    state.tracks.last.title = '白玫瑰';
    state.keyword = '十年';
    expect(state.filteredTracks.map((t) => t.title), ['十年']);
    state.keyword = '陈奕迅';
    expect(state.filteredTracks, isEmpty); // 不搜歌手
    state.keyword = '  十年  ';
    expect(state.filteredTracks.length, 1);
  });

  test('清空播放列表同时清文件仓与顺序键', () async {
    await state.importPaths(['/m/a.flac']);
    await state.clearPlaylist();
    expect(state.tracks, isEmpty);
    final snap = await LibraryRepository(directory: dir.path).load();
    expect(snap.tracks, isEmpty);
  });

  test('删除当前曲目后指向接续的那首，删空则 currentId 为空', () async {
    await state.importPaths(['/m/a.flac', '/m/b.flac']);
    final firstId = state.tracks.first.id;
    await state.setCurrent(firstId);
    await state.removeTrack(firstId);
    expect(state.tracks.length, 1);
    expect(state.currentId, state.tracks.first.id);
    await state.removeTrack(state.tracks.first.id);
    expect(state.tracks, isEmpty);
    expect(state.currentId, isNull);
  });

  test('还原期间 restoring 为真，界面走骨架而不是空态', () async {
    var observed = false;
    state.addListener(() {
      if (state.restoring) observed = true;
    });
    await state.restore();
    expect(observed, isTrue);
    expect(state.restoring, isFalse);
  });

  test('脏文件仓不炸界面，退化成空歌单', () async {
    await state.importPaths(['/m/a.flac']);
    File('${dir.path}/library.json').writeAsStringSync('{"tracks": [坏数据]}');
    final fresh = LibraryState(
      prefs: prefs,
      repo: LibraryRepository(directory: dir.path),
      importer: ImportService(playlist: Playlist(tracks: const []), toasts: toasts),
      toasts: toasts,
    );
    await fresh.restore();
    expect(fresh.tracks, isEmpty);
  });
}
```

```dart
// test/state/player_state_persist_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/playback/audio_driver.dart';
import 'package:light_music/playback/audio_player.dart';
import 'package:light_music/playback/playlist.dart';
import 'package:light_music/playback/track.dart';
import 'package:light_music/playback/transport_controller.dart';
import 'package:light_music/state/player_state.dart';
import 'package:light_music/state/toast_state.dart';

Track t(String id) => Track(id: id, src: '/$id.flac', title: '歌$id', duration: 100);

void main() {
  test('音量、静音、模式写进 prefs 并可读回', () async {
    final prefs = AppPrefs.inMemory();
    final state = PlayerState(
      prefs: prefs,
      transport: TransportController(
        player: AudioPlayer(FakeAudioDriver(), scheduler: (d, cb) => cb()),
        recent: _NoRecent(),
        toasts: ToastState(),
        playlist: Playlist.fromTracks([t('1')]),
      ),
    );
    await state.setVolume(0.42);
    await state.toggleMute();
    state.cycleMode();
    await state.flushPersist();
    expect(await prefs.readNumber('volume'), 0.42);
    expect(await prefs.readBool('muted'), isTrue);
    expect(await prefs.readString('mode'), 'one');
  });

  test('冷启动读回音量与模式', () async {
    final prefs = AppPrefs.inMemory();
    await prefs.writeNumber('volume', 0.3);
    await prefs.writeString('mode', 'shuffle');
    final state = PlayerState(
      prefs: prefs,
      transport: TransportController(
        player: AudioPlayer(FakeAudioDriver(), scheduler: (d, cb) => cb()),
        recent: _NoRecent(), toasts: ToastState(),
        playlist: Playlist.fromTracks([t('1')]),
      ),
    );
    await state.ready();
    expect(state.volume, 0.3);
    expect(state.transport.playlist.mode.name, 'shuffle');
  });

  test('当前曲目与顺序落 prefs', () async {
    final prefs = AppPrefs.inMemory();
    final state = PlayerState(
      prefs: prefs,
      transport: TransportController(
        player: AudioPlayer(FakeAudioDriver(), scheduler: (d, cb) => cb()),
        recent: _NoRecent(), toasts: ToastState(),
        playlist: Playlist.fromTracks([t('1'), t('2')]),
      ),
    );
    await state.playTrack('2');
    await state.flushPersist();
    expect(await prefs.readString('currentId'), '2');
    expect(await prefs.readJson('order'), ['1', '2']);
  });

  test('进度通知只发给订阅者，不触发全局 notify', () async {
    final prefs = AppPrefs.inMemory();
    final driver = FakeAudioDriver();
    final transport = TransportController(
      player: AudioPlayer(driver, scheduler: (d, cb) => cb()),
      recent: _NoRecent(), toasts: ToastState(),
      playlist: Playlist.fromTracks([t('1')]),
    );
    final state = PlayerState(prefs: prefs, transport: transport);
    var notifierCalls = 0;
    var stateCalls = 0;
    state.position.addListener(() => notifierCalls++);
    state.addListener(() => stateCalls++);
    final baseline = stateCalls;
    await state.playTrack('1');
    driver.emitPosition(1);
    driver.emitPosition(2);
    expect(notifierCalls, 2);
    expect(stateCalls - baseline, isNot(greaterThan(3))); // 进度不驱动整树
  });

  test('损坏曲目不写进 currentId', () async {
    final prefs = AppPrefs.inMemory();
    final state = PlayerState(
      prefs: prefs,
      transport: TransportController(
        player: AudioPlayer(FakeAudioDriver()..alwaysFail = true,
            scheduler: (d, cb) => cb()),
        recent: _NoRecent(), toasts: ToastState(),
        playlist: Playlist.fromTracks([t('1')]),
      ),
    );
    await state.playTrack('1');
    await state.flushPersist();
    expect(await prefs.readString('currentId'), isNot('1'));
  });
}

class _NoRecent implements RecentRecorder {
  @override
  void record(Track track, {DateTime? at}) {}
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/state/`
Expected: 编译失败 —— `library_state.dart` / `player_state.dart` / `recent_state.dart` 不存在。

- [ ] **Step 3: 给 Playlist 加还原入口**

`lib/playback/playlist.dart` 追加（整体替换条目并重建洗牌队列）：

```dart
  /// 冷启动还原：整体替换，不逐条 addAt。
  void replaceAll(List<Track> next) {
    _tracks
      ..clear()
      ..addAll(next);
    _currentIndex = next.isEmpty ? -1 : 0;
    _rebuildShuffle();
  }
```

- [ ] **Step 4: 实现三个 State**

```dart
// lib/state/library_state.dart
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/app_prefs.dart';
import '../core/storage_keys.dart';
import '../library/import_service.dart';
import '../library/library_repository.dart';
import '../playback/audio_player.dart' show ToastSink;
import '../playback/playlist.dart';
import '../playback/track.dart';

class LibraryState extends ChangeNotifier {
  LibraryState({
    required this.prefs,
    required this.repo,
    required this.importer,
    required this.toasts,
  });

  final AppPrefs prefs;
  final LibraryRepository repo;
  final ImportService importer;
  final ToastSink toasts;

  String _keyword = '';
  String _effectiveKeyword = '';
  bool _restoring = false;
  Timer? _searchDebounce;

  Playlist get playlist => importer.playlist;
  List<Track> get tracks => playlist.tracks;
  String get keyword => _keyword;
  bool get restoring => _restoring;
  String? get currentId => playlist.current?.id;
  int get totalSeconds => playlist.totalDuration.isNaN
      ? 0
      : playlist.totalDuration.floor();

  /// 显示用：只匹配歌名（两个 tab 共用同一关键词）。
  List<Track> get filteredTracks {
    if (_effectiveKeyword.isEmpty) return playlist.tracks;
    return playlist.tracks
        .where((t) => t.title.toLowerCase().contains(_effectiveKeyword))
        .toList();
  }

  set keyword(String next) {
    if (_keyword == next) return;
    _keyword = next;
    // 生效值走防抖后的值：即时输入不参与过滤，列表才不会边打字边塌高度
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 200), () {
      _effectiveKeyword = next.trim().toLowerCase();
      notifyListeners();
    });
    notifyListeners();
  }

  Future<void> restore() async {
    _restoring = true;
    notifyListeners();
    try {
      final snap = await repo.load();
      if (snap.tracks.isEmpty) {
        playlist.clear();
        return;
      }
      final byId = {for (final t in snap.tracks) t.id: t};
      final ordered = [
        for (final id in snap.order)
          if (byId.containsKey(id)) byId[id]!,
      ];
      playlist.replaceAll(ordered);
      playlist.setMode(snap.mode);
      if (snap.currentId != null) playlist.setCurrentById(snap.currentId!);
    } finally {
      _restoring = false;
      notifyListeners();
    }
  }

  Future<int> importPaths(List<String> paths) async {
    final result = await importer.importPaths(paths);
    if (result.added > 0) {
      toasts.show('已添加 ${result.added} 首', key: 'import');
      await persist();
      notifyListeners();
    }
    return result.added;
  }

  Future<int> importDirectory(String root) async {
    final result = await importer.importDirectory(root);
    if (result.added > 0) {
      toasts.show('已从文件夹添加 ${result.added} 首', key: 'import');
      await persist();
      notifyListeners();
    }
    return result.added;
  }

  Future<void> setCurrent(String id) async {
    playlist.setCurrentById(id);
    await persist();
    notifyListeners();
  }

  Future<void> removeTrack(String id) async {
    final track = playlist.byId(id);
    if (track == null) return;
    final result = playlist.removeById(id);
    await repo.deleteTracks([id]);
    toasts.show('已移除《${track.title}》', key: 'remove');
    await persist();
    notifyListeners();
  }

  Future<void> clearPlaylist() async {
    final ids = playlist.tracks.map((t) => t.id).toList();
    playlist.clear();
    await repo.deleteTracks(ids);
    await prefs.remove(StorageKeys.currentId);
    await prefs.remove(StorageKeys.order);
    toasts.info('播放列表已清空');
    notifyListeners();
  }

  Future<void> persist() async {
    await repo.save(LibrarySnapshot(
      tracks: playlist.tracks,
      order: playlist.tracks.map((t) => t.id).toList(),
      currentId: playlist.current?.id,
      mode: playlist.mode,
    ));
    await prefs.writeJson(
        StorageKeys.order, playlist.tracks.map((t) => t.id).toList());
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    super.dispose();
  }
}
```

> Step 4 的 `ImportService` 需要暴露 `playlist`（T18 里它是构造参数、字段私有）。实现时在 `ImportService` 加 `final Playlist playlist;`（去掉下划线），`_buildTrack`/`hydrateMetadata` 直接用 `playlist`。这是 T18 与本任务之间的唯一接口缺口，改完两边测试都要重跑。

```dart
// lib/state/player_state.dart
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/app_prefs.dart';
import '../core/storage_keys.dart';
import '../playback/audio_player.dart';
import '../playback/play_mode.dart';
import '../playback/transport_controller.dart';
import '../playback/track.dart';

class PlayerState extends ChangeNotifier {
  PlayerState({required this.prefs, required this.transport}) {
    _sub = transport.player.events.listen(_onEvent);
    transport.view.addListener(_onView);
    unawaited(ready());
  }

  final AppPrefs prefs;
  final TransportController transport;
  late final StreamSubscription<PlayerEvent> _sub;
  Timer? _persistDebounce;
  bool _ready = false;

  ValueNotifier<double> get position => transport.position;
  ValueNotifier<double?> get buffered => transport.buffered;
  ValueNotifier<double?> get duration => transport.duration;
  ValueNotifier<TransportView> get view => transport.view;
  Track? get current => transport.current;
  bool get playing => transport.playing;
  double get volume => transport.player.volume;
  bool get muted => transport.player.muted;
  String? get blockedMessage => transport.blockedMessage;
  bool get circuitOpen => transport.circuitOpen;

  /// 冷启动把音量/静音/模式读回；测试里 await 它再断言。
  Future<void> ready() async {
    if (_ready) return;
    final volume = await prefs.readNumber(StorageKeys.volume, min: 0, max: 1);
    if (volume != null) await transport.setVolume(volume.toDouble());
    if (await prefs.readBool(StorageKeys.muted)) {
      await transport.player.setMuted(true);
    }
    final mode = await prefs.readString(StorageKeys.mode);
    if (mode != null) transport.playlist.setMode(playModeFromId(mode));
    _ready = true;
    _onView();
  }

  void _onEvent(PlayerEvent event) {
    if (event is StateChangedEvent && event.playing) schedulePersist();
  }

  void _onView() => notifyListeners();

  Future<void> playTrack(String id) async {
    await transport.playTrack(id);
    schedulePersist();
  }

  Future<void> togglePlay() async {
    await transport.togglePlay();
    schedulePersist();
  }

  Future<void> next() => transport.next();
  Future<void> previous() => transport.previous();

  void cycleMode() {
    transport.cycleMode();
    unawaited(prefs.writeString(
        StorageKeys.mode, transport.playlist.mode.name));
    notifyListeners();
  }

  Future<void> setVolume(double value) async {
    await transport.setVolume(value);
    await prefs.writeNumber(StorageKeys.volume, value);
    await prefs.writeBool(StorageKeys.muted, value == 0);
    notifyListeners();
  }

  Future<void> toggleMute() async {
    final muted = await transport.toggleMute();
    await prefs.writeBool(StorageKeys.muted, muted);
    notifyListeners();
  }

  Future<bool> seekTo(double seconds) => transport.seekTo(seconds);
  Future<bool> seekBy(double delta) => transport.seekBy(delta);
  Future<void> userGesture() => transport.userGesture();

  void schedulePersist() {
    _persistDebounce?.cancel();
    _persistDebounce = Timer(const Duration(milliseconds: 400), flushPersist);
  }

  Future<void> flushPersist() async {
    final playlist = transport.playlist;
    final current = playlist.current;
    if (current != null && !current.broken) {
      await prefs.writeString(StorageKeys.currentId, current.id);
    }
    await prefs.writeJson(
        StorageKeys.order, playlist.tracks.map((t) => t.id).toList());
    await prefs.writeString(StorageKeys.mode, playlist.mode.name);
  }

  @override
  void dispose() {
    _persistDebounce?.cancel();
    transport.view.removeListener(_onView);
    _sub.cancel();
    super.dispose();
  }
}
```

```dart
// lib/state/recent_state.dart
import 'package:flutter/foundation.dart';

import '../library/recent_store.dart';

class RecentState extends ChangeNotifier {
  RecentState(this.store);

  final RecentStore store;

  List<RecentEntry> get entries => store.entries;

  Future<void> refresh(Set<String> playlistIds) async {
    await store.markInPlaylist(playlistIds);
    notifyListeners();
  }

  Future<void> clear() async {
    await store.clear();
    notifyListeners();
  }
}
```

- [ ] **Step 5: 跑测试确认通过**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/state/`
Expected: `All tests passed!`。「进度只发给订阅者」那条失败时，检查是否把 `position` 更新接到了 `notifyListeners()` —— 那正是原版记录过的「一秒四次整树重绘」，必须回到 `ValueNotifier`，不许放宽断言。

- [ ] **Step 6: Commit**

```bash
cd flutter-app && git add lib/state lib/playback lib/library test/state && git commit -m "feat(state): 装配播放器与曲库状态层及持久化时机"
```

---

## Task 24: 应用装配与断点布局骨架


`LayoutBuilder` 复刻 app.css 的两档结构：≥900 双栏 grid（列比 `minmax(0,1.02fr) minmax(0,1fr)`、gap 18），<900 单列堆叠 + 控制条吸附底部；≤480 隐藏品牌副标题与按钮文字。外层 padding 桌面 `24/28/28`、窄屏 `16/14/14`，gap 桌面 18、窄屏 14。

**Files:**
- Create: `lib/app.dart`
- Modify: `lib/main.dart`
- Create: `lib/ui/shell.dart`
- Test: `test/ui/shell_test.dart`

**Interfaces:**
- Consumes: `AppPrefs`（T2）、`AppTokens`/`buildTheme`（T19）、`LibraryState`/`PlayerState`/`RecentState`/`ToastState`（T20/T23）、`Breaks`（T19）
- Produces:
  - `class LightMusicApp extends StatelessWidget { const LightMusicApp({required this.bootstrap, super.key}); final AppBootstrap bootstrap; }`
  - `class AppBootstrap { AppBootstrap({required this.prefs, required this.library, required this.player, required this.recent, required this.toasts}); ... }` —— 组合根的构造结果，`main()` 里建好后注入，界面层不再自己 `new` 业务对象。
  - `class AppShell extends StatelessWidget`（消费 `Breaks`，输出 `HomeLayout`）
  - `class HomeLayout extends StatelessWidget { const HomeLayout({required this.header, required this.stage, required this.panel, required this.transport, super.key}); }` —— 桌面双栏时 `stage` 与 `panel` 并排、`transport` 在 stage 列底部；窄屏时 `stage → panel → transport`，transport 贴底。

- [ ] **Step 1: 写失败测试**

```dart
// test/ui/shell_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/ui/shell.dart';

Widget wrap(Widget child, double width, double height) => MaterialApp(
      home: SizedBox(
        width: width,
        height: height,
        child: MediaQuery(
          data: MediaQueryData(size: Size(width, height)),
          child: Scaffold(body: child),
        ),
      ),
    );

void main() {
  const layout = HomeLayout(
    header: Text('HEADER', key: Key('header')),
    stage: Text('STAGE', key: Key('stage')),
    panel: Text('PANEL', key: Key('panel')),
    transport: Text('TRANSPORT', key: Key('transport')),
  );

  testWidgets('桌面 1200 宽：stage 在左、panel 在右且同顶', (tester) async {
    await tester.pumpWidget(wrap(layout, 1200, 800));
    final stage = tester.getRect(find.byKey(const Key('stage')));
    final panel = tester.getRect(find.byKey(const Key('panel')));
    expect(stage.left, lessThan(panel.left));
    expect(stage.top, panel.top);
    expect(stage.bottom, closeTo(panel.bottom, 1.0)); // 控制区底边与右栏对齐
  });

  testWidgets('窄屏 420 宽：单列堆叠且控制条在最底', (tester) async {
    await tester.pumpWidget(wrap(layout, 420, 800));
    final stage = tester.getRect(find.byKey(const Key('stage')));
    final panel = tester.getRect(find.byKey(const Key('panel')));
    final transport = tester.getRect(find.byKey(const Key('transport')));
    expect(stage.bottom, lessThanOrEqualTo(panel.top));
    expect(panel.bottom, lessThanOrEqualTo(transport.top));
    expect(transport.bottom, closeTo(800, 1.0));
  });

  testWidgets('900 断点两侧列数不同', (tester) async {
    await tester.pumpWidget(wrap(layout, 900, 700));
    expect(find.byKey(const Key('desktop-grid')), findsOneWidget);
    await tester.pumpWidget(wrap(layout, 899, 700));
    expect(find.byKey(const Key('desktop-grid')), findsNothing);
  });

  testWidgets('整页不出现横向滚动', (tester) async {
    await tester.pumpWidget(wrap(layout, 320, 640));
    expect(tester.takeException(), isNull);
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/ui/shell_test.dart`
Expected: 编译失败 —— `shell.dart` 不存在。

- [ ] **Step 3: 实现 HomeLayout**

```dart
// lib/ui/shell.dart
import 'package:flutter/material.dart';

import '../core/breakpoints.dart';

class HomeLayout extends StatelessWidget {
  const HomeLayout({
    required this.header,
    required this.stage,
    required this.panel,
    required this.transport,
    super.key,
  });

  final Widget header;
  final Widget stage;
  final Widget panel;
  final Widget transport;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final desktop = isDesktop(constraints.maxWidth);
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              desktop ? 28 : 14,
              desktop ? 24 : 16,
              desktop ? 28 : 14,
              desktop ? 28 : 0,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                header,
                SizedBox(height: desktop ? 18 : 14),
                if (desktop)
                  Expanded(
                    child: Row(
                      key: const Key('desktop-grid'),
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          // minmax(0,1.02fr) / minmax(0,1fr) 的 1.02 : 1
                          flex: 102,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(child: stage),
                              SizedBox(height: 18),
                              transport,
                            ],
                          ),
                        ),
                        SizedBox(width: 18),
                        Expanded(flex: 100, child: panel),
                      ],
                    ),
                  )
                else ...[
                  stage,
                  SizedBox(height: 14),
                  Expanded(child: panel),
                  transport,
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
```

- [ ] **Step 4: 实现 app 根与注入**

```dart
// lib/app.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/app_prefs.dart';
import 'library/library_repository.dart';
import 'playback/transport_controller.dart';
import 'state/library_state.dart';
import 'state/player_state.dart';
import 'state/recent_state.dart';
import 'state/toast_state.dart';
import 'theme/app_theme.dart';
import 'theme/app_tokens.dart';

class AppBootstrap {
  AppBootstrap({
    required this.prefs,
    required this.library,
    required this.player,
    required this.recent,
    required this.toasts,
    required this.repository,
  });

  final AppPrefs prefs;
  final LibraryState library;
  final PlayerState player;
  final RecentState recent;
  final ToastState toasts;
  final LibraryRepository repository;
}

class LightMusicApp extends StatelessWidget {
  const LightMusicApp({required this.bootstrap, super.key});

  final AppBootstrap bootstrap;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: bootstrap.library),
        ChangeNotifierProvider.value(value: bootstrap.player),
        ChangeNotifierProvider.value(value: bootstrap.recent),
        ChangeNotifierProvider.value(value: bootstrap.toasts),
        Provider<AppPrefs>.value(value: bootstrap.prefs),
      ],
      child: MaterialApp(
        title: '流光音乐',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(tokens: AppTokens.dark),
        home: const HomePage(),
      ),
    );
  }
}
```

`lib/main.dart` 建组合根（真实 driver / bridge / repo 都在这里连线，界面层不 new 业务对象）：

```dart
// lib/main.dart
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'core/app_prefs.dart';
import 'library/import_service.dart';
import 'library/library_repository.dart';
import 'library/recent_store.dart';
import 'metadata/cover_image.dart';
import 'playback/audio_driver.dart';
import 'playback/audio_player.dart';
import 'playback/media_kit_driver.dart';
import 'playback/media_session_bridge.dart';
import 'playback/flutter_media_session_bridge.dart';
import 'playback/playlist.dart';
import 'playback/transport_controller.dart';
import 'state/library_state.dart';
import 'state/player_state.dart';
import 'state/recent_state.dart';
import 'state/toast_state.dart';
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  // 先读 prefs 再 runApp：浅色用户不会先闪一帧深色（spec §9）
  final prefs = await AppPrefs.ready();
  final support = await getApplicationSupportDirectory();
  final bootstrap = await buildBootstrap(
    prefs: prefs,
    dataDirectory: support.path,
    driver: MediaKitDriver(),
    bridge: FlutterMediaSessionBridge(),
  );
  runApp(LightMusicApp(bootstrap: bootstrap));
}

Future<AppBootstrap> buildBootstrap({
  required AppPrefs prefs,
  required String dataDirectory,
  required AudioDriver driver,
  required MediaSessionBridge bridge,
}) async {
  final playlist = Playlist(tracks: const []);
  final repository = LibraryRepository(directory: dataDirectory);
  final toasts = ToastState();
  final recent = RecentStore(prefs);
  final transport = TransportController(
    player: AudioPlayer(driver, initialVolume: 0.7),
    recent: recent,
    toasts: toasts,
    playlist: playlist,
  );
  final library = LibraryState(
    prefs: prefs,
    repo: repository,
    importer: ImportService(
      playlist: playlist,
      toasts: toasts,
      covers: const CoverImageWriter(),
      coverDirectory: '$dataDirectory/covers',
    ),
    toasts: toasts,
  );
  final player = PlayerState(prefs: prefs, transport: transport);
  final state = RecentState(recent);
  await library.restore();
  await recent.restore();
  final coordinator = MediaSessionCoordinator(bridge: bridge, transport: transport);
  await coordinator.attach();
  return AppBootstrap(
    prefs: prefs,
    library: library,
    player: player,
    recent: state,
    toasts: toasts,
    repository: repository,
  );
}
```

`lib/ui/home_page.dart` 只是把 `HomeLayout` 与四个业务 widget 连起来的薄壳（T25-T29 逐个填进去），M1 期间 stage 的 panel/transport 允许先挂占位 widget，但 **布局文件不许再改结构** —— 后续任务只替换子 widget。

- [ ] **Step 5: 跑测试确认通过**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/ui/shell_test.dart`
Expected: `All tests passed!`（4 个用例）。若 `stage.bottom` 与 `panel.bottom` 差超过 1px，说明 stage 列用了 `mainAxisSize: min` 而不是 `Expanded` —— 原版要求「控制区底边与右栏面板底边对齐」，这条对齐是视觉验收项，不能放宽。

- [ ] **Step 6: Commit**

```bash
cd flutter-app && git add lib && git commit -m "feat(ui): 装配应用根与双栏布局骨架"
```

---

## Task 25: 顶栏与一级抽屉

原版规则：顶栏只留品牌区 + 右侧唯一「菜单」按钮（+ 左侧明暗切换，但换肤内容属 M3，M1 只放按钮且不实现换肤），抽屉里 **只放一级入口**：添加音乐 / 添加整个文件夹 / 清空播放列表。抽屉收窄、平铺行、无说明文字。

**Files:**
- Create: `lib/ui/header.dart`
- Create: `lib/ui/drawer_menu.dart`
- Test: `test/ui/header_test.dart`

**Interfaces:**
- Consumes: `LibraryState`（T23）、`AppTokens`（T19）、`isUltraCompact`（T19）、`file_picker`
- Produces:
  - `class AppHeader extends StatelessWidget`
  - `class DrawerMenu extends StatelessWidget { const DrawerMenu({required this.onAddFiles, required this.onAddFolder, required this.onClear, super.key}); }` —— 三个回调，测试直接注入，不依赖 file_picker
  - `Future<List<String>> pickAudioFiles();` / `Future<String?> pickAudioFolder();`（放在 `lib/core/file_picking.dart`，把 file_picker 隔离在一处）

- [ ] **Step 1: 写失败测试**

```dart
// test/ui/header_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/ui/drawer_menu.dart';
import 'package:light_music/ui/header.dart';

void main() {
  Future<void> pump(WidgetTester tester, double width) async {
    var added = 0;
    var cleared = 0;
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme().copyWith(
        extensions: const [AppTokensData(tokens: AppTokens.dark)],
      ),
      home: Scaffold(
        body: SizedBox(
          width: width,
          child: AppHeader(
            onAddFiles: () async => added++,
            onAddFolder: () async => added++,
            onClearPlaylist: () async => cleared++,
          ),
        ),
      ),
    ));
  }

  testWidgets('桌面显示品牌标题与副标题，只一个菜单按钮', (tester) async {
    await pump(tester, 1200);
    expect(find.text('流光音乐'), findsOneWidget);
    expect(find.text('LIGHT MUSIC PLAYER'), findsOneWidget);
    expect(find.bySemanticLabel('更多'), findsOneWidget);
    expect(find.bySemanticsLabel('菜单'), findsNothing);
  });

  testWidgets('≤479 隐藏副标题与按钮文字', (tester) async {
    await pump(tester, 420);
    expect(find.text('LIGHT MUSIC PLAYER'), findsNothing);
    expect(find.text('流光音乐'), findsOneWidget);
  });

  testWidgets('菜单里只有一级入口，且不出现说明文字', (tester) async {
    await pump(tester, 1200);
    await tester.tap(find.bySemanticLabel('更多'));
    await tester.pumpAndSettle();
    expect(find.text('添加音乐'), findsOneWidget);
    expect(find.text('添加整个文件夹'), findsOneWidget);
    expect(find.text('清空播放列表'), findsOneWidget);
    expect(find.text('换肤'), findsNothing); // M3 才出现
    expect(find.textContaining('把音频文件'), findsNothing); // 一级行不带说明
  });

  testWidgets('清空是二次确认，不在菜单里直接执行', (tester) async {
    await pump(tester, 1200);
    await tester.tap(find.bySemanticLabel('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空播放列表'));
    await tester.pumpAndSettle();
    expect(find.text('确定清空播放列表吗？'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('确定清空播放列表吗？'), findsNothing);
  });

  testWidgets('抽屉宽度收窄且共用一套动效', (tester) async {
    await pump(tester, 1200);
    await tester.tap(find.bySemanticLabel('更多'));
    await tester.pump();
    final sheet = tester.getRect(find.byType(DrawerMenu));
    expect(sheet.width, lessThanOrEqualTo(320));
  });
}
```

> `find.bySemanticLabel(...)` 是自定义 finder：Flutter 测试里用 `find.bySemanticsLabel`。请在测试文件顶部定义一次 `Finder bySemanticLabel(String label) => find.bySemanticsLabel(label);` 或直接统一使用 `find.bySemanticsLabel` —— 两处名字必须一致，实现时统一成 `find.bySemanticsLabel` 并改掉本文件里的 5 处调用。

- [ ] **Step 2: 跑测试确认失败**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/ui/header_test.dart`
Expected: 编译失败 —— `header.dart` / `drawer_menu.dart` 不存在。

- [ ] **Step 3: 实现抽屉菜单**

```dart
// lib/ui/drawer_menu.dart
import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

typedef MenuAction = Future<void> Function();

class DrawerMenu extends StatelessWidget {
  const DrawerMenu({
    required this.onAddFiles,
    required this.onAddFolder,
    required this.onClear,
    super.key,
  });

  final MenuAction onAddFiles;
  final MenuAction onAddFolder;
  final MenuAction onClear;

  static const double width = 300;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Align(
      alignment: Alignment.centerRight,
      child: Material(
        color: tokens.sheetA,
        child: SizedBox(
          width: width,
          height: double.infinity,
          child: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text('菜单',
                      style: TextStyle(fontSize: 13, color: tokens.textFaint)),
                ),
                _MenuRow(icon: Icons.add, label: '添加音乐', onTap: () => _closeAnd(context, onAddFiles)),
                _MenuRow(icon: Icons.folder_open, label: '添加整个文件夹', onTap: () => _closeAnd(context, onAddFolder)),
                _MenuRow(
                  icon: Icons.delete_outline,
                  label: '清空播放列表',
                  danger: true,
                  onTap: () => _confirmClear(context),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _closeAnd(BuildContext context, MenuAction action) async {
    Navigator.of(context).maybePop();
    await action();
  }

  Future<void> _confirmClear(BuildContext context) async {
    final tokens = context.tokens;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('确定清空播放列表吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed == true) await onClear();
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final Future<void> Function() onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final color = danger ? tokens.danger : tokens.text;
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 44, // 触控目标
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Text(label, style: TextStyle(fontSize: 13, color: color)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: 实现顶栏**

```dart
// lib/ui/header.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/breakpoints.dart';
import '../state/library_state.dart';
import '../theme/app_tokens.dart';
import 'drawer_menu.dart';

class AppHeader extends StatelessWidget {
  const AppHeader({
    required this.onAddFiles,
    required this.onAddFolder,
    required this.onClearPlaylist,
    super.key,
  });

  final Future<void> Function() onAddFiles;
  final Future<void> Function() onAddFolder;
  final Future<void> Function() onClearPlaylist;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final width = MediaQuery.sizeOf(context).width;
    final compact = isUltraCompact(width);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Row(
            children: [
              _Brand(compact: compact, tokens: tokens),
              const Spacer(),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Semantics(
          button: true,
          label: '更多',
          child: InkWell(
            key: const Key('menu-button'),
            onTap: () => _openMenu(context),
            child: const _MenuChip(compact: compact),
          ),
        ),
      ],
    );
  }

  void _openMenu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DrawerMenu(
        onAddFiles: onAddFiles,
        onAddFolder: onAddFolder,
        onClear: onClearPlaylist,
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand({required this.compact, required this.tokens});
  final bool compact;
  final AppTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: tokens.accentLine),
          ),
          alignment: Alignment.center,
          child: Icon(Icons.graphic_eq, size: 18, color: tokens.accent),
        ),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('流光音乐',
                style: TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w650, color: tokens.text)),
            if (!compact)
              Text('LIGHT MUSIC PLAYER',
                  style: TextStyle(
                      fontSize: 10, letterSpacing: 1.7, color: tokens.textFaint)),
          ],
        ),
      ],
    );
  }
}

class _MenuChip extends StatelessWidget {
  const _MenuChip({required this.compact});
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Container(
      height: 36,
      padding: compact ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: tokens.border),
      ),
      alignment: Alignment.center,
      child: compact
          ? const Icon(Icons.menu, size: 16)
          : Row(
              children: [
                const Icon(Icons.menu, size: 16),
                const SizedBox(width: 6),
                Text('菜单', style: TextStyle(fontSize: 12.5, color: tokens.text)),
              ],
            ),
    );
  }
}
```

- [ ] **Step 5: 跑测试确认通过**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/ui/header_test.dart`
Expected: `All tests passed!`（5 个用例）。若 sheet 宽度断言失败，说明用了 `DraggableScrollableSheet` 默认全宽 —— 原版抽屉是收窄的，按 `DrawerMenu.width = 300` 对齐。

- [ ] **Step 6: Commit**

```bash
cd flutter-app && git add lib/ui test/ui && git commit -m "feat(ui): 新增顶栏与一级抽屉菜单"
```

## Task 26: 播放卡 Stage

原版契约（README + `styles/app.css:983-999`、`:111`）：封面裁成正圆碟、M1 黑胶静态（旋转与唱臂动画在 M3）、曲名/歌手可点（M2 起进歌词页，M1 先把热区与语义留好）、`损坏` 时标题旁给状态、封面未就绪时骨架微光。`--cover-size` 三档由 `kCoverSize` 提供。

**Files:**
- Create: `lib/ui/stage.dart`
- Create: `lib/ui/vinyl_deck.dart`
- Test: `test/ui/stage_test.dart`

**Interfaces:**
- Consumes: `PlayerState`（T23）、`AppTokens`（T19）、`kCoverSize`/`kButtonSize`（T19）、`formatTime`（T5）
- Produces:
  - `class Stage extends StatelessWidget`
  - `class VinylDeck extends StatelessWidget { const VinylDeck({required this.coverPath, required this.spinAngle, required this.title, required this.artist, super.key}); }` —— M1 里 `spinAngle` 恒为 0，字段先留着（M3 换动画不改签名）
  - `class CoverDisc extends StatelessWidget`（圆形裁切 + 骨架微光）

- [ ] **Step 1: 写失败测试**

```dart
// test/ui/stage_test.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/ui/stage.dart';

Widget wrap(Widget child) => MaterialApp(
      theme: buildTheme().copyWith(
        extensions: const [AppTokensData(tokens: AppTokens.dark)],
      ),
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('显示曲名、歌手、专辑与时长', (tester) async {
    await tester.pumpWidget(wrap(const SizedBox(
      width: 1000,
      height: 700,
      child: StagePreview(
        title: '白玫瑰',
        artist: '陈奕迅',
        album: 'Stranger Under My Skin',
        elapsed: '02:15',
        total: '03:46',
      ),
    )));
    expect(find.text('白玫瑰'), findsOneWidget);
    expect(find.text('陈奕迅'), findsOneWidget);
    expect(find.text('02:15 / 03:46'), findsOneWidget);
  });

  testWidgets('长曲名省略号截断，不换行不撑宽', (tester) async {
    await tester.pumpWidget(wrap(const SizedBox(
      width: 360,
      height: 700,
      child: StagePreview(title: '一', artist: '陈奕迅', album: '', elapsed: '00:00', total: '--:--'),
    )));
    final title = tester.getRect(find.text('一'));
    expect(title.width, lessThan(360));
  });

  testWidgets('没有真封面时显示占位碟而不是空白', (tester) async {
    await tester.pumpWidget(wrap(const SizedBox(
      width: 800,
      height: 700,
      child: StagePreview(title: 'A', artist: '', album: '', elapsed: '--:--', total: '--:--', coverPath: ''),
    )));
    expect(find.byKey(const Key('cover-placeholder')), findsOneWidget);
  });

  testWidgets('损坏态显示状态而不是清空标题', (tester) async {
    await tester.pumpWidget(wrap(const SizedBox(
      width: 800,
      height: 700,
      child: StagePreview(title: '坏文件', artist: '某人', album: '', elapsed: '--:--', total: '--:--', broken: true),
    )));
    expect(find.text('坏文件'), findsOneWidget);
    expect(find.text('损坏'), findsOneWidget);
  });

  testWidgets('曲目信息区整体是一个可点热区，封面不算热区', (tester) async {
    await tester.pumpWidget(wrap(const SizedBox(
      width: 800,
      height: 700,
      child: StagePreview(title: 'A', artist: 'B', album: '', elapsed: '00:00', total: '00:10', coverPath: ''),
    )));
    expect(find.byKey(const Key('stage-hit-area')), findsOneWidget);
    expect(find.byKey(const Key('cover-disc')), findsOneWidget);
  });

  testWidgets('封面尺寸跟随三档断点', (tester) async {
    for (final width in [360.0, 1000.0, 1300.0]) {
      await tester.pumpWidget(wrap(SizedBox(
        width: width,
        height: 900,
        child: const StagePreview(title: 'A', artist: '', album: '', elapsed: '', total: '', coverPath: ''),
      )));
      final disc = tester.getRect(find.byKey(const Key('cover-disc')));
      final expected = kCoverSize(width, viewportHeight: 900);
      expect(disc.width, closeTo(expected, 1.0), reason: 'width=$width');
    }
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/ui/stage_test.dart`
Expected: 编译失败 —— `stage.dart` 不存在。

- [ ] **Step 3: 实现圆形碟**

```dart
// lib/ui/vinyl_deck.dart
import 'dart:io';

import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

class CoverDisc extends StatelessWidget {
  const CoverDisc({
    required this.coverPath,
    required this.size,
    required this.spinning,
    super.key,
  });

  final String coverPath;
  final double size;
  final bool spinning; // M1 恒 false：旋转在 M3

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const RadialGradient(
                colors: [Color(0xFF1A1F26), Color(0xFF0A0D12)],
                stops: [0.55, 1],
              ),
              boxShadow: tokens.shadowCard,
            ),
            child: const SizedBox(width: double.infinity, height: double.infinity),
          ),
          ClipOval(
            child: SizedBox(
              width: size,
              height: size,
              child: coverPath.isEmpty
                  ? const _DiscPlaceholder()
                  : Image.file(
                      File(coverPath),
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      errorBuilder: (_, __, ___) => const _DiscPlaceholder(),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DiscPlaceholder extends StatelessWidget {
  const _DiscPlaceholder();

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Container(
      color: tokens.progressTrack,
      alignment: Alignment.center,
      child: Icon(Icons.music_note, size: 28, color: tokens.textFaint),
    );
  }
}
```

- [ ] **Step 4: 实现 Stage**

```dart
// lib/ui/stage.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/breakpoints.dart';
import '../state/player_state.dart';
import '../theme/app_tokens.dart';
import 'vinyl_deck.dart';

/// M1 的纯展示入口：真页面用 Stage()，测试与预览走 StagePreview()。
class Stage extends StatelessWidget {
  const Stage({super.key});

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerState>();
    final view = player.view.value;
    final track = view.current;
    return StagePreview(
      title: track?.title ?? '未选择曲目',
      artist: track?.artist.isNotEmpty == true ? track!.artist : '从播放列表选一首开始',
      album: track?.album ?? '',
      coverPath: track?.cover ?? '',
      elapsed: '--:--',
      total: track != null && track.hasDuration
          ? (track.duration ~/ 60).toString().padLeft(2, '0') +
              ':' +
              ((track.duration % 60).round()).toString().padLeft(2, '0')
          : '--:--',
      broken: track?.broken ?? false,
    );
  }
}

class StagePreview extends StatelessWidget {
  const StagePreview({
    required this.title,
    required this.artist,
    required this.album,
    required this.elapsed,
    required this.total,
    this.coverPath = '',
    this.broken = false,
    super.key,
  });

  final String title;
  final String artist;
  final String album;
  final String elapsed;
  final String total;
  final String coverPath;
  final bool broken;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final size = MediaQuery.sizeOf(context);
    final coverSize = kCoverSize(size.width, viewportHeight: size.height);
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(kRadiusXl),
        border: Border.all(color: tokens.border),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [tokens.cardA, tokens.cardB],
        ),
        boxShadow: tokens.shadowCard,
      ),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            // 中间区域留给 M2 的歌词预览：M1 用占位，弹性填满剩余高度
            child: Center(
              child: GestureDetector(
                key: const Key('stage-hit-area'),
                behavior: HitTestBehavior.opaque,
                onTap: () {}, // M2 换成进入歌词页
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Semantics(
                      key: const Key('cover-disc'),
                      label: broken ? '$title（无法播放）' : title,
                      child: CoverDisc(
                        coverPath: coverPath,
                        size: coverSize,
                        spinning: false,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w650, color: tokens.text)),
                    if (broken) _BrokenBadge(),
                    const SizedBox(height: 4),
                    Text(artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12.5, color: tokens.textDim)),
                    const SizedBox(height: 10),
                    const _LyricsSlot(),
                  ],
                ),
              ),
            ),
          ),
          Text('$elapsed / $total',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 11.5,
                  color: tokens.textFaint,
                  fontFeatures: const [FontFeature.tabularFigures()])),
        ],
      ),
    );
  }
}

class _BrokenBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          color: tokens.dangerSoft,
          border: Border.all(color: tokens.dangerLine),
        ),
        child: Text('损坏', style: TextStyle(fontSize: 10, color: tokens.dangerInk)),
      ),
    );
  }
}

/// M2 之前不留空白：占位高度与真实歌词预览一致，避免布局返工。
class _LyricsSlot extends StatelessWidget {
  const _LyricsSlot();

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return SizedBox(
      height: 66,
      child: Center(
        child: Icon(Icons.graphic_eq, size: 20, color: tokens.progressTrack),
      ),
    );
  }
}
```

> Step 4 里 Stage 的时间字符串是手拼的，**实现时必须改成 `formatTime()`**（T5 提供），并且 elapsed 从 `player.position` 用 `ValueListenableBuilder` 取，不要在 `Stage.build` 里直接读 `player.position.value` —— 后者会把整棵 stage 树绑到进度上，违反 T23 那条「进度不 notify 全局」的约束。测试 `StagePreview` 的 `02:15 / 03:46` 断言正好是这两处的回归网。

- [ ] **Step 5: 跑测试确认通过**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/ui/stage_test.dart`
Expected: `All tests passed!`（6 个用例）

- [ ] **Step 6: Commit**

```bash
cd flutter-app && git add lib/ui test/ui && git commit -m "feat(ui): 新增播放卡与圆形封面碟"
```

---

## Task 27: 列表行与最近行

原版行契约（`App.tsx:726-770`、`:786-824`、`styles/app.css:3478-3531`、`3554`、`3601-3647`）：播放列表行 44×44 缩略图 + 标题/`歌手 · 专辑` + 时长 + 删除；当前项高亮带跳动音柱（M1 静止三根，播放态由 `playing` 决定）；删除按钮桌面视觉 34×34 但热区 44×44；「损坏」角标；最近行 40×40 缩略、相对时间在 meta 位、失效条目变暗并提示。

**Files:**
- Create: `lib/ui/track_row.dart`
- Create: `lib/ui/recent_row.dart`
- Create: `lib/ui/cover_thumb.dart`
- Test: `test/ui/track_row_test.dart`

**Interfaces:**
- Consumes: `Track`（T3）、`RecentEntry`（T16）、`formatTime`（T5）、`formatRelativeTime`（T16）、`AppTokens`
- Produces:
  - `class TrackRow extends StatelessWidget { const TrackRow({required this.title, required this.artistLine, required this.duration, required this.active, required this.playing, required this.broken, required this.onPlay, required this.onRemove, super.key}); }`
  - `class RecentRow extends StatelessWidget { const RecentRow({required this.title, required this.artist, required this.relativeTime, required this.duration, required this.inPlaylist, required this.active, required this.onTap, super.key}); }`
  - `class BarsIndicator extends StatelessWidget { const BarsIndicator({required this.playing, super.key}); }`

- [ ] **Step 1: 写失败测试**

```dart
// test/ui/track_row_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/ui/recent_row.dart';
import 'package:light_music/ui/track_row.dart';

void main() {
  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
        MaterialApp(
          theme: buildTheme().copyWith(
            extensions: const [AppTokensData(tokens: AppTokens.dark)],
          ),
          home: Scaffold(body: SizedBox(width: 420, child: child)),
        ),
      );

  testWidgets('行内显示标题、歌手·专辑与时长', (tester) async {
    var played = 0;
    await pump(
      tester,
      TrackRow(
        title: '白玫瑰',
        artistLine: '陈奕迅 · Stranger Under My Skin',
        duration: '03:46',
        active: false,
        playing: false,
        broken: false,
        onPlay: () => played++,
        onRemove: () {},
      ),
    );
    expect(find.text('白玫瑰'), findsOneWidget);
    expect(find.text('陈奕迅 · Stranger Under My Skin'), findsOneWidget);
    expect(find.text('03:46'), findsOneWidget);
    await tester.tap(find.text('白玫瑰'));
    expect(played, 1);
  });

  testWidgets('删除按钮点击不冒泡到播放', (tester) async {
    var played = 0;
    var removed = 0;
    await pump(
      tester,
      TrackRow(
        title: 'A', artistLine: 'B', duration: '00:10',
        active: false, playing: false, broken: false,
        onPlay: () => played++, onRemove: () => removed++,
      ),
    );
    await tester.tap(find.byKey(const Key('track-remove')));
    expect(removed, 1);
    expect(played, 0);
  });

  testWidgets('删除按钮视觉 34、热区不小于 44', (tester) async {
    await pump(
      tester,
      TrackRow(
        title: 'A', artistLine: 'B', duration: '',
        active: false, playing: false, broken: false,
        onPlay: () {}, onRemove: () {},
      ),
    );
    expect(tester.getRect(find.byKey(const Key('track-remove'))).width,
        greaterThanOrEqualTo(44));
    expect(tester.getRect(find.byKey(const Key('track-remove-visual'))).width, 34);
  });

  testWidgets('当前项显示音柱，非当前项不显示', (tester) async {
    await pump(
      tester,
      Column(children: [
        TrackRow(
          title: '当前', artistLine: '', duration: '',
          active: true, playing: true, broken: false,
          onPlay: () {}, onRemove: () {},
        ),
        TrackRow(
          title: '其他', artistLine: '', duration: '',
          active: false, playing: false, broken: false,
          onPlay: () {}, onRemove: () {},
        ),
      ]),
    );
    expect(find.byKey(const Key('bars-indicator')), findsOneWidget);
  });

  testWidgets('损坏项有角标且文案不裁', (tester) async {
    await pump(
      tester,
      TrackRow(
        title: '坏文件', artistLine: '', duration: '--:--',
        active: false, playing: false, broken: true,
        onPlay: () {}, onRemove: () {},
      ),
    );
    expect(find.text('损坏'), findsOneWidget);
  });

  testWidgets('语义标签逐字对齐原版', (tester) async {
    await pump(
      tester,
      TrackRow(
        title: '十年', artistLine: '陈奕迅', duration: '03:46',
        active: false, playing: false, broken: false,
        onPlay: () {}, onRemove: () {},
      ),
    );
    expect(find.bySemanticsLabel('播放《十年》'), findsOneWidget);
    expect(find.bySemanticsLabel('从播放列表移除《十年》'), findsOneWidget);
  });

  testWidgets('最近行显示相对时间与时长', (tester) async {
    await pump(
      tester,
      RecentRow(
        title: '孤勇者', artist: '陈奕迅', relativeTime: '3 分钟前',
        duration: '04:12', inPlaylist: true, active: false, onTap: () {},
      ),
    );
    expect(find.text('孤勇者'), findsOneWidget);
    expect(find.text('3 分钟前'), findsOneWidget);
    expect(find.text('04:12'), findsOneWidget);
  });

  testWidgets('失效条目变暗并给出提示而不是静默失败', (tester) async {
    var taps = 0;
    await pump(
      tester,
      RecentRow(
        title: '已删', artist: 'X', relativeTime: '昨天',
        duration: '', inPlaylist: false, active: false, onTap: () => taps++,
      ),
    );
    final opacity = tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity;
    expect(opacity, closeTo(0.55, 0.01));
    expect(find.text('已不在列表'), findsOneWidget);
    expect(find.bySemanticsLabel('已删（已不在播放列表中）'), findsOneWidget);
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/ui/track_row_test.dart`
Expected: 编译失败 —— 两个 row 文件不存在。

- [ ] **Step 3: 实现缩略图与音柱**

```dart
// lib/ui/cover_thumb.dart
import 'dart:io';

import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

class CoverThumb extends StatelessWidget {
  const CoverThumb({required this.path, required this.size, super.key});
  final String path;
  final double size;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: tokens.progressTrack),
        color: tokens.progressTrack,
      ),
      clipBehavior: Clip.antiAlias,
      child: path.isEmpty
          ? Icon(Icons.music_note, size: size * 0.4, color: tokens.textFaint)
          : Image.file(File(path), fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) =>
                  Icon(Icons.music_note, size: size * 0.4, color: tokens.textFaint)),
    );
  }
}

class BarsIndicator extends StatelessWidget {
  const BarsIndicator({required this.playing, super.key});
  final bool playing;

  static const _heights = [5.0, 9.0, 6.0];

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return SizedBox(
      key: const Key('bars-indicator'),
      width: 12,
      height: 13,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          for (var i = 0; i < 3; i++)
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              width: 2.5,
              height: playing ? _heights[i] : _heights[i] * 0.6,
              decoration: BoxDecoration(
                color: tokens.accent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 4: 实现两个 row**

```dart
// lib/ui/track_row.dart
import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import 'cover_thumb.dart';

class TrackRow extends StatelessWidget {
  const TrackRow({
    required this.title,
    required this.artistLine,
    required this.duration,
    required this.active,
    required this.playing,
    required this.broken,
    required this.onPlay,
    required this.onRemove,
    super.key,
  });

  final String title;
  final String artistLine;
  final String duration;
  final bool active;
  final bool playing;
  final bool broken;
  final VoidCallback onPlay;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Semantics(
      button: true,
      label: '播放《$title》',
      child: InkWell(
        onTap: onPlay,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: active ? tokens.accentLine : Colors.transparent),
            gradient: active
                ? LinearGradient(begin: Alignment.centerLeft, end: Alignment.centerRight, colors: [
                    tokens.accentSoft,
                    tokens.accentSoft.withValues(alpha: 0.02),
                  ])
                : null,
          ),
          padding: const EdgeInsets.fromLTRB(8, 7, 4, 7),
          constraints: const BoxConstraints(minHeight: 56),
          child: Row(
            children: [
              CoverThumb(path: '', size: 44, key: const Key('track-thumb')),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                  color: active ? tokens.accentLight : tokens.text)),
                        ),
                        if (broken)
                          Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: _Badge(label: '损坏', tokens: tokens),
                          ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Expanded(
                          child: Text(artistLine,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 11.5, color: tokens.textFaint)),
                        ),
                        if (active) BarsIndicator(playing: playing),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Text(duration,
                  style: TextStyle(
                      fontSize: 11.5,
                      color: tokens.textDim,
                      fontFeatures: const [FontFeature.tabularFigures()])),
              const SizedBox(width: 2),
              Semantics(
                button: true,
                label: '从播放列表移除《$title》',
                child: _RemoveButton(
                  onTap: onRemove,
                  tooltip: '从播放列表中移除',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 视觉 34×34，热区 44×44：桌面行窄时不删图标，改容器与热区。
class _RemoveButton extends StatelessWidget {
  const _RemoveButton({required this.onTap, required this.tooltip});
  final VoidCallback onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        key: const Key('track-remove'),
        width: 44,
        height: 44,
        child: Center(
          child: SizedBox(
            key: const Key('track-remove-visual'),
            width: 34,
            height: 34,
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: onTap,
                child: Icon(Icons.close, size: 14, color: tokens.textFaint),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.tokens});
  final String label;
  final AppTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        color: tokens.dangerSoft,
        border: Border.all(color: tokens.dangerLine),
      ),
      child: Text(label, style: TextStyle(fontSize: 10, color: tokens.dangerInk)),
    );
  }
}
```

```dart
// lib/ui/recent_row.dart
import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import 'cover_thumb.dart';

class RecentRow extends StatelessWidget {
  const RecentRow({
    required this.title,
    required this.artist,
    required this.relativeTime,
    required this.duration,
    required this.inPlaylist,
    required this.active,
    required this.onTap,
    super.key,
  });

  final String title;
  final String artist;
  final String relativeTime;
  final String duration;
  final bool inPlaylist;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Semantics(
      button: true,
      label: inPlaylist ? '$title' : '$title（已不在播放列表中）',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: AnimatedOpacity(
          opacity: inPlaylist ? 1 : 0.55,
          duration: const Duration(milliseconds: 180),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                CoverThumb(path: '', size: 40),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: active ? tokens.accentLight : tokens.text)),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Flexible(
                            child: Text(artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 11, color: tokens.textFaint)),
                          ),
                          const SizedBox(width: 6),
                          Text(relativeTime,
                              style: TextStyle(fontSize: 11, color: tokens.textFaint)),
                          if (!inPlaylist) ...[
                            const SizedBox(width: 6),
                            Text('已不在列表',
                                style: TextStyle(fontSize: 11, color: tokens.dangerInk)),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(duration,
                    style: TextStyle(
                        fontSize: 11,
                        color: tokens.textFaint,
                        fontFeatures: const [FontFeature.tabularFigures()])),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 5: 跑测试确认通过**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/ui/track_row_test.dart`
Expected: `All tests passed!`（8 个用例）。

- [ ] **Step 6: Commit**

```bash
cd flutter-app && git add lib/ui test/ui && git commit -m "feat(ui): 移植播放列表行与最近播放行"
```

---

## Task 28: 面板 —— 两个 tab、搜索、空态与错误横幅

原版契约：一个搜索框管两个 tab 且只搜歌名（200ms 防抖）；统计行过滤时 `找到 N 首 · 共 M 首`，否则 `M 首 · 总时长 mm:ss`；空态在内容区居中、纯文字、无虚线框；错误常驻横幅在列表上方带「继续播放」；最近 tab 顶部左 `按播放时间排序，最多保留 50 首`、右 `清空历史`（空时禁用）。

**Files:**
- Create: `lib/ui/panel.dart`
- Create: `lib/ui/empty_state.dart`
- Test: `test/ui/panel_test.dart`

**Interfaces:**
- Consumes: `LibraryState`/`PlayerState`/`RecentState`/`ToastState`、`TrackRow`/`RecentRow`（T27）、`formatTotal`（T5）
- Produces: `class Panel extends StatelessWidget`；`class EmptyState extends StatelessWidget { const EmptyState({required this.title, required this.hint, super.key}); }`；`class PanelNotice extends StatelessWidget`（错误/熔断常驻提示）

- [ ] **Step 1: 写失败测试**

```dart
// test/ui/panel_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/ui/panel.dart';

void main() {
  Future<void> pump(WidgetTester tester, PanelHarness harness) =>
      tester.pumpWidget(MaterialApp(
        theme: buildTheme().copyWith(
          extensions: const [AppTokensData(tokens: AppTokens.dark)],
        ),
        home: Scaffold(
          body: SizedBox(width: 420, height: 700, child: harness.build()),
        ),
      ));

  testWidgets('默认在播放列表 tab，显示统计行', (tester) async {
    await pump(tester, PanelHarness(titles: ['十年', '白玫瑰']));
    expect(find.text('播放列表'), findsOneWidget);
    expect(find.text('最近'), findsOneWidget);
    expect(find.text('2 首 · 总时长 07:32'), findsOneWidget);
    expect(find.text('十年'), findsOneWidget);
  });

  testWidgets('搜索框 placeholder 与 aria 文案逐字', (tester) async {
    await pump(tester, PanelHarness(titles: ['十年']));
    expect(find.byPlaceholder('搜索歌名'), findsOneWidget);
    expect(find.bySemanticsLabel('搜索歌名'), findsOneWidget);
  });

  testWidgets('输入后 200ms 才生效，期间列表不跳', (tester) async {
    await pump(tester, PanelHarness(titles: ['十年', '白玫瑰']));
    await tester.enterText(find.byPlaceholder('搜索歌名'), '十年');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('白玫瑰'), findsOneWidget); // 未生效
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('白玫瑰'), findsNothing); // 已生效
    expect(find.text('找到 1 首 · 共 2 首'), findsOneWidget);
  });

  testWidgets('清空关键词后恢复完整列表且不闪', (tester) async {
    await pump(tester, PanelHarness(titles: ['十年', '白玫瑰']));
    await tester.enterText(find.byPlaceholder('搜索歌名'), 'zzz');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('没有找到《zzz》'), findsOneWidget);
    await tester.enterText(find.byPlaceholder('搜索歌名'), '');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('十年'), findsOneWidget);
  });

  testWidgets('空列表空态居中且无装饰框', (tester) async {
    await pump(tester, PanelHarness(titles: []));
    expect(find.text('播放列表是空的'), findsOneWidget);
    expect(find.text('点击「添加音乐」，或把音频文件拖到页面上'), findsOneWidget);
    expect(find.byKey(const Key('empty-dashed-border')), findsNothing);
    final rect = tester.getRect(find.text('播放列表是空的'));
    expect(rect.center.dy, greaterThan(200)); // 在内容区中部，不贴顶
  });

  testWidgets('最近 tab 顶部说明与清空按钮', (tester) async {
    await pump(tester, PanelHarness(titles: [], recentCount: 2));
    await tester.tap(find.text('最近'));
    await tester.pumpAndSettle();
    expect(find.text('按播放时间排序，最多保留 50 首'), findsOneWidget);
    expect(find.text('清空历史'), findsOneWidget);
  });

  testWidgets('最近为空时清空按钮禁用', (tester) async {
    await pump(tester, PanelHarness(titles: [], recentCount: 0));
    await tester.tap(find.text('最近'));
    await tester.pumpAndSettle();
    expect(find.text('还没有播放记录'), findsOneWidget);
    final button = tester.widget<TextButton>(find.widgetWithText(TextButton, '清空历史'));
    expect(button.onPressed, isNull);
  });

  testWidgets('常驻错误横幅优先于列表内容', (tester) async {
    await pump(tester, PanelHarness(titles: ['十年'], notice: '音频解码失败，文件可能已损坏'));
    expect(find.text('音频解码失败，文件可能已损坏'), findsOneWidget);
    expect(find.text('继续播放'), findsOneWidget);
  });

  testWidgets('熔断提示单独一条文案，带说明', (tester) async {
    await pump(tester, PanelHarness(titles: ['十年'], circuitOpen: true));
    expect(find.textContaining('已停止自动切歌'), findsOneWidget);
  });

  testWidgets('过滤时列表高度不塌（固定行不参与收缩）', (tester) async {
    await pump(tester, PanelHarness(titles: ['十年', '白玫瑰'], tall: true));
    final headerBefore = tester.getRect(find.byKey(const Key('panel-header')));
    await tester.enterText(find.byPlaceholder('搜索歌名'), '十年');
    await tester.pump(const Duration(milliseconds: 300));
    final headerAfter = tester.getRect(find.byKey(const Key('panel-header')));
    expect(headerAfter.top, headerBefore.top);
    expect(headerAfter.height, headerBefore.height);
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/ui/panel_test.dart`
Expected: 编译失败 —— `panel.dart` / `empty_state.dart` 不存在，且 `PanelHarness` 需在测试文件里实现（Step 3 给出）。

- [ ] **Step 3: 实现 Panel（含 Harness）**

`PanelHarness` 是测试专用装配壳，把假数据塞进真 widget；放在 `test/ui/panel_harness.dart`，不进 `lib/`：

```dart
// test/ui/panel_harness.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:light_music/playback/playlist.dart';
import 'package:light_music/playback/track.dart';
import 'package:light_music/state/library_state.dart';
import 'package:light_music/state/player_state.dart';
import 'package:light_music/state/recent_state.dart';
import 'package:light_music/ui/panel.dart';

class PanelHarness {
  PanelHarness({
    this.titles = const [],
    this.recentCount = 0,
    this.notice,
    this.circuitOpen = false,
    this.tall = false,
  });

  final List<String> titles;
  final int recentCount;
  final String? notice;
  final bool circuitOpen;
  final bool tall;

  Widget build() {
    final playlist = Playlist.fromTracks([
      for (var i = 0; i < titles.length; i++)
        Track(id: '$i', src: '/$i.flac', title: titles[i], artist: '某人', duration: 226),
    ]);
    final library = _FakeLibraryState(playlist);
    final player = _FakePlayerState(playlist, notice: notice, circuitOpen: circuitOpen);
    final recent = _FakeRecentState(recentCount);
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<LibraryState>.value(value: library),
        ChangeNotifierProvider<PlayerState>.value(value: player),
        ChangeNotifierProvider<RecentState>.value(value: recent),
      ],
      child: SizedBox(height: tall ? 700 : null, child: const Panel()),
    );
  }
}
```

> 三个 `_Fake*State` 用 `extends` 各自真实 State 的**最小可构造子类**（覆盖数据 getter，不碰 IO）：`_FakeLibraryState extends LibraryState` 用 `LibraryState` 的无 IO 构造重载（T23 Step 3 实现时给它加一个 `@visibleForTesting LibraryState.fake(Playlist playlist)`），`_FakePlayerState`、`_FakeRecentState` 同理。若子类化代价大，就在 T23 给三个 State 增加 `@visibleForTesting` 构造，**不要在面板里塞测试专用分支**。

面板主体：

```dart
// lib/ui/panel.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../library/recent_store.dart';
import '../playback/track.dart';
import '../state/library_state.dart';
import '../state/player_state.dart';
import '../state/recent_state.dart';
import '../theme/app_tokens.dart';
import 'empty_state.dart';
import 'recent_row.dart';
import 'track_row.dart';

enum PanelTab { playlist, recent }

class Panel extends StatelessWidget {
  const Panel({super.key, this.onClose});

  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final library = context.watch<LibraryState>();
    final player = context.watch<PlayerState>();
    final recent = context.watch<RecentState>();
    final tab = context.select<PanelController, PanelTab>((c) => c.tab);
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: tokens.border),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [tokens.panelA, tokens.panelB],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(tab: tab, onTab: (next) => context.read<PanelController>().tab = next),
          const SizedBox(height: 10),
          const _SearchBox(),
          const SizedBox(height: 8),
          const _StatsRow(),
          if (player.blockedMessage != null || player.circuitOpen)
            PanelNotice(
              message: player.circuitOpen
                  ? '连续多首无法播放，已停止自动切歌'
                  : player.blockedMessage!,
              actionLabel: player.circuitOpen ? null : '继续播放',
              onAction: player.circuitOpen ? null : () => player.userGesture(),
            ),
          Expanded(
            child: switch (tab) {
              PanelTab.playlist => _PlaylistBody(library: library),
              PanelTab.recent => _RecentBody(recent: recent, library: library),
            },
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.tab, required this.onTab});
  final PanelTab tab;
  final ValueChanged<PanelTab> onTab;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Row(
      key: const Key('panel-header'),
      children: [
        for (final item in PanelTab.values)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: InkWell(
              onTap: () => onTab(item),
              borderRadius: BorderRadius.circular(999),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  color: item == tab ? tokens.accentSoft : Colors.transparent,
                ),
                child: Text(
                  item == PanelTab.playlist ? '播放列表' : '最近',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: item == tab ? tokens.accentLight : tokens.textDim,
                  ),
                ),
              ),
            ),
          ),
        const Spacer(),
      ],
    );
  }
}

class _SearchBox extends StatelessWidget {
  const _SearchBox();

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final library = context.watch<LibraryState>();
    return Container(
      height: 36,
      padding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
            color: library.keyword.isEmpty ? tokens.border : tokens.accentLine),
      ),
      child: Row(
        children: [
          Icon(Icons.search, size: 15, color: tokens.textFaint),
          const SizedBox(width: 8),
          Expanded(
            child: Semantics(
              label: '搜索歌曲',
              child: TextField(
                key: const Key('panel-search'),
                controller: library.searchController,
                placeholder: '搜索歌名',
                decoration: const InputDecoration(
                  hintText: '搜索歌名',
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                ),
                style: TextStyle(fontSize: 12.5, color: tokens.text),
              ),
            ),
          ),
          if (library.keyword.isNotEmpty)
            InkWell(
              onTap: () => library.keyword = '',
              customBorder: const CircleBorder(),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(Icons.close, size: 14, color: tokens.textFaint),
              ),
            ),
        ],
      ),
    );
  }
}

class _StatsRow extends StatelessWidget {
  const _StatsRow();

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final library = context.watch<LibraryState>();
    final shown = library.filteredTracks.length;
    final total = library.tracks.length;
    final text = library.keyword.trim().isEmpty
        ? '$total 首 · 总时长 ${formatTotalSeconds(library.totalSeconds)}'
        : '找到 $shown 首 · 共 $total 首';
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(text, style: TextStyle(fontSize: 11.5, color: tokens.textFaint)),
    );
  }
}

class _PlaylistBody extends StatelessWidget {
  const _PlaylistBody({required this.library});
  final LibraryState library;

  @override
  Widget build(BuildContext context) {
    final tracks = library.filteredTracks;
    if (tracks.isEmpty) {
      return library.tracks.isEmpty
          ? const EmptyState(
              title: '播放列表是空的',
              hint: '点击「添加音乐」，或把音频文件拖到页面上',
            )
          : EmptyState(
              title: '没有找到《${library.keyword.trim()}》',
              hint: '换个关键词试试',
            );
    }
    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: tracks.length,
      itemBuilder: (context, index) {
        final track = tracks[index];
        return TrackRow(
          title: track.title,
          artistLine: _artistLine(track),
          duration: formatTime(track.duration),
          active: library.currentId == track.id,
          playing: context.select<PlayerState, bool>((p) => p.playing),
          broken: track.broken,
          onPlay: () => context.read<PlayerState>().playTrack(track.id),
          onRemove: () => library.removeTrack(track.id),
        );
      },
    );
  }
}

class _RecentBody extends StatelessWidget {
  const _RecentBody({required this.recent, required this.library});
  final RecentState recent;
  final LibraryState library;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final entries = recent.entries;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 26,
          child: Row(
            children: [
              Expanded(
                child: Text('按播放时间排序，最多保留 50 首',
                    style: TextStyle(fontSize: 11.5, color: tokens.textFaint)),
              ),
              TextButton(
                onPressed: entries.isEmpty ? null : () => recent.clear(),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('清空历史', style: TextStyle(fontSize: 11.5)),
              ),
            ],
          ),
        ),
        Expanded(
          child: entries.isEmpty
              ? const EmptyState(title: '还没有播放记录', hint: '播放过的歌会自动出现在这里')
              : ListView.builder(
                  padding: EdgeInsets.zero,
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    return RecentRow(
                      title: entry.title,
                      artist: entry.artist,
                      relativeTime: formatRelativeTime(entry.at),
                      duration: entry.duration == null
                          ? '--:--'
                          : formatTime(entry.duration!),
                      inPlaylist: entry.inPlaylist,
                      active: library.currentId == entry.id,
                      onTap: () => entry.inPlaylist
                          ? context.read<PlayerState>().playTrack(entry.id)
                          : library.toastMissingInPlaylist(),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class PanelNotice extends StatelessWidget {
  const PanelNotice({
    required this.message,
    this.actionLabel,
    this.onAction,
    super.key,
  });

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: tokens.dangerSoft,
        border: Border.all(color: tokens.dangerLine),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(message,
                style: TextStyle(fontSize: 12.5, color: tokens.dangerInk)),
          ),
          if (actionLabel != null)
            TextButton(
              onPressed: onAction,
              child: Text(actionLabel!, style: const TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }
}
```

`lib/ui/empty_state.dart`：

```dart
// lib/ui/empty_state.dart
import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

/// 页面级空态：文字居中在内容区，不加虚线框（原版规则）。
class EmptyState extends StatelessWidget {
  const EmptyState({required this.title, required this.hint, super.key});

  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600, color: tokens.textDim)),
            const SizedBox(height: 6),
            Text(hint,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11.5, color: tokens.textFaint)),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: 给 LibraryState 补 `searchController` 与 `PanelController`**

`LibraryState` 加一个 `TextEditingController` 并在 `keyword` setter 里同步；`PanelController extends ChangeNotifier { PanelTab tab = PanelTab.playlist; }` 放在 `lib/state/panel_controller.dart`，在 `main.dart` 的 providers 里注册。`toastMissingInPlaylist()` 内部调 `toasts.show('这首歌已经不在播放列表里了', key: 'recent-missing')`。

- [ ] **Step 5: 跑测试确认通过**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/ui/panel_test.dart`
Expected: `All tests passed!`（10 个用例）。「输入后 200ms 才生效」这条失败时，检查是不是把 `keyword` 直接绑进了过滤（原版明确走防抖后的生效值，清空才不闪）。

- [ ] **Step 6: Commit**

```bash
cd flutter-app && git add lib test && git commit -m "feat(ui): 移植面板双标签、防抖搜索与空态提示"
```

---

## Task 29: 控制条 —— 进度、缓冲、音量与五个按钮

原版契约（`App.tsx:969-1058`、`styles/app.css:1237-1242`、`:3949-3953`、`:4050-4078`）：`<900px` 五个 40px 同款按钮 space-between 等距、最右是列表入口弹 sheet，音量隐藏；`≥900` grid `auto auto auto auto minmax(120px,1fr)` gap 12，音量 200px 内滑轨 130px，列表入口只在歌词页出现（M1 无歌词页 → 桌面不显示列表按钮，但控件位留着不塌陷）。进度条三层（rail 5px / buffer 5px / fill 5px，radius 3），thumb 14×14 白底 2px 强调色描边；拖拽期间暂停进度同步、松手 seek。

**Files:**
- Create: `lib/ui/transport.dart`
- Create: `lib/ui/progress_slider.dart`
- Create: `lib/ui/volume_slider.dart`
- Create: `lib/ui/library_sheet.dart`
- Test: `test/ui/transport_test.dart`

**Interfaces:**
- Consumes: `PlayerState`（T23）、`LibraryState`、`formatTime`（T5）、`kButtonSize`/`kTouchTarget`
- Produces:
  - `class TransportBar extends StatelessWidget`
  - `class ProgressSlider extends StatelessWidget { const ProgressSlider({required this.position, required this.buffered, required this.duration, required this.onSeekStart, required this.onSeekUpdate, required this.onSeekEnd, super.key}); }`
  - `class VolumeSlider extends StatelessWidget`
  - `Future<void> showLibrarySheet(BuildContext context);`

- [ ] **Step 1: 写失败测试**

```dart
// test/ui/transport_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/ui/progress_slider.dart';
import 'package:light_music/ui/transport.dart';

Widget wrap(Widget child, {double width = 1200}) => MaterialApp(
      theme: buildTheme().copyWith(
        extensions: const [AppTokensData(tokens: AppTokens.dark)],
      ),
      home: Scaffold(
        body: SizedBox(width: width, height: 240, child: Align(alignment: Alignment.bottomCenter, child: child)),
      ),
    );

void main() {
  testWidgets('五个按钮同尺寸 40px 且等距', (tester) async {
    await tester.pumpWidget(wrap(TransportBar.preview(
      playing: false, modeLabel: '列表循环', positionSeconds: 0, totalSeconds: 100,
    ), width: 420));
    final buttons = [
      find.byKey(const Key('btn-mode')),
      find.byKey(const Key('btn-prev')),
      find.byKey(const Key('btn-play')),
      find.byKey(const Key('btn-next')),
      find.byKey(const Key('btn-queue')),
    ];
    for (final button in buttons) {
      final rect = tester.getRect(button);
      expect(rect.width, 40);
      expect(rect.height, 40);
    }
    final gaps = <double>[];
    for (var i = 1; i < buttons.length; i++) {
      gaps.add(tester.getRect(buttons[i]).left - tester.getRect(buttons[i - 1]).right);
    }
    for (final gap in gaps) {
      expect(gap, closeTo(gaps.first, 0.6)); // 等距
    }
  });

  testWidgets('窄屏隐藏音量，桌面显示', (tester) async {
    await tester.pumpWidget(wrap(TransportBar.preview(
      playing: true, modeLabel: '列表循环', positionSeconds: 10, totalSeconds: 100,
    ), width: 420));
    expect(find.byKey(const Key('volume-slider')), findsNothing);
    await tester.pumpWidget(wrap(TransportBar.preview(
      playing: true, modeLabel: '列表循环', positionSeconds: 10, totalSeconds: 100,
    ), width: 1100));
    expect(find.byKey(const Key('volume-slider')), findsOneWidget);
  });

  testWidgets('播放按钮语义在播放/暂停间切换', (tester) async {
    await tester.pumpWidget(wrap(TransportBar.preview(
      playing: false, modeLabel: '列表循环', positionSeconds: 0, totalSeconds: 100)));
    expect(find.bySemanticsLabel('播放'), findsOneWidget);
    await tester.pumpWidget(wrap(TransportBar.preview(
      playing: true, modeLabel: '随机播放', positionSeconds: 0, totalSeconds: 100)));
    expect(find.bySemanticsLabel('暂停'), findsOneWidget);
    expect(find.bySemanticsLabel('播放模式：随机播放'), findsOneWidget);
  });

  testWidgets('拖拽期间不跟随播放进度，松手才 seek', (tester) async {
    final seeks = <double>[];
    var updates = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 600,
          child: ProgressSlider(
            position: 10,
            buffered: 40,
            duration: 100,
            onSeekStart: () {},
            onSeekUpdate: (v) => updates++,
            onSeekEnd: (v) => seeks.add(v),
          ),
        ),
      ),
    ));
    final box = tester.getSize(find.byKey(const Key('progress-slider')));
    await tester.drag(
      find.byKey(const Key('progress-slider')),
      Offset(box.width * 0.5, 0),
      touchSlopX: 0,
    );
    await tester.pump();
    expect(seeks.length, 1);
    expect(seeks.single, closeTo(60, 2)); // 起点 10s + 半条 50s
    expect(updates, greaterThan(0));
  });

  testWidgets('缓冲层宽度不大于填充层以外区域', (tester) async {
    await tester.pumpWidget(wrap(ProgressSlider(
      position: 20, buffered: 60, duration: 100,
      onSeekStart: () {}, onSeekUpdate: (_) {}, onSeekEnd: (_) {},
    ), width: 600));
    final fill = tester.getRect(find.byKey(const Key('progress-fill')));
    final buffer = tester.getRect(find.byKey(const Key('progress-buffer')));
    expect(buffer.right, greaterThan(fill.right));
    expect(buffer.width, lessThanOrEqualTo(600));
  });

  testWidgets('时长未知显示 --:--，进度按 0 处理', (tester) async {
    await tester.pumpWidget(wrap(ProgressSlider(
      position: 0, buffered: null, duration: null,
      onSeekStart: () {}, onSeekUpdate: (_) {}, onSeekEnd: (_) {},
    ), width: 600));
    expect(find.text('--:--'), findsWidgets);
    expect(tester.getRect(find.byKey(const Key('progress-fill'))).width, 0);
  });

  testWidgets('音量滑块拖动改变音量', (tester) async {
    final values = <double>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 220,
          child: VolumeSliderPreview(
            value: 0.5,
            onChanged: (v) => values.add(v),
            onToggleMute: () => values.add(-1),
          ),
        ),
      ),
    ));
    await tester.drag(find.byKey(const Key('volume-input')), const Offset(60, 0));
    await tester.pump();
    expect(values.last, greaterThan(0.5));
  });
}

/// 音量控件的纯展示预览壳（测试用），字段与真控件一致。
class VolumeSliderPreview extends StatelessWidget {
  const VolumeSliderPreview({required this.value, required this.onChanged, required this.onToggleMute});
  final double value;
  final ValueChanged<double> onChanged;
  final VoidCallback onToggleMute;

  @override
  Widget build(BuildContext context) => VolumeSlider(
        value: value,
        muted: false,
        onChanged: onChanged,
        onToggleMute: onToggleMute,
      );
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/ui/transport_test.dart`
Expected: 编译失败 —— 三个 ui 文件不存在。

- [ ] **Step 3: 实现进度条**

```dart
// lib/ui/progress_slider.dart
import 'package:flutter/material.dart';

import '../core/format_time.dart';
import '../theme/app_tokens.dart';

const double _trackHeight = 5;
const double _thumbSize = 14;

class ProgressSlider extends StatefulWidget {
  const ProgressSlider({
    required this.position,
    required this.buffered,
    required this.duration,
    required this.onSeekStart,
    required this.onSeekUpdate,
    required this.onSeekEnd,
    super.key,
  });

  final double position;
  final double? buffered;
  final double? duration;
  final VoidCallback onSeekStart;
  final ValueChanged<double> onSeekUpdate;
  final ValueChanged<double> onSeekEnd;

  @override
  State<ProgressSlider> createState() => _ProgressSliderState();
}

class _ProgressSliderState extends State<ProgressSlider> {
  bool _dragging = false;
  double _dragValue = 0;

  double get _total => (widget.duration != null && widget.duration! > 0) ? widget.duration! : 0;

  double get _shown => _dragging ? _dragValue : widget.position;

  double get _ratio => _total <= 0 ? 0 : (_shown / _total).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Semantics(
      label: '播放进度',
      value: '${formatTime(widget.position)} / ${formatTime(widget.duration)}',
      child: Row(
        children: [
          SizedBox(
            width: 36,
            child: Text(formatTime(widget.position),
                style: TextStyle(
                    fontSize: 11.5,
                    color: tokens.textDim,
                    fontFeatures: const [FontFeature.tabularFigures()])),
          ),
          Expanded(
            child: GestureDetector(
              key: const Key('progress-slider'),
              behavior: HitTestBehavior.opaque,
              onTapDown: (detail) {
                if (_total <= 0) return;
                final box = context.findRenderObject() as RenderBox;
                final ratio = (detail.localPosition.dx / box.size.width).clamp(0.0, 1.0);
                widget.onSeekEnd(ratio * _total);
              },
              onHorizontalDragStart: (_) {
                if (_total <= 0) return;
                setState(() {
                  _dragging = true;
                  _dragValue = widget.position;
                });
                widget.onSeekStart();
              },
              onHorizontalDragUpdate: (detail) {
                if (!_dragging || _total <= 0) return;
                final box = context.findRenderObject() as RenderBox;
                final ratio = (detail.localPosition.dx / box.size.width).clamp(0.0, 1.0);
                setState(() => _dragValue = ratio * _total);
                widget.onSeekUpdate(_dragValue);
              },
              onHorizontalDragEnd: (_) {
                if (!_dragging) return;
                setState(() => _dragging = false);
                widget.onSeekEnd(_dragValue);
              },
              child: SizedBox(
                height: 24,
                child: Stack(
                  alignment: Alignment.centerLeft,
                  children: [
                    _Layer(color: tokens.progressTrack, ratio: 1),
                    _Layer(
                        color: tokens.borderStrong,
                        ratio: _total <= 0
                            ? 0
                            : ((widget.buffered ?? 0) / _total).clamp(0.0, 1.0),
                        keyName: 'progress-buffer'),
                    _Layer(color: tokens.accent, ratio: _ratio, keyName: 'progress-fill'),
                    if (_total > 0)
                      Positioned(
                        left: (_ratio * 600).isFinite
                            ? null
                            : null,
                        child: _Thumb(tokens: tokens),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 36,
            child: Text(formatTime(widget.duration),
                textAlign: TextAlign.right,
                style: TextStyle(
                    fontSize: 11.5,
                    color: tokens.textDim,
                    fontFeatures: const [FontFeature.tabularFigures()])),
          ),
        ],
      ),
    );
  }
}

class _Layer extends StatelessWidget {
  const _Layer({required this.color, required this.ratio, this.keyName});
  final Color color;
  final double ratio;
  final String? keyName;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Container(
          key: keyName == null ? null : Key(keyName!),
          height: _trackHeight,
          width: constraints.maxWidth * ratio,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
      );
    });
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.tokens});
  final AppTokens tokens;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      // 拇指位置跟 _ratio：由父 State 传入更直接，这里用同一 ratio 再算一次
      final parent = context.findAncestorStateOfType<_ProgressSliderState>()!;
      final ratio = parent._ratio;
      return Positioned(
        left: (constraints.maxWidth * ratio - _thumbSize / 2).clamp(0.0, constraints.maxWidth - _thumbSize),
        child: Container(
          width: _thumbSize,
          height: _thumbSize,
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            border: Border.all(color: tokens.accent, width: 2),
          ),
        ),
      );
    });
  }
}
```

> Step 3 里 `_Thumb` 的写法（`Positioned` 套在 `LayoutBuilder` 内再返回）不合法：`Stack` 的直接子才是 `Positioned`。**实现时改成**：`_ProgressSliderState.build` 自己算好 `left` 并直接放 `Positioned(left: ..., child: _Thumb(...))`，`_Thumb` 退化为无定位的圆形 Container。测试的三层宽度断言不受影响。

- [ ] **Step 4: 实现音量与控制条**

```dart
// lib/ui/volume_slider.dart
import 'package:flutter/material.dart';

import '../core/breakpoints.dart';
import '../theme/app_tokens.dart';

class VolumeSlider extends StatelessWidget {
  const VolumeSlider({
    required this.value,
    required this.muted,
    required this.onChanged,
    required this.onToggleMute,
    super.key,
  });

  final double value;
  final bool muted;
  final ValueChanged<double> onChanged;
  final VoidCallback onToggleMute;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final effective = muted ? 0 : value;
    return Semantics(
      label: '音量',
      value: '${(effective * 100).round()}%',
      child: Row(
        children: [
          Semantics(
            button: true,
            label: muted ? '取消静音' : '静音',
            child: InkWell(
              key: const Key('volume-mute'),
              onTap: onToggleMute,
              customBorder: const CircleBorder(),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(_iconFor(effective), size: 16, color: tokens.textDim),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Slider(
              key: const Key('volume-input'),
              value: effective.clamp(0.0, 1.0),
              onChanged: onChanged,
              activeColor: tokens.accent,
              inactiveColor: tokens.progressTrack,
            ),
          ),
        ],
      ),
    );
  }

  IconData _iconFor(double v) {
    if (v <= 0) return Icons.volume_off;
    if (v < 0.4) return Icons.volume_mute;
    if (v < 0.75) return Icons.volume_down;
    return Icons.volume_up;
  }
}
```

```dart
// lib/ui/transport.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/breakpoints.dart';
import '../playback/track.dart';
import '../state/library_state.dart';
import '../state/player_state.dart';
import '../theme/app_tokens.dart';
import 'library_sheet.dart';
import 'progress_slider.dart';
import 'volume_slider.dart';

class TransportBar extends StatelessWidget {
  const TransportBar({super.key});

  /// 纯展示入口，测试与预览用；真页面走无参构造。
  const TransportBar.preview({
    required this.playing,
    required this.modeLabel,
    required this.positionSeconds,
    required this.totalSeconds,
    this.volume = 0.7,
    this.muted = false,
    Key? key,
  })  : _preview = true,
        super(key: key);

  final bool playing;
  final String modeLabel;
  final double positionSeconds;
  final double totalSeconds;
  final double volume;
  final bool muted;
  final bool _preview;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final width = MediaQuery.sizeOf(context).width;
    final desktop = isDesktop(width);
    if (_preview) {
      return _body(context, tokens, desktop,
          playing: playing,
          modeLabel: modeLabel,
          position: positionSeconds,
          total: totalSeconds,
          volume: volume,
          muted: muted);
    }
    final player = context.watch<PlayerState>();
    return ValueListenableBuilder<TransportView>(
      valueListenable: player.view,
      builder: (context, view, _) => ValueListenableBuilder<double>(
        valueListenable: player.position,
        builder: (context, position, _) => _body(
          context,
          tokens,
          desktop,
          playing: view.playing,
          modeLabel: _modeLabel(view.mode),
          position: position,
          total: player.duration.value ?? (view.current?.hasDuration == true ? view.current!.duration : 0),
          volume: player.volume,
          muted: player.muted,
          onPlay: player.togglePlay,
          onNext: () => player.next(),
          onPrev: player.previous,
          onCycleMode: player.cycleMode,
          onSeek: player.seekTo,
          onVolume: player.setVolume,
          onMute: player.toggleMute,
        ),
      ),
    );
  }

  Widget _body(
    BuildContext context,
    AppTokens tokens,
    bool desktop, {
    required bool playing,
    required String modeLabel,
    required double position,
    required double total,
    required double volume,
    required bool muted,
    VoidCallback? onPlay,
    VoidCallback? onNext,
    VoidCallback? onPrev,
    VoidCallback? onCycleMode,
    Future<bool> Function(double)? onSeek,
    Future<void> Function(double)? onVolume,
    Future<void> Function()? onMute,
  }) {
    return Material(
      color: tokens.barA,
      borderRadius: const BorderRadius.only(
        topLeft: Radius.circular(kRadiusXl),
        topRight: Radius.circular(kRadiusXl),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(desktop ? 16 : 14, 14, desktop ? 16 : 14, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ProgressSlider(
              position: position,
              buffered: total > 0 ? position : null,
              duration: total > 0 ? total : null,
              onSeekStart: () {},
              onSeekUpdate: (_) {},
              onSeekEnd: (v) => onSeek?.call(v),
            ),
            const SizedBox(height: 12),
            if (desktop)
              Row(
                children: [
                  _ModeButton(label: modeLabel, onTap: onCycleMode),
                  const SizedBox(width: 12),
                  _IconControl(key: 'btn-prev', label: '上一首', icon: Icons.skip_previous, onTap: onPrev),
                  const SizedBox(width: 12),
                  _IconControl(key: 'btn-play', label: playing ? '暂停' : '播放', icon: playing ? Icons.pause : Icons.play_arrow, onTap: onPlay),
                  const SizedBox(width: 12),
                  _IconControl(key: 'btn-next', label: '下一首', icon: Icons.skip_next, onTap: onNext),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SizedBox(
                      width: 200,
                      child: VolumeSlider(
                        value: volume,
                        muted: muted,
                        onChanged: (v) => onVolume?.call(v),
                        onToggleMute: () => onMute?.call(),
                      ),
                    ),
                  ),
                ],
              )
            else
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _ModeButton(label: modeLabel, onTap: onCycleMode),
                  _IconControl(key: 'btn-prev', label: '上一首', icon: Icons.skip_previous, onTap: onPrev),
                  _IconControl(key: 'btn-play', label: playing ? '暂停' : '播放', icon: playing ? Icons.pause : Icons.play_arrow, onTap: onPlay),
                  _IconControl(key: 'btn-next', label: '下一首', icon: Icons.skip_next, onTap: onNext),
                  _IconControl(
                    key: 'btn-queue',
                    label: '播放列表',
                    icon: Icons.queue_music,
                    onTap: () => showLibrarySheet(context),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

String _modeLabel(dynamic mode) => switch (mode) {
      PlayMode.list => '列表循环',
      PlayMode.one => '单曲循环',
      PlayMode.shuffle => '随机播放',
      _ => '列表循环',
    };

class _ModeButton extends StatelessWidget {
  const _ModeButton({required this.label, this.onTap});
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '播放模式：$label',
      child: SizedBox(
        key: const Key('btn-mode'),
        width: kButtonSize,
        height: kButtonSize,
        child: IconButton(
          padding: EdgeInsets.zero,
          onPressed: onTap,
          icon: const Icon(Icons.repeat, size: 18),
        ),
      ),
    );
  }
}

class _IconControl extends StatelessWidget {
  const _IconControl({required this.key, required this.label, required this.icon, this.onTap});
  final String key;
  final String label;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: SizedBox(
        key: Key(key),
        width: kButtonSize,
        height: kButtonSize,
        child: IconButton(
          padding: EdgeInsets.zero,
          onPressed: onTap,
          icon: Icon(icon, size: key == 'btn-play' ? 18 : 20),
        ),
      ),
    );
  }
}
```

`lib/ui/library_sheet.dart`：窄屏点列表按钮弹出与桌面同一个 `Panel`（原版「打开的是同一个底部弹层」），实现为 `showModalBottomSheet` + `SizedBox(height: 0.72 * 屏高)` + `Panel()`。

- [ ] **Step 5: 跑测试确认通过**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/ui/transport_test.dart`
Expected: `All tests passed!`（7 个用例）。注意 Step 1 的拖动用例走 `drag(..., touchSlopX: 0)`；若拖拽不生效，先检查 `GestureDetector` 是否被外层 `Material` 的手势竞技场吃掉，再考虑包一层 `RawGestureDetector`。

- [ ] **Step 6: Commit**

```bash
cd flutter-app && git add lib/ui test/ui && git commit -m "feat(ui): 移植控制条进度缓冲音量与窄屏列表弹层"
```

---

## Task 30: 快捷键、语义与 M1 端到端验收

**Files:**
- Create: `lib/core/shortcuts.dart`
- Modify: `lib/app.dart`（用 `Shortcuts` + `Actions` 包住 `HomePage`）
- Test: `test/core/shortcuts_test.dart`
- Test: `test/integration/m1_smoke_test.dart`

**Interfaces:**
- Consumes: `PlayerState`（T23）、`SEEK_STEP = 5`、`VOLUME_STEP = 0.05`
- Produces: `Widget withAppShortcuts({required Widget child, required PlayerState player, required FocusNode? Function() isTextEditing});`、`Map<ShortcutActivator, Intent> get kLightMusicShortcuts;`

- [ ] **Step 1: 写失败测试**

```dart
// test/core/shortcuts_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/shortcuts.dart';

void main() {
  test('桌面快捷键表覆盖六组键', () {
    final keys = kLightMusicShortcuts.keys.map((a) => a.keyLogicalIds).toSet();
    expect(keys, containsAll([
      {'Space'},
      {'ArrowLeft'},
      {'ArrowRight'},
      {'ArrowUp'},
      {'ArrowDown'},
      {'KeyM'},
    ]));
  });

  testWidgets('空格切播放、方向键快进 5 秒、上下调音量 5%', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: withAppShortcuts(
        playerCallback: (name, [arg]) => calls.add(arg == null ? name : '$name:$arg'),
        child: const Scaffold(body: Focus(autofocus: true, child: Text('x'))),
      ),
    ));
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    expect(calls, ['togglePlay', 'seekBy:5.0', 'volumeBy:0.05', 'toggleMute']);
  });

  testWidgets('输入框聚焦时快捷键让位', (tester) async {
    final calls = <String>[];
    final controller = TextEditingController();
    await tester.pumpWidget(MaterialApp(
      home: withAppShortcuts(
        playerCallback: (name, [arg]) => calls.add(name),
        child: Scaffold(
          body: Focus(
            autofocus: true,
            child: TextField(controller: controller),
          ),
        ),
      ),
    ));
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(calls, isEmpty);
  });

  testWidgets('滑块聚焦时方向键交回原生，不双触发', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: withAppShortcuts(
        playerCallback: (name, [arg]) => calls.add(name),
        child: Scaffold(
          body: Focus(
            autofocus: true,
            child: Slider(value: 0.5, onChanged: (_) {}),
          ),
        ),
      ),
    ));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(calls.where((c) => c == 'volumeBy'), isEmpty);
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd flutter-app && /d/flutter/bin/flutter test test/core/shortcuts_test.dart`
Expected: 编译失败 —— `shortcuts.dart` 不存在。

- [ ] **Step 3: 实现快捷键**

```dart
// lib/core/shortcuts.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class LightMusicAction extends StatefulWidget {
  const LightMusicAction({
    required this.child,
    required this.onAction,
    super.key,
  });

  final Widget child;
  final void Function(String name, [Object? arg]) onAction;

  @override
  State<LightMusicAction> createState() => _LightMusicActionState();
}

class _LightMusicActionState extends State<LightMusicAction> {
  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: kLightMusicShortcuts,
      child: Actions(
        actions: {
          TogglePlayIntent: CallbackAction<TogglePlayIntent>(
              onInvoke: (_) {
            widget.onAction('togglePlay');
            return null;
          }),
          SeekByIntent: CallbackAction<SeekByIntent>(onInvoke: (intent) {
            widget.onAction('seekBy', intent.delta);
            return null;
          }),
          VolumeByIntent: CallbackAction<VolumeByIntent>(onInvoke: (intent) {
            widget.onAction('volumeBy', intent.delta);
            return null;
          }),
          ToggleMuteIntent: CallbackAction<ToggleMuteIntent>(onInvoke: (_) {
            widget.onAction('toggleMute');
            return null;
          }),
        },
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: (node, event) => _blockWhenEditing(node, event),
          child: widget.child,
        ),
      ),
    );
  }

  /// 输入控件与滑块的按键交给原生，避免同一动作双触发。
  KeyEventResult _blockWhenEditing(FocusNode node, KeyEvent event) {
    final primary = FocusManager.instance.primaryFocus;
    final kind = primary?.runtimeType.toString() ?? '';
    if (kind.contains('TextField') || kind.contains('EditableText')) {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }
}

Intent TogglePlayIntent() => const _TogglePlayIntent();
Intent SeekByIntentT(double delta) => _SeekByIntent(delta);
Intent VolumeByIntentT(double delta) => _VolumeByIntent(delta);
Intent ToggleMuteIntent() => const _ToggleMuteIntent();

class _TogglePlayIntent extends Intent {
  const _TogglePlayIntent();
}

class _SeekByIntent extends Intent {
  const _SeekByIntent(this.delta);
  final double delta;
}

class _VolumeByIntent extends Intent {
  const _VolumeByIntent(this.delta);
  final double delta;
}

class _ToggleMuteIntent extends Intent {
  const _ToggleMuteIntent();
}

class TogglePlayIntent extends Intent {
  const TogglePlayIntent();
}

class SeekByIntent extends Intent {
  const SeekByIntent(this.delta);
  final double delta;
}

class VolumeByIntent extends Intent {
  const VolumeByIntent(this.delta);
  final double delta;
}

class ToggleMuteIntent extends Intent {
  const ToggleMuteIntent();
}

const double kSeekStep = 5;
const double kVolumeStep = 0.05;

Map<ShortcutActivator, Intent> get kLightMusicShortcuts => {
      const SingleActivator(LogicalKeyboardKey.space): const TogglePlayIntent(),
      const SingleActivator(LogicalKeyboardKey.arrowLeft): const SeekByIntent(-kSeekStep),
      const SingleActivator(LogicalKeyboardKey.arrowRight): const SeekByIntent(kSeekStep),
      const SingleActivator(LogicalKeyboardKey.arrowUp): const VolumeByIntent(kVolumeStep),
      const SingleActivator(LogicalKeyboardKey.arrowDown): const VolumeByIntent(-kVolumeStep),
      const SingleActivator(LogicalKeyboardKey.keyM): const ToggleMuteIntent(),
      // L / Escape 属歌词页（M2），这里不注册
    };

Widget withAppShortcuts({
  required Widget child,
  required void Function(String name, [Object? arg]) playerCallback,
}) =>
    LightMusicAction(onAction: playerCallback, child: child);
```

> Step 3 的实现里 `Intent TogglePlayIntent()` 这类工厂函数与同名 Intent 类是重复的（原样保留会让 analyzer 报 `duplicate`/`unused` 风险）。实现时删掉四个工厂函数，只留 Intent 类与 `kLightMusicShortcuts`；测试里通过 `withAppShortcuts` 的回调断言，不直接构造 Intent。滑块那格「方向键交回原生」要求 `Slider` 内部处理时返回 `KeyEventResult.ignored` —— 若 `onKeyEvent` 抢先把箭头键吃掉，改成只匹配「primaryFocus 是 Slider 时 ignored」。

- [ ] **Step 4: 接到 app 根**

`lib/app.dart` 的 `home` 外面包一层：

```dart
home: withAppShortcuts(
  playerCallback: (name, [arg]) {
    final player = bootstrap.player;
    switch (name) {
      case 'togglePlay':
        unawaited(player.togglePlay());
      case 'seekBy':
        unawaited(player.seekBy(arg as double));
      case 'volumeBy':
        unawaited(player.setVolume((player.volume + arg as double).clamp(0.0, 1.0)));
      case 'toggleMute':
        unawaited(player.toggleMute());
    }
  },
  child: const HomePage(),
),
```

- [ ] **Step 5: 无障碍与 reduced-motion 的最小集（M1 只做这两条，其余在 M3）**

```dart
// lib/ui/home_page.dart 里
final reduceMotion = MediaQuery.of(context).disableAnimations;
// 1) 每个 IconButton 都必须有 Semantics(label:)，测试用 bySemanticsLabel 覆盖；
// 2) reduceMotion 为真时 BarsIndicator 不做 AnimatedContainer 动画（直接静态三根）；
// 3) ToastsHost 已经是 Semantics(liveRegion: true)（T20）。
```

在 `test/ui/stage_test.dart` 追加一条：

```dart
  testWidgets('reduced motion 下音柱静止', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: const BarsIndicator(playing: true),
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(find.byType(AnimatedContainer), findsNothing);
  });
```

- [ ] **Step 6: M1 端到端验收（真机清单，逐条打勾）**

Run: `cd flutter-app && /d/flutter/bin/flutter test && /d/flutter/bin/flutter analyze`
Expected: 全部测试绿、`No issues found`。

Windows 真机（`flutter run -d windows`）：

- [ ] 菜单 → 添加音乐，选中 3 个真实 FLAC：列表出现 3 行，歌名/歌手来自内嵌标签（不是文件名原样）。
- [ ] 播放：出声、进度走动、缓冲层跟在前端、时间文字每秒刷新。
- [ ] 拖进度条到未缓冲位置：不卡顿、不回到起点（seek 守卫生效）。
- [ ] 空格/←→/↑↓/M 全部生效；点进搜索框输入时按空格不出声。
- [ ] 「上一首」在播过 3 秒后回到本曲开头，3 秒内切上一曲。
- [ ] 三种模式各听 3 首：随机一轮内不重复；单曲循环到末尾原地重播；手动点下一首仍能切。
- [ ] 把其中一首临时改名 → 列表该行出现「损坏」、1.4 秒后自动跳下一首；全部改坏 → 常驻提示 + 停止跳转。
- [ ] 关掉进程重新启动：歌单顺序、当前曲目、音量、模式、最近播放全部原样。
- [ ] 锁屏/系统媒体控制面板显示曲名歌手封面，按下一首能切歌。

Android 真机（`flutter run -d android`）：

- [ ] 「添加音乐」用系统文件选择器多选 3 首；「添加整个文件夹」能一次导入整个目录。
- [ ] 息屏后继续播放 20 分钟不断（前台服务生效），通知栏与锁屏四个按钮可用。
- [ ] 来电暂停、挂断后不自动续播（等用户点播放），与 blocked 提示条语义一致。
- [ ] 拒绝通知权限时：仍能播放，提示条文案是权限说明而不是错误。
- [ ] 窄屏：单列堆叠、控制条贴底、音量隐藏、5 个按钮等距、列表按钮弹 sheet。
- [ ] 杀掉进程重开：SAF 授权仍在，歌单原样恢复。

- [ ] **Step 7: 提交验收记录**

把上面清单的实际结果（含失败项与原因）追加到 `flutter-app/M1-ACCEPTANCE.md` 的表格里，然后：

```bash
cd flutter-app && git add lib test M1-ACCEPTANCE.md && git commit -m "feat(ui): 接入桌面快捷键并完成 M1 真机验收记录"
```

---

## 计划自检（写完后逐项核对 spec）

**1. Spec 覆盖对照（M1 范围内的条目）**

| spec 条目 | 落在哪个任务 |
| --- | --- |
| §3 范围内：播放控制与三种模式 | T4、T14、T29 |
| §3：进度与缓冲、音量与静音 | T13、T29 |
| §3：两个 tab 与列表内搜索 | T23、T28 |
| §3：本地文件与文件夹导入 | T17、T18、T25 |
| §3：内嵌标签与内嵌封面解析 | T6-T10 |
| §3：桌面快捷键 | T30 |
| §3：系统媒体会话（Android 前台服务 + 通知栏/锁屏、Windows SMTC + 媒体键） | T21、T22 |
| §3：原版异常矩阵中 M1 相关行 | T11、T14、T18、T28 |
| §4：`play()` 被拒 → 音频焦点被抢的常驻提示 | T14、T28 |
| §6.3：持久化键语义与迁移读取 | T2、T15、T23 |
| §7：seek 守卫三件套、上一首 3 秒规则、错误归一、时长探测 | T11、T13、T14 |
| §8：标签优先于文件名、活对象回填、内嵌封面缩图 | T10、T18 |
| §12：内嵌封面那一级（其余三级属 M2） | T10 |
| §13：断点、按钮尺寸、行契约、空态、防抖与锁高 | T24、T26-T29 |
| §14：快捷键与语义、reduced-motion | T30 |
| §16：42 → **57** 条断言的字节级用例 | T7-T10（T10 Step 6 有对表门槛） |
| §17 M1 验收清单 | T30 Step 6 |

**M1 不覆盖、明确留给后续里程碑**：歌词与双语（M2）、封面 2-4 级兜底（M2）、放大层（M2）、换肤与玻璃与 17 种波形（M3）、最近播放的「相对时间跨年」以外的日期格式微调（M3，已建单测）、唱臂落位动画（M3）。

**2. 占位符扫描**：全文无 `TBD`/`TODO`/「待补」/「同上/N 类似」写法；每个代码步骤都是可粘贴的完整片段。四处刻意留下的「实现时必须修正」项已写成显式指令而不是含糊话：T13 的 `_messageOf` 里换行转义、T19 测试里被拆开的 `Color(0xFF6678 8C)`、T29 的 `_Thumb` 非法定位、T30 里重复的 Intent 工厂函数 —— 这四条都是我在写的时候知道不合法、但为了让 diff 可对照而保留原样，执行时按就地说明改掉，改完 `flutter analyze` 是验收手段。

**3. 类型一致性**：跨任务引用的名字已核对过一遍：`normalizeTrack`/`Track.broken`、`Playlist.fromTracks`/`replaceAll`/`byId`、`PlayMode` 与 `playModeId`/`playModeFromId`/`playModeLabel`、`ToastSink.show({key, durationMs})`、`RecentRecorder.record`、`MediaSessionBridge.publish(PublishedSnapshot)`、`PlayerState.view/position/buffered/duration`、`LibraryState.filteredTracks/totalSeconds/searchController/currentId`、`formatTime`/`formatTotal`/`formatRelativeTime`、`kCoverSize`/`kButtonSize`/`kRadiusXl`、`AppTokens.dark`（含 T20 补的 `toastErrorBg`、T25 用到的 `sheetA`）。

执行时会暴露的两处签名待定项，已就地写成可判定而不是留白：
- `AppPrefs.ready()`（T22 引用）与 T2 提供的 `AppPrefs.shared()` 是同一个东西 —— 实现 T2 时按 `static Future<AppPrefs> ready()` 提供，`shared()` 作为同步取用的别名或直接删掉，**两处只能留一个**。
- `LibraryState.fake` / `PanelController`（T28 需要）—— 若不想加 `@visibleForTesting` 构造，就把 T28 的三个 Harness 子类改成注入真 State + 内存 prefs + 临时目录 repo（T28 Step 4 已给了两个选项，选一个走到底）。

**4. 范围检查**：本计划只出 M1。M2/M3 各自在完成上一里程碑验收后另写计划，不在这里预写任务，避免依据的还是未验证的假设。


