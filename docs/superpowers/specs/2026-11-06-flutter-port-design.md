# 流光音乐 Flutter 移植 · 设计文档

日期：2026-11-06（2026-11-07 修订：M2 基准取工作区现状、双语生命周期与开关位置改写、网易直连风险关闭）
状态：M1 已实现并本地合回 `main`；本次 M2 相关的修订待用户复核
范围：把现有 React 18 + Vite + TypeScript 版「流光音乐」移植为 Flutter 工程，目标平台 Windows 桌面 + Android，终点是功能与视觉 1:1。

---

## 1. 背景与基准

现有实现约 12k 行：`src/App.tsx` 1757 行、`src/styles/app.css` 4229 行、`src/lib/wave-styles.ts` 1042 行（17 种波形样式）、`src/server/music-api.ts` 960 行（5 个同源代理）、`src/state/` 15 个 Context + hook、`src/lib/` 18 个纯逻辑模块。

移植期间 React 版**原地保留**，作为唯一的验收基准：同一批 FLAC、同一首歌，两侧并排比对歌名/歌手拆分、封面命中、歌词命中、双语行对齐、布局与配色。Flutter 工程落在 `music-player/flutter-app/`，与 React 版同一个 git 仓库，不新增子模块、不改动画笔触及 React 侧任何代码。

**基准取工作区现状，不取 HEAD**（2026-11-07 用户确认）。React 侧有一批未提交的改动正好压在 M2/M3 的靶心上：`src/state/lyrics.tsx` 的双语缓存语义、`BilingualToggle` 的位置与尺寸、`App.tsx` 的 Lightbox `zoomAt` 抽取与双击缩放，以及 M3 的 `glass.tsx` / `GlassControl.tsx` / `cardTransparency`·`cardFrost` 两个键。对照与并排验收一律以**他正在跑的那份**为准；本文档 §11 / §13 已按这份现状改写。这些 React 文件在移植期间**只读**：不暂存、不修改、不提交。

## 2. 已确认的决策

| 决策 | 取值 | 理由 |
| --- | --- | --- |
| 目标平台 | Windows 桌面 + Android | 桌面放本地 FLAC 曲库，手机随身上听 |
| 曲库接入 | 手动多选添加与拖放为主，桌面额外提供「添加整个文件夹」 | 保住原版「添加→还原」语义，不引入原版没有的曲库模式 |
| 频谱数据源 | 离线预解析（`audio_decoder` 解 PCM → 本地 FFT → 帧表） | Web Audio `AnalyserNode` 在 Flutter 无对应物；离线方案双端一套代码、暂停冻结与 seek 取帧天然正确 |
| 交付节奏 | M1 / M2 / M3 三个里程碑，每段验收一次 | 每段都是能装能听的真版本，问题定位在小范围 |
| 视觉还原 | 像素级 1:1 | 布局、控件、图标、文案、间距、token、材质全部按原版重建 |
| 播放内核 | media_kit（libmpv） | 覆盖原版 11 个扩展名白名单，含 Windows Media Foundation 不支持的 ogg/oga/opus/webm/weba；双端同一解码器 |
| 网络层 | Dart 直连 LRCLIB / iTunes / 网易 / 维基 | Flutter 无 CORS，`server/music-api.ts` 整体不迁移；React 生产构建里被降级关闭的封面匹配与中文双语，在 Flutter 侧完整可用 |
| 状态管理 | ChangeNotifier / ValueNotifier + Provider | 与原版 15 个 Context 一一对应；进度单独走 `ValueListenableBuilder`，等价于 `useSyncExternalStore` 的叶子订阅 |
| 系统媒体会话 | Android 前台服务 + 通知栏/锁屏控制，Windows SMTC + 媒体键 | 用户明确要求「锁屏切歌」；Android 没有前台服务时息屏即被系统挂起，所以这项与核心播放同期交付（M1），不能后补 |

## 3. 范围与非目标

**范围内**：播放控制与三种播放模式、进度与缓冲、音量与静音、播放列表与「最近播放」两个 tab、列表内搜索、本地文件与文件夹导入、内嵌标签与内嵌封面解析、四级封面兜底、歌词自动匹配、非中文歌词双语、手动 `.lrc` 导入与配对、完整歌词页、封面放大层、四套换肤（明暗 × 主题色）、17 种波形样式、卡面透明/磨砂双滑块、歌词高亮色、桌面快捷键、系统媒体会话（Android 前台服务 + 通知栏与锁屏控制、Windows SMTC 与媒体键）、无障碍与 reduced-motion、原版异常矩阵。

**不在范围内**：Web 编译目标（等于把 React 版重写一遍，收益为零）；iOS（本机无 Mac + Xcode，无法打包）；歌词与封面的手动编辑、音频转码；曲库文件夹常驻监听；多设备同步。

> 系统媒体会话是本设计里**唯一一处原版没有的能力**（浏览器拿不到锁屏与媒体键）。它按用户明确要求加入，其余「不移植原版没有的东西」的约束不变。详细语义见 §7。

## 4. 浏览器语义的映射

移植时不静默删除分支。原版每条依赖浏览器能力的路径，对应关系如下。

| 原版 | Flutter | 说明 |
| --- | --- | --- |
| `URL.createObjectURL(blob)` | 桌面：绝对路径；Android：SAF 持久 URI | `Track.src` 语义不变，只是不再需要回收对象 URL |
| IndexedDB 存音频 Blob | 只存路径/URI + 回填后的元数据 | 文件系统本身是持久层，不再复制音频字节 |
| 「刷新页面后恢复」 | 冷启动恢复 | 同一套还原流程与同一套顺序、当前曲目、封面、时长、歌词 |
| 整页拖放文件 | 桌面保留拖放；Android 换成文件选择器 + 「分享到本应用」 | 系统不向第三方应用派发页面级 drop |
| `play()` 被自动播放策略拒绝（`NotAllowedError`） | Android 音频焦点被抢 / 输出设备不可用 | 仍走同一档 UI：常驻提示条 + 「继续播放」按钮 + 用户真实交互后自动重试，最多 3 次；**额度用尽后按 §7 的三支收尾**（撤横幅与「继续播放」+ 一条错误级提示「仍无法自动恢复播放，请点击播放按钮」+ 不再自动重试，改为用户点播放按钮），详见 §7「错误归一」段的第五类文案 |
| `MEDIA_ERR_*` 四类 | media_kit 状态与预校验归一（见 §7） | mpv 不暴露原生媒体错误码，需自行分类 |
| `matchMedia('prefers-color-scheme')` | `PlatformBrightness` + `didChangePlatformBrightness` | system 模式的解析与实时跟随 |
| `prefers-reduced-motion` | `MediaQuery.disableAnimationsOf` | 关闭旋转、呼吸、律动等装饰动画 |
| `localStorage` | `shared_preferences` | 键名语义逐条映射（见 §6.3） |
| CSS 变量 + `data-mode`/`data-accent` | `AppTokens` + `ThemeData` | 组件层同样不碰颜色（见 §9） |
| `aria-label` / `aria-live` / skip-link | `Semantics(label:)` / `Semantics(liveRegion:)` / `sortKey` + 焦点顺序 | 见 §14 |

## 5. 工程结构与分层

```
flutter-app/
├─ lib/
│  ├─ main.dart                     # 先读 prefs 再 runApp，浅色用户不闪黑帧
│  ├─ app.dart                      # MaterialApp + 断点分发
│  ├─ playback/                     # 播放内核层
│  │   ├─ audio_player.dart         # media_kit 封装，等价 lib/player.js
│  │   ├─ playlist.dart             # 纯数据，等价 lib/playlist.js
│  │   ├─ play_error.dart            # 四类错误归一
│  │   ├─ media_session_bridge.dart  # 系统媒体会话抽象 + 双端实现
│  │   └─ transport_controller.dart  # 编排：模式、上下曲、熔断、自动跳
│  ├─ metadata/
│  │   └─ audio_tags.dart           # 字节级标签与内嵌封面（1:1 移植）
│  ├─ library/
│  │   ├─ library_repository.dart   # JSON 文件仓库（替代 local-store.js）
│  │   ├─ import_service.dart        # 文件/文件夹导入、白名单、入列、回填
│  │   ├─ recent_store.dart          # 最近 50 条
│  │   └─ track_handle.dart          # 路径 / SAF URI 的统一句柄
│  ├─ lyrics/
│  │   ├─ lrc_parser.dart            # parseLRC 全量移植
│  │   ├─ lyrics_source.dart         # LRCLIB 并行匹配、缓存、冷却、失败分类
│  │   ├─ translate_source.dart      # 网易译文 + 跨库对齐
│  │   ├─ language_detect.dart        # 字符集判语种
│  │   ├─ s2t.dart                   # 在线内容转简体
│  │   └─ lyrics_file.dart            # 手动 .lrc 读取与配对评分
│  ├─ artwork/
│  │   ├─ cover_source.dart          # iTunes 打分匹配
│  │   ├─ artist_image.dart         # 维基写真
│  │   ├─ generated_cover.dart      # CustomPainter 生成卡（FNV-1a 派生）
│  │   ├─ image_cache.dart          # 磁盘图片缓存目录
│  │   └─ cover_for_display.dart     # 四级兜底汇合点
│  ├─ wave/
│  │   ├─ wave_frame.dart            # WaveFrame 数据契约（与原版同字段）
│  │   ├─ wave_source.dart           # 帧表查询 + 装饰回退
│  │   ├─ spectrum_analyzer.dart     # 离线 FFT 分帧与对数折叠
│  │   ├─ spectrum_store.dart        # 帧文件的读写与失效判定
│  │   ├─ spectrum_queue.dart        # 串行解析队列，当前曲目插队
│  │   └─ styles/                    # 17 个 CustomPainter
│  ├─ state/                        # 15 个 ChangeNotifier，与原版 Context 一一对应
│  ├─ theme/
│  │   ├─ tokens.dart                # app.css 变量表逐条提成 Dart token
│  │   ├─ theme_spec.dart            # mode × accent → 解析后的具体颜色
│  │   └─ app_theme.dart             # ThemeData 与组件默认样式
│  ├─ core/
│  │   ├─ app_prefs.dart             # 带容错的读写（替代 storage.js）
│  │   ├─ shortcuts.dart             # 桌面快捷键
│  │   └─ breakpoints.dart           # 900px 断点等常量
│  └─ ui/                           # 一 widget 一文件，对应 App.tsx 的组件块
│      ├─ header.dart
│      ├─ stage.dart
│      ├─ panel.dart
│      ├─ transport.dart
│      ├─ lyrics_page.dart
│      ├─ lightbox.dart
│      ├─ toasts.dart
│      ├─ drawer_menu.dart
│      ├─ theme_drawer.dart
│      ├─ glass_control.dart
│      ├─ wave_strip.dart
│      ├─ wave_style_picker.dart
│      ├─ vinyl_deck.dart
│      ├─ library_sheet.dart
│      ├─ bilingual_toggle.dart
│      └─ lyric_color_button.dart
├─ test/                            # audio_tags_test.dart 等（见 §16）
└─ pubspec.yaml
```

层与层之间的规则：`playback` / `metadata` / `lyrics` / `artwork` / `wave` 是纯逻辑，不 import `flutter/material.dart`（`wave/styles/` 除外，它只依赖 `dart:ui`）；`state/` 是唯一能把逻辑层接进 UI 的地方；`ui/` 不出现十六进制颜色字面量，只从 `AppTokens` 取。这样原版「模块职责互不越界」的约束在 Dart 侧同样可检查。

## 6. 数据契约

### 6.1 Track

与 `src/state/types.ts` 同字段，新增 `handle` 承载音频来源。

```dart
class Track {
  String id;
  String title;
  String artist;
  String album;
  String cover;          // 空串表示还需要匹配；一有值即代表「已有真封面」，在线匹配永久跳过
  String src;            // 由 handle 生成的可播放地址
  double duration;       // NaN 表示尚未探到
  bool isLocal;
  String? lyrics;        // 带时间轴的 LRC
  String? lyricsPlain;   // 无时间轴纯文本
  String? lyricsSource;  // 'auto' | 'manual'
  bool restored;
  TrackHandle handle;    // FilePath | SafUri
}
```

`TrackHandle` 两个实现：`FilePathHandle(path)`（桌面）与 `SafUriHandle(uri, displayName)`（Android，持有持久读取权限）。`exists` 与 `openRead` 由句柄提供；文件消失时 `exists` 为假，列表项打失效标记，点击给提示而非静默失败。

### 6.2 WaveFrame

字段与 `src/lib/wave-signal.ts` 完全一致，17 个 painter 因此无需改数据接口。

```dart
class WaveFrame {
  final Float64List bands;  // 频段能量 0..1
  final Float64List wave;   // 时域 -1..1
  final double level;       // 整帧平均能量
  final double phase;       // 累计动画时间（秒）
  final double dt;          // 距上一帧的秒数，峰值回落用墙钟
  final double width, height;
  final bool live;          // 是否来自真实音频（含暂停后冻结的那一帧）
  final String seed;        // 曲目 id
}
```

采样输入 `WaveReadInput` 同样保留原版字段：`playing`、`phase`、`dt`、`seed`、`bandCount`、`waveCount`、`width`、`height`。

### 6.3 持久化键

`shared_preferences` 的键沿用原版语义（去掉 `light-music-player:v1:` 前缀的短键存在同一张映射表里，便于对照）：`playlist`、`currentId`、`mode`、`volume`、`muted`、`order`、`waveStyle`、`waveColored`、`lyricColor`、`cardTransparency`、`cardFrost`、`themeMode`、`themeColor`、`recent`、`bilingual`，加上老 `theme` 单值键只用于迁移读取（`mint|pink|blue` → `mode=dark` + 对应 accent，`light` → `mode=light`）。

三类存储的分工与原版一致：小键值走 prefs；歌单、历史、歌词缓存与配对结果走 `library_repository` 的 JSON 文件（原子写：写临时文件后 rename，解析失败时保留 `.bak` 并回退默认值，绝不白屏）；二进制走缓存目录（内嵌封面 JPEG、iTunes/维基图片、频谱帧文件、歌词与译文磁盘缓存）。

## 7. 播放与传输层

`AudioPlayer` 包住 `media_kit.Player`，对外接口与 `lib/player.js` 同名同义：`load(track, {autoplay})`、`pause()`、`seek(seconds)`、`seekBy(delta)`、`setVolume(0..1)`、`setMuted(bool)`、`toggleMute()`、`stop()`、`dispose()`，事件用 `on('error' | 'loading' | 'canplay' | 'playing' | 'pause' | 'timeupdate')` 形态派发，便于逐条对照。

三条流各自挂一个 `ValueNotifier`：`positionSeconds`、`bufferedSeconds`、`durationSeconds`。只有进度条、时间文字、波形条订阅它们，其余组件不随进度重绘。`positionNotifier` 的更新频率对齐原版 `timeupdate`（约 4Hz），波形条用自己的 `Tickerable` 以 60fps 读帧表，两者不共用节奏。

**跳转守卫照搬**：mpv 赋值 `position` 后仍会派发状态变化，原版的「一次记忆最多补做一次」约束（`#armSeekGuard` / `#clearSeekGuard` / `#verifySeekGuard` / `#applySeekGuardOnPlay`）完整移植，避免 `赋值 → playing → 再赋值` 自激导致播放位置永远停在起点。

**上一首语义**：已播放超过 `PREV_RESTART_AFTER = 3` 秒时回到本曲开头，否则切上一曲。

**错误归一**：导入时按 `AUDIO_EXTENSIONS`（mp3/wav/ogg/oga/opus/m4a/aac/flac/webm/weba/mp4）预校验，不支持的明确提示并跳过。运行期把 media_kit 的失败映射成原版四类文案：加载被中断 / 网络错误无法获取音频文件 / 音频解码失败文件可能已损坏 / 格式不支持或音频文件不存在，另有兜底文案「音频播放失败，请稍后重试」。曲目加载失败 → 列表打「损坏」角标 → 延迟 1.4s 自动跳下一首；`consecutiveFailures` 只在真正可播放时清零，累计 ≥ 列表长度时熔断：停止自动跳转、暂停播放、列表上方常驻提示 + Toast。

**第五类文案（移植新增，第 3 轮 I2；`kAutoplayGaveUpMessage`）**：「仍无法自动恢复播放，请点击播放按钮」—— 文案逐字取原版 `src/state/player.tsx:206`。触发点是手势重试额度（`MAX_AUTOPLAY_RETRIES` = 3）用尽那一次：同一处必须做完三件事 —— 清被拦状态、撤下那条带「继续播放」的横幅、发这一句**错误级**提示。只 `return` 不做后两件是缺陷：横幅还在、而它那颗按钮此后每次点击都原样返回，等于一个永远不动的死键，且没有任何解释。提示走 `toasts.error`，因此自动适用去重规矩（同 key 只留一条、原地改文案并重新计时）。

**时长探测**：入列后用一次性解码探 `duration`，3s 超时则保持 `--:--`，不阻塞入列。

### 7.1 系统媒体会话与锁屏控制

这是原版没有的能力（浏览器拿不到锁屏与媒体键），按用户要求补上，接在 `transport_controller` 之上而不是旁边 —— 所有来自锁屏、通知栏、媒体键的动作都走界面按钮用的同一个入口，因此模式、熔断、损坏跳过、最近播放记录这些语义自动一致，不出现第二条播放控制路径。

抽象成一个 `MediaSessionBridge` 接口：`updateMetadata(Track)`、`updatePlaybackState`、`updatePosition`、`updateActions`、`events` 流（`play` / `pause` / `next` / `prev` / `seek` / `stop`）。Android 与 Windows 各一个实现，界面层只依赖接口。

动作集合与语义：

- **播放/暂停**、**上一首**、**下一首**、**停止**（停止等价于界面上的停止：清当前曲目并回到空状态）。上一首沿用「已播放超过 3 秒则回到本曲开头，否则切上一曲」；随机模式下按洗牌队列推进，与界面按钮完全一致。
- **进度拖动**（Android 通知条支持时）走与界面进度条同一套 seek 守卫。
- 元数据带曲名、歌手、专辑、封面（用四级兜底后的 `coverForDisplay()` 那张；生成卡是画出来的，需要离屏渲染成位图再交给系统）。
- 播放模式变化同步给系统（Android 的 repeat / shuffle 状态），随机播放时「下一首」按钮按队列给出。

Android 侧必须做对的四件事：

1. **前台服务**：`media_player` 服务类型 + `FOREGROUND_SERVICE_MEDIA_PLAYBACK` 权限，Android 14 起缺这个声明会在息屏时被系统直接杀掉，表现为「锁屏就断」。
2. **通知权限**：Android 13+ 运行时申请 `POST_NOTIFICATIONS`。被拒时播放继续，但提示条明确写「通知栏控制需要允许通知权限」，并保留界面内控制 —— 这是权限态，不是错误态。
3. **音频焦点与路由**：申请 `AUDIOFOCUS_GAIN`；焦点被临时打断（来电、导航播报）时暂停并在 `AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK` 恢复后续播；耳机/蓝牙断开时按系统事件暂停，与原版 `MEDIA_ERR_ABORTED` 的话术分开写（「耳机已断开，播放暂停」）。
4. **后台起始**：服务被系统重启或从通知栏直接按下播放时，仍按冷启动还原流程走（先恢复歌单再播），不能拿空列表响应媒体键。

Windows 侧接 System Media Transport Controls：元数据与播放状态推给 SMTC，订阅按钮事件；物理媒体键（Play/Pause、Next、Prev）经由同一通道进来，因此 §14 的键盘快捷键表额外列出这三个键，且与 §13 的放大层让位规则一致（放大层开着时不响应系统媒体键，避免与拖拽冲突）。SMTC 无进度拖动，Windows 侧只提供四个按钮动作。

「真正出声才记最近播放」这条记录规则对媒体键路径同样成立；被系统拦下的自动播放不计入，锁屏按下的那次算真实用户交互，因此它会正常触发播放与记录。

### 7.2 媒体会话的两个实现通道

首选 `flutter_media_session`（同一套 API 覆盖 Android 与 Windows，双端只维护一个 bridge 的实现表）。若 M1 实测发现它的 Android 通知缺动作按钮或缺前台服务（媒体会话的必需项，不是可选项），则按下列降级走，且不回头改界面层：Android 换 `audio_service` 0.18.19（前台服务、通知动作、headless restart 齐备，配合 media_kit 的 `AudioHandler` 封装），Windows 换 `smtc_windows` 1.1.0。两个通道都藏在 `MediaSessionBridge` 后面，切换只影响 `playback/` 目录内的文件。

## 8. 曲库与导入

流程与原版 `state/library.tsx` 一致：校验扩展名 → 立即入列（可播）→ 解析内嵌标签 → 探时长 → 落库 → 后台预取封面与歌词。

标签优先于文件名：先读内嵌 title/artist/album/albumArtist，无标签才按「歌手 - 歌名」或「歌名 - 歌手」拆文件名；拆错会被标签纠正，纠正结果落库，下次启动不重复解析。`mergeTaggedNames` 的判定逐条移植。

内嵌封面解析走 `metadata/audio_tags.dart`，覆盖 ID3v2.2/2.3/2.4（含整标签与单帧 unsynchronisation、UTF-16 文本、缺失 mime 时按魔数嗅探）、ID3v1、FLAC `PICTURE`、OGG base64 `METADATA_BLOCK_PICTURE`、MP4 `moov.udta.meta.ilst.covr`。读取策略保持「只读需要的字节」：头 64KB 判格式，标签区按需再读，上限 8MB；任何一段失败只影响对应字段，畸形长度、越界帧、无 `moov` 的 MP4 一律不许抛出。文本编码按 ASCII → UTF-8 → GBK（连续高位字节）→ Latin-1 嗅探。取到的封面缩到 ≤600px JPEG 写入缓存目录。

桌面「添加整个文件夹」：递归扫描上述扩展名，按自然排序入列，数量超过一次性处理上限时分批（每批 50 首）落库并更新进度提示；不做曲库监听，导入是一次性动作。

「数据对了不等于界面变了」这条历史教训在 Dart 侧的防法：所有回填必须以列表里的活对象为目标（按 id 找回再改），改完显式 `notifyListeners()`，并在 widget 测试里断言「回填后 DOM（widget tree）里的文本确实变了」，而不只断言 repository 里有值。

冷启动还原时「文件仓 vs prefs」这对现场的取舍（框架是终审 I4 定的，内容经第 2 轮 R1/R2/R4/R6/R8 修订；与 `state/library_state.dart` 的 `restore()` / `_restoreCursor()` / `_restoreMode()` 注释同一条规则，两边不许各写一份）。

**顺序**：权威一律是文件仓 —— prefs 里那份 `order` 再陈旧也参与不了列表重建，还原末尾由 `_syncPrefsTrace()` 把它纠正成现场的真实顺序。**档案损坏**（回退过 `.bak`，或两份都读不出来、仓储退回空快照）时还原流程**只读痕迹、不写痕迹**（终审 R8）：那份快照本身关于「用户停过哪一首」什么也没说，按它写下去就是把 prefs 里最后一条可读记录覆盖成空数组，只有真正拿到过一次健康档案才允许改写现场。第 4 轮 I11 把这条承诺**补到收尾那一次落库上**：`persist()` 里的痕迹同步与 `restore()` 受同一个 gate（`LibraryState` 把「这份档案坏过」记成字段），回填收尾仍照常写**文件仓**（把回填结果写回去反而是在修档案），但 prefs 的 `order` / `currentId` 一个字都不动。从前那次落库绕过了 gate，于是 `.bak` 回退出来的陈旧快照会在**同一个 launch 里**把痕迹改写成它自己、把 `currentId` 重建 —— M3 那句「停过」当场作废（虽不复活停过的歌，因为写的是 R4 定下的第一首，但 R8 的承诺被破坏了）。

**光标**：现场自洽（prefs 的 `order` 与文件仓顺序逐位一致，这是「这份现场没跨代过期」的闸门）时以 prefs 的 `currentId` 为准 —— 播放推进只经 `PlayerState.schedulePersist()` 按 400ms 防抖写 prefs、不重写整份档案，所以自洽的现场里 prefs 才是更新的陈述。同一前提下 `currentId` **键缺失**是一句**否定断言**（用户按过停止，或当前曲目被删空过，两条路径都把键如实清掉了；终审 R2），候选集即为空，绝不回落到 `snap.currentId` —— 那正是停止之前那次 `persist()` 写下的值，回落它就是复活用户明明停掉的那一首。两份 `order` 矛盾（或 prefs 缺 `order`）时整条 prefs 痕迹按过期处理，这时才轮到文件仓快照的 `currentId` 打头 —— **只有一个例外**（第 3 轮 M3）：那句否定断言不以「自洽」为前提，只要 `order` 写过而 `currentId` 不在，就是「没有光标」这句陈述本身，候选集仍为空。原先它只在痕迹自洽时参与判定，于是 R8 × R2 的双故障组合（正式档案坏了、回退 `.bak`，痕迹又是上一代的陈旧 order）里第一顺位恰好是停止之前那次 `persist()` 留下的值，停过的歌照样复活；R8 的「陈旧」该决定的是**要不要信它指的那一首**，不是**要不要信它说没有光标**。**两边都给不出有效 id 时：非空列表落到第一首**，保持暂停、绝不自动播；只有空列表才是空舞台。原版 `src/state/player.tsx:556` 写的是 `storedId && indexOfId(storedId) >= 0 ? indexOfId(storedId) : 0` —— 任何一次非空启动都落得到一个光标，第 1 轮在此处调 `clearCurrent()`（「没有有效 id 就没有光标」）是移植自创、已被代码与原版共同推翻。光标落定后 `_syncPrefsTrace()` 把 prefs 的 `currentId` 跟着**补写一致**（原版 `src/state/player.tsx:243-249` 的 `persist()` 每次都以 `playlist.current` 重写这两个键，空才 `Storage.remove`），不留「界面指第一首、存档指幽灵」两份真相。落盘时机：**停止播放那一条腿走 `flushPersist()` 同步落盘**（装配层把 `TransportController.onStopped` 接到它，且 `stopPlayback()` `await` 到落完才返回，终审 R2 的残留），因为防抖窗口对播放推进是省写盘的优化、对停止却是一段真实丢数据的空档（「停止 → 立刻杀进程」等于没停过）；播放推进仍保持 400ms 防抖不变。

**模式**：与光标同源同权（终审 R6）—— prefs 写过 `mode` 就以它为准（`PlayerState.cycleMode` 只写 prefs 这一处，档案里那份要等下一次 `persist()` 才跟上），没写过才回落 `snap.mode`；`clearPlaylist()` 只作废 `order` 与 `currentId` 两个键，**不动模式**（原版清列表不改模式）。

**音量与静音**只由 prefs 的 `volume` / `muted` 两个键承载（文件仓快照里那两个字段已删，见 §6.3），文件仓不可用或被重建都不会把它们悄悄清回默认值；`setVolume` **两个分支都清 muted**（对齐 `src/lib/player.js:322`：else 分支同样写 `muted = false`，只有 `v > 0` 那支额外记 `lastVolume`），所以「静音中拖到 0」留下的是 `volume=0、muted=false` 而不是解不掉的静音。也正因两个分支都清 muted，**冷启动读回的先后是承重的**（第 3 轮 M2）：`PlayerState._loadPersistedPrefs` 必须**先 volume 后 muted**，反过来写时那句 `setVolume(...)`（哪怕存档里音量就是 0）会把刚还原好的静音当场擦掉，「静音 + 音量 0」这份现场重启就变成「没静音」，而音量本来就是 0，按静音按钮也解不掉任何东西。

冷启动还有一次**自愈回填**（终审 C1 引入，第 2 轮 R1 换成落盘判据，第 3 轮 C1/I1、第 4 轮 C8/I9 收紧置位条件）：谓词是 `Track.metadataProbed` **未置位**且**字段仍缺**（时长未知，或标题/歌手还停在文件名猜出来的值上）才补跑 —— 标记负责「只治一次」，字段负责「没东西可补就别开文件」。标记**只记给真的得出了结论的那一条**：批次收尾时要求①时长探针**真的问过**，没被 3s 预算掐掉、途中也没被 `close()` 关掉（`DurationProbe.probeOutcome` 的 `DurationProbeOutcome` 是四态 `probed` / `timedOut` / `notAttempted` / `interrupted`，只有 `probed` 算数；第 4 轮 C8 补的两支正是「退出时正在跑自愈回填，探针被关掉」—— `close()` 会把已入队的探测照常排空，排空期间拿到的答案不作数，但已经拿到的时间数值照填），并且②这一次**确实有见证**：要么真的打开并读到了文件字节（`hydrateMetadata` 如实回报；`_prefetchHead` 给 null 意味着「文件不在 / 打不开 / SAF URI 用不了 dart:io」，那不是「这文件没标签」），要么探到了时长（第 4 轮 I9：mpv 打得开而 dart:io 打不开的文件 —— Windows 共享冲突就是这个形状 —— 标签一个字节也读不到，但时长是真的；从前只认「读到字节」，这类曲目永远不记账，每次启动重开文件、重探一遍再整库重写档案）。「打开了、也确实没标签没时长」照旧置位 —— 那才是 R1 要止住的那次反复重跑。另外，这一批**什么都没学到**（一条都没记上）时，批次收尾那次落库也不发生（第 4 轮 I9）：没有新结论就没有要落盘的东西，别每次启动白写一遍整库档案。从前这些全塞在一个无条件 `finally` 里，连「整个文件没读到」也置位，而重复导入同一路径是 no-op，于是永久冻结一次暂时的失败（U 盘没挂上、文件被占用、大 FLAC 首次打开慢），除了改档案格式没有任何自愈路径 —— 复审据此判 Critical。**接受的代价**：真的被永久拔掉的盘会每次启动重试一次，但一条曲目一次启动最多重试一次、失败即不置位，`!metadataProbed` 那道闸仍在，不会退化成整库重跑；这条不许被读成「回到旧写法」。从前只按字段猜，「无封面」「标题等于文件名猜值」对用户那批「`歌手 - 歌名` 命名 + 带标签」的真实曲目几乎恒真，于是每次启动把整个曲库重开文件重解析一遍、再整库重写一次档案。SAF 的 `content://` 句柄在 M1 开不了：按句柄能力位 `canProbeDuration` **跳过时长探针**（终审 R7，不留 3 秒白等，守卫保留），并且第 3 轮 I1 起，谓词的准入条件也从 `track.isLocal` **换成同一个能力位** —— 这类曲目因此既不进回填队列（不每次启动白跑）、也**不置探测标记**，等 M2 真接上 SAF 读取、把能力位翻成真值的那一刻，它们自动回到「未探测」状态被自愈接住；从前「标记照记」的写法会让新能力对这批曲目永久隐形。

## 9. 外观系统

两个维度正交：`ThemeMode`（`system` / `light` / `dark`）× `ThemeColor`（`mint` / `pink` / `blue`），解析成 `ThemeSpec`（`ResolvedMode` + accent）。`themeKey = "$resolvedMode-$resolvedAccent"`，波形这类「变了就重画」的地方以它为依赖。

`theme/tokens.dart` 承载 app.css 的变量表，包含：页面底色与卡片面、`accent` 与 `accentRgb` 三元组（凡「带透明度的强调色」一律用 `accent.withValues(alpha:)`，换肤不残留旧色）、深/浅各自翻转的层次 token（深色用白色薄提亮，浅色用深色薄压暗）、`dangerInk` / `dangerLine` / `dangerSoft` / `toastBg`（浅色翻成深红字 + 浅红底）、歌词三档色（当前/未唱/已唱，浅色单独放宽到 0.82/0.8，因为深色那套 0.62/0.5 在白底上只有 2.24:1）。

用户自选歌词高亮色在浅色主题下按原版 `highlightOnLight` 公式处理：保持色相、每步压 6%、最多压到 12% 亮度，直到对白底对比度 ≥4.5:1；色板预览显示压暗后的颜色，所见即所得。实现后要在 Windows 与 Android 真机各自实测对比度，不只靠截图。

`main()` 里先 `await` 读完 prefs 再 `runApp`，等价于原版 `useLayoutEffect` 在首帧前挂属性。黑胶在两套主题下都保持深色实体反光。玻璃材质：`BackdropFilter(ImageFilter.blur)` + 当前封面模糊底 + 雾面颗粒，播放卡与列表卡等同族容器同步改，手机端的模糊半径降到 30px 并用真实 `Image`；浅色主题、多层背景与滤镜效果一律真机验（系统深色时浏览器/ WebView 会自己刷画布，Flutter 无此问题但平台亮度反查有差异）。

## 10. 频谱子系统

### 10.1 解析管线

`compute` isolate 内执行，全局串行队列，当前播放曲目插队优先：

1. `audio_decoder` 把曲目解码为 PCM（默认 44100Hz，取单声道求和）。
2. Hann 窗分帧，`frameSize = 2048`、`hop = 1024`，帧率对齐显示所需的每 50ms 一帧（相邻帧取能量最大者）。
3. `fft` 包做 radix-2 变换取幅度谱。
4. 按原版 `readBands` 的公式折叠成 64 段：`binWidth = sampleRate / 2048`、`maxBin = clamp(round(10000 / binWidth), 8, …)`、`bin = pow(maxBin, t)`、`value = max(buf[bin], buf[bin + 1])`、`tilt = 0.78 + 0.72 * t`、`out = clamp(pow(value / 255, 1.35) * tilt * 1.05, 0.02, 1)`。
5. 帧间平滑沿用 `smoothingTimeConstant = 0.78`，保证「整条同亮同动」的观感与原版一致。
6. 时域那路每帧存当前窗口 128 点的峰谷包络（真数据，非合成）。
7. 落盘 `spectrum/<trackKey>.bin`：16 字节头（魔数、版本、sampleRate、frameMs、bandCount、waveCount、frameCount）+ 帧数据。bands 64×uint8 + wave 128×int8 ＝ 192B/帧，4 分钟约 920KB。

失效判定：文件路径/URI、修改时间、大小三者构成 key 指纹，任一变化即重算。缓存目录整体可随时删除，下次启动自动重建。

### 10.2 渲染

`WaveSource.read(input)` 按当前 `positionSeconds` 取帧（帧间做线性插值，避免柱高台阶感）；暂停时冻结在最后一帧真实数据（不回落到装饰形状）；`live` 在「有帧表」时为真。17 个样式各一个 `CustomPainter`：`spectrum`、`ribbon`、`hairline`、`sine`、`roundBars`、`blob`、`strands`、`noise`、`histogram`、`mirrorArea`、`jagged`、`hatch`、`spikes`、`led`、`flow`、`dots`、`hills`，一个都不减。播放段发光、柱高轻微起伏、峰值点带衰减拖尾（拖尾用 `dt` 而不是帧数）、未播放段压暗但仍可读。

「彩色」开关关掉时只留歌词高亮色的亮度层次；单色频谱与当前行歌词及其辉光一起跟随高亮色变化。

降级链：帧表不存在或解析失败 → 逐字节移植的 `fallbackBands` / `fallbackWave`（FNV-1a 按曲目 id 生成，带钟形包络 + 每柱抖动 + 五个谐波叠加）继续律动，同时状态行明示「当前非真实频谱」。装饰回退是显式降级状态，不是默认交付状态。

## 11. 歌词与双语

**匹配**：Flutter 直连 LRCLIB，自己承担 React 版 Vite 代理那一侧的编排（客户端直连的三路其实是串行的，并行只存在于代理）。job 按固定顺序构造：对 `[曲名, 歌手]` 与（歌手非空且不等于曲名时）`[歌手, 曲名]` 两个方向，各发「带时长 get」与「不带时长 get」；再加一条按**原方向**拼 `q=<曲名> <歌手>` 的 search。于是 job 数为 2~5。全部 job 并行发出、**等全部结束**再裁决，不是谁先回来用谁。裁决顺序：带时间轴的 get 命中 > 带时间轴的 search 命中 > 任意 get 命中 > （任一 get 路报错则抛最严重的那个）> search 命中 > （有错则抛）> not-found。同类多个命中取 **job 顺序最靠前**的那个。歌名与歌手对调后重查一遍，命中结果同时写入两个缓存 key，下次两种写法都瞬时命中。`cleanTitle` 去音轨号与 `(Live)`、`(Official)` 一类噪声括号（**不含 `feat`**：词表里没有它），`splitArtistTitle` 与 `normalizeQuery` 逐条移植。

**抗抖动**：5xx 与网络错误退避重试一次并遵循 `Retry-After`；404 不浪费请求；连续失败进入 60s 冷却，期间不再自动打接口，界面提示「N 秒后自动重试」，到点自动补一次；上游失败时允许回退过期缓存。失败归一成 `rate-limit` / `timeout` / `unreachable` / `upstream` 四类，各配各的中文话术 —— 超时就说超时，不写「服务在维护」。客户端总预算 60s 大于任一单程预算（get 12s / search 26s，见本节末「直连合并裁定」）。所有成功结果双层缓存（prefs 索引 + 磁盘，命中 30 天、未命中 3 天）。

**格式兼容**：标准 LRC、一行多时间标签、`[offset:]`、逐字增强型行内标签剥离；只在前 4 行内判断并剔除「词：/曲：」署名行与「歌名 - 歌手」标题行，且至少保留 3 行正文。同步高亮用二分查找 + 0.12s 容差，当前行滚到可视区中央，手动滚动时暂停跟随 2.6s。

**纯文本降级**：只有原文没有时间轴时静态展示全文、不高亮、不响应点击，状态行注明。

**双语**：判语种只看字符集 —— 出现假名或谚文即外语；纯汉字占正文比例 ≥35% 才当中文；判成中文一个请求都不发、界面上不出现开关。译文取网易云 `song/lyric?tv=1`（人工翻译、自带时间轴），取不到只用原文，不拿机翻凑。认歌要求不降：歌名（去版本后缀）一致，且歌手对得上或时长差 ≤6s；歌手名先按 `/ , 、 & feat.` 拆成单个名字再比，不做整串包含。跨库对齐：用两边文本相同的行做锚点取中位数估整体偏移（>20s 视为不可信按 0 处理），把每条译文落到所属歌词行的时间区间，同区间多条并成一行，再加 1.5s 起手保护（译文离下一句更近时归下一句）；纯文本按行文本配对。覆盖率闸：带时间轴时 = `非空译文槽数 / 译文行数`（分母是**译文行数**，不是展示行数），<25% 整首退回单语；纯文本时 = `配上的展示行数 / 展示行数`，<50% 退回单语。带时间轴那一支失败返回**全空**数组；纯文本那一支达标时允许部分槽为空。译文行同样是 `.lyrics__text` 语义 —— 点它跳到那句时间，热区收回文字本身，行内左右留白仍算「进/出歌词页」的空白点击。失败话术分档（`song-not-matched` / `no-translation` / 超时或连不上），任何一档都不影响歌词本身显示。

**双语的数据生命周期**（2026-11-07 按工作区 `src/state/lyrics.tsx:159-278` 改写，取代原先「关掉即清空、重开绕过缓存重取」的写法）：会话缓存的 key 是 `track.id | fingerprint(歌词文本)`，命中项连「没有译文」这个结论一起记。三条规则各自独立、都要有用例钉住：

1. **关掉只停显示，不丢数据**。`bilingual = false` 只把状态置成 `off`，`translation` 原样留着；再打开立刻恢复显示，不重新等一次网络 —— 否则在 LRCLIB/网易慢或失败时会变成「怎么都切不回来」。
2. **换歌才清**。手上这份译文记着归属曲目 id：id 变了才清空；同一首只是歌词文本升级（纯文本 → 带时间轴）要沿用已有译文。曲目为空或判成中文时一并清空。
3. **重开是「先显示、后台刷新」**。打开开关置 `force`：有缓存就先把旧译文摆出来、状态照旧，同时带 `refresh=1` 在后台再问一次；**后台刷新失败或查不到都不覆盖手上这份**，状态保持 `ready`。没有缓存才进 `loading`。结论写缓存的分寸不变：`none` / `unavailable` 记（短期不再问），网络类 `error` 不记（留给下次重试）。

失败档位里的「无代理」（React 的 `unavailable`：静态部署时提示依赖 `npm run dev`）在 Flutter 侧**不可达** —— 客户端直连，没有代理这个前提。枚举与话术保留以便对照，但直连实现永不产出这一档，也不要在界面上凭空提示「需要本地代理」。

**转简体**：在线取回的歌词转简体，用户手动导入的 `.lrc` 保持原样。实现为**纯 Dart 移植 OpenCC 的 `tw2s` 链路**（码位 Trie + 最长前缀匹配 + IDS 感知的未匹配步长 + 分词后逐段转换），词典以生成的 Dart 源码内嵌，**不新增依赖**。原因（2026-11-07 实测）：`flutter_open_chinese_convert` 不声明 Windows；`opencc` 走 native assets；`flutter_opencc_ffi` 与 `flutter_opencc` 的 SDK 约束都 `<3.0.0`；而本工程 `pubspec` 已冻结（`permission_handler` 钉 `^12.0.0` 以守住 compileSdk 36）。词典与算法取自 `opencc-js`（MIT）及其上游 OpenCC 数据（Apache-2.0），两份许可全文随仓库保留在 `third_party/`，生成器可复跑。行为与 `opencc-js` 逐字节一致，用 Node 侧黄金样本对表。

**手动 `.lrc`**：支持批量导入，按可信度取最高分配对（50「歌手 - 歌名」组合名一致 > 45 拆出歌名且歌手一致 > 40 曲名与文件名一致 > 30 仅歌名一致）；对不上名的跳过并提示，不堆到正在播放的歌上；对不上名的一律拒绝并提示，**不挂到当前曲目**（工作区 `src/state/library.tsx` 的 `applyLyricsFiles` 没有这条兜底；早期文档里的说法与实现不符）。挂上后 `lyricsSource = 'manual'` 并落库，联网结果不覆盖。解析不出任何 `[mm:ss]` 行时拒绝导入并提示，不冲掉已有歌词。

**预取**：后台串行预取歌词（间隔 350ms）与封面（前 3 首、`COVER_PREFETCH_DELAY = 400ms`），译文不进预取队列，只在播到那首歌时取。

**隐私**：只发曲名/歌手/时长，不上传音频。

**直连合并裁定（2026-11-07）**：React 版把「拓扑」放在代理、把「韧性」放在客户端，两侧策略并不相同（代理只重试 timeout/unreachable、固定 400ms、不读 Retry-After；客户端重试 429/500/502/503/504、700ms 或 Retry-After、记 60s 冷却）。Flutter 没有代理，必须二合一：**拓扑与单程预算取代理**（get 12s / search 26s / 2~5 路并行 / job 顺序裁决 / 对调重试 / 双 key 写 / stale 回退），**韧性取本文档明定的客户端策略**（可重试状态集合、Retry-After 上限 6s、冷却 [10s,60s]、404 清冷却），外加 60s 总预算。译文链路不在此裁定内，逐字照抄代理（8s / 2 次 / 400ms / 只重试 timeout 与 unreachable）。

## 12. 封面四级兜底

顺序与原版完全一致，任何一级失败都静默往下走，永不阻塞播放、不打扰用户。

1. 文件内嵌封面（零网络，最准）。
2. iTunes 专辑图：按「歌手 + 歌名」查，歌名完全一致或歌手对得上才采用，得分不足宁可继续往下；中国区与美区都查，全局取最高。
3. 歌手写真图：维基条目配图（zh 优先、en 兜底）。本机现状是 wikipedia 不可达，这一级会经常直接失败到第四级 —— 照抄，不假装能命中。
4. 本地生成歌手封面卡：FNV-1a 派生配色与声波柱形状，中间首字（CJK 取一个字、拉丁取两个首字母），下方歌手名与曲名；内容全部落在「安全圆」内（界面把封面裁成正圆）。**生成卡不写回 `track.cover`**，只活在显示层 `coverForDisplay()`；写真或专辑图到位后自动替换。

缓存：命中 30 天、未命中 3 天；图片落盘缓存目录，前端读本地文件。触发时机：切到没有封面的曲目时自动匹配，导入后后台预取前 3 首。

## 13. 界面与交互

按原版组件与断点一比一建。断点阈值 900px（`LayoutBuilder`）。桌面双栏：左列播放卡纵向撑满、控制区底边与右栏面板底边对齐；右栏是「播放列表 / 最近」tab 面板（内部滚动）。窄屏单栏堆叠（曲目信息 → 面板 → 控制区），控制区吸附在视口底部，触控目标 ≥40px 且 5 个按钮同款同尺寸等距、最右是列表入口弹 sheet，音量与内联列表在窄屏隐藏。全站无横向滚动，长曲名/歌手名统一 ellipsis 截断；内容被裁时改容器布局，不删图标或文案来凑宽度。

歌词区弹性填满剩余高度（原版 `flex-basis: 0` 的等价写法：`Flexible` + 不设固定行数），顶部留白 `clamp(20, 4vh, 36)`，两页左右滑切歌 —— 这条滑切歌依赖速度阈值，测试必须用带初速度的手势。

组件与交互细节：

- **Header**：左侧明暗模式切换，右侧唯一「菜单」按钮。抽屉只放一级入口（添加音乐 / 添加整个文件夹 / 清空播放列表 / 换肤），换肤再叠一层抽屉，四套主题连同缩略预览列出，点一下即时生效、抽屉不关可以来回比对。所有抽屉共用一套动效与焦点管理。
- **Stage 播放卡**：黑胶盘 + 62% 中心封面 + 右上金属/薄荷唱臂；播放时唱臂 -17° 落在纹路中间带过冲回退，暂停 -45° 摆出；封面整圈缓慢顺时针旋转（24s/圈），暂停只冻结不摘动画、恢复时接着当前角度转。点曲目区任意位置（歌名、歌手、留白都算）进完整歌词页；点封面是放大层；点歌词行是 seek。**「双语」开关跟在歌名右侧、与歌名同排居中**（`stage__title-row`，`App.tsx:490`），不再单独占状态行。
- **Panel**：一个搜索框管两个 tab、只搜歌名；200ms 防抖（用 `debounce` 工具函数，不手写 timer）；搜索/筛选时先锁原高度，解锁跟防抖后的生效值走，清空不闪；固定行（标题/统计/提示）不参与收缩，只让列表收缩；当前项高亮带跳动音柱（暂停时静止）；空态在内容区居中、纯文字、无虚线框，顶部只留来源提示。
- **Transport**：播放模式 / 上一首 / 播放 / 下一首同尺寸同款式；进度条支持点击与拖拽，拖拽期间暂停 position 同步、松手 seek；下方显示缓冲区间；音量 0–100 + 一键静音（记住静音前音量、图标随档位变化）；「T」按钮改歌词高亮色（8 个预设，首页与歌词页、所有断点位置一致，选择记住）；T 右边的水滴按钮打开透明/磨砂双滑块（两个独立滑块）。
- **LyricsPage**：左歌词右封面大图（这一页封面不旋转，但点它同样进放大层）；封面下方是律动频谱条；**右上角只剩波形样式下拉**（17 项 + 顶部「彩色」开关），**「双语」开关跟播放卡一样挪到歌名右侧**（`lyrics-page__title-row`，`App.tsx:1096-1100`）。两处开关是同一个组件、同一份规格：高 26px、字号 11.5px、图标 12px、左右内边距 9px、图文间距 3px、胶囊圆角；开 = 强调色描边与浅底，关 = 灰；只在非中文歌词时出现（`app.css:3091`，注意那段 CSS 的块注释还写着旧位置，以选择器实际数值和 `App.tsx` 的挂载点为准）。正文大字号、当前行自动居中、可滚动；控制条留在页面下方，不用退出就能操作。返回方式：左上角「返回」或 `Esc`，返回后焦点还给原处。
- **Lightbox 放大层**：看完整方图（曲目区把封面裁成正圆、四角看不到）。关闭三种：点图以外的遮罩、右上角关闭、`Esc`；点在图上不关闭。滚轮 1×~4× 以光标为锚点；双击逐级 1×→2×→4×→1× 以点击处为锚点（移动端连点两下同有效）；双指捏合以两指中点为锚点、指间内容不漂移；放大后可拖拽平移，位移夹在「图片边缘不离开视口」范围内，缩回 1× 自动回正中；关闭或换歌复位。层开着时其余快捷键全部让位，关闭后焦点还给封面。用的是当前已拿到的那一张，不为大图再找更高分辨率的源。
- **Toasts**：`Semantics(liveRegion: true)` 容器，同屏最多 3 条、其余排队（与原版 `toast.tsx` 一致，默认时长 3200ms）；连点同一动作只保留一条（改文案 + 重新计时），同文案也去重。
- **最近播放**：真正出声才记录（被系统拦下的不算），重播置顶、永不重复、500ms 内重复事件忽略；相对时间文案 `刚刚 / N 分钟前 / N 小时前 / 昨天 / N 天前 / 一周以上显示日期（跨年带年份）`；点任意一条切到那首歌，当前播放项高亮；曲目移出列表后条目变暗标注「已不在列表」，点击给提示；一键清空，空态时按钮禁用。
- **滚动条**：歌词两处完全不显示滚动条、占位也去掉；播放列表与最近播放两个滚动容器平时滑块透明、滚动时浮现、停手 900ms 收回，且只认用户滚动（滚轮/触摸/滚动键），跟随播放的自动居中属于程序化滚动、不点亮。

## 14. 输入与无障碍

桌面注册 `Space`（播放/暂停，不滚动页面）、`←`/`→`（快退/快进 5s）、`↑`/`↓`（音量 ±5%）、`M`（静音）、`L`（进/出歌词页）、`Esc`（返回/关闭）。文本输入聚焦时快捷键让位；滑块聚焦时方向键交回原生，避免双倍响应。物理媒体键 `Play/Pause`、`NextTrack`、`PrevTrack` 不在「桌面 only」那批里 —— 它们经 §7.1 的系统媒体会话通道进来，Android 与 Windows 都要接，且与界面按钮共用同一个编排入口；放大层开着时同样让位。

无障碍：所有按钮 `Semantics(label:)`，两个滑块 `value` + `valueHint`，焦点环可见；桌面双栏视觉顺序与控制区焦点顺序不一致，因此用 `Semantics(sortKey)` + 焦点序把「跳到播放控制」放成页面第一个可聚焦项；`MediaQuery.disableAnimationsOf` 为真时关闭旋转、呼吸、律动、抽屉动效；频谱条纯装饰、对读屏隐藏；Toast 容器 `liveRegion`。

## 15. 依赖

| 包 | 版本（已核） | 用途 |
| --- | --- | --- |
| `media_kit` | 1.2.6 | 播放内核（libmpv） |
| `media_kit_libs_windows_audio` | 1.0.9 | Windows mpv 库 |
| `media_kit_libs_android_audio` | 1.3.8 | Android mpv 库 |
| `audio_decoder` | 0.8.1 | 离线解 PCM（声明覆盖 android/ios/macos/linux/windows/web，无需 FFmpeg） |
| `fft` | 0.5.1 | FFT |
| `provider` | 6.1.5+1 | 状态注入 |
| `shared_preferences` | 2.5.6 | 小键值持久化 |
| `path_provider` | 2.1.6 | 缓存与数据目录 |
| `http` | 1.6.0 | 四个源直连 |
| `file_picker` | 13.3.2 | 文件与文件夹选择（Android SAF、桌面原生对话框） |
| `flutter_svg` | 2.3.2 | 16 组 24×24 图标沿用原 SVG path，保证图标 1:1 |
| `flutter_media_session` | 3.0.9 | 系统媒体会话首选：Android 通知栏/锁屏 + Windows SMTC 同一套 API |
| `audio_service` | 0.18.19 | Android 降级通道（前台服务、通知动作、headless restart） |
| `smtc_windows` | 1.1.0 | Windows 降级通道 |

繁简转换不引包：见 §11「转简体」，纯 Dart 移植 + 内嵌词典，`pubspec` 不变。

## 16. 测试与验收

单元测试以「能对着原版断言」为准：

- `audio_tags_test.dart`：把 `tests/t-tags.mjs` 的 **57 条**字节级断言整体译成 Dart 用例（本机 `node tests/t-tags.mjs` 实测输出 `通过 57 · 失败 0`，README 里写的 42 已过时），覆盖 ID3v2.3 / v2.4 unsync / ID3v1 / FLAC / OGG / M4A、GBK 与 Latin-1 标签嗅探、六类畸形输入不抛、`mergeTaggedNames` 四档；移植后必须全绿，这是最硬的 1:1 标尺。
- `lrc_parser_test.dart`：多时间戳、`[offset:]`、逐字标签剥离、署名行剔除（含「至少保留 3 行正文」边界）。
- `lyrics_source_test.dart`：查询归一、对调重试、双 key 写入、四类失败分类与冷却状态、缓存命中/未命中 TTL。
- `translate_align_test.dart`：中位数偏移、>20s 不可信、1.5s 起手保护、覆盖率 <25%/<50% 退回单语、歌手拆分后逐个比（含「Zzzx Nope vs N.O.P.E」这类误包含反例）。
- `playlist_test.dart`：三种模式、`nextIndex({auto})` 与手动点选时游标同步、列表变化重建队列、一轮内不重复、`removeById` 删当前项后的接续。
- `spectrum_test.dart`：对数分频折叠的 golden 比对（同一 PCM 输入 → 同一 bands）；帧文件读写往返；指纹变化触发重算。
- `app_prefs_test.dart`：脏数据回退默认值并清理、JSON 仓库原子写与 `.bak` 恢复。
- Widget 测试：当前行居中、sheet 打开/关闭、滑切歌用带初速度的手势（单步拖拽速度归 0 会测不到阈值）、搜索锁高与清空不闪、换肤后 token 与预览色同步。

集成验证：`flutter run -d windows` 与 Android 真机各跑一轮，与 React 版并排比对同一批 FLAC 的标签拆分、封面命中、歌词命中、双语行对齐、布局与四套主题截图。浅色主题、玻璃透明/磨砂、多层背景与滤镜效果必须真机看（模拟与真机不一致）。每次改完重新起服务，不擅自停掉正在用的实例；同一页面可能他同时在用，改设置类操作前先读当前值。

## 17. 里程碑

**M1 核心播放**：工程与双端可运行、断点布局骨架、播放卡（黑胶先静态）、列表与两个 tab、添加文件/文件夹、白名单校验、内嵌标签与时长、播放/暂停/上下曲/进度/缓冲/音量/三种模式、桌面快捷键、系统媒体会话（Android 前台服务 + 通知栏/锁屏控制、Windows SMTC + 媒体键，见 §7.1）、持久化与冷启动还原、空态、四类错误 + 损坏角标 + 1.4s 自动跳 + 熔断、Toast 去重。
验收：Windows 与 Android 各连续听完一批 FLAC，重启后歌单、当前曲目、音量、模式原样恢复；把某首改坏能看到「损坏」与自动跳转，全部改坏触发熔断。锁屏与通知栏可切歌：Android 息屏后连续播 20 首不被系统挂起，来电暂停并在结束后按「真实交互」语义恢复；Windows 物理媒体键与 Xbox Game Bar / 蓝牙耳机的上下曲全部生效。

**M2 元数据与歌词**：四级封面兜底与生成卡、维基写真通道、LRCLIB 并行匹配（含对调重试、冷却、四类文案、双层缓存）、网易双语与跨库对齐、手动 `.lrc` 批量配对、完整歌词页、封面放大层、最近播放、后台预取。

M2 拆成两段执行，各一次闸口与整分支复核（2026-11-07 用户确认）。理由是网络风险集中在歌词那一侧，先把它验掉再动封面；两段之间的接缝是**封面来源**：M2a 只用 M1 已有的内嵌封面，M2b 才接上二~四级。

- **M2a 歌词与双语**：LRCLIB 2~5 路 job 并行、等全部结束按 job 顺序裁决与对调重试、退避与 60s 冷却、四类失败文案、双层缓存（命中 30 天 / 未命中 3 天）、LRC 格式兼容与纯文本降级、同步高亮与滚动跟随、手动 `.lrc` 批量配对与「不被联网覆盖」、在线转简体、完整歌词页（含歌名右侧的双语开关）、网易双语与跨库对齐及三条生命周期规则。
- **M2b 封面与灯箱**：iTunes 两区匹配、维基写真通道（本机不通，照抄降级）、本地生成歌手卡与 `coverForDisplay()`、图片落盘缓存、封面放大层（滚轮/双击/捏合三种锚点缩放与平移夹取）、最近播放打磨、歌词与封面后台预取。

验收：断网与慢源下每条降级路径的文案与行为正确（超时/限流/查无分开说）；非中文歌词出双语且行对齐；手动歌词不被联网结果覆盖；双语三条生命周期规则各有用例（关掉再开立刻恢复且不打网络、换歌清掉上一首、重开时后台刷新失败不覆盖手上这份）；两处开关都在歌名右侧且规格一致。M2b 另验：内嵌 → iTunes → 写真 → 生成卡每一级失败都静默下沉且不阻塞播放，生成卡不写回 `track.cover`；灯箱三种缩放都以锚点为不动点、平移不越界。

**M3 视觉与律动**：四套换肤与两维 token、卡面透明/磨砂双滑块、离线 FFT 管线 + 17 波形样式 + 彩色开关 + T 高亮色、黑胶旋转与唱臂过冲落位、封面光晕呼吸、滚动条 auto-hide、无障碍与 reduced-motion、白色主题层次与对比度实测。
验收：与 React 版并排截图逐项比对；频谱柱随真实音频内容起伏（非合成律动），暂停冻结、seek 取帧正确；浅色主题下正文与歌词对比度实测 ≥4.5:1。

每段各自需要一份独立实现计划，不是一次计划覆盖全部：`writing-plans` 先出 M1 的计划并按它实现，M1 验收通过后再出 M2a，M2a 验收通过后出 M2b，M3 同理。每份计划都以本文档对应章节为约束源，不重新定义行为。

## 18. 风险与未验证项

| 风险 | 现状 | 处理 |
| --- | --- | --- |
| `audio_decoder` 在 Windows 上解他这批 24bit FLAC 的实际表现 | pubspec 声明了 `windows: AudioDecoderPluginCApi`，但未在本机曲目上跑过 | M3 第一天实测；失败则整条频谱走 §10.2 的显式降级链（装饰信号 + 状态行说明），不阻塞其他交付 |
| 网易译文接口在 Dart 直连时是否校验 UA/Referer | **已验证可直连（2026-11-07）**：用 React 代理同款朴素头（`Accept: application/json` + `User-Agent: light-music-react/1.0`）、不带 Referer、不带浏览器 UA，`api/search/get` 200 / 0.29s，`api/song/lyric?id=536622304&lv=1&tv=1` 200 / 0.09s，`tlyric.version=42`、42 行带时间轴人工中译；中文歌《十年》`tlyric` 为空，符合预期 | 风险关闭。Flutter 直连，不加代理、不加 Referer。Dart `http` 落地后在集成用例里再确认一次同样的响应形状（curl 通不等于 Dart 通） |
| 维基写真本机不可达 | **2026-11-07 复测仍不通**：`zh.wikipedia.org/api/rest_v1/page/summary/...` 12s 超时 | 保留这一级但设 8s 超时，直接落第四级生成卡；不假装能命中 |
| LRCLIB 单程 15~30s 且偶发 503，移动网络更慢 | **2026-11-07 复测：`api/search` 单程 45.0s 才回 200**，贴着超时线 | 原版已有并行 + 冷却 + 过期缓存回退；客户端预算 60s 必须大于上游 45s，状态行按四类分开说 |
| iTunes 分区差异 | **2026-11-07 实测**：中国区搜「陈奕迅 十年」`resultCount: 0`，美区搜 `eason chan ten years` 有结果；搜索 0.64s、图片 CDN 0.46s 均通 | 两区都查、全局取最高分这条不能省，否则中文曲目第二级封面几乎全空 |
| media_kit 随包体积（Android 约 +8MB，Windows 随包 DLL） | 换取 11 个扩展名全覆盖 | 已在 §2 作为决策记录，不回头改内核 |
| `flutter_media_session` 在 Android 上是否给足前台服务与通知动作按钮 | 双端一套 API 是它最大的优点，但媒体会话的必需项（息屏续播 + 上下曲按钮）没实测过 | M1 里排在播放链路之后第一件事验；任一项缺失即按 §7.2 降级成 `audio_service` + `smtc_windows`，界面层与编排层不动 |
| Android 14 对 `media_player` 前台服务的启动限制 | 服务类型声明不全直接被系统拒起服务，表现为「锁屏就断」 | manifest 与服务类型、`FOREGROUND_SERVICE_MEDIA_PLAYBACK` 权限在 M1 一次性配齐，用真机息屏验证而不是只看通知栏出现 |
| `flutter_svg` 对 stroke 型图标的还原度 | 16 组图标里 8 组是 `fill="none" stroke` | 逐个与原版并排比对，必要时改用 `CustomPainter` 描 path |
| 移动端滑切歌与双指捏合的手势语义 | 原版有明确速度阈值与锚点约束 | M3 用真机 + 带初速度的 widget 手势双向验 |

## 19. 明确不做的事

不新增原版没有的控件、状态或页面；不因宽度不够就删图标/文案来凑；不把频谱做成假的律动；不把 Node 代理进程带进 Flutter 工程；不改动 React 侧任何源码（除本文档所在目录之外）；不在设计未确认前写任何 Dart 代码。
