# M2b 封面与灯箱 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 Flutter 端补齐 React 版封面链路的第 2~4 级与封面放大层：iTunes 两区搜索匹配（得分 + 采纳门槛 + 600px 大图换算 + 30 天/3 天双层缓存）、维基写真通道（zh 优先 en 兜底，本机不通时稳定落到第四级）、本地生成歌手封面卡（FNV-1a 派生，纯 Painter 实现不引 SVG 依赖）、`CoverState` 显示层（`coverForDisplay`，生成卡与写真**不写回** `track.cover`）、封面放大层（滚轮/双击/捏合三种锚点缩放 + 拖拽平移 + 位移夹取）、最近播放与封面显示层的联动、导入后与启动后的封面预取。

**Architecture:** 三层。`lib/cover/` 是纯逻辑（iTunes 打分、维基挑图、生成卡派生都是无 IO 纯函数；HTTP、落盘、缓存各一个可注入接缝）；`lib/state/cover_state.dart` 是显示层唯一入口（对译 `src/state/covers.tsx`：resolver + 去重 + 内存写真表 + 预取调度）；`lib/ui/cover_lightbox.dart` 只读状态、手势全在 widget 内。**生成卡/写真/在线匹配结果都不写 `track.cover`** —— `hasRealCover`（track.dart:131）、导入回填判重（import_service.dart:311）与自愈谓词（import_service.dart:593-611）都依赖「cover == 内嵌封面落盘路径」这条不变量。在线封面（iTunes 结果）落盘到独立目录 `$dataDirectory/covers-net/`，返回**文件路径**而不是 URL —— 显示层全是 `Image.file`，不引网络图片加载。

**Tech Stack:** Flutter 3.47.9 / Dart 3.13.7；`http ^1.6.0`（M1 已声明、M2a 启用，复用 `HttpJsonClient` 查 iTunes / 维基；**取图字节另立 `ImageBytesClient` 接缝**，同样懒建内核）；`crypto`（sha1 缓存键）；`shared_preferences`（索引层）；`dart:io`（磁盘层）。**不新增任何依赖** —— 不引 `flutter_svg`（生成卡用 `CustomPainter` 直绘），`pubspec.yaml` / `pubspec.lock` 冻结。

**Spec:** `docs/superpowers/specs/2026-11-06-flutter-port-design.md` §12（封面四级兜底）、§13（界面与交互：Lightbox 段）、§14（输入与无障碍）、§16（测试与验收）、§17（M2b 范围）、§19（明确不做的事）。

**基准:** React **工作区现状**。下文引用的 `src/` 行号指工作区文件。React 侧任何文件在本段全程**只读**。

---

## Global Constraints

每个任务的要求都隐含包含本节全部条目。

### 环境与命令

- Flutter CLI 不在 Git Bash PATH 上：一律 `/d/flutter/bin/flutter`，且**在 `flutter-app/` 目录内**执行。
- **每条 Flutter 命令都必须带镜像环境变量**：
  ```bash
  PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter <cmd>
  ```
- 静态检查：`... /d/flutter/bin/flutter analyze`（必须 0 issue）。
- 构建闸口：`... /d/flutter/bin/flutter build windows --debug` 与 `... /d/flutter/bin/flutter build apk --debug`。
- **禁止** `git add -A` / `git add .`；只 add 本任务列出的具体路径。
- **禁止** amend / rebase / push / 仓库级 `dart format`。
- **禁止**改动 `pubspec.yaml`、`pubspec.lock`、`android/`、`windows/` 下的生成文件。
- **禁止**改动仓库根目录的 React 源码（`src/`、`README.md`、`vite.config.ts`、`tests/` 等）。它们只读。
- **禁止**为了让测试变绿而削弱或删除既有断言。

### 范围（spec §17 M2b）

- 本段**只做 M2b**：封面第 2~4 级、`coverForDisplay`、灯箱、最近播放联动、预取。**不做**四套主题 / 频谱 / 黑胶旋转 / 卡面透明磨砂（M3）。
- 灯箱里看到的封面与播放卡同源（同一个 `coverForDisplay`），**不为大图再找更高分辨率的源**（spec §13）。
- 不新增原版没有的控件、状态或页面（spec §19）。

### 网络与失败语义

- **直连，无代理**。React 的 `api/cover` / `api/artist-image` 同源代理**不移植**（M2a 同款裁定）；Dart 直连 iTunes Search 与维基 REST，iTunes 原生 HTTP 不受浏览器 CORS 限制，**不需要** JSONP 通道 —— React 的「代理 + JSONP」两级通道在 Flutter 侧合并成一级直连。
- iTunes Search：`https://itunes.apple.com/search`，参数 `term`（`[artist, trackName].filter(Boolean).join(' ')`）、`entity=song`、`media=music`、`limit=8`、**`country=CN` 与不带 country（美区默认）各查一次**，两区结果**全局取得分最高**（React 只有服务端做两区，music-api.ts:687-690；Flutter 没有服务端，两区移进客户端，spec §18「两区都查、全局取最高分这条不能省」）。
- iTunes 单程超时 **10s/区**（对齐 React 服务端 `COVER_TIMEOUT = 10_000`，music-api.ts:54）；总预算（两区串行）20s。维基 REST 单程 **8s**（spec §18：保留这一级但设 8s 超时），zh → en 逐语言，共 16s。
- 请求头（iTunes）：`Accept: application/json`。维基另加 `Api-User-Agent: light-music-player/1.0 (local dev)`（artist-image.js:126 逐字）。**iTunes 与维基都不发 Cookie / Referer。**
- 失败分类沿用 `UpstreamReason` 四类（`rate-limit` / `timeout` / `unreachable` / `upstream`）；封面链路**不重试、不进冷却闸**（React 侧 matchCover 也没有重试语义，失败静默下沉到下一级兜底）。404 是「条目不存在」，不算错误。
- **错误绝不打扰**：任何一级失败都静默往下走，永不阻塞播放、不弹 Toast（spec §12）。
- 网络错误**不写缓存**（cover-source.js:125「网络错误不缓存，下次还值得一试」）；`aborted` 也不写。
- 封面请求只发曲名 / 歌手 / 时长 / 歌手名，**绝不上传音频**。

### 缓存

- **iTunes 封面索引**：prefs 键 `light-music.cover-cache.v1`（cover-source.js:24 逐字），最多 **150** 条（:25），命中 TTL **30 天**、未命中 TTL **3 天**（:28-29），超限按 `at` 升序淘汰最旧的溢出部分（:76-81）。条目形状：命中 `{u: <文件路径>, src: 'iTunes', at}`；未命中 `{miss: true, at}`。
- **写真索引**：prefs 键 `light-music.artist-image.v1`（artist-image.js:26 逐字），最多 **80** 条（:27），命中 30 天、未命中 **1 天**（:30-31）。条目形状：命中 `{url: <文件路径>, source: 'Wikipedia（zh）', at}`；未命中 `{miss: true, at}`。
- **在线封面落盘**：目录 `$dataDirectory/covers-net/`，文件名 `sha1("<title>|<artist>|<duration>".toLowerCase()).jpg`（iTunes）或 `sha1(imageUrl).jpg`（写真；对齐 React 服务端 music-api.ts:711/:750 的 id 规则）。**复用 `CoverImageWriter.write`**（解码 → ≤600px → PNG 字节 → `.jpg` 名，cover_image.dart:13-17 的格式约定不变）；下载字节上限 **8MB**，超限当失败。
- 写真另有**内存负缓存**：`Map<String, String?>`，值为 null 表示「问过没有」（covers.tsx:23），会话内不再问第二次（与索引层的 1 天 miss 并存，React 同款双层）。
- `useCache: false`（手动重试）**只跳过读**，仍然写。M2b 没有封面「重试」按钮，该参数只为测试保留。

### 显示层与写回纪律（spec §12 红线）

- `coverForDisplay(track)` 判定顺序（covers.tsx:41-53 逐字对译）：
  1. `track == null` → 占位碟（Flutter 侧 = 空路径，`CoverDisc` 自己落 `_DiscPlaceholder`，**不需要** React 的 `DEFAULT_COVER` 常量）；
  2. `track.cover` 非空（= 内嵌封面落盘路径）→ 它；
  3. 写真表 `artistPhotos[normalizeArtistKey(track.artist)]` 非空 → 写真文件路径；
  4. → 生成卡（现算，**不落盘、不写回**）。
- `needsCoverMatch(track)` = `track != null && track.cover.isEmpty`（covers.tsx:33-35 对译；React 那个 `=== DEFAULT_COVER` 分支是本地静态站特有，Flutter 的 cover 只会是 '' 或真实路径）。
- **只有 iTunes 匹配结果可以落盘并进入 resolver 第 2.5 级**（介于内嵌与写真之间，React 侧等价物是「matchCover ok → track.cover = url」，covers.tsx:92-95；Flutter 不写 track.cover，改为 `matchedCovers` 内存表 `Map<trackId, 文件路径>` + 索引层持久化）。
- 写真/生成卡**绝不**写 `track.cover`、**绝不**落库。
- `normalizeArtistKey(artist)` = `trim().toLowerCase()` + 连续空白（含 `\u3000`）折叠成单空格（artist-image.js:42-48 逐字）。

### 生成卡（Painter 实现的确定性约束）

- 生成卡是**离线、确定性**的：同一 `artist`（经 `normalizeArtist` 归一）+ 同一 `title` 恒定同一画面。**Dart 侧不生成 SVG 字符串**（不引 flutter_svg、也不自己画 SVG），改为 `CustomPainter` 按 React 版公式直绘，golden 数值用例钉死派生量。
- FNV-1a 32 位哈希逐字对译（generated-cover.js:23-30）：初值 `0x811C9DC5`，`value ^= charCode`，`value = (value * 0x01000193) & 0xFFFFFFFF`（Dart 用 `*` 后 `& 0xFFFFFFFF` 等价 JS `Math.imul`），返回无符号 32 位。**输入按 UTF-16 码元遍历**（`text.codeUnitAt(i)`，与 JS `charCodeAt` 一致，emoji 的代理对拆成两个码元参与哈希 —— 不按 codePoint）。
- `normalizeArtist`（generated-cover.js:37-44 逐字）：`trim().toLowerCase()` → `\s+` 折叠 → `\u3000` 折叠 → 去尾部 `\s*[-–—]\s*$`。空串用 `'unknown'`。
- 派生量（:89-92 逐字）：`seed = hash(key)`；`hue = seed % 360`；`hue2 = (hue + 32 + seed % 26) % 360`；`rotation = seed % 4`。
- `initialsOf`（:65-79）：空 → `'♪'`；`artist.replace(/[^\p{L}\p{N}]/gu, ' ')` 后取非空字符序列；首字符匹配 CJK 正则 `[\u3400-\u9fff\u3040-\u30ff\uac00-\ud7af]` → 取 1 个字；否则取前 2 个 `toUpperCase()`。**Dart 正则**：`[^\p{L}\p{N}]` 用 `RegExp(r'[^\p{L}\p{N}]', unicode: true)`；CJK 判定用 `RegExp(r'[\u3400-\u9fff\u3040-\u30ff\uac00-\ud7af]')`。
- 黄金数值（node 现算，用例逐条断言）：

  | artist | key | seed | hue | hue2 | rotation | initials |
  | --- | --- | --- | --- | --- | --- | --- |
  | `周杰伦` | `周杰伦` | 3719078777 | 137 | 180 | 1 | 周 |
  | `Jay Chou` | `jay chou` | 3504833698 | 58 | 92 | 2 | JA |
  | `  陈奕迅  ` | `陈奕迅` | 3387159545 | 185 | 220 | 1 | 陈 |
  | `未知歌手` | `未知歌手` | 2278938309 | 69 | 112 | 1 | 未 |
  | `''` | `unknown` | 2608177081 | 121 | 156 | 1 | ♪ |

  另有 `周杰伦` 的 27 根柱高（哈希派生，逐根断言前 5 根即可）：`[66,37,40,80,58,…]`；`Jay Chou`：`[61,19,78,52,51,…]`。
- 画面结构（:115-144）：viewBox 600×600 → 画布 600×600 逻辑像素；线性渐变（rotation % 2 ? 横向 : 斜向，stop 0/0.55/1 三档，色 `HSL(hue 68% 22%)` / `HSL(hue2 72% 34%)` / `HSL((hue2+18)%360 78% 48%)`）；径向白光（cx .5 cy .42 r .62，白 22% → 透明）；三个同心装饰圆（圆心 (300,228)，r 150/196/242，白 12% 描边）；首字居中 (300,228)（字号 2 字 168 / 1 字 216，白 92%）；27 根声波柱（中线 y=360，`barSpan=408`、`barStart=96`、`barWidth=408/27/1.9`，柱高 `18 + round((sin((i+1)*(1+seed%5)*0.6)*0.5+0.5 + jitter)*46)`，jitter = `hash('key#i') % 100 / 100 * 0.5`，胶囊形，色 `HSL(hue2 85% 62%) @ 50%`）；底部歌手名（y=450，28 号，白 86%，截 14 字，空 → `未知歌手`）；曲名小字（y=507，18 号，白 55%，截 16 字，仅非空时画）。
- **安全圆**：内容都落在内切圆内 —— 横向柱列只占中间 68%，文字纵向最远到 y=507 < 300+300。Painter 画的是**方图**，圆裁由外层 `ClipOval`（CoverDisc 既有行为）负责，painter 不自裁。
- **测试渲染**：`dart:ui` 编解码/渲染需要 `TestWidgetsFlutterBinding.ensureInitialized()` + 普通 `test()`（`cover_image_test.dart:5-8` 的既有手法）；golden 用 `GoldenFileComparator` 或直接断言 painter 的派生字段。生成卡类必须把派生量（seed/hue/hue2/rotation/initials/bars）暴露成可断言的字段或返回结构，**不许**把画面埋进 paint 里没法测。

### 灯箱（spec §13 Lightbox 段 + App.tsx:1155-1447 逐字对译）

- 常量：`LIGHTBOX_MAX_SCALE = 4`、`LIGHTBOX_ZOOM_RATE = 0.0016`、`LIGHTBOX_DOUBLE_SCALE = 2`（App.tsx:1156/1159/1162 逐字）。
- 视图状态**以 ref 为准**（App.tsx:1172-1176）：触控板惯性会让滚轮同帧连发，从 state 读会基于旧值。Flutter 侧等价物 = 单个 `ValueNotifier<LightboxView>`（view 含 scale+offset），每次变换在**同一个同步帧**内「读 notifier.value → 算 → 写 notifier」，避免 listener 回读旧值。
- 打开 / 换图复位：`applyView(1, 0, 0)` 并清指针表、pinch、dragging（App.tsx:1231-1238）——**不把上一首的缩放状态带过去**。
- 位移夹取（App.tsx:1240-1255 逐字公式）：图片居中 + 以自身中心缩放，`maxX = 尺寸 × (scale − 1) / 2`，offset 夹到 `[−maxX, maxX]`。Flutter 侧 img 尺寸取布局后的 `BoxConstraints`（`LayoutBuilder`），600×600 的逻辑尺寸在两侧一致。
- 锚点缩放 zoomAt（App.tsx:1261-1282 逐字换算）：`cx = 锚点 − 图中心`；`local = (cx − offset) / currentScale`；`nextOffset = cx − local × nextScale`；`nextScale == currentScale` 时直接 return。滚轮（`exp(−deltaY × 0.0016)`、光标锚点）与双击（`current >= 4 ? 1 : min(4, current × 2)`、点击处锚点）共用。
- 捏合（App.tsx:1200-1223 / 1341-1356）：第二指落下建基准 —— `distance`（两指距离 || 1）、`scale`（当前值）、`center`（**图自身中心**：`rect中心 − offset`）、`local`（起始中点在图片本地坐标系的位置）；移动时 `nextScale = clamp(pinch.scale × distance'/distance, 1, 4)`，`nextOffset = mid − center − local × nextScale`。**指间内容不漂移、中点移动同时当平移**。
- 指针生命周期（App.tsx:1307-1401）：
  - `pointerDown`：登记指针；`size >= 2` → beginPinch；`scale <= 1` → 不启动拖拽（把点击让给「点空白关闭」）；`scale > 1` → 记 dragging 基准。
  - `pointerMove`：pinch 分支优先；单指 dragging = `base + delta` 再 clamp。
  - `pointerEnd`：删指针；剩 ≥2 → 重新 beginPinch；剩 1 且 scale>1 → 那根手指无缝转拖拽（以当前位置为新基准）；否则清 dragging。
  - Flutter 侧用 `Listener`（raw pointer events）而不是 GestureDetector：多指跟踪与「移动距离」语义要逐事件掌控，GestureDetector 的 gesture arena 会吞第二指。
- 关闭三路：点图以外遮罩、右上角关闭按钮、`Esc`（复用 `CloseOverlayIntent`，app.dart:219-220 分支改成「灯箱开着先关灯箱」）。点在图上不关闭。
- 视觉（app.css:3654-3751 对译）：遮罩 `Color(0xE604080C)`（rgba(4,8,12,.86)）+ `ImageFilter.blur(10)`；图 `min(78vw, 620px)` × `min(72vh, 620px)` 方形（`BoxConstraints(maxWidth: 620, maxHeight: 620)`，占位 78vw/72vh 由 LayoutBuilder 算），圆角 `radiusXl`（token 已有），1px `borderStrong` 描边，大投影；caption 13px `textDim` 居中单行 ellipsis（`[title, artist, album].filter(Boolean).join(' · ')`，App.tsx:1444）；关闭按钮 40×40 圆形右上 (18,18)，`tint2` 底 + `borderStrong` 描边，按下缩到 0.94。**颜色全部取自 token**：遮罩色加进 `AppTokens`（新字段 `lightboxScrim`，字面量 `0xE604080C`；浅色翻表是 M3 的事，本段只有 dark 一套）。
- 无障碍（spec §14）：整层 `Semantics(label: '封面大图')`；关闭按钮 `Semantics(button: true, label: '关闭大图（Esc）')`；打开时焦点交给关闭按钮（`FocusNode` + `autofocus`）；图片放大层 `ExcludeSemantics`（纯装饰语义交给外层）。打开前的焦点元素在关闭后归还 —— React 走 rAF 回焦，Flutter 侧 `FocusScope` 在 overlay 卸载后自动回落 + 显式 `FocusNode.requestFocus(previous)` 双保险，测试断言「关闭后焦点在封面热区」。
- 层叠关系：灯箱 > 歌词页。灯箱开着时 `Esc` 只关灯箱（App.tsx:1581-1591）；歌词页仍在其下渲染（overlay 二选一改为「歌词页开着渲染歌词页，灯箱开着**再叠**灯箱」—— `HomeLayout.overlay` 槽保持歌词页语义，灯箱用**全屏 Stack 顶层**挂载，不复用 overlay 槽，避免歌词页被卸载）。

### 界面数值（逐字）

- 封面显示点 6 处全部换成 `coverForDisplay`：stage（track.cover → resolver）、lyrics_page 右栏、track_row 44、recent_row 40、panel 两处调用点。React 侧 `useCover(current)` 的 5 个调用点（App.tsx:385/547/1069/1166/1483）在 Flutter 侧对应「Stage / Panel 毛玻璃位（M3 才有）/ 歌词页 / 灯箱 / （body 背景 M3）」——本段只接 Stage、歌词页、track_row、recent_row、灯箱 5 处，`panelCover` 那档是 M3 毛玻璃，不做。
- 预取：封面 `COVER_PREFETCH_DELAY = 400`（cover-source.js:411）、歌词 `PREFETCH_GAP = 350`（lyrics-prefetch.ts:16），各自**串行**（一次一张/一首在飞），两个触发点：导入完成后（library.tsx:182-183）、启动还原后（player.tsx:582-584，**等标签纠正/时长补探完成再发**）。
- 预取跳过条件（lyrics-prefetch.ts:33-43 对译）：当前曲目、已有歌词/封面、本会话已排队、本地文件时长未探到（`isLocal && !hasDuration`）。
- **歌词预取是 M2a 漏掉的**（Flutter 侧 lyrics_state.dart 只有当前曲目 attach，无预取）——本段一并补上，作为独立文件 `lib/lyrics/lyrics_prefetch.dart`，对译 lyrics-prefetch.ts 全部 68 行语义。
- 最近播放：M1 已完整落地（`_recordIfAudible` transport_controller.dart:537-548 + 500ms 去抖 + 「已不在列表」），本段**只做封面联动** —— `RecentEntry.cover` 快照字段（recent_store.dart:44）与 resolver 第 3/4 级打通（recent_row 也走 `coverForDisplay`，传入 entry 的 cover/artist/title 三字段）。

### 颜色

- `lib/ui/` 下**不许出现颜色字面量**，一律 `context.tokens`。
- `AppTokens` 里的半透明色必须写成字面量 `0xAARRGGBB`。
- 本段只新增一个 token：`lightboxScrim = Color(0xE604080C)`。其余复用 `bg` / `borderStrong` / `radiusXl` / `textDim` / `tint2` / `shadowCard`。

---

## File Structure

新建（`flutter-app/` 下）：

| 文件 | 职责 |
| --- | --- |
| `lib/cover/itunes_source.dart` | `normalizeCoverQuery`（复用 lyrics/query.dart 的 `normalizeQuery`）、`scoreItem`、`pickBest`、`iTunesSearch`（两区直连 + `HttpJsonClient`）、`CoverMatch` 结果类型。 |
| `lib/cover/cover_disk_cache.dart` | iTunes 索引层（prefs `light-music.cover-cache.v1`，150 条 30d/3d）+ 落盘器（下载字节 → `CoverImageWriter` → `covers-net/sha1.jpg`）。 |
| `lib/cover/artist_image.dart` | `normalizeArtistKey`、维基 REST 直连（zh→en，8s）、`ArtistImageMatch`、写真索引层（prefs 80 条 30d/1d）+ 落盘器。 |
| `lib/cover/generated_cover.dart` | FNV-1a、`normalizeArtist`、`initialsOf`、派生量、`GeneratedCoverPainter`（600×600 CustomPainter）+ `paintGeneratedCover(TrackLike) → 可断言结构`。 |
| `lib/cover/cover_source.dart` | `matchCover`（查询 → 索引 → 两区搜索 → 落盘 → 状态）、`matchArtistImage`（查询 → 索引 → 直连 → 落盘）、`ImageBytesClient` 接缝 + 懒建实现。 |
| `lib/lyrics/lyrics_prefetch.dart` | 后台歌词预取（350ms 串行，跳过条件逐字）。 |
| `lib/state/cover_state.dart` | `CoverState`：`coverForDisplay`、`needsCoverMatch`、matchedCovers/artistPhotos 内存表、`matchFor`（去重 + 静默下沉写真）、`prefetchCovers`（400ms 串行）、`revalidateTrack`。 |
| `lib/state/lightbox_controller.dart` | 灯箱开合（仿 `LyricsPageController` 的单 bool 幂等 ChangeNotifier）。 |
| `lib/ui/cover_lightbox.dart` | 灯箱 widget：遮罩、大图（`InteractiveViewer` 不用 —— 手势语义逐事件掌控，自绘变换）、滚轮/双击/捏合/拖拽、caption、关闭按钮。 |
| `lib/ui/generated_cover_view.dart` | `GeneratedCoverView`：`CustomPaint(painter: GeneratedCoverPainter(...))` 的 widget 壳。 |
| `lib/ui/cover_image.dart` | `CoverImage`：统一封面显示件 —— 有路径 `Image.file`、无路径 `GeneratedCoverView`，包 `ClipOval` 可选；stage/行内/灯箱共用（对译 `useCover` 的显示侧）。 |

修改：

| 文件 | 改什么 |
| --- | --- |
| `lib/theme/app_tokens.dart` | 新增 `lightboxScrim`。 |
| `lib/core/storage_keys.dart` | 不加键（索引键逐字用 React 的裸键，同 M2a 歌词索引做法）。 |
| `lib/ui/vinyl_deck.dart` | `CoverDisc` 增加可选 `fallbackArtist`/`fallbackTitle`：无内嵌封面时画生成卡碟面（替代 `_DiscPlaceholder` 的音符），`existsSync` 失效路径行为不变。 |
| `lib/ui/stage.dart` | `cover-disc` 热区 `onTap` 接灯箱 `open()`；`coverPath` 换 resolver 输出。 |
| `lib/ui/lyrics_page.dart` | `_ArtColumn` 变成灯箱入口（`art-btn` 对译）；`coverPath` 换 resolver 输出。 |
| `lib/ui/track_row.dart` / `lib/ui/recent_row.dart` | 缩略图换 resolver 输出（Track/RecentEntry 三字段）。 |
| `lib/ui/panel.dart` | 两处调用点改传 resolver。 |
| `lib/ui/home_page.dart` | 全屏 Stack 顶层挂 `CoverLightbox`（灯箱开时）。 |
| `lib/core/shortcuts.dart` / `lib/app.dart` | `closeOverlay` 分支：灯箱开着先关灯箱。 |
| `lib/state/library_state.dart` | `importPaths`/`importDirectory` 完成后触发封面预取（经回调注入，不直接依赖 CoverState）。 |
| `lib/main.dart` | 装配 `CoverState` / `coverSource` / 预取挂载（transport.view、restore 后、import 回调）。 |
| `lib/app.dart` | AppBootstrap 加 `cover` 字段 + provider 注册。 |
| `lib/state/lyrics_state.dart` | 不改本体；预取由装配层把 `LyricsSource` 交给 `LyricsPrefetch`。 |

测试（与源码镜像）：

| 文件 | 覆盖 |
| --- | --- |
| `test/cover/itunes_source_test.dart` | scoreItem 全档、pickBest 门槛与二次校验、artworkBig、两区取最高、limit/term 拼参。 |
| `test/cover/generated_cover_test.dart` | FNV-1a 黄金数值、initialsOf、派生量、柱高、确定性（同输入同结构）。 |
| `test/cover/artist_image_test.dart` | normalizeArtistKey、pickImage 顺序、zh→en 回退、404→null、占位歌手拒绝、缓存 TTL。 |
| `test/cover/cover_source_test.dart` | 索引命中/过期/未命中、网络错误不写缓存、落盘路径（真临时目录）、`useCache:false`。 |
| `test/state/cover_state_test.dart` | coverForDisplay 四级、生成卡不写回、matchFor 去重与静默下沉、预取间隔与跳过条件。 |
| `test/lyrics/lyrics_prefetch_test.dart` | 350ms 节奏、跳过条件、manual 不覆盖、落库。 |
| `test/ui/cover_lightbox_test.dart` | 开/关三路、复位、双击分级、clamp 公式、Esc 优先级、焦点归还。 |
| `test/ui/cover_image_test.dart`（widget） | `CoverImage` 路径失效退生成卡、`CoverDisc` 生成卡碟面。 |
| `test/ui/cover_thumb_test.dart` | track_row/recent_row 走 resolver 的快照。 |

---

## Task 1: 生成卡派生量与 Painter（纯 Dart，黄金数值钉死）

**Files:**
- Create: `flutter-app/lib/cover/generated_cover.dart`
- Create: `flutter-app/lib/ui/generated_cover_view.dart`
- Test: `flutter-app/test/cover/generated_cover_test.dart`

**Interfaces:**
- Consumes: 无（纯 Dart + dart:ui）
- Produces:
  ```dart
  class GeneratedCoverSpec {
    final String key; final int seed, hue, hue2, rotation;
    final String initials; final String label; final String sub;
    final List<int> bars; // 27 根柱高
    final bool showSub;
  }
  GeneratedCoverSpec generatedCoverSpec(String artist, String title);
  int fnv1aHash(String text); // UTF-16 码元遍历
  String normalizeArtistForCover(String artist);
  String initialsOfArtist(String artist);
  class GeneratedCoverPainter extends CustomPainter { GeneratedCoverPainter(this.spec); final GeneratedCoverSpec spec; }
  ```
  供 [GeneratedCoverView]（ui 壳）与测试用。painter 画 600×600 逻辑坐标（`canvas.scale(size/600)` 归一）。

**基准源码（`src/lib/generated-cover.js`，逐字；上面 Global Constraints「生成卡」节已给黄金数值与公式表）：**

移植要点（逐条都有用例）：
1. 哈希输入走 UTF-16 码元：`for (var i = 0; i < text.codeUnits.length; i++)`。
2. `bars[i] = 18 + round((sin((i+1)*(1+seed%5)*0.6)*0.5+0.5 + jitter_i) * 46)`，`jitter_i = (fnv1aHash('$key#$i') % 100) / 100 * 0.5`。
3. HSL→Color 的换算写在 painter 内私有函数（`hsl(h, s%, l%)` → `Color.fromLAB` 不存在，用标准 HSL→RGB 公式，s/l 按 0~1 传入）。
4. 渐变与柱形按 Global Constraints「画面结构」节的几何逐字。
5. `label = artist.trim().isEmpty ? '未知歌手' : artist.trim()`，截 14 字；`sub` 截 16 字，空则整行不画。

- [ ] **Step 1: 写失败测试**（黄金数值表逐条 + bars 前 5 根 + `'♪'` 兜底 + 确定性断言 `spec1 == spec2` 的字段相等）
- [ ] **Step 2: 跑测试确认失败**：`flutter test test/cover/generated_cover_test.dart` → 编译失败（文件不存在）
- [ ] **Step 3: 实现** `lib/cover/generated_cover.dart`（spec 派生 + painter）与 `lib/ui/generated_cover_view.dart`（`CustomPaint` 壳，尺寸由父级给）
- [ ] **Step 4: 跑测试确认通过**
- [ ] **Step 5: `flutter analyze` 0 issue**
- [ ] **Step 6: Commit**
  ```bash
  git add flutter-app/lib/cover/generated_cover.dart flutter-app/lib/ui/generated_cover_view.dart flutter-app/test/cover/generated_cover_test.dart
  git commit -m "feat(cover): 生成卡派生量与 Painter，黄金数值对表 React 版"
  ```

---

## Task 2: iTunes 匹配源（打分 + 两区搜索 + 结果类型）

**Files:**
- Create: `flutter-app/lib/cover/itunes_source.dart`
- Test: `flutter-app/test/cover/itunes_source_test.dart`

**Interfaces:**
- Consumes: `HttpJsonClient`（lyrics/upstream.dart:102）、`normalizeQuery`（lyrics/query.dart:73）、`CancelToken`
- Produces:
  ```dart
  class CoverMatch {
    final String status; // ok | not-found | error | aborted | empty-query
    final String? url;   // ok 时：600px 图的远程地址（下载由上层做）
    final String source; // 'iTunes'
    final String message;
  }
  class iTunesItem / ScoreResult { score, titleExact, artistMatch }
  ScoreResult scoreItem(Map item, ({String trackName, String artistName, double duration}) query);
  Map? pickBest(List results, query);
  Future<CoverMatch> itunesSearch(query, {required HttpJsonClient client, CancelToken? cancel, double cnTimeout = 10, double usTimeout = 10});
  String artworkBig(String artworkUrl); // /100x100bb.x → /600x600bb.x
  ```
- `normalizeCoverQuery(track)` 直接复用 `normalizeQuery(title:, artist:, duration:)`（query.dart:73）—— 曲名字段同源（`cleanTitle`、占位歌手反推），**不再实现第二份**。

**基准源码（`src/lib/cover-source.js:139-224` scoreItem/pickBest/artworkBig 逐字 + music-api.ts:687-690 两区参数）：**

打分表（lowercase 比较）：歌名相等 +30 / 互相包含 +12；歌手相等 +25 / 互相包含 +10（`artistMatch = a===b || a.contains(b) || b.contains(a)`）；时长差 `<=2` +20 / `<=6` +8 / `>25` −25。`pickBest`：跳过无 `artworkUrl100` 的条目；取最高分；`bestScore < 18` 放弃；二次校验 `titleExact || artistMatch`（注意：二次校验的 `artistMatch` 是 covers 侧的**三连或**定义，:219-222 与 scoreItem 内一致）。两区顺序 CN → 默认（不传 country），单区失败不影响另一区，结果全局取 score 最高。

- [ ] **Step 1: 写失败测试**（打分全档：30/12/25/10/20/8/−25 边界 2/6/25；门槛 17 拒 18 收；无 artworkUrl100 跳过；二次校验「分数够但歌名歌手都不匹配 → null」反例：`wantTitle='光年之外'`、`name='Light Years Away'` 无包含、score 由歌手+时长凑够 18 → 拒；artworkBig 正则；两区 mock：CN 回低分条目、US 回高分条目 → 取 US 的；CN 抛错不影响 US；请求参数断言 term/entity/media/limit=8/country）
- [ ] **Step 2: 跑测试确认失败**
- [ ] **Step 3: 实现**
- [ ] **Step 4: 跑测试确认通过 + analyze 0 issue**
- [ ] **Step 5: Commit**
  ```bash
  git add flutter-app/lib/cover/itunes_source.dart flutter-app/test/cover/itunes_source_test.dart
  git commit -m "feat(cover): iTunes 打分与两区搜索源"
  ```

---

## Task 3: 在线封面缓存与取图接缝

**Files:**
- Create: `flutter-app/lib/cover/cover_disk_cache.dart`
- Create: `flutter-app/lib/cover/cover_source.dart`（本任务先做缓存与下载骨架；Task 4 补写真后合并 matchCover）
- Test: `flutter-app/test/cover/cover_source_test.dart`

**Interfaces:**
- Consumes: `AppPrefs`、`CoverImageWriter`（metadata/cover_image.dart:20）、`CoverMatch`（Task 2）
- Produces:
  ```dart
  class CoverIndexCache { // prefs: light-music.cover-cache.v1, 150 条, 30d/3d
    Future<CoverRecord?> read(String key);
    Future<void> write(String key, CoverRecord record); // 只收 ok / not-found
    Future<void> clear();
  }
  class CoverRecord { final String status; final String path; final String source; } // path = 落盘文件绝对路径
  class CoverDiskStore {
    CoverDiskStore({required this.directory, CoverImageWriter writer = const CoverImageWriter()});
    Future<String?> saveFromUrl({required String url, required String id, required ImageBytesClient bytes});
    String fileFor(String id); // '$directory/<sanitized-id>.jpg'
  }
  abstract class ImageBytesClient { Future<ImageBytesOutcome> getBytes(Uri url, {required Duration timeout}); }
  class ImageBytesClientImpl implements ImageBytesClient { ... } // 懒建 http.Client，8MB 上限，超限/超时/网络错 → 失败 outcome
  ```
- 缓存键 = `query.key`（`"<trackName>|<artist>|<duration>".toLowerCase()`，query.dart:96 已给）。落盘 id = `sha1(key)`（crypto 包；**与 React 服务端 sha1(title|artist 小写) 对齐**，music-api.ts:711）。
- 索引条目形状 `{'p': <路径>, 'src': 'iTunes', 'at': ms}` / `{'miss': true, 'at': ms}` —— 与 `LyricsIndexCache` 同构（lyrics_cache.dart:123-142 的写法），坏 JSON 读后留原地不删。

- [ ] **Step 1: 写失败测试**（inMemory prefs：写→读往返；TTL 过期返回 null 不删条目；超 150 条淘汰最旧；`miss` 3 天 / 命中 30 天不同 TTL；网络错误不写缓存；`saveFromUrl` 用真临时目录 + 1×1 PNG 字节断言落盘文件存在且 `Image.file` 可读路径成立；8MB 超限 mock 大字节 → null；`ImageBytesClientImpl` 懒建 —— 构造不发请求）
- [ ] **Step 2: 跑测试确认失败**
- [ ] **Step 3: 实现**
- [ ] **Step 4: 跑测试确认通过 + analyze 0 issue**
- [ ] **Step 5: Commit**
  ```bash
  git add flutter-app/lib/cover/cover_disk_cache.dart flutter-app/lib/cover/cover_source.dart flutter-app/test/cover/cover_source_test.dart
  git commit -m "feat(cover): 在线封面双层缓存与取图接缝"
  ```

---

## Task 4: 维基写真源

**Files:**
- Create: `flutter-app/lib/cover/artist_image.dart`
- Test: `flutter-app/test/cover/artist_image_test.dart`

**Interfaces:**
- Consumes: `HttpJsonClient`、`ImageBytesClient`、`CoverImageWriter`
- Produces:
  ```dart
  String normalizeArtistKey(String artist); // trim/lowercase/空白含\u3000折叠
  class ArtistImageMatch { final String status; final String? url; final String source; final String reason; final String message; }
  Future<ArtistImageMatch> matchArtistImage(String artist, {required HttpJsonClient json, required ImageBytesClient bytes, required String directory, ArtistIndexCache? index, bool useCache = true, double perLangTimeout = 8});
  class ArtistIndexCache { ... } // prefs: light-music.artist-image.v1, 80 条, 30d/1d, {'u': path,'source': ..., 'at'} / {'miss': true,'at'}
  ```
- 直连端点逐字：`https://{lang}.wikipedia.org/api/rest_v1/page/summary/{encodeURIComponent(artist.trim())}`，lang 顺序 `['zh','en']`；404 → 换语言；`pickImage` 顺序 `originalimage.source` → `thumbnail.source`（`^https?://` 校验）；source 文案 `Wikipedia（zh）`（React 的「，直连」后缀是通道区分用的，Flutter 只有一条通道，去掉）。
- 占位歌手拒绝：key 为空或等于 `'本地文件'` / `'未知歌手'` → `not-found`（artist-image.js:193-195 逐字）。
- 落盘 id = `sha1(imageUrl)`（music-api.ts:750）。
- 维基失败（本机 DNS 污染常态）→ `not-found` 或 `error(reason: unreachable)`，**绝不抛**，上层静默下沉到生成卡。

- [ ] **Step 1: 写失败测试**（normalizeArtistKey 全角空格/连续空格/大小写；占位歌手拒绝；pickImage 顺序与非法 URL；zh 404 → en 命中；两语言全 404 → not-found；两语言全网络错 → error(unreachable)；缓存读写与 1 天 miss TTL；落盘写真文件路径）
- [ ] **Step 2: 跑测试确认失败**
- [ ] **Step 3: 实现**
- [ ] **Step 4: 跑测试确认通过 + analyze 0 issue**
- [ ] **Step 5: Commit**
  ```bash
  git add flutter-app/lib/cover/artist_image.dart flutter-app/test/cover/artist_image_test.dart
  git commit -m "feat(cover): 维基写真源与写真缓存"
  ```

---

## Task 5: matchCover 编排（Task 2+3+4 的合流点）

**Files:**
- Modify: `flutter-app/lib/cover/cover_source.dart`
- Test: `flutter-app/test/cover/cover_source_test.dart`（追加）

**Interfaces:**
- Produces:
  ```dart
  class CoverSource {
    CoverSource({required this.json, required this.bytes, required this.diskStore, this.coverIndex, this.artistIndex, this.artistStore});
    Future<CoverMatch> matchCover(TrackLike t, {CancelToken? cancel, bool useCache = true});
    Future<ArtistImageMatch> matchArtistImage(String artist, {bool useCache = true});
  }
  class TrackLike { final String title, artist; final double duration; } // 或直接用 record 类型
  ```
- `matchCover` 流程 = React matchCover（cover-source.js:368-396）去掉代理/JSONP 分叉、加上两区与落盘：空查询 → `empty-query`；`useCache` → 读索引（命中直接返回**文件路径**）；离线不判（M2a 同款：`isOnline` 恒 true 语义，实际网络失败走 error 不写缓存）；两区搜索 → `pickBest` 命中 → `artworkBig` → `saveFromUrl` 落盘 → 索引写 `{p: path}` → 返回 ok+路径；搜索 not-found → 索引写 miss → 返回 not-found；网络错 → 不写缓存 → error。**下载失败降级**：图下载/落盘失败 → 按 not-found 处理（索引写 miss），不返回半成品。
- `TrackLike` 由调用方从 `Track` / `RecentEntry` 三字段构造。

- [ ] **Step 1: 追加失败测试**（假 json client + 假 bytes client：ok 全链路返回文件路径且索引可读回；not-found 写 miss；搜索错不写缓存；下载失败 → miss；useCache:false 绕过读仍写；aborted）
- [ ] **Step 2: 跑测试确认失败**
- [ ] **Step 3: 实现**
- [ ] **Step 4: 跑测试确认通过 + analyze 0 issue**
- [ ] **Step 5: Commit**
  ```bash
  git add flutter-app/lib/cover/cover_source.dart flutter-app/test/cover/cover_source_test.dart
  git commit -m "feat(cover): matchCover 编排——索引、两区搜索、落盘与降级"
  ```

---

## Task 6: CoverState 显示层

**Files:**
- Create: `flutter-app/lib/state/cover_state.dart`
- Test: `flutter-app/test/state/cover_state_test.dart`

**Interfaces:**
- Consumes: `CoverSource`（Task 5）、`generatedCoverSpec`（Task 1）
- Produces:
  ```dart
  class CoverState extends ChangeNotifier {
    CoverState({required CoverSource source, this.isOnline});
    String coverForDisplay({required String cover, required String artist, required String title}); // Track/RecentEntry 三字段入口
    bool needsCoverMatch({required String cover}); // cover.isEmpty
    void matchFor(TrackLike track);               // 去重 key=track.id；ok→matchedCovers；miss/error→requestArtistPhoto
    void requestArtistPhoto(String artist);       // 写真表 Map<String,String?>，负缓存 null
    Future<void> prefetchCovers(List<TrackLike> tracks); // 400ms 串行
    void forget(String trackId); // 曲目删除时清 matchedCovers（防内存泄漏）
  }
  ```
- `coverForDisplay` 判定顺序按 Global Constraints「显示层」节：`cover` 非空 → `matchedCovers[id]` → `artistPhotos[key]` → `''`（生成卡由显示件现画，不产生路径）。**matchedCovers 挡在 cover 字段之前**：内嵌封面优先，其次在线匹配（React 把匹配结果写进 track.cover 形成等价顺序）。
- `matchFor` 去重：`pending: Set<String>`；`matchedCovers.has(id)` 或 `cover` 非空 → 跳过。
- 通知语义：写真/匹配图到达后 `notifyListeners()`（对译 React 的 `notifyPhotoArrived` + context tick 陷阱 —— ChangeNotifier 天然规避）。

- [ ] **Step 1: 写失败测试**（四级顺序各一例：cover 优先于 matched；matched 优先于 photo；photo 优先于空；空 → ''；生成卡不写回 —— matchFor 后 `track.cover` 仍 ''；pending 去重 —— 同 id 两次只发一次网络；photo 负缓存 —— not-found 后同歌手不再发；prefetchCovers 400ms 间隔用假 sleep 注入断言调用节奏；forget 清表）
- [ ] **Step 2: 跑测试确认失败**
- [ ] **Step 3: 实现**
- [ ] **Step 4: 跑测试确认通过 + analyze 0 issue**
- [ ] **Step 5: Commit**
  ```bash
  git add flutter-app/lib/state/cover_state.dart flutter-app/test/state/cover_state_test.dart
  git commit -m "feat(state): CoverState 显示层——四级兜底、去重与预取调度"
  ```

---

## Task 7: 歌词预取（M2a 漏项补齐）

**Files:**
- Create: `flutter-app/lib/lyrics/lyrics_prefetch.dart`
- Test: `flutter-app/test/lyrics/lyrics_prefetch_test.dart`

**Interfaces:**
- Consumes: `LyricsMatcher`（lyrics_source.dart:86）、`LyricsQuery`/`normalizeQuery`
- Produces:
  ```dart
  class LyricsPrefetch {
    LyricsPrefetch({required LyricsMatcher matcher, Future<void> Function(Duration)? sleep, bool Function()? isOnline});
    Future<int> prefetch(List<Track> tracks, {String? currentId}); // 返回补齐条数
  }
  ```
- 逐字对译 `src/state/lyrics-prefetch.ts`（基准全文 68 行已在调研报告内）：`PREFETCH_GAP = 350`；跳过 `id == currentId`、已有 `lyrics/lyricsPlain`、`queued` 集合、`isLocal && !hasDuration`；成功且 `lyricsSource != 'manual'` 且仍无歌词才写回（`synced → lyrics`，纯文本 → `lyricsPlain`，`lyricsSource='auto'`）；单条失败继续。
- **落库**：React 逐条 `patchLocalRecord`，Flutter 侧没有逐条 patch —— 写回活对象后由调用方（装配层）在 prefetch 完成后 `library.persist()` **一次**（M2a 批量落库同款裁定）。
- `Track` 是 `lib/playback/track.dart` 的类型，这里直接用它（不另造 TrackLike）。

- [ ] **Step 1: 写失败测试**（假 matcher：350ms 节奏由注入 sleep 断言；跳过条件逐条；manual 不覆盖；返回值=补齐条数；isOnline=false → 0）
- [ ] **Step 2: 跑测试确认失败**
- [ ] **Step 3: 实现**
- [ ] **Step 4: 跑测试确认通过 + analyze 0 issue**
- [ ] **Step 5: Commit**
  ```bash
  git add flutter-app/lib/lyrics/lyrics_prefetch.dart flutter-app/test/lyrics/lyrics_prefetch_test.dart
  git commit -m "feat(lyrics): 后台歌词预取（350ms 串行，M2a 漏项补齐）"
  ```

---

## Task 8: 装配（CoverState / 灯箱控制器 / 双预取挂载）

**Files:**
- Modify: `flutter-app/lib/main.dart`、`flutter-app/lib/app.dart`、`flutter-app/lib/state/library_state.dart`
- Test: `flutter-app/test/state/cover_wiring_test.dart`

**Interfaces:**
- `buildBootstrap` 新增可注入参数：`CoverSource? coverSource`、`bool Function()? coverSleep...`（封面预取 sleep）、`LyricsPrefetch? lyricsPrefetch`、`Future<void> Function(Duration)? prefetchDelay`（预取节流；默认生产 `Future.delayed`、测试永不完成 —— main.dart:296-302 同款手法）。生产 `coverSource` 缺省建真实现（`HttpJsonClientImpl` 复用 main.dart:183 的实例、`ImageBytesClientImpl` 懒建、`covers-net` 目录）。
- `CoverState` 建在 `library`/`player` 之后；三个挂载点：
  1. `transport.view.addListener`（main.dart:221-222 同款）→ `cover.matchFor(player.current)`（当前曲目切歌联动）；
  2. `library` 导入完成回调 → 对新增 `addedIds` 逐个 `matchFor` + `prefetchCovers`（library.tsx:182-183）；
  3. `await player.ready(); await library.restore();` 之后 → `enrichmentSettled` 完成后再发封面预取与歌词预取（player.tsx:582-584「等 tagsDone」对译 —— 用 `ImportResult.enrichment` 的 Future，LibraryState 已暴露 `enrichmentSettled`，library_state.dart:482）。
- `LibraryState` 加 `onImportCompleted: void Function(List<String> addedIds)?`（importPaths/importDirectory 成功后调用），避免 LibraryState 直接依赖 CoverState。
- `AppBootstrap` 加 `final CoverState cover; final LyricsPrefetch? lyricsPrefetch;` 与灯箱 `final LightboxController lightbox;`（Task 9 建 controller，本任务先加字段装配 —— 若 Task 9 未开工，字段仍加，构造参数给缺省实例）。provider 注册在 app.dart:156-174 加两行。`dispose()` 释放 `transport.view` 的封面监听（同 `onLyricsViewChanged` 模式，app.dart:100-102）。
- 歌词预取挂载：restore 后（`enrichmentSettled` 之后）`lyricsPrefetch.prefetch(playlist.tracks, currentId: player.current?.id)`，完成后 `library.persist()` 一次。
- 预取一律 `unawaited`（不阻塞启动），但**内部仍等 enrichment**。

- [ ] **Step 1: 写失败测试**（假 CoverSource/LyricsPrefetch 注入：restore 后预取被调；import 后预取被调且传的是新增 id；当前曲目切歌 matchFor 被调；dispose 后监听移除）
- [ ] **Step 2: 跑测试确认失败**
- [ ] **Step 3: 实现**（main.dart 装配 + app.dart 字段/provider + library_state 回调）
- [ ] **Step 4: 跑测试确认通过 + analyze 0 issue**
- [ ] **Step 5: Commit**
  ```bash
  git add flutter-app/lib/main.dart flutter-app/lib/app.dart flutter-app/lib/state/library_state.dart flutter-app/test/state/cover_wiring_test.dart
  git commit -m "feat(app): 装配封面状态与双预取挂载"
  ```

---

## Task 9: 灯箱控制器与 Esc 接线

**Files:**
- Create: `flutter-app/lib/state/lightbox_controller.dart`
- Modify: `flutter-app/lib/core/shortcuts.dart`、`flutter-app/lib/app.dart`
- Test: `flutter-app/test/state/lightbox_controller_test.dart`

**Interfaces:**
- `LightboxController extends ChangeNotifier`：`bool isOpen`、`void open()`（幂等）、`void close()`（幂等）、`void toggle()`（对译 `LyricsPageController` 全套，state/lyrics_page_controller.dart:23-33）。
- `closeOverlay` 语义升级（app.dart:219-220）：`if (lightbox.isOpen) lightbox.close() else if (lyricsPage.isOpen) lyricsPage.close()` —— 灯箱在歌词页之上，Esc 先关灯箱（App.tsx:1581-1591）。

- [ ] **Step 1: 写失败测试**（open/close/toggle 幂等；closeOverlay 分支矩阵：灯箱开→只关灯箱、歌词页开→只关歌词页、都开→只关灯箱、都关→无动作）
- [ ] **Step 2: 跑测试确认失败**
- [ ] **Step 3: 实现**
- [ ] **Step 4: 跑测试确认通过 + analyze 0 issue**
- [ ] **Step 5: Commit**
  ```bash
  git add flutter-app/lib/state/lightbox_controller.dart flutter-app/lib/core/shortcuts.dart flutter-app/lib/app.dart flutter-app/test/state/lightbox_controller_test.dart
  git commit -m "feat(state): 灯箱开合控制器与 Esc 层叠优先级"
  ```

---

## Task 10: CoverImage 统一封面件 + CoverDisc 生成卡碟面

**Files:**
- Create: `flutter-app/lib/ui/cover_image.dart`
- Modify: `flutter-app/lib/ui/vinyl_deck.dart`、`flutter-app/lib/ui/track_row.dart`、`flutter-app/lib/ui/recent_row.dart`、`flutter-app/lib/ui/panel.dart`、`flutter-app/lib/ui/stage.dart`（本任务只换显示，Task 11 接灯箱点击）、`flutter-app/lib/ui/lyrics_page.dart`（同）
- Test: `flutter-app/test/ui/cover_image_test.dart`、`flutter-app/test/ui/cover_thumb_test.dart`

**Interfaces:**
- `CoverImage({required String path, required String artist, required String title, required double size, bool square = true})`：`path` 非空且 `File(path).existsSync()` → `Image.file`（gaplessPlayback: true，errorBuilder → 生成卡）；否则 → `GeneratedCoverView`。方图不裁圆（圆裁由调用方决定）。
- `CoverDisc`（vinyl_deck.dart）加可选 `fallbackArtist` / `fallbackTitle`：`hasFile == false` 时碟面从 `_DiscPlaceholder` 换成 `ClipOval(GeneratedCoverView)`（黑胶盘面逻辑不动）。stage/歌词页传 resolver 三字段。
- `track_row` / `recent_row` / `panel` 的 `CoverThumb` 换 `CoverImage`（44/40 尺寸，`ClipOval` 保留）。
- stage.dart:109 `coverPath: track?.cover ?? ''` → `coverPath: cover.coverForDisplay(...)`（经 `context.watch<CoverState>()`；`StagePreview` 保持纯展示 —— 新字段走参数，默认行为不变）。lyrics_page.dart:278 同。
- 语义红线：resolver 输出的路径来自 `matchedCovers`（在线匹配）时同样 `existsSync` 校验（缓存目录可能被清），失效退生成卡。

- [ ] **Step 1: 写失败测试**（widget：path 空 → `Key('generated-cover')` 出现；path 指向临时目录真文件 → `Image.file` 分支；path 指向不存在文件 → 生成卡；CoverDisc fallback 生成卡碟面；track_row/recent_row 用真临时封面文件与空路径各断言一次）
- [ ] **Step 2: 跑测试确认失败**
- [ ] **Step 3: 实现**
- [ ] **Step 4: 跑测试确认通过 + analyze 0 issue**
- [ ] **Step 5: Commit**
  ```bash
  git add flutter-app/lib/ui/cover_image.dart flutter-app/lib/ui/vinyl_deck.dart flutter-app/lib/ui/track_row.dart flutter-app/lib/ui/recent_row.dart flutter-app/lib/ui/panel.dart flutter-app/lib/ui/stage.dart flutter-app/lib/ui/lyrics_page.dart flutter-app/test/ui/cover_image_test.dart flutter-app/test/ui/cover_thumb_test.dart
  git commit -m "feat(ui): 封面显示层接生成卡与 resolver"
  ```

---

## Task 11: 灯箱 widget（滚轮/双击/捏合/拖拽/关闭三路）

**Files:**
- Create: `flutter-app/lib/ui/cover_lightbox.dart`
- Modify: `flutter-app/lib/ui/home_page.dart`、`flutter-app/lib/ui/stage.dart`、`flutter-app/lib/ui/lyrics_page.dart`
- Test: `flutter-app/test/ui/cover_lightbox_test.dart`

**Interfaces:**
- `CoverLightbox({required VoidCallback onClose})`：从 provider 读 `CoverState.coverForDisplay(player.current 三字段)`（与播放卡同源，App.tsx:1166 `useCover(current)`）+ `player.current` 的 title/artist/album 拼 caption。
- 挂载：`home_page.dart` 的 `MaterialApp` body 之外不用 —— 放 `HomePage` `Scaffold` 的 `Stack` 顶层（`Material` 之上），`context.watch<LightboxController>().isOpen ? CoverLightbox(...) : SizedBox.shrink()`。歌词页照常渲染（不被卸载）。
- 手势按 Global Constraints「灯箱」节逐字：`Listener`（onPointerDown/Move/Up/Cancel）+ `Listener(onPointerSignal: PointerScrollEvent)` 接滚轮；双击用 `GestureDetector(onDoubleTap)`（与 Listener 共存：arena 对 doubleTap 的裁决不影响 raw Listener 收到 down/move —— 若实测双击被吞，回退为手写双击判定：同位置 300ms 内两次 down）；平移/缩放变换 = `Transform.translate(offset) × Transform.scale(scale, alignment: center)` 作用于 600×600（`min(78vw,620)` 约束）方图。
- 视图状态：`ValueNotifier<LightboxView>`，`zoomAt`/`clampOffset`/`beginPinch` 全按基准公式逐字；`open`/`cover` 变化复位（controller.open 时 reset —— controller 只管开关，复位由 widget 的 `didUpdateWidget`/initState 对齐 cover 来源变化）。
- 关闭三路：遮罩 `GestureDetector(onTap: onClose)`（图自己在 Listener 里消费 pointer，1× 时 pointer 不启动拖拽也不关闭 —— React 是「点图上不关闭」，Flutter 侧图区域用 `GestureDetector(onTap: () {})` 吞掉 tap 竞技场）；关闭按钮 `IconButton`（40×40 圆形，右上 18,18，`Semantics(label: '关闭大图（Esc）')`）；Esc 走 Task 9 的 closeOverlay。
- 焦点：打开时 `closeFocusNode.requestFocus()`；关闭时把焦点还给封面热区（stage 的 `cover-disc` FocusNode；React rAF 回焦对译 —— 由 Task 11 在 stage/lyrics_page 的封面入口上建 FocusNode，close 时 requestFocus）。测试断言焦点归还。
- 入口接线：stage.dart:291-294 `onTap: () {}` → `context.read<LightboxController>().open()`（外面包 `Focus` 挂 `coverDiscFocus`）；lyrics_page.dart `_ArtColumn` 的容器换成 `Semantics(button: true, label: '放大封面图片')` + `GestureDetector(onTap: open)` + FocusNode（App.tsx:1121-1137 对译）。
- caption 逐字：`[title, artist, album].where((s) => s.isNotEmpty).join(' · ')`（App.tsx:1444）。

- [ ] **Step 1: 写失败测试**（widget 测试，600×600 视口）：
  - 开：stage 封面 tap → `Key('cover-lightbox')` 出现；歌词页封面 tap → 同样出现；
  - 复位：开灯箱后视图 scale==1 && offset==0（暴露 `ValueListenable` 供测试）；
  - 双击分级：`tester.doubleTap` → scale 2 → 再双击 → 4 → 再双击 → 1（锚点在中心时 offset 保持 0）；
  - clamp：scale=2 时把 offset 拖到 500 → 夹回 `600×(2−1)/2 = 300`；
  - 关闭三路：tap 遮罩空白区关；tap 关闭按钮关；`closeOverlay` 快捷键关；
  - 点图上不关闭：tap 图中心 → 仍开着；
  - 焦点归还：关灯箱后 `FocusManager.primaryFocus` 回到封面热区；
  - caption 内容断言。
- [ ] **Step 2: 跑测试确认失败**
- [ ] **Step 3: 实现**
- [ ] **Step 4: 跑测试确认通过 + analyze 0 issue**
- [ ] **Step 5: Commit**
  ```bash
  git add flutter-app/lib/ui/cover_lightbox.dart flutter-app/lib/ui/home_page.dart flutter-app/lib/ui/stage.dart flutter-app/lib/ui/lyrics_page.dart flutter-app/test/ui/cover_lightbox_test.dart
  git commit -m "feat(ui): 封面放大层——滚轮/双击/捏合锚点缩放与关闭三路"
  ```

---

## Task 12: 验收闸口

**Files:**
- Create: `flutter-app/docs/M2B-ACCEPTANCE.md`
- Modify: `docs/superpowers/specs/2026-11-06-flutter-port-design.md`（§12 追加 M2b 落地记录）

- [ ] **Step 1: 四条闸口**（analyze / test / build windows --debug / build apk --debug，现场取尾行与字节数）
- [ ] **Step 2: 真实上游探测**
  ```bash
  curl -sS -o "$TEMP/itunes-cn.json" -w '%{http_code} %{time_total}\n' \
    'https://itunes.apple.com/search?term=%E9%99%88%E5%A5%95%E8%BF%85%20%E5%8D%81%E5%B9%B4&entity=song&media=music&limit=8&country=CN'
  curl -sS -o "$TEMP/itunes-us.json" -w '%{http_code} %{time_total}\n' \
    'https://itunes.apple.com/search?term=eason%20chan%20ten%20years&entity=song&media=music&limit=8'
  curl -sS -o "$TEMP/wiki-zh.json" -w '%{http_code} %{time_total}\n' \
    -H 'Api-User-Agent: light-music-player/1.0 (local dev)' \
    'https://zh.wikipedia.org/api/rest_v1/page/summary/%E9%99%88%E5%A5%95%E8%BF%85'
  ```
  三行状态码与耗时写进验收文档。维基在本机大概率超时（spec §18 已记录），**如实写「不通，按预期落到生成卡」**，不许写「通过」。
- [ ] **Step 3: 写 `flutter-app/docs/M2B-ACCEPTANCE.md`**：闸口结果 / 自动化覆盖（T1–T11 用例数）/ 真实链路（Windows 真机：导入带内嵌封面的 FLAC、导入无封面的 mp3 看生成卡与 iTunes 匹配、双击/滚轮/捏合灯箱）/ 未验项（Android 真机手势、浅色主题遮罩对比度留给 M3、`panelCover` 毛玻璃位 M3）。
- [ ] **Step 4: spec §12 追加「M2b 落地记录」**：新增文件清单；三处有意差异（①iTunes JSONP 通道合并为直连、代理通道不移植；②在线封面落盘返回文件路径而非 URL，显示层全 `Image.file`；③在线匹配结果进 `matchedCovers` 内存表而非写回 `track.cover` —— 语义等价于 React 把结果写 track.cover，但保住 M1 的「cover == 内嵌封面路径」不变量）；生成卡用 Painter 直绘替代 SVG data URL 的原因（不引 flutter_svg）。
- [ ] **Step 5: Commit**
  ```bash
  git add flutter-app/docs/M2B-ACCEPTANCE.md docs/superpowers/specs/2026-11-06-flutter-port-design.md
  git commit -m "docs: M2b 验收记录与设计文档 §12 落地记录"
  ```

---

## Self-Review 结果（写计划时已逐条过）

**Spec 覆盖**

| spec 要求 | 落在 |
| --- | --- |
| §12 第 1 级内嵌封面 | M1 已有（import_service.dart），本段不改 |
| §12 第 2 级 iTunes 两区、得分不足宁可继续 | T2 + T5 |
| §12 第 3 级维基写真（本机不通照抄降级） | T4 |
| §12 第 4 级生成卡（FNV-1a、安全圆、不写回 track.cover） | T1 + T6 + T10 |
| §12 缓存 30d/3d、命中写回、预取前 3 首 | T3 + T6 + T8 |
| §13 灯箱（三缩放锚点、平移夹取、关闭三路、焦点归还、同源封面） | T9 + T11 |
| §13 双入口（曲目区封面 / 歌词页右栏） | T11 |
| §14 Esc、焦点 | T9 + T11 |
| §16 测试类别（打分、夹取、手势） | T2/T11 |
| §17 M2b 范围（含「最近播放打磨」「歌词与封面后台预取」） | T6（联动）+ T7 + T8 |
| §19 不新增控件、不改 React | 全局约束 |

**有意差异（执行时不要「顺手改回」）：**
1. JSONP/代理双通道合并为一级直连 —— Flutter 无 CORS 限制。
2. 在线封面落盘为文件、resolver 返回路径 —— 显示层不需要网络图加载。
3. 匹配结果不写 `track.cover`，进 `matchedCovers` —— 保 M1 不变量，语义顺序与 React 等价。
4. 生成卡 Painter 直绘而非 SVG 字符串 —— 不引 flutter_svg；派生量与黄金数值逐位一致，视觉结果等价。
5. 维基写真 source 文案去掉「，直连」后缀 —— 只有一条通道，无需区分。
6. `DEFAULT_COVER` 不移植 —— Flutter 占位碟即空路径语义。

**类型一致性：** `CoverMatch`（T2）与 `ArtistImageMatch`（T4）字段不同、名字不同；`ImageBytesClient` 在 T3 定义、T4/T5 消费、T8 注入；`TrackLike`（T5/T6）三字段与 `Track`/`RecentEntry` 的映射在 T8 的装配处唯一一次；`LightboxView`（scale+offset 不可变值类型）在 T11 内聚。

**占位符扫描：** 无 TBD / TODO。所有常量逐字给出；所有公式逐字给出；黄金数值已用 node 现算钉死。
