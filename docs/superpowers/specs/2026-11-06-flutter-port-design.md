# 流光音乐 Flutter 移植 · 设计文档

日期：2026-11-06
状态：待用户复核
范围：把现有 React 18 + Vite + TypeScript 版「流光音乐」移植为 Flutter 工程，目标平台 Windows 桌面 + Android，终点是功能与视觉 1:1。

---

## 1. 背景与基准

现有实现约 12k 行：`src/App.tsx` 1757 行、`src/styles/app.css` 4229 行、`src/lib/wave-styles.ts` 1042 行（17 种波形样式）、`src/server/music-api.ts` 960 行（5 个同源代理）、`src/state/` 15 个 Context + hook、`src/lib/` 18 个纯逻辑模块。

移植期间 React 版**原地保留**，作为唯一的验收基准：同一批 FLAC、同一首歌，两侧并排比对歌名/歌手拆分、封面命中、歌词命中、双语行对齐、布局与配色。Flutter 工程落在 `music-player/flutter-app/`，与 React 版同一个 git 仓库，不新增子模块、不改动画笔触及 React 侧任何代码。

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

## 3. 范围与非目标

**范围内**：播放控制与三种播放模式、进度与缓冲、音量与静音、播放列表与「最近播放」两个 tab、列表内搜索、本地文件与文件夹导入、内嵌标签与内嵌封面解析、四级封面兜底、歌词自动匹配、非中文歌词双语、手动 `.lrc` 导入与配对、完整歌词页、封面放大层、四套换肤（明暗 × 主题色）、17 种波形样式、卡面透明/磨砂双滑块、歌词高亮色、桌面快捷键、无障碍与 reduced-motion、原版异常矩阵。

**不在范围内**：Web 编译目标（等于把 React 版重写一遍，收益为零）；iOS（本机无 Mac + Xcode，无法打包）；歌词与封面的手动编辑、音频转码、系统媒体键与通知栏控制（原版没有，按「不移植原版没有的东西」处理，除 §4 明确列出的两处平台补偿）；曲库文件夹常驻监听；多设备同步。

## 4. 浏览器语义的映射

移植时不静默删除分支。原版每条依赖浏览器能力的路径，对应关系如下。

| 原版 | Flutter | 说明 |
| --- | --- | --- |
| `URL.createObjectURL(blob)` | 桌面：绝对路径；Android：SAF 持久 URI | `Track.src` 语义不变，只是不再需要回收对象 URL |
| IndexedDB 存音频 Blob | 只存路径/URI + 回填后的元数据 | 文件系统本身是持久层，不再复制音频字节 |
| 「刷新页面后恢复」 | 冷启动恢复 | 同一套还原流程与同一套顺序、当前曲目、封面、时长、歌词 |
| 整页拖放文件 | 桌面保留拖放；Android 换成文件选择器 + 「分享到本应用」 | 系统不向第三方应用派发页面级 drop |
| `play()` 被自动播放策略拒绝（`NotAllowedError`） | Android 音频焦点被抢 / 输出设备不可用 | 仍走同一档 UI：常驻提示条 + 「继续播放」按钮 + 用户真实交互后自动重试，最多 3 次 |
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

**时长探测**：入列后用一次性解码探 `duration`，3s 超时则保持 `--:--`，不阻塞入列。

## 8. 曲库与导入

流程与原版 `state/library.tsx` 一致：校验扩展名 → 立即入列（可播）→ 解析内嵌标签 → 探时长 → 落库 → 后台预取封面与歌词。

标签优先于文件名：先读内嵌 title/artist/album/albumArtist，无标签才按「歌手 - 歌名」或「歌名 - 歌手」拆文件名；拆错会被标签纠正，纠正结果落库，下次启动不重复解析。`mergeTaggedNames` 的判定逐条移植。

内嵌封面解析走 `metadata/audio_tags.dart`，覆盖 ID3v2.2/2.3/2.4（含整标签与单帧 unsynchronisation、UTF-16 文本、缺失 mime 时按魔数嗅探）、ID3v1、FLAC `PICTURE`、OGG base64 `METADATA_BLOCK_PICTURE`、MP4 `moov.udta.meta.ilst.covr`。读取策略保持「只读需要的字节」：头 64KB 判格式，标签区按需再读，上限 8MB；任何一段失败只影响对应字段，畸形长度、越界帧、无 `moov` 的 MP4 一律不许抛出。文本编码按 ASCII → UTF-8 → GBK（连续高位字节）→ Latin-1 嗅探。取到的封面缩到 ≤600px JPEG 写入缓存目录。

桌面「添加整个文件夹」：递归扫描上述扩展名，按自然排序入列，数量超过一次性处理上限时分批（每批 50 首）落库并更新进度提示；不做曲库监听，导入是一次性动作。

「数据对了不等于界面变了」这条历史教训在 Dart 侧的防法：所有回填必须以列表里的活对象为目标（按 id 找回再改），改完显式 `notifyListeners()`，并在 widget 测试里断言「回填后 DOM（widget tree）里的文本确实变了」，而不只断言 repository 里有值。

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

**匹配**：LRCLIB 三路（带时长精确 / 不带时长精确 / 宽松搜索）并行发出，先给出可信结果的先用；精确命中优先，搜索命中兜底。歌名与歌手对调后重查一遍，命中结果同时写入两个 key，下次两种写法都瞬时命中。`cleanTitle` 去 `(feat. X)`、`(Live)` 等噪声标记，`splitArtistTitle` 与 `normalizeQuery` 逐条移植。

**抗抖动**：5xx 与网络错误退避重试一次并遵循 `Retry-After`；404 不浪费请求；连续失败进入 60s 冷却，期间不再自动打接口，界面提示「N 秒后自动重试」，到点自动补一次；上游失败时允许回退过期缓存。失败归一成 `rate-limit` / `timeout` / `unreachable` / `upstream` 四类，各配各的中文话术 —— 超时就说超时，不写「服务在维护」。客户端超时预算 60s 大于上游预算 45s。所有成功结果双层缓存（prefs 索引 + 磁盘，命中 30 天、未命中 3 天）。

**格式兼容**：标准 LRC、一行多时间标签、`[offset:]`、逐字增强型行内标签剥离；只在前 4 行内判断并剔除「词：/曲：」署名行与「歌名 - 歌手」标题行，且至少保留 3 行正文。同步高亮用二分查找 + 0.12s 容差，当前行滚到可视区中央，手动滚动时暂停跟随 2.6s。

**纯文本降级**：只有原文没有时间轴时静态展示全文、不高亮、不响应点击，状态行注明。

**双语**：判语种只看字符集 —— 出现假名或谚文即外语；纯汉字占正文比例 ≥35% 才当中文；判成中文一个请求都不发、界面上不出现开关。译文取网易云 `song/lyric?tv=1`（人工翻译、自带时间轴），取不到只用原文，不拿机翻凑。认歌要求不降：歌名（去版本后缀）一致，且歌手对得上或时长差 ≤6s；歌手名先按 `/ , 、 & feat.` 拆成单个名字再比，不做整串包含。跨库对齐：用两边文本相同的行做锚点取中位数估整体偏移（>20s 视为不可信按 0 处理），把每条译文落到所属歌词行的时间区间，同区间多条并成一行，再加 1.5s 起手保护（译文离下一句更近时归下一句）；纯文本按行文本配对。覆盖率带时间轴 <25% 或纯文本 <50% 时整首退回单语。开关在状态行与歌词页右上角各一个，与同行其它控件同尺寸同款式，只在非中文歌词时出现；重开会绕过会话缓存带 `refresh=1` 再取一次。译文行同样是 `.lyrics__text` 语义 —— 点它跳到那句时间，热区收回文字本身，行内左右留白仍算「进/出歌词页」的空白点击。失败话术分四档（`song-not-matched` / `no-translation` / 无代理 / 超时或连不上），任何一档都不影响歌词本身显示。

**转简体**：在线取回的歌词转简体（`opencc` 包，实现时与 `flutter_open_chinese_convert` 二选一，取在本机能稳定转换的）；用户手动导入的 `.lrc` 保持原样。

**手动 `.lrc`**：支持批量导入，按可信度取最高分配对（50「歌手 - 歌名」组合名一致 > 45 拆出歌名且歌手一致 > 40 曲名与文件名一致 > 30 仅歌名一致）；对不上名的跳过并提示，不堆到正在播放的歌上；单个导入对不上名时挂到当前曲目。挂上后 `lyricsSource = 'manual'` 并落库，联网结果不覆盖。解析不出任何 `[mm:ss]` 行时拒绝导入并提示，不冲掉已有歌词。

**预取**：后台串行预取歌词（间隔 350ms）与封面（前 3 首、`COVER_PREFETCH_DELAY = 400ms`），译文不进预取队列，只在播到那首歌时取。

**隐私**：只发曲名/歌手/时长，不上传音频。

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
- **Stage 播放卡**：黑胶盘 + 62% 中心封面 + 右上金属/薄荷唱臂；播放时唱臂 -17° 落在纹路中间带过冲回退，暂停 -45° 摆出；封面整圈缓慢顺时针旋转（24s/圈），暂停只冻结不摘动画、恢复时接着当前角度转。点曲目区任意位置（歌名、歌手、留白都算）进完整歌词页；点封面是放大层；点歌词行是 seek。
- **Panel**：一个搜索框管两个 tab、只搜歌名；200ms 防抖（用 `debounce` 工具函数，不手写 timer）；搜索/筛选时先锁原高度，解锁跟防抖后的生效值走，清空不闪；固定行（标题/统计/提示）不参与收缩，只让列表收缩；当前项高亮带跳动音柱（暂停时静止）；空态在内容区居中、纯文字、无虚线框，顶部只留来源提示。
- **Transport**：播放模式 / 上一首 / 播放 / 下一首同尺寸同款式；进度条支持点击与拖拽，拖拽期间暂停 position 同步、松手 seek；下方显示缓冲区间；音量 0–100 + 一键静音（记住静音前音量、图标随档位变化）；「T」按钮改歌词高亮色（8 个预设，首页与歌词页、所有断点位置一致，选择记住）；T 右边的水滴按钮打开透明/磨砂双滑块（两个独立滑块）。
- **LyricsPage**：左歌词右封面大图（这一页封面不旋转，但点它同样进放大层）；封面下方是律动频谱条；右上角波形样式下拉（17 项 + 顶部「彩色」开关）与「双语」按钮；正文大字号、当前行自动居中、可滚动；控制条留在页面下方，不用退出就能操作。返回方式：左上角「返回」或 `Esc`，返回后焦点还给原处。
- **Lightbox 放大层**：看完整方图（曲目区把封面裁成正圆、四角看不到）。关闭三种：点图以外的遮罩、右上角关闭、`Esc`；点在图上不关闭。滚轮 1×~4× 以光标为锚点；双击逐级 1×→2×→4×→1× 以点击处为锚点（移动端连点两下同有效）；双指捏合以两指中点为锚点、指间内容不漂移；放大后可拖拽平移，位移夹在「图片边缘不离开视口」范围内，缩回 1× 自动回正中；关闭或换歌复位。层开着时其余快捷键全部让位，关闭后焦点还给封面。用的是当前已拿到的那一张，不为大图再找更高分辨率的源。
- **Toasts**：`Semantics(liveRegion: true)` 容器，同屏 1 条、其余排队；连点同一动作只保留一条（改文案 + 重新计时），同文案也去重。
- **最近播放**：真正出声才记录（被系统拦下的不算），重播置顶、永不重复、500ms 内重复事件忽略；相对时间文案 `刚刚 / N 分钟前 / N 小时前 / 昨天 / N 天前 / 一周以上显示日期（跨年带年份）`；点任意一条切到那首歌，当前播放项高亮；曲目移出列表后条目变暗标注「已不在列表」，点击给提示；一键清空，空态时按钮禁用。
- **滚动条**：歌词两处完全不显示滚动条、占位也去掉；播放列表与最近播放两个滚动容器平时滑块透明、滚动时浮现、停手 900ms 收回，且只认用户滚动（滚轮/触摸/滚动键），跟随播放的自动居中属于程序化滚动、不点亮。

## 14. 输入与无障碍

桌面注册 `Space`（播放/暂停，不滚动页面）、`←`/`→`（快退/快进 5s）、`↑`/`↓`（音量 ±5%）、`M`（静音）、`L`（进/出歌词页）、`Esc`（返回/关闭）。文本输入聚焦时快捷键让位；滑块聚焦时方向键交回原生，避免双倍响应。Android 不注册物理键快捷键（按 target platform 过滤）。

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
| `opencc` | 1.1.0 | 在线歌词转简体（与 `flutter_open_chinese_convert` 1.0.0 二选一） |

## 16. 测试与验收

单元测试以「能对着原版断言」为准：

- `audio_tags_test.dart`：把 `tests/t-tags.mjs` 的 42 条字节级断言整体译成 Dart 用例（ID3v2.3 / v2.4 unsync / ID3v1 / FLAC / OGG / M4A、GBK 标签、畸形输入不抛出），移植后必须全绿，这是最硬的 1:1 标尺。
- `lrc_parser_test.dart`：多时间戳、`[offset:]`、逐字标签剥离、署名行剔除（含「至少保留 3 行正文」边界）。
- `lyrics_source_test.dart`：查询归一、对调重试、双 key 写入、四类失败分类与冷却状态、缓存命中/未命中 TTL。
- `translate_align_test.dart`：中位数偏移、>20s 不可信、1.5s 起手保护、覆盖率 <25%/<50% 退回单语、歌手拆分后逐个比（含「Zzzx Nope vs N.O.P.E」这类误包含反例）。
- `playlist_test.dart`：三种模式、`nextIndex({auto})` 与手动点选时游标同步、列表变化重建队列、一轮内不重复、`removeById` 删当前项后的接续。
- `spectrum_test.dart`：对数分频折叠的 golden 比对（同一 PCM 输入 → 同一 bands）；帧文件读写往返；指纹变化触发重算。
- `app_prefs_test.dart`：脏数据回退默认值并清理、JSON 仓库原子写与 `.bak` 恢复。
- Widget 测试：当前行居中、sheet 打开/关闭、滑切歌用带初速度的手势（单步拖拽速度归 0 会测不到阈值）、搜索锁高与清空不闪、换肤后 token 与预览色同步。

集成验证：`flutter run -d windows` 与 Android 真机各跑一轮，与 React 版并排比对同一批 FLAC 的标签拆分、封面命中、歌词命中、双语行对齐、布局与四套主题截图。浅色主题、玻璃透明/磨砂、多层背景与滤镜效果必须真机看（模拟与真机不一致）。每次改完重新起服务，不擅自停掉正在用的实例；同一页面可能他同时在用，改设置类操作前先读当前值。

## 17. 里程碑

**M1 核心播放**：工程与双端可运行、断点布局骨架、播放卡（黑胶先静态）、列表与两个 tab、添加文件/文件夹、白名单校验、内嵌标签与时长、播放/暂停/上下曲/进度/缓冲/音量/三种模式、桌面快捷键、持久化与冷启动还原、空态、四类错误 + 损坏角标 + 1.4s 自动跳 + 熔断、Toast 去重。
验收：Windows 与 Android 各连续听完一批 FLAC，重启后歌单、当前曲目、音量、模式原样恢复；把某首改坏能看到「损坏」与自动跳转，全部改坏触发熔断。

**M2 元数据与歌词**：四级封面兜底与生成卡、维基写真通道、LRCLIB 并行匹配（含对调重试、冷却、四类文案、双层缓存）、网易双语与跨库对齐、手动 `.lrc` 批量配对、完整歌词页、封面放大层、最近播放、后台预取。
验收：断网与慢源下每条降级路径的文案与行为正确（超时/限流/查无分开说）；非中文歌词出双语且行对齐；手动歌词不被联网结果覆盖。

**M3 视觉与律动**：四套换肤与两维 token、卡面透明/磨砂双滑块、离线 FFT 管线 + 17 波形样式 + 彩色开关 + T 高亮色、黑胶旋转与唱臂过冲落位、封面光晕呼吸、滚动条 auto-hide、无障碍与 reduced-motion、白色主题层次与对比度实测。
验收：与 React 版并排截图逐项比对；频谱柱随真实音频内容起伏（非合成律动），暂停冻结、seek 取帧正确；浅色主题下正文与歌词对比度实测 ≥4.5:1。

三个里程碑各自需要一份独立实现计划，不是一次计划覆盖全部：`writing-plans` 先出 M1 的计划并按它实现，M1 验收通过后再为 M2 出计划，M3 同理。每份计划都以本文档对应章节为约束源，不重新定义行为。

## 18. 风险与未验证项

| 风险 | 现状 | 处理 |
| --- | --- | --- |
| `audio_decoder` 在 Windows 上解他这批 24bit FLAC 的实际表现 | pubspec 声明了 `windows: AudioDecoderPluginCApi`，但未在本机曲目上跑过 | M3 第一天实测；失败则整条频谱走 §10.2 的显式降级链（装饰信号 + 状态行说明），不阻塞其他交付 |
| 网易译文接口在 Dart 直连时是否校验 UA/Referer | React 侧靠代理转发，未验过纯客户端直连 | M2 第一天用 Dart `http` 带与浏览器一致的 UA 实测；被拒则补 Referer/UA 头，仍不行则双语状态行明确写「当前网络下译文需额外配置」，歌词不受影响 |
| 维基写真本机不可达 | 原版同样失败（记忆记录 last.fm / 维基不通） | 保留这一级但设 8s 超时，直接落第四级生成卡 |
| LRCLIB 单程 15~30s 且偶发 503，移动网络更慢 | 原版已有并行 + 冷却 + 过期缓存回退 | 客户端预算保持大于上游；状态行按四类分开说 |
| media_kit 随包体积（Android 约 +8MB，Windows 随包 DLL） | 换取 11 个扩展名全覆盖 | 已在 §2 作为决策记录，不回头改内核 |
| `flutter_svg` 对 stroke 型图标的还原度 | 16 组图标里 8 组是 `fill="none" stroke` | 逐个与原版并排比对，必要时改用 `CustomPainter` 描 path |
| 移动端滑切歌与双指捏合的手势语义 | 原版有明确速度阈值与锚点约束 | M3 用真机 + 带初速度的 widget 手势双向验 |

## 19. 明确不做的事

不新增原版没有的控件、状态或页面；不因宽度不够就删图标/文案来凑；不把频谱做成假的律动；不把 Node 代理进程带进 Flutter 工程；不改动 React 侧任何源码（除本文档所在目录之外）；不在设计未确认前写任何 Dart 代码。
