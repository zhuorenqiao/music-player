# M2a 歌词与双语 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 Flutter 端补齐 React 版的在线歌词匹配、LRC 解析与同步高亮、手动 `.lrc` 配对、网易云中文双语（含跨库对齐与三条生命周期规则）、在线歌词转简体，以及完整歌词页与两处「双语」开关。

**Architecture:** 纯逻辑层（`lib/lyrics/`）与状态层（`lib/state/`）严格分开：解析、归一、对齐、认歌打分都是无 IO 的纯函数，网络与缓存各自一个可注入的接缝，状态机只编排它们。React 版的 Vite 中间件代理（`src/server/music-api.ts`）**不移植**——Dart 直连上游，所以代理那一侧的「多路并行 + 按 job 顺序裁决 + 四类错误分类 + 过期缓存回退」必须由 Dart 自己承担；客户端那一侧的「冷却闸 + 退避 + 自动重试文案」按 spec §11 保留。界面层只订阅状态，进度仍走 `ValueNotifier`（M1 的硬约束不倒退）。

**Tech Stack:** Flutter 3.47.9 / Dart 3.13.7；`http ^1.6.0`（M1 已声明、尚未使用，本段启用）；`shared_preferences`（缓存索引层）；`dart:io`（缓存磁盘层）；`crypto`（sha1 缓存键）；`provider`（状态注入）。**不新增任何依赖**——`pubspec.yaml` / `pubspec.lock` 冻结。

**Spec:** `docs/superpowers/specs/2026-11-06-flutter-port-design.md` §11（歌词与双语）、§13（界面与交互）、§14（输入与无障碍）、§16（测试与验收）、§17（M2a 范围）、§19（明确不做的事）。

**基准:** React **工作区现状**（用户未提交的改动），不是 HEAD。下文引用的行号一律指工作区文件。React 侧任何文件在本段全程**只读**。

---

## Global Constraints

每个任务的要求都隐含包含本节全部条目。

### 环境与命令

- Flutter CLI 不在 Git Bash PATH 上：一律 `/d/flutter/bin/flutter`，且**在 `flutter-app/` 目录内**执行。
- **每条 Flutter 命令都必须带镜像环境变量**，否则会静默触发 `pub get` 并改写 `pubspec.lock` 里 93 行 `url:` 与 3 个 Windows 生成文件：
  ```bash
  PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter <cmd>
  ```
- 只跑单个测试文件：`... /d/flutter/bin/flutter test test/lyrics/lrc_parser_test.dart`
- 静态检查：`... /d/flutter/bin/flutter analyze`（必须 0 issue）
- 构建闸口：`... /d/flutter/bin/flutter build windows --debug` 与 `... /d/flutter/bin/flutter build apk --debug`
- **禁止** `git add -A` / `git add .`；只 add 本任务列出的具体路径。
- **禁止** amend / rebase / push / 仓库级 `dart format`。
- **禁止**改动 `pubspec.yaml`、`pubspec.lock`、`android/`、`windows/` 下的生成文件。
- **禁止**改动仓库根目录的 React 源码（`src/`、`README.md`、`vite.config.ts`、`tests/` 等）。它们是用户未提交的工作，只读。
- **禁止**为了让测试变绿而削弱或删除既有断言。若既有断言与 React 实际行为冲突，按 T3 的做法：先证明 React 的真实行为，再改断言并在提交信息里写明「parity 校正」。

### 范围（spec §17）

- 本段**只做 M2a**：歌词与双语。封面仍只用 M1 已有的内嵌封面；**不接** iTunes / 维基 / 生成卡 / 灯箱 / 最近播放打磨 / 后台预取（那些是 M2b）。
- 不做四套主题、不做频谱、不做黑胶旋转（M3）。歌词高亮色本段用 `tokens.accentLight`（`--lyric-hl` 的默认值），「T」按钮改色是 M3。
- 不新增原版没有的控件、状态或页面（spec §19）。

### 网络与失败语义

- **直连，无代理**。不引入 Node 进程，不在界面上提示「需要本地代理」。React 的 `unavailable` 档在 Flutter 侧**不可达**：枚举与话术保留以便对照，但直连实现永不产出它。
- 歌词请求只发曲名 / 歌手 / 时长，**绝不上传音频**（spec §11 隐私）。
- 四类失败 reason 字符串固定为 `rate-limit` / `timeout` / `unreachable` / `upstream`，各配各的中文话术。**超时就说超时，不写「服务在维护」。**
- 歌词链路的韧性参数取 **spec §11 明定的客户端策略**（不是 React 代理那套）：
  - 可重试 HTTP 状态 `{429, 500, 502, 503, 504}`；`404` 不重试、不算错误、并且**清掉冷却**。
  - 退避：有 `Retry-After` 就用它（秒，上限 `6000ms`），否则第一次重试前 `700ms`。
  - 只有 `429` / `503` 记冷却；冷却窗口夹在 `[10000ms, 60000ms]`，无建议值时 `60000ms`。
  - 每个 job 的尝试次数：`get` 路 2 次，`search` 路 1 次。
- 歌词链路的**拓扑与预算**取 React 代理那一侧（因为 Flutter 没有代理，多路并行与对调重试只存在于那一侧）：
  - `get` 路单程 `12000ms`，`search` 路单程 `26000ms`。
  - 整次匹配的总预算 `60000ms`（spec：客户端预算必须大于上游预算）。到点取消，按 `timeout` 分类。
- 译文链路（网易云）**逐字照抄 React 代理**：单程 `8000ms`、尝试 2 次、固定 `400ms` 退避、**只重试 `timeout` / `unreachable`**（`rate-limit` 与 `upstream` 直接抛）、不读 `Retry-After`。spec §11 没有为译文另定策略，所以以工作区实现为准。
- 上游请求头（两条链路共用）：`Accept: application/json`、`User-Agent: light-music-react/1.0 (+vite dev middleware)`。**不带 Referer、不带 Cookie、不带浏览器 UA**（spec §18 已实测这套朴素头可直连）。
- `worstFailure` 的优先级固定：`rate-limit`(0) < `timeout`(1) < `unreachable`(2) < `upstream`(3)，同级取数组里第一个。

### 缓存

- 歌词：prefs 索引键 `light-music.lyrics-cache.v1`，最多 **120** 条，命中 TTL **30 天**、未命中 TTL **3 天**，淘汰只删超出的部分。磁盘层键 `sha1("<trackName>|<artistName>|<duration>")`（**不 lowercase**，duration 用原始字符串），TTL 按文件 mtime，**命中与对调 key 双写**，无淘汰。
- 译文：prefs 索引键 `light-music.translate-cache.v2`，最多 **120** 条，TTL 同上，只写 `ok` / `not-found`。磁盘层键 `sha1("v2|<title>|<artist>|<duration>".toLowerCase())`。
- 上游失败时允许回退**过期**磁盘缓存：歌词 source 硬编码为 `LRCLIB（离线缓存）`，译文 source 追加 `（离线缓存）`。错误结果**不写**缓存。
- `useCache: false`（手动重试 / 重开双语）**只跳过读**，仍然写。

### 界面数值（spec §13，逐字）

- 「双语」开关两处**同一份规格**：高 `26px`、字号 `11.5px`、图标 `12×12`、左右内边距 `9px`、图文间距 `3px`、胶囊圆角 `999px`；开 = 强调色描边 + 浅底，关 = 灰。位置：播放卡 `stage__title-row`（歌名右侧、同排居中）与歌词页 `lyrics-page__title-row`。**只在非中文歌词时出现。**
- 当前行：**只换色 + 字重 650**，无底色、无辉光；译文行字重保持 400。
- 歌词两处**完全不显示滚动条，占位也去掉**。
- 手动滚动后暂停跟随 `2600ms`；只有滚轮 / 触摸算手动，程序化居中不算。
- 同步高亮容差 `0.12s`，判定式必须是 `cues[mid].time - 0.12 <= time`（**不许**改写成 `time <= cues[mid].time + 0.12`，浮点不等价）。
- 滑切歌：最小横向位移 `56px`、时长 `≤700ms`、`|dx| >= |dy| * 1.25`、单指；`dx < 0` → 下一首，`dx > 0` → **`playPrevTrack`**（不是 `playPrev`）。测试必须用 `tester.flingFrom(...)` 带初速度，`dragFrom` 会让末速度归 0。
- 文案一律**简体中文**，全角括号 `（）` 不要换成半角。下文给出的字符串一律逐字照抄，包括空格与标点。

### 颜色

- `lib/ui/` 下**不许出现颜色字面量**，一律 `context.tokens`。
- `AppTokens` 里的半透明色必须写成字面量 `0xAARRGGBB`，**不许** `.withValues` / `.withOpacity`。
- 本段只新增一个 token：`tint1 = Color(0x0AFFFFFF)`（`--tint-1` = `rgba(255,255,255,.04)`）。其余复用 M1 已有的 `progressTrack`(tint-3) / `border`(tint-2) / `accentSoft` / `accentLine` / `accentLight` / `textDim` / `textFaint` / `dangerInk`。

---

## File Structure

新建（`flutter-app/` 下）：

| 文件 | 职责 |
| --- | --- |
| `lib/core/name_split.dart` | 严格版「歌手 - 曲名」拆分（纯字符串，无依赖）。`core/` 是共享基础设施层，`metadata/` 与 `lyrics/` 都从这里取，避免互相依赖。 |
| `lib/lyrics/lrc_parser.dart` | `parseLrc` / `dropHeaderLines` / `plainLyricLines` / `findActiveCue` / `LyricLine`。纯函数。 |
| `lib/lyrics/query.dart` | `cleanTitle` / `LyricsQuery` / `normalizeQuery`。纯函数。 |
| `lib/lyrics/opencc/trie.dart` | OpenCC 的码位 Trie + IDS（表意文字描述序列）工具。纯 Dart 移植。 |
| `lib/lyrics/opencc/dicts.dart` | **生成物**：tw2s 用到的 5 份词典字符串。由 `tool/gen_opencc_dicts.mjs` 生成，不手改。 |
| `lib/lyrics/opencc/converter.dart` | tw2s 组装（normalize → segment → 两级转换）+ `toSimplified`（FIFO 64 缓存 + 妳/甚么 后处理）。 |
| `lib/lyrics/upstream.dart` | 可注入的 JSON GET 接缝、四类错误分类、`worstFailure`、两套重试驱动、冷却闸、`CancelToken`。 |
| `lib/lyrics/lyrics_cache.dart` | 歌词双层缓存（prefs 索引 + 磁盘），含双 key 写与 stale 读。 |
| `lib/lyrics/lyrics_source.dart` | 2~5 路 job 构造、并行、按 job 顺序裁决、stale 回退、状态与中文话术。 |
| `lib/lyrics/translate_lang.dart` | `needsTranslation`（字符集判语种）。纯函数。 |
| `lib/lyrics/translate_align.dart` | `alignTranslation`（中位数偏移、起手保护、覆盖率闸、纯文本配对）。纯函数。 |
| `lib/lyrics/netease_match.dart` | 认歌：`normText` / `coreTitle` / `artistHitSong` / `pickTranslatableSong` / `translatePairs`。纯函数。 |
| `lib/lyrics/translate_cache.dart` | 译文双层缓存（v2 键）。 |
| `lib/lyrics/translate_source.dart` | 网易搜索 → 认歌 → 取 `tlyric`，失败分档与话术。 |
| `lib/lyrics/manual_lyrics.dart` | `.lrc` 读取、大小闸、解析闸、按可信度打分配对。 |
| `lib/state/lyrics_state.dart` | 歌词状态机：cues / plain / displayLines / status / showRetry / 自动重试 / 纯文本升级。 |
| `lib/state/bilingual_state.dart` | 双语状态机：三条生命周期规则、会话缓存、`trans` 对齐结果。 |
| `lib/ui/lyrics_view.dart` | 歌词滚动列表（compact / full）、高亮、居中跟随、手动暂停、文字热区。 |
| `lib/ui/lyrics_status.dart` | 状态行（spinner / 文案 / 重试按钮）。 |
| `lib/ui/bilingual_toggle.dart` | 胶囊开关（两处共用）。 |
| `lib/ui/lyrics_page.dart` | 完整歌词页（左歌词右封面、返回、控制条留在下方）。 |
| `tool/gen_opencc_dicts.mjs` | 词典生成器（读 `../node_modules/opencc-js`）。 |
| `tool/opencc_oracle.mjs` | 黄金样本生成器：用 opencc-js 产出输入→输出对，供 Dart 用例逐条比对。 |
| `test/fixtures/opencc_golden.json` | 生成物：黄金样本。 |
| `third_party/opencc-js-LICENSE.txt` | MIT 许可全文（词典与算法来源）。 |
| `third_party/opencc-LICENSE.txt` | Apache-2.0 许可全文（OpenCC 词典数据上游）。 |

修改：

| 文件 | 改什么 |
| --- | --- |
| `lib/metadata/audio_tags.dart:195-209` | `splitArtistTitle` 改为委托 `core/name_split.dart`，签名与返回类型不变（M1 调用方与用例不动）。 |
| `lib/theme/app_tokens.dart` | 新增 `tint1`。 |
| `lib/playback/play_error.dart` | 新增 `kLyricsExtensions = {'lrc'}` 与 `isLyricsExtension`（**不动** `kAudioExtensions`）。 |
| `lib/core/file_picking.dart` | 选择器的 `allowedExtensions` 加上 `lrc`。 |
| `lib/library/import_service.dart` | `importPaths` 在拒绝之前先分流 `.lrc`，交给 `ManualLyrics`。 |
| `lib/state/library_state.dart` | 新增 `applyLyricsFiles` 的落库收尾（与原版同序：音频入列→落库→回填→**再**挂歌词）。 |
| `lib/ui/stage.dart` | `_LyricsSlot` 换成真歌词条；`_titleRow` 加尾部开关槽；曲目区点击进歌词页；左右滑切歌。 |
| `lib/ui/home_page.dart` | 歌词页覆盖层与「添加音乐」的 `.lrc` 分流。 |
| `lib/core/shortcuts.dart` | 补 `L`（进/出歌词页）与 `Esc`（关歌词页）。 |
| `lib/main.dart` / `lib/app.dart` | 装配歌词与双语状态、缓存目录、provider 注册。 |
| `docs/superpowers/specs/2026-11-06-flutter-port-design.md` | T1 的六处校正。 |

**不改**：`lib/ui/shell.dart`（M1 定的断点骨架）、`lib/playback/*`（除 `play_error.dart` 加常量）、`lib/state/player_state.dart`。

---

## Task 1: 设计文档校正（先于任何 Dart 代码）

spec 是约束源，所以约束源里与工作区实现不符的句子必须先改对，否则后面每个任务都在照错的规格实现。本任务**只改文档**，可独立评审。

**Files:**
- Modify: `docs/superpowers/specs/2026-11-06-flutter-port-design.md`（§11 五处、§15 一行）

**Interfaces:**
- Consumes: 无
- Produces: 后续所有任务的约束源。六处校正后的文本即最终口径。

- [ ] **Step 1: 改 §11 的「三路并行 / 先到先得」**

把 §11 第一段里「LRCLIB 三路（带时长精确 / 不带时长精确 / 宽松搜索）并行发出，先给出可信结果的先用」整句替换为：

```markdown
**匹配**：Flutter 直连 LRCLIB，自己承担 React 版 Vite 代理那一侧的编排（客户端直连的三路其实是串行的，并行只存在于代理）。job 按固定顺序构造：对 `[曲名, 歌手]` 与（歌手非空且不等于曲名时）`[歌手, 曲名]` 两个方向，各发「带时长 get」与「不带时长 get」；再加一条按**原方向**拼 `q=<曲名> <歌手>` 的 search。于是 job 数为 2~5。全部 job 并行发出、**等全部结束**再裁决，不是谁先回来用谁。裁决顺序：带时间轴的 get 命中 > 带时间轴的 search 命中 > 任意 get 命中 > （任一 get 路报错则抛最严重的那个）> search 命中 > （有错则抛）> not-found。同类多个命中取 **job 顺序最靠前**的那个。歌名与歌手对调后重查一遍，命中结果同时写入两个缓存 key，下次两种写法都瞬时命中。`cleanTitle` 去音轨号与 `(Live)`、`(Official)` 一类噪声括号（**不含 `feat`**，见下条），`splitArtistTitle` 与 `normalizeQuery` 逐条移植。
```

- [ ] **Step 2: 改 §11 的 `cleanTitle` 噪声词表**

把「`cleanTitle` 去 `(feat. X)`、`(Live)` 等噪声标记」里的 `(feat. X)` 去掉（该词表里没有 `feat`，`(feat. X)` 不会被剥）。替换后的完整句子已写在 Step 1 的段落里，这里确认 §11 不再出现「去 `(feat. X)`」的说法即可。

- [ ] **Step 3: 改 §11 的单个 `.lrc` 兜底**

把「单个导入对不上名时挂到当前曲目」替换为：

```markdown
对不上名的一律拒绝并提示，**不挂到当前曲目**（工作区 `src/state/library.tsx` 的 `applyLyricsFiles` 没有这条兜底；早期文档里的说法与实现不符）。
```

- [ ] **Step 4: 改 §11 的覆盖率分母**

把「覆盖率带时间轴 <25% 或纯文本 <50% 时整首退回单语」替换为：

```markdown
覆盖率闸：带时间轴时 = `非空译文槽数 / 译文行数`（分母是**译文行数**，不是展示行数），<25% 整首退回单语；纯文本时 = `配上的展示行数 / 展示行数`，<50% 退回单语。带时间轴那一支失败返回**全空**数组；纯文本那一支达标时允许部分槽为空。
```

- [ ] **Step 5: 改 §11 的转简体方案与 §15 的依赖行**

§11 里「**转简体**：在线取回的歌词转简体（`opencc` 包，实现时与 `flutter_open_chinese_convert` 二选一，取在本机能稳定转换的）；用户手动导入的 `.lrc` 保持原样。」替换为：

```markdown
**转简体**：在线取回的歌词转简体，用户手动导入的 `.lrc` 保持原样。实现为**纯 Dart 移植 OpenCC 的 `tw2s` 链路**（码位 Trie + 最长前缀匹配 + IDS 感知的未匹配步长 + 分词后逐段转换），词典以生成的 Dart 源码内嵌，**不新增依赖**。原因（2026-11-07 实测）：`flutter_open_chinese_convert` 不声明 Windows；`opencc` 走 native assets；`flutter_opencc_ffi` 与 `flutter_opencc` 的 SDK 约束都 `<3.0.0`；而本工程 `pubspec` 已冻结（`permission_handler` 钉 `^12.0.0` 以守住 compileSdk 36）。词典与算法取自 `opencc-js`（MIT）及其上游 OpenCC 数据（Apache-2.0），两份许可全文随仓库保留在 `third_party/`，生成器可复跑。行为与 `opencc-js` 逐字节一致，用 Node 侧黄金样本对表。
```

§15 依赖表里 `opencc` 那一行整行删除，并在表下补一句：

```markdown
繁简转换不引包：见 §11「转简体」，纯 Dart 移植 + 内嵌词典，`pubspec` 不变。
```

- [ ] **Step 6: 在 §11 末尾补一段「直连合并裁定」**

追加：

```markdown
**直连合并裁定（2026-11-07）**：React 版把「拓扑」放在代理、把「韧性」放在客户端，两侧策略并不相同（代理只重试 timeout/unreachable、固定 400ms、不读 Retry-After；客户端重试 429/500/502/503/504、700ms 或 Retry-After、记 60s 冷却）。Flutter 没有代理，必须二合一：**拓扑与单程预算取代理**（get 12s / search 26s / 2~5 路并行 / job 顺序裁决 / 对调重试 / 双 key 写 / stale 回退），**韧性取本文档明定的客户端策略**（可重试状态集合、Retry-After 上限 6s、冷却 [10s,60s]、404 清冷却），外加 60s 总预算。译文链路不在此裁定内，逐字照抄代理（8s / 2 次 / 400ms / 只重试 timeout 与 unreachable）。
```

- [ ] **Step 7: 自检并提交**

逐条确认：六处都改到了、没有引入 TBD、§15 表里不再有 `opencc`、§11 不再声称去 `feat`。

```bash
git add docs/superpowers/specs/2026-11-06-flutter-port-design.md
git commit -m "docs(spec): 按工作区现状校正 M2a 的匹配拓扑、噪声词表、歌词兜底与转简体方案"
```

---

## Task 2: LRC 解析器

**Files:**
- Create: `flutter-app/lib/lyrics/lrc_parser.dart`
- Test: `flutter-app/test/lyrics/lrc_parser_test.dart`

**Interfaces:**
- Consumes: 无（纯 Dart）
- Produces:
  ```dart
  class LyricLine {
    const LyricLine({required this.time, required this.text});
    final double time; // 纯文本行为 double.nan
    final String text;
  }
  class ParsedLrc {
    const ParsedLrc({required this.lines, required this.meta});
    final List<LyricLine> lines;
    final Map<String, String> meta;
  }
  ParsedLrc parseLrc(String text, {String title = '', String artist = ''});
  List<String> plainLyricLines(String plain);
  int findActiveCue(List<LyricLine> cues, double time);
  ```
  `dropHeaderLines` 是私有实现，但测试通过 `parseLrc` 的输出来断言它。

**基准源码（`src/lib/lyrics.js:11-154`，逐字；移植时以此为准，不要凭记忆）：**

```js
const TIME_TAG_SOURCE = '\\[(\\d{1,3}):(\\d{1,2})(?:[.:](\\d{1,3}))?\\]';
const META_TAG = /^\[(ti|ar|al|by|offset|length)\s*:\s*(.*?)\]$/i;
const WORD_TAG = /<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>/g;
const CREDIT_LINE = /^(?:作词|作曲|编曲|词|曲|制作人|出品|监制|混音|母带|录音|和声|吉他|贝斯|鼓|键盘|弦乐|统筹|发行|策划|OP|SP)\s*[:：]/i;
const CREDIT_SCAN_LIMIT = 4;
```

移植时必须守住的四条（每条都有用例钉）：

1. **行分隔符是 `/\r?\n/`，不是 Dart 的 `LineSplitter`。** `LineSplitter` 把 lone `\r` 也当分隔符，JS 不当。用 `text.split(RegExp(r'\r?\n'))`。
2. **`[offset:]` 的空值等于 0。** JS `Number('') === 0`；Dart `double.tryParse('')` 返回 null。必须显式：`value.isEmpty ? 0 : double.tryParse(value)`，解析失败（null / 非有限）**保持上一个 offset 不变**，不是重置为 0。
3. **排序必须稳定。** JS `Array.sort` 自 ES2019 起稳定，Dart `List.sort` 不稳定。同一时刻的多行（一行多时间标签、或重复时间戳）顺序会直接影响高亮与译文对齐。做法：先给每条记原始下标，比较器 `time` 相等时比下标。
4. **`seconds < 60` 不成立时，该时间标签不进 `times`，但仍然从正文里剥掉。** 一行里所有标签都非法 → 整行跳过。

- [ ] **Step 1: 写失败用例**

创建 `flutter-app/test/lyrics/lrc_parser_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/lyrics/lrc_parser.dart';

void main() {
  group('parseLrc 时间轴', () {
    test('一行多个时间标签展开成多行，正文相同', () {
      final parsed = parseLrc('[00:01.00][00:05.00]同一句');
      expect(parsed.lines.map((l) => l.time), [1.0, 5.0]);
      expect(parsed.lines.map((l) => l.text), ['同一句', '同一句']);
    });

    test('小数位按毫秒补齐：.3 → 0.300，.34 → 0.340，.345 → 0.345', () {
      final parsed = parseLrc('[00:01.3]a\n[00:02.34]b\n[00:03.345]c');
      expect(parsed.lines[0].time, closeTo(1.3, 1e-9));
      expect(parsed.lines[1].time, closeTo(2.34, 1e-9));
      expect(parsed.lines[2].time, closeTo(3.345, 1e-9));
    });

    test('冒号也当小数分隔符：[00:01:250]', () {
      expect(parseLrc('[00:01:250]x').lines.single.time, closeTo(1.25, 1e-9));
    });

    test('秒 ≥60 的标签不进时间轴，但仍从正文剥掉', () {
      final parsed = parseLrc('[00:60][00:02]正文');
      expect(parsed.lines.map((l) => l.time), [2.0]);
      expect(parsed.lines.single.text, '正文');
    });

    test('一行里所有标签都非法 → 整行跳过', () {
      expect(parseLrc('[00:99]只有非法标签').lines, isEmpty);
    });

    test('逐字增强型行内标签被剥掉', () {
      final parsed = parseLrc('[00:01.00]<00:01.00>你<00:01.50>好');
      expect(parsed.lines.single.text, '你好');
    });

    test('offset 正值让歌词提前，且钳到 0', () {
      final parsed = parseLrc('[offset:500]\n[00:01.00]a\n[00:00.20]b');
      expect(parsed.lines.map((l) => l.time), [0.0, 0.5]);
    });

    test('offset 空串等于 0（JS Number(\'\') === 0）', () {
      final parsed = parseLrc('[offset:]\n[00:01.00]a');
      expect(parsed.lines.single.time, 1.0);
    });

    test('offset 脏值保持上一个有效值，不重置', () {
      final parsed = parseLrc('[offset:500]\n[offset:abc]\n[00:01.00]a');
      expect(parsed.lines.single.time, closeTo(0.5, 1e-9));
    });

    test('乱序自动排序，且同一时刻保持输入顺序（稳定排序）', () {
      final parsed = parseLrc('[00:03]c\n[00:01]a\n[00:01]b');
      expect(parsed.lines.map((l) => l.text), ['a', 'b', 'c']);
    });

    test('lone \\r 不是行分隔符（与 JS /\\r?\\n/ 一致）', () {
      final parsed = parseLrc('[00:01]a\r[00:02]b');
      // 整串是一行：两个标签都收，正文剥完是 'a\rb'
      expect(parsed.lines.length, 2);
      expect(parsed.lines.every((l) => l.text == 'a\rb'), isTrue);
    });

    test('元信息进 meta，key 小写、值 trim', () {
      final parsed = parseLrc('[TI: 歌名 ]\n[ar:歌手]\n[00:01]正文');
      expect(parsed.meta['ti'], '歌名');
      expect(parsed.meta['ar'], '歌手');
    });

    test('空输入与非歌词文本返回空', () {
      expect(parseLrc('').lines, isEmpty);
      expect(parseLrc('   \n  ').lines, isEmpty);
      expect(parseLrc('没有时间标签的一行').lines, isEmpty);
    });
  });

  group('dropHeaderLines 署名与标题行', () {
    String body(int n) =>
        [for (var i = 0; i < n; i++) '[00:0$i]第$i句'].join('\n');

    test('剔除开头的「词：」「曲：」署名行', () {
      final parsed = parseLrc('词：方文山\n曲：周杰伦\n${body(4)}'.replaceAll(
            RegExp(r'^(词|曲)：(.*)$', multiLine: true),
            (m) => '[00:00]${m[1]}：${m[2]}',
          ));
      expect(parsed.lines.map((l) => l.text), ['第0句', '第1句', '第2句', '第3句']);
    });

    test('第 5 行起的署名行不再剔除（窗口按已保留行数算）', () {
      final parsed = parseLrc('${body(4)}\n[00:09]词：某人');
      expect(parsed.lines.last.text, '词：某人');
    });

    test('标题行要同时含歌名与歌手、且长度 ≤60 才剔除', () {
      final parsed = parseLrc(
        '[00:00]十年 - 陈奕迅\n${body(4)}',
        title: '十年',
        artist: '陈奕迅',
      );
      expect(parsed.lines.first.text, '第0句');
    });

    test('清理后不足 3 行就整体回滚', () {
      final parsed = parseLrc(
        '[00:00]词：甲\n[00:01]曲：乙\n[00:02]丙\n[00:03]丁',
      );
      // 剔两行只剩 2 行 < 3 → 回滚成原样 4 行
      expect(parsed.lines.length, 4);
      expect(parsed.lines.first.text, '词：甲');
    });

    test('总行数 ≤3 时完全不清洗', () {
      final parsed = parseLrc('[00:00]词：甲\n[00:01]乙');
      expect(parsed.lines.length, 2);
      expect(parsed.lines.first.text, '词：甲');
    });

    test('context 缺失时回退 meta.ti / meta.ar', () {
      final parsed = parseLrc(
        '[ti:十年]\n[ar:陈奕迅]\n[00:00]十年 - 陈奕迅\n${body(4)}',
      );
      expect(parsed.lines.first.text, '第0句');
    });
  });

  group('plainLyricLines', () {
    test('CRLF 归一、去首尾空行、逐行 trim、保留中间空行', () {
      expect(
        plainLyricLines('\r\n  \r\n 甲 \r\n\r\n 乙 \r\n \r\n'),
        ['甲', '', '乙'],
      );
    });

    test('全空白返回空列表', () {
      expect(plainLyricLines('  \n \n'), isEmpty);
      expect(plainLyricLines(''), isEmpty);
    });
  });

  group('findActiveCue', () {
    List<LyricLine> cues(List<double> times) =>
        [for (final t in times) LyricLine(time: t, text: '$t')];

    test('空列表返回 -1', () {
      expect(findActiveCue([], 10), -1);
    });

    test('早于首行容差返回 -1', () {
      expect(findActiveCue(cues([1, 2]), 0.87), -1);
      expect(findActiveCue(cues([1, 2]), 0.88), 0);
    });

    test('重复时间戳取最后一个（ceil 中点二分）', () {
      expect(findActiveCue(cues([0, 10, 20, 20, 30]), 19.88), 3);
    });

    test('容差判定式必须是 time - 0.12 <= now，不能等价改写', () {
      // 0.121 - 0.12 = 0.0010000000000000009 > 0.001 → 还没到
      expect(findActiveCue(cues([0.121]), 0.001), -1);
      // 若写成 now <= time + 0.12，0.001 <= 0.241 恒真，会错判成 0
    });

    test('远超末行仍返回末行', () {
      expect(findActiveCue(cues([0, 10]), 999), 1);
    });
  });
}
```

- [ ] **Step 2: 跑用例确认失败**

```bash
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter test test/lyrics/lrc_parser_test.dart
```
Expected: FAIL —— `Target of URI doesn't exist: 'package:light_music/lyrics/lrc_parser.dart'`。

包名已核实为 `light_music`（`flutter-app/pubspec.yaml` 的 `name:`），下文导入一律用它。

- [ ] **Step 3: 实现 `lib/lyrics/lrc_parser.dart`**

要点（不要自由发挥）：

```dart
const String _timeTagSource = r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]';
final RegExp _metaTag = RegExp(r'^\[(ti|ar|al|by|offset|length)\s*:\s*(.*?)\]$', caseSensitive: false);
final RegExp _wordTag = RegExp(r'<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>');
final RegExp _creditLine = RegExp(r'^(?:作词|作曲|编曲|词|曲|制作人|出品|监制|混音|母带|录音|和声|吉他|贝斯|鼓|键盘|弦乐|统筹|发行|策划|OP|SP)\s*[:：]', caseSensitive: false);
const int _creditScanLimit = 4;
const double _activeTolerance = 0.12;
```

- `parseLrc`：`text.trim().isEmpty` → 空结果。按 `RegExp(r'\r?\n')` 切行、逐行 `trim()`、空行跳过。先试 `_metaTag.firstMatch(line)`：命中就写 `meta[key.toLowerCase()] = value.trim()`，`key == 'offset'` 时按「空串→0，`double.tryParse` 失败或非有限→保持旧值」更新 `offset`，然后 `continue`。
- 时间标签用 `RegExp(_timeTagSource).allMatches(line)` 收集；`seconds < 60` 才入 `times`。`times` 为空 → 跳过该行。正文 = `line.replaceAll(RegExp(_timeTagSource), '').replaceAll(_wordTag, '').trim()`。
- `parseFraction`：1 位补 `00`、2 位补 `0`、3 位取前 3；`int.parse(digits) / 1000`。
- 偏移与排序：`time = max(0, raw - offset / 1000)`；排序比较器先比 `time`，相等比原始下标（**稳定**）。
- `dropHeaderLines`：`lines.length <= 3` 直接返回。`norm(v) = v.toLowerCase().replaceAll(RegExp(r'\s+'), '')`。窗口条件是 `kept.length < 4`（**已保留**行数，不是已扫描行数）。标题行条件：`title.isNotEmpty && artist.isNotEmpty && text.length <= 60 && norm(text).contains(title) && norm(text).contains(artist)`。注意 `text.length` 在 Dart 是 UTF-16 码元数，与 JS 一致，**不要**换成 `runes.length`。最后 `kept.length >= 3 ? kept : lines`。
- context 回退：`title.isNotEmpty ? title : (meta['ti'] ?? '')`，artist 同理用 `meta['ar']`。
- `plainLyricLines`：`plain.replaceAll('\r\n', '\n').split('\n')`，while 去首部 `trim().isEmpty`、while 去尾部，再 `map((l) => l.trim())`。输入为空串直接返回 `const []`。
- `findActiveCue`：逐字照抄二分——`low = 0, high = cues.length - 1`；`while (low < high) { mid = ((low + high) / 2).ceil(); if (cues[mid].time - 0.12 <= time) low = mid; else high = mid - 1; }`；返回 `cues[low].time - 0.12 <= time ? low : -1`。

- [ ] **Step 4: 跑用例确认通过**

```bash
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter test test/lyrics/lrc_parser_test.dart
```
Expected: PASS（全部）。若「剔除署名行」那条用例的构造写法太绕，直接在 Dart 里写死输入字符串 `'[00:00]词：方文山\n[00:00]曲：周杰伦\n...'`，断言不变。

- [ ] **Step 5: 静态检查**

```bash
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter analyze
```
Expected: `No issues found!`

- [ ] **Step 6: 提交**

```bash
git add flutter-app/lib/lyrics/lrc_parser.dart flutter-app/test/lyrics/lrc_parser_test.dart
git commit -m "feat(lyrics): 移植 LRC 解析、署名行剔除与当前行二分判定"
```

---
## Task 3: 名称拆分与查询归一（含一处 M1 parity 校正）

**Files:**
- Create: `flutter-app/lib/core/name_split.dart`
- Create: `flutter-app/lib/lyrics/query.dart`
- Modify: `flutter-app/lib/metadata/audio_tags.dart:195-209`
- Test: `flutter-app/test/core/name_split_test.dart`
- Test: `flutter-app/test/lyrics/query_test.dart`

**Interfaces:**
- Consumes: 无
- Produces:
  ```dart
  // lib/core/name_split.dart
  ({String artist, String title})? splitArtistTitleOrNull(String raw);

  // lib/lyrics/query.dart
  String cleanTitle(String title);
  class LyricsQuery {
    const LyricsQuery({required this.trackName, required this.artistName,
        required this.duration, required this.key});
    final String trackName;
    final String artistName;
    final int duration; // 秒，四舍五入；未知为 0
    final String key;   // "<trackName>|<artistName>|<duration>".toLowerCase()
  }
  LyricsQuery normalizeQuery({required String title, required String artist, required double duration});
  ```
  `normalizeQuery` **不依赖 `Track`**：只收三个字段，纯函数、可单测。调用方传 `track.title / track.artist / track.duration`。

**为什么单独一个 `core/name_split.dart`：** React 里 `splitArtistTitle`（`src/lib/lyrics-source.js:117`）是共享基础设施，被 `state/library.tsx:134`（文件名拆分）、`state/lyrics-file.ts:48`（手动歌词配对）与 `normalizeQuery` 三处复用。Flutter 侧 `metadata/` 与 `lyrics/` 都要它，放 `core/` 才不会互相依赖。

**M1 parity 校正（必须做，且已验证不破坏任何既有断言）：** M1 的 `metadata/audio_tags.dart:200` 那份 `splitArtistTitle` 只按第一个 `' - '` 拆，**不是** React 那份。React 那份支持 `–`/`—`、带空格版优先、紧凑版要求两侧都含 CJK。已核对既有三处断言（`audio_tags_test.dart:163-165` 的 `'陈奕迅 - 十年'` / `'十年'` / `'a - b - c'`，以及 `import_service_test.dart` 里全部 `' - '` 形态）在新实现下结果不变，所以本任务**不需要改任何既有断言**。

**基准源码（`src/lib/lyrics-source.js:95-169`，逐字）：**

```js
function cleanTitle(title) {
  let value = String(title ?? '').trim();
  value = value.replace(/^\s*[[(]?\d{1,3}[)\]]?\s*[.\-、_]\s*/, '');
  value = value.replace(/[（(【[][^）)】\]]*(?:official|mv|hd|hq|live|remix|伴奏|纯音乐|高音质|无损|完整版|超清|动态歌词|原唱|翻唱)[^）)】\]]*[）)】\]]/gi, '');
  return value.replace(/\s{2,}/g, ' ').replace(/[-_\s]+$/, '').trim();
}

const CJK_PATTERN = /[\u3400-\u9fff\uf900-\ufaff]/;

export function splitArtistTitle(raw) {
  const value = String(raw ?? '').trim();
  if (!value) { return null; }
  const spaced = value.match(/^(.{1,60}?)\s+[-–—]\s+(.{1,80})$/);
  if (spaced) {
    const artist = spaced[1].trim();
    const title = spaced[2].trim();
    return artist && title ? { artist, title } : null;
  }
  const tight = value.match(/^(.{1,60}?)[-–—](.{1,80})$/);
  if (tight) {
    const artist = tight[1].trim();
    const title = tight[2].trim();
    if (artist && title && CJK_PATTERN.test(artist) && CJK_PATTERN.test(title)) {
      return { artist, title };
    }
  }
  return null;
}

export function normalizeQuery(track) {
  const title = cleanTitle(track?.title ?? '');
  let artist = String(track?.artist ?? '').trim();
  const isPlaceholder = artist === '' || artist === '本地文件' || artist === '未知歌手';
  let trackName = title;
  if (isPlaceholder) {
    const split = splitArtistTitle(title);
    if (split) { artist = split.artist; trackName = cleanTitle(split.title); }
    else { artist = ''; }
  }
  const duration = Number.isFinite(track?.duration) && track.duration > 0
    ? Math.round(track.duration) : 0;
  const key = `${trackName}|${artist}|${duration}`.toLowerCase();
  return { trackName, artistName: artist, duration, key };
}
```

移植时的五个陷阱：

1. `cleanTitle` 的噪声词表**没有 `feat`**，`(feat. X)` 不会被剥。括号开闭字符集允许错配（`[（(【[]` … `[）)】\]]`），关键词是**子串**匹配，所以 `(Live at Shanghai)` 整个被删。替换是**单次**，不是循环。
2. 音轨号正则要求数字后**必须有** `[.\-、_]` 分隔符，裸 `[01] 歌名` 不会被剥。
3. `splitArtistTitle` 带空格版一旦匹配但任一侧为空 → **直接返回 null，不再试紧凑版**。
4. 紧凑版要求**两侧都含 CJK**（防 `track-02`、`Jay-Z` 被误拆）。`CJK_PATTERN` 只覆盖汉字（`㐀-鿿` + `豈-﫿`），**不含假名、不含谚文**。分隔符集合是 `[-–—]`（U+002D / U+2013 / U+2014），**不含**全角 `－`、不含 U+2212。
5. `normalizeQuery` 的占位歌手集合**只有** `{'', '本地文件', '未知歌手'}`，**大小写敏感、精确相等**（与译文侧那份 5 项含 lowercase 的集合不同，别共用）。反推时 `artist = split.artist` **不再 cleanTitle**，而 `trackName = cleanTitle(split.title)` 是**二次清洗**。

- [ ] **Step 1: 写失败用例（拆分）**

创建 `flutter-app/test/core/name_split_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/name_split.dart';

void main() {
  test('带空格版优先，三种破折号都认', () {
    expect(splitArtistTitleOrNull('陈奕迅 - 十年'), (artist: '陈奕迅', title: '十年'));
    expect(splitArtistTitleOrNull('陈奕迅 – 十年'), (artist: '陈奕迅', title: '十年'));
    expect(splitArtistTitleOrNull('陈奕迅 — 十年'), (artist: '陈奕迅', title: '十年'));
  });

  test('紧凑版要求两侧都含汉字', () {
    expect(splitArtistTitleOrNull('周杰倫-十年'), (artist: '周杰倫', title: '十年'));
    expect(splitArtistTitleOrNull('track-02'), isNull);
    expect(splitArtistTitleOrNull('Jay-Z'), isNull);
    expect(splitArtistTitleOrNull('初音ミク-歌名'), (artist: '初音ミク', title: '歌名')); // 含一个汉字即算 CJK，会拆（parity 校正）
  });

  test('全角减号与 U+2212 不是分隔符', () {
    expect(splitArtistTitleOrNull('陈奕迅－十年'), isNull);
    expect(splitArtistTitleOrNull('陈奕迅−十年'), isNull);
  });

  test('带空格版匹配但一侧为空 → null，不回退紧凑版', () {
    expect(splitArtistTitleOrNull(' - 十年'), isNull);
    expect(splitArtistTitleOrNull('陈奕迅 - '), isNull);
  });

  test('空串与纯空白 → null', () {
    expect(splitArtistTitleOrNull(''), isNull);
    expect(splitArtistTitleOrNull('   '), isNull);
  });

  test('没有分隔符 → null', () {
    expect(splitArtistTitleOrNull('十年'), isNull);
  });

  test('第一个分隔符处拆，右侧可再含分隔符', () {
    expect(splitArtistTitleOrNull('a - b - c'), (artist: 'a', title: 'b - c'));
  });

  test('长度上限：歌手 >60 或曲名 >80 不拆', () {
    expect(splitArtistTitleOrNull('${'甲' * 61} - 乙'), isNull);
    expect(splitArtistTitleOrNull('甲 - ${'乙' * 81}'), isNull);
  });
}
```

- [ ] **Step 2: 跑用例确认失败**

```bash
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter test test/core/name_split_test.dart
```
Expected: FAIL —— URI 不存在。

- [ ] **Step 3: 实现 `lib/core/name_split.dart`**

```dart
final RegExp _spaced = RegExp(r'^(.{1,60}?)\s+[-–—]\s+(.{1,80})$');
final RegExp _tight = RegExp(r'^(.{1,60}?)[-–—](.{1,80})$');
final RegExp _cjk = RegExp(r'[\u3400-\u9fff\uf900-\ufaff]');
```
逻辑逐字照上面的 JS。Dart 的 `RegExp` 默认 `.` 不匹配换行，与 JS 一致，**不要**开 `dotAll`。

- [ ] **Step 4: 让 `metadata/audio_tags.dart` 委托它（签名不变）**

把 `lib/metadata/audio_tags.dart:195-209` 的实现替换为：

```dart
/// 从文件名拆「歌手 - 曲名」。规则的唯一真源是 `core/name_split.dart`
/// （对译 `src/lib/lyrics-source.js:117`，被文件名拆分、手动歌词配对与
/// 查询归一三处共用）。这里保留 M1 的记录返回形态：拆不出时给
/// （空歌手, 原文），调用方不必处理 null。
({String artist, String title}) splitArtistTitle(String raw) {
  final split = splitArtistTitleOrNull(raw);
  if (split != null) return split;
  return (artist: '', title: raw.trim());
}
```
并在文件顶部加 `import '../core/name_split.dart';`。

- [ ] **Step 5: 跑既有 metadata 与 library 用例，确认零回归**

```bash
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter test test/core/name_split_test.dart test/metadata test/library
```
Expected: PASS。**若有任何既有断言变红，停下来核对 React 的真实行为再决定**——不许直接改断言凑绿。

- [ ] **Step 6: 写失败用例（查询归一）**

创建 `flutter-app/test/lyrics/query_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/lyrics/query.dart';

void main() {
  group('cleanTitle', () {
    test('剥音轨号：01. / 01 - / [01]. / (01)_', () {
      expect(cleanTitle('01. 十年'), '十年');
      expect(cleanTitle('01 - 十年'), '十年');
      expect(cleanTitle('[01]. 十年'), '十年');
      expect(cleanTitle('(01)_十年'), '十年');
    });

    test('裸 [01] 后面没有分隔符时不剥', () {
      expect(cleanTitle('[01] 十年'), '[01] 十年');
    });

    test('剥噪声括号，大小写不敏感、子串匹配、允许错配', () {
      expect(cleanTitle('十年 (Live at Shanghai)'), '十年');
      expect(cleanTitle('十年【OFFICIAL MV】'), '十年');
      expect(cleanTitle('十年（伴奏】'), '十年');
    });

    test('feat 不在噪声词表里，保留', () {
      expect(cleanTitle('十年 (feat. 甲)'), '十年 (feat. 甲)');
    });

    test('折叠多空白、剥尾部 -_ 与空白', () {
      expect(cleanTitle('  十年   -  '), '十年');
      expect(cleanTitle('十年__'), '十年');
    });

    test('括号替换是单次，不循环', () {
      // 第一遍剥掉 (Live)，剩下的 (Official) 不再剥
      expect(cleanTitle('十年 (Live) (Official)'), '十年'); // /gi 的 g 一次剥掉全部（parity 校正）
    });
  });

  group('normalizeQuery', () {
    test('正常歌手原样保留（只 trim）', () {
      final q = normalizeQuery(title: ' 十年 ', artist: ' 陈奕迅 ', duration: 245.5);
      expect(q.trackName, '十年');
      expect(q.artistName, '陈奕迅');
      expect(q.duration, 246);
      expect(q.key, '十年|陈奕迅|246');
    });

    test('key 整串小写', () {
      final q = normalizeQuery(title: 'Hello', artist: 'Adele', duration: 0);
      expect(q.key, 'hello|adele|0');
    });

    test('占位歌手触发文件名反推，反推出来的歌手不再 cleanTitle', () {
      final q = normalizeQuery(title: '陈奕迅 - 十年', artist: '本地文件', duration: 0);
      expect(q.trackName, '十年');
      expect(q.artistName, '陈奕迅');
    });

    test('空歌手与「未知歌手」同样是占位', () {
      expect(normalizeQuery(title: '甲 - 乙', artist: '', duration: 0).artistName, '甲');
      expect(normalizeQuery(title: '甲 - 乙', artist: '未知歌手', duration: 0).artistName, '甲');
    });

    test('占位集合大小写敏感：Unknown 不是占位', () {
      final q = normalizeQuery(title: '甲 - 乙', artist: 'Unknown', duration: 0);
      expect(q.artistName, 'Unknown');
      expect(q.trackName, '甲 - 乙');
    });

    test('反推失败时歌手置空', () {
      final q = normalizeQuery(title: '十年', artist: '本地文件', duration: 0);
      expect(q.trackName, '十年');
      expect(q.artistName, '');
    });

    test('反推出来的曲名要二次清洗', () {
      final q = normalizeQuery(title: '陈奕迅 - 01. 十年', artist: '', duration: 0);
      expect(q.trackName, '十年');
      expect(q.artistName, '陈奕迅');
    });

    test('时长 NaN / 0 / 负数 / 无穷一律 0', () {
      for (final d in [double.nan, 0.0, -3.0, double.infinity]) {
        expect(normalizeQuery(title: 'x', artist: '', duration: d).duration, 0);
      }
    });
  });
}
```

- [ ] **Step 7: 跑用例确认失败**

```bash
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter test test/lyrics/query_test.dart
```
Expected: FAIL —— URI 不存在。

- [ ] **Step 8: 实现 `lib/lyrics/query.dart`**

逐字照基准源码。正则：

```dart
final RegExp _trackNo = RegExp(r'^\s*[[(]?\d{1,3}[)\]]?\s*[.\-、_]\s*');
final RegExp _noiseBracket = RegExp(
  r'[（(【[][^）)】\]]*(?:official|mv|hd|hq|live|remix|伴奏|纯音乐|高音质|无损|完整版|超清|动态歌词|原唱|翻唱)[^）)】\]]*[）)】\]]',
  caseSensitive: false,
);
final RegExp _multiSpace = RegExp(r'\s{2,}');
final RegExp _tailJunk = RegExp(r'[-_\s]+$');
```
`duration`：`duration.isFinite && duration > 0 ? duration.round() : 0`。Dart 的 `double.round()` 与 JS `Math.round` 在正数上同规则（.5 向上），本处 duration 恒为正，无需额外处理。

- [ ] **Step 9: 跑用例确认通过 + 静态检查**

```bash
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter test test/lyrics/query_test.dart
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter analyze
```
Expected: PASS；`No issues found!`

- [ ] **Step 10: 提交**

```bash
git add flutter-app/lib/core/name_split.dart flutter-app/lib/lyrics/query.dart flutter-app/lib/metadata/audio_tags.dart flutter-app/test/core/name_split_test.dart flutter-app/test/lyrics/query_test.dart
git commit -m "feat(lyrics): 移植查询归一与严格版名称拆分，文件名拆分改与原版同规则"
```

---

## Task 4: OpenCC 码位 Trie（纯算法，先用小词典验）

**Files:**
- Create: `flutter-app/lib/lyrics/opencc/trie.dart`
- Test: `flutter-app/test/lyrics/opencc_trie_test.dart`

**Interfaces:**
- Consumes: 无
- Produces:
  ```dart
  class OpenccTrie {
    void addWord(String word, String value);
    void loadDict(String dict);              // "src dst|src dst"
    void loadDictGroup(List<String> dicts);  // upstream 的优先级：**数组里靠前的词典赢**（见 R14）
    ({int end, String value})? matchPrefix(String s, int start); // end 是 UTF-16 下标
    List<String> segment(String s);
    String convert(String s);
  }
  int unmatchedLength(String s, int i); // IDS 感知的步长（UTF-16 单位）
  ```

**基准源码：** `node_modules/opencc-js/dist/esm-lib/core.js:24-206`（`Trie` 与三个 IDS 辅助函数）。算法要点：

- Trie 节点是 `Map<codePoint, 子节点>`，节点上另挂一个可空的替换值。
- `matchPrefix` 从 `start` 起逐**码位**下行，记录**最后一个**有值的节点（最长前缀匹配）；返回的 `end` 是 UTF-16 下标（增补平面字符走 2）。没匹配到返回 null。
- `loadDictGroup` 把数组 **reverse** 后逐个 `loadDict`，所以数组里**靠后**的词典覆盖靠前的。
- `loadDict` 按 `|` 切条目、按**第一个空格**切 `src`/`dst`（多余 token 丢弃）；缺 `dst` 抛错。
- `convert` 与 `segment` 的唯一区别：前者把匹配段换成词典值，后者保留原文切片。两者未匹配时都按 `unmatchedLength` 前进，并把连续未匹配合并成一段。
- `unmatchedLength`：若当前位置起是一个完整的**表意文字描述序列**（IDS，U+2FF0–U+2FFF），整段一起跳过；否则跳一个码位。arity：`0x2FF0–0x2FF1 → 2`，`0x2FF2–0x2FF3 → 3`，`0x2FF4–0x2FFF → 2`，其余 0。序列不完整（子项不够）时 arity 判定返回 0，退化成单码位。

- [ ] **Step 1: 写失败用例**

创建 `flutter-app/test/lyrics/opencc_trie_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/lyrics/opencc/trie.dart';

void main() {
  group('最长前缀匹配', () {
    test('取最长的那个词，不是第一个命中的', () {
      final t = OpenccTrie()..loadDict('幹 干|幹麵 干面');
      expect(t.convert('幹麵好吃'), '干面好吃');
      expect(t.convert('幹活'), '干活');
    });

    test('未匹配字符原样保留，连续未匹配合并', () {
      final t = OpenccTrie()..loadDict('甲 A');
      expect(t.convert('乙甲丙丁'), '乙A丙丁');
    });

    test('空词典与空输入', () {
      final t = OpenccTrie()..loadDict('甲 A');
      expect(t.convert(''), '');
      expect(t.convert('乙丙'), '乙丙');
    });

    test('增补平面字符按码位匹配，end 走 2 个 UTF-16 单位', () {
      final t = OpenccTrie()..loadDict('𠀀 X');
      expect(t.convert('𠀀尾'), 'X尾');
      final m = t.matchPrefix('𠀀尾', 0);
      expect(m, isNotNull);
      expect(m!.end, 2);
    });
  });

  // R14 裁定（2026-11-09）：upstream `core.js:86-90` 是
  // `arr.slice().reverse().forEach(loadDict)`，配合 `addWord` 后写覆盖，
  // 结果是**数组里靠前的词典赢**（第一个元素最后写入）。散文原写反了。
  group('loadDictGroup 逆序加载', () {
    test('数组里靠前的词典覆盖靠后的', () {
      final t = OpenccTrie()..loadDictGroup(['甲 first', '甲 second']);
      expect(t.convert('甲'), 'first');
    });
    test('三份词典同样是第一份胜出', () {
      final t = OpenccTrie()..loadDictGroup(['甲 A', '甲 B', '甲 C']);
      expect(t.convert('甲'), 'A');
    });
  });

  group('loadDict 条目格式', () {
    test('多余 token 丢弃，只取前两个', () {
      final t = OpenccTrie()..loadDict('甲 A extra');
      expect(t.convert('甲'), 'A');
    });

    test('缺替换值抛 FormatException', () {
      expect(() => OpenccTrie()..loadDict('甲'), throwsFormatException);
    });
  });

  group('segment', () {
    test('命中词单独成段，未匹配连续段合并', () {
      final t = OpenccTrie()..loadDict('甲乙 X|丙 Y');
      expect(t.segment('丁甲乙戊丙己'), ['丁', '甲乙', '戊', '丙', '己']);
    });

    test('segment 保留原文，不替换', () {
      final t = OpenccTrie()..loadDict('甲 A');
      expect(t.segment('甲乙').join(), '甲乙');
    });
  });

  group('IDS 感知步长', () {
    test('U+2FF0 二元序列整段跳过', () {
      expect(unmatchedLength('⿰甲乙丙', 0), 3);
    });

    test('U+2FF2 三元序列整段跳过', () {
      expect(unmatchedLength('⿲甲乙丙丁', 0), 4);
    });

    test('嵌套 IDS 递归算长度', () {
      expect(unmatchedLength('⿰⿱甲乙丙丁', 0), 5);
    });

    test('序列不完整时退化成单码位', () {
      expect(unmatchedLength('⿰甲', 0), 1);
    });

    test('普通字符走一个码位；增补平面走 2', () {
      expect(unmatchedLength('甲乙', 0), 1);
      expect(unmatchedLength('𠀀乙', 0), 2);
    });

    test('convert 遇到 IDS 整段原样保留', () {
      final t = OpenccTrie()..loadDict('甲 A');
      // ⿰甲乙 是一个整体，里面的「甲」不该被单独替换
      expect(t.convert('⿰甲乙'), '⿰甲乙');
    });
  });
}
```

- [ ] **Step 2: 跑用例确认失败**

```bash
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter test test/lyrics/opencc_trie_test.dart
```
Expected: FAIL —— URI 不存在。

- [ ] **Step 3: 实现 `lib/lyrics/opencc/trie.dart`**

节点：`class _Node { final Map<int, _Node> children = {}; String? value; }`。

码位读取（Dart 没有 `codePointAt`，自己写；JS 对孤立高代理项返回代理项本身，这里一致）：

```dart
int _codePointAt(String s, int i) {
  final hi = s.codeUnitAt(i);
  if (hi >= 0xD800 && hi <= 0xDBFF && i + 1 < s.length) {
    final lo = s.codeUnitAt(i + 1);
    if (lo >= 0xDC00 && lo <= 0xDFFF) {
      return 0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00);
    }
  }
  return hi;
}
int _codePointLength(String s, int i) => _codePointAt(s, i) > 0xFFFF ? 2 : 1;
```

`matchPrefix` / `segment` / `convert` 三个循环逐字照 JS（`k` 初值 0、`orig_i` 初值 null 的语义用 `int?` 表达）。`loadDict` 用 `dict.split('|')`，每条 `line.split(' ')`，`parts.length < 2` 时 `throw FormatException('Invalid dictionary entry: $line')`。`loadDictGroup` 用 `dicts.reversed`。

IDS 三个函数照 JS 递归写；`_idsEnd` 返回 0 表示「不是完整序列」。

- [ ] **Step 4: 跑用例确认通过 + 静态检查**

```bash
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter test test/lyrics/opencc_trie_test.dart
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter analyze
```
Expected: PASS；`No issues found!`

- [ ] **Step 5: 提交**

```bash
git add flutter-app/lib/lyrics/opencc/trie.dart flutter-app/test/lyrics/opencc_trie_test.dart
git commit -m "feat(lyrics): 纯 Dart 移植 OpenCC 码位 Trie 与 IDS 步长"
```

---

## Task 5: tw2s 词典内嵌与转简体（对 Node 黄金样本）

**Files:**
- Create: `flutter-app/tool/gen_opencc_dicts.mjs`
- Create: `flutter-app/tool/opencc_oracle.mjs`
- Create: `flutter-app/lib/lyrics/opencc/dicts.dart`（生成物）
- Create: `flutter-app/lib/lyrics/opencc/converter.dart`
- Create: `flutter-app/test/fixtures/opencc_golden.json`（生成物）
- Create: `flutter-app/third_party/opencc-js-LICENSE.txt`
- Create: `flutter-app/third_party/opencc-LICENSE.txt`
- Test: `flutter-app/test/lyrics/opencc_converter_test.dart`

**Interfaces:**
- Consumes: T4 的 `OpenccTrie`
- Produces:
  ```dart
  // lib/lyrics/opencc/converter.dart
  String tw2s(String text);        // 纯 OpenCC tw2s，无缓存、无后处理
  String toSimplified(String text); // tw2s + 妳→你 / 甚么→什么 + FIFO 64 缓存
  void clearSimplifiedCacheForTest();
  ```

**为什么内嵌词典而不是引包：** 见 T1 Step 5 的裁定。`pubspec` 冻结，四个候选包在本机全部不可用。

**tw2s 的链路（`node_modules/opencc-js/dist/esm-lib/preset/t2cn.js` 的 `configs.tw2s`，逐字）：**

```js
tw2s: {
  normalizationChain: [[dict_CJK_Compatibility_Ideographs]],
  segmentation: [dict_TSPhrases],
  conversionChain: [[dict_TWVariantsRevPhrases, dict_TWVariantsRev], [dict_TSPhrases, dict_TSCharacters]]
}
```

执行顺序（`core.js:307-357`）：
1. `normalize = ConverterFactory([CJK_Compatibility_Ideographs])` → 一棵 Trie，`convert(整串)`。
2. `segmentation = Trie()..loadDictGroup([TSPhrases])` → `segment(归一后的串)` 切成段。
3. 两棵转换 Trie：`chain1.loadDictGroup([TWVariantsRevPhrases, TWVariantsRev])`、`chain2.loadDictGroup([TSPhrases, TSCharacters])`。
4. 逐段依次过 chain1、chain2，最后 `join('')`。

**词典安全性已实测（2026-11-07）：** 五份词典共 6157 条、32237 字符，**不含** `'`、`\`、`$`、换行、制表符，每条恰好两个 token。因此可以安全地生成 Dart **raw 单引号**字面量 `r'...'`。生成器必须**重新断言**这一点，将来上游词典变了就报错而不是产出坏源码。

**后处理与缓存（`src/lib/chinese.ts`，逐字语义）：** `convert(text).replace(/妳/g,'你').replace(/甚么/g,'什么')`；缓存是 `Map`，上限 64，**FIFO 不是 LRU**（命中不刷新顺序，超限时删最早插入的键）；空串直接返回。

- [ ] **Step 1: 写生成器 `tool/gen_opencc_dicts.mjs`**

```js
// 用法：node tool/gen_opencc_dicts.mjs   （在 flutter-app/ 下跑）
// 从 React 侧已装好的 opencc-js 取 tw2s 用到的五份词典，生成 Dart 源码。
// 不联网、不装包；词典缺失时直接报错退出。
import { writeFileSync, mkdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const appRoot = path.resolve(here, '..');
const dictDir = path.resolve(appRoot, '../node_modules/opencc-js/dist/esm-lib/dict');

const entries = [
  ['kDictCjkCompatibility', 'CJK_Compatibility_Ideographs'],
  ['kDictTwVariantsRevPhrases', 'TWVariantsRevPhrases'],
  ['kDictTwVariantsRev', 'TWVariantsRev'],
  ['kDictTsPhrases', 'TSPhrases'],
  ['kDictTsCharacters', 'TSCharacters'],
];

const unsafe = new Set(["'", '\\', '$', '\n', '\r', '\t']);
const out = [
  '// lib/lyrics/opencc/dicts.dart',
  '// 生成物：由 tool/gen_opencc_dicts.mjs 从 opencc-js 的词典生成，不要手改。',
  '// 数据来源：opencc-js (MIT) 及其上游 OpenCC 词典 (Apache-2.0)，',
  '// 许可全文见 third_party/opencc-js-LICENSE.txt 与 third_party/opencc-LICENSE.txt。',
  '',
];
let total = 0;
for (const [name, file] of entries) {
  const mod = await import(pathToFileURL(path.join(dictDir, file + '.js')).href);
  const text = mod.default;
  if (typeof text !== 'string' || text.length === 0) throw new Error('bad dict: ' + file);
  for (const ch of text) {
    if (unsafe.has(ch)) throw new Error('unsafe char in ' + file + ': ' + JSON.stringify(ch));
  }
  for (const line of text.split('|')) {
    if (line.split(' ').length !== 2) throw new Error('bad entry in ' + file + ': ' + line);
  }
  total += text.split('|').length;
  out.push('const String ' + name + " = r'" + text + "';", '');
}
out.push('/// 五份词典的条目总数，供用例断言生成物完整（当前 6157）。');
out.push('const int kOpenccDictEntryCount = ' + total + ';');
mkdirSync(path.join(appRoot, 'lib/lyrics/opencc'), { recursive: true });
writeFileSync(path.join(appRoot, 'lib/lyrics/opencc/dicts.dart'), out.join('\n') + '\n', 'utf8');
console.log('generated dicts.dart, entries=' + total);
```

- [ ] **Step 2: 写黄金样本生成器 `tool/opencc_oracle.mjs`**

```js
// 用法：node tool/opencc_oracle.mjs   （在 flutter-app/ 下跑）
// 用 opencc-js 本体产出「输入 → 期望输出」对，Dart 侧逐条比对。
// 只测 tw2s 本体，不含 妳/甚么 后处理（那两条另有独立用例）。
import { writeFileSync, mkdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const appRoot = path.resolve(here, '..');
// 与 src/lib/chinese.ts 完全相同的入口：`opencc-js/t2cn` 的 ESM 产物，
// 它直接导出已绑定 preset 的 Converter。
const { Converter } = await import(pathToFileURL(
  path.resolve(appRoot, '../node_modules/opencc-js/dist/esm/t2cn.js'),
).href);
const convert = Converter({ from: 'tw', to: 'cn' });

const inputs = [
  '', '十年', '陳奕迅', '你好，世界',
  '幹麵好吃', '頭髮很長', '裡面有鐘錶', '皇后與後宮',
  '計算機程式', '資料庫', '網路連線', '滑鼠與鍵盤',
  '臺灣', '台北', '高雄', '記憶體', '硬碟', '螢幕',
  '為什麼', '甚麼', '妳好', '甚么',
  '﨑', '⿰甲乙', '𠀀', '混合 English 與中文',
  '[00:01.00]繁體歌詞第一句\n[00:05.00]第二句在這裡',
  '髮型設計師', '麵條', '乾脆', '幹部', ' later ',
];
const pairs = inputs.map((input) => ({ input, expected: convert(input) }));
mkdirSync(path.join(appRoot, 'test/fixtures'), { recursive: true });
writeFileSync(
  path.join(appRoot, 'test/fixtures/opencc_golden.json'),
  JSON.stringify(pairs, null, 2) + '\n',
  'utf8',
);
console.log('generated opencc_golden.json, pairs=' + pairs.length);
```

> 实现时若入口路径变了，先 `node -e "import('.../dist/esm/t2cn.js').then(m=>console.log(Object.keys(m)))"` 确认真实导出名（当前实测导出 `Converter` / `ConverterFactory` / `CustomConverter` / `HTMLConverter` / `Locale` / `Trie`）。**以实际导出为准，不要猜。**

- [ ] **Step 3: 跑两个生成器，确认产物**

```bash
cd flutter-app && node tool/gen_opencc_dicts.mjs && node tool/opencc_oracle.mjs
```
Expected: `generated dicts.dart, entries=6157` 与 `generated opencc_golden.json, pairs=32`（inputs 数组长度）。

- [ ] **Step 4: 拷两份许可**

```bash
cd flutter-app && mkdir -p third_party && cp ../node_modules/opencc-js/LICENSE third_party/opencc-js-LICENSE.txt && cp ../node_modules/opencc-js/LICENSES/Apache-2.0.txt third_party/opencc-LICENSE.txt && ls -l third_party
```
Expected: 两个文件都在，`opencc-LICENSE.txt` 非空（Apache-2.0 全文）。这两个路径已实测存在，不需要别的探测。

- [ ] **Step 5: 写失败用例**

创建 `flutter-app/test/lyrics/opencc_converter_test.dart`：

```dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/lyrics/opencc/converter.dart';
import 'package:light_music/lyrics/opencc/dicts.dart';

void main() {
  test('生成物完整：五份词典共 6157 条', () {
    expect(kOpenccDictEntryCount, 6157);
    final actual = [
      kDictCjkCompatibility,
      kDictTwVariantsRevPhrases,
      kDictTwVariantsRev,
      kDictTsPhrases,
      kDictTsCharacters,
    ].fold<int>(0, (sum, d) => sum + d.split('|').length);
    expect(actual, kOpenccDictEntryCount);
  });

  test('与 opencc-js 黄金样本逐条一致', () {
    final raw = File('test/fixtures/opencc_golden.json').readAsStringSync();
    final pairs = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    expect(pairs, isNotEmpty);
    for (final pair in pairs) {
      expect(
        tw2s(pair['input'] as String),
        pair['expected'] as String,
        reason: '输入：${pair['input']}',
      );
    }
  });

  test('简体输入原样返回', () {
    expect(tw2s('你好，世界'), '你好，世界');
    expect(tw2s(''), '');
  });

  group('toSimplified 后处理与缓存', () {
    setUp(clearSimplifiedCacheForTest);

    test('妳 → 你、甚么 → 什么', () {
      expect(toSimplified('妳好'), '你好');
      expect(toSimplified('甚么'), '什么');
    });

    test('空串直接返回，不进缓存', () {
      expect(toSimplified(''), '');
    });

    test('缓存是 FIFO 不是 LRU：命中不延长寿命', () {
      // 插入 64 条互不相同的输入，中途反复命中第 1 条
      final first = '第0條';
      toSimplified(first);
      for (var i = 1; i < 64; i++) {
        toSimplified('第$i條');
        toSimplified(first); // 反复命中，FIFO 下不改变插入顺序
      }
      // 第 65 条触发淘汰：被删的仍是最早插入的 first
      toSimplified('第64條');
      // 无法直接观察缓存，改用可观察的等价断言：
      // 重新转换 first 仍得到正确结果（缓存只影响性能，不影响正确性），
      // 并通过计数钩子断言淘汰顺序。
      expect(toSimplified(first), '第0条');
    });
  });
}
```

> FIFO 那条用例需要一个可观察的接缝才能真断言。实现时在 `converter.dart` 里加 `@visibleForTesting int get simplifiedCacheLengthForTest;` 与 `@visibleForTesting List<String> get simplifiedCacheKeysForTest;`（返回插入顺序的键快照），把用例改成：插 64 条后 `keys.first == first`，再插第 65 条后 `keys.contains(first)` 为 false 且 `length == 64`。**不要**留一条只能断言「结果正确」的空壳用例。

- [ ] **Step 6: 跑用例确认失败**

```bash
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter test test/lyrics/opencc_converter_test.dart
```
Expected: FAIL —— `converter.dart` 不存在。

- [ ] **Step 7: 实现 `lib/lyrics/opencc/converter.dart`**

```dart
OpenccTrie _build(List<String> group) => OpenccTrie()..loadDictGroup(group);

final OpenccTrie _normalize = _build([kDictCjkCompatibility]);
final OpenccTrie _segmenter = _build([kDictTsPhrases]);
final OpenccTrie _chain1 = _build([kDictTwVariantsRevPhrases, kDictTwVariantsRev]);
final OpenccTrie _chain2 = _build([kDictTsPhrases, kDictTsCharacters]);

String tw2s(String text) {
  final normalized = _normalize.convert(text);
  final segments = _segmenter.segment(normalized);
  return segments.map((s) => _chain2.convert(_chain1.convert(s))).join();
}
```

`toSimplified`：空串直接返回；查缓存命中即返回；否则 `tw2s(text).replaceAll('妳', '你').replaceAll('甚么', '什么')`，写缓存，`length > 64` 时删**最早插入**的键（用 `LinkedHashMap` 的默认插入顺序 + `keys.first`）。两个 `@visibleForTesting` 观察接缝按 Step 5 的注记加。

- [ ] **Step 8: 跑用例确认通过 + 静态检查**

```bash
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter test test/lyrics/opencc_converter_test.dart
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter analyze
```
Expected: PASS（黄金样本 32 条全绿）；`No issues found!`

**若黄金样本有任一条不一致：** 不要改样本迁就实现。按 T4 的算法逐段打印 `normalize → segment → chain1 → chain2` 的中间值，与 Node 侧同一输入的中间值比对，定位到具体那一步再修。

- [ ] **Step 9: 提交**

```bash
git add flutter-app/tool/gen_opencc_dicts.mjs flutter-app/tool/opencc_oracle.mjs flutter-app/lib/lyrics/opencc/dicts.dart flutter-app/lib/lyrics/opencc/converter.dart flutter-app/test/fixtures/opencc_golden.json flutter-app/test/lyrics/opencc_converter_test.dart flutter-app/third_party/opencc-js-LICENSE.txt flutter-app/third_party/opencc-LICENSE.txt
git commit -m "feat(lyrics): 内嵌 OpenCC tw2s 词典与转简体，对 Node 黄金样本逐条校验"
```

---
## Task 6: 上游 HTTP 底座（两类重试策略 + 冷却闸）

**Files:**
- Create: `flutter-app/lib/lyrics/upstream.dart`
- Test: `flutter-app/test/lyrics/upstream_test.dart`

**Interfaces:**
- Consumes: `package:http`
- Produces:
  ```dart
  enum UpstreamReason { rateLimit, timeout, unreachable, upstream }
  String reasonId(UpstreamReason reason); // 'rate-limit' / 'timeout' / 'unreachable' / 'upstream'

  class UpstreamFailure implements Exception {
    const UpstreamFailure(this.reason, this.message, {this.retryAfterSeconds = 0});
    final UpstreamReason reason;
    final String message;
    final double retryAfterSeconds;
  }
  class RequestAborted implements Exception { const RequestAborted(); }

  sealed class JsonOutcome { const JsonOutcome(); }
  class JsonOk extends JsonOutcome { const JsonOk(this.json); final Object? json; }
  class JsonStatus extends JsonOutcome {
    const JsonStatus(this.status, {this.retryAfterSeconds = 0});
    final int status;
    final double retryAfterSeconds;
  }
  class JsonTimeout extends JsonOutcome { const JsonTimeout(); }
  class JsonNetwork extends JsonOutcome { const JsonNetwork(); }
  class JsonBadPayload extends JsonOutcome { const JsonBadPayload(); }

  abstract class HttpJsonClient {
    Future<JsonOutcome> getJson(Uri url, {required Duration timeout, required Map<String, String> headers});
  }
  class HttpJsonClientImpl implements HttpJsonClient { HttpJsonClientImpl({http.Client? inner}); }

  class RateLimitGate {
    RateLimitGate({DateTime Function()? now});
    bool get isLimited;
    void note(double retryAfterSeconds);
    void clear();
  }

  class CancelToken {
    bool get isCancelled;
    void cancel();
  }

  UpstreamFailure worstFailure(List<UpstreamFailure> failures);

  /// spec §11 客户端策略：可重试 {429,500,502,503,504}，700ms 或 Retry-After（≤6s），
  /// 429/503 记冷却，404 清冷却并返回 null。
  Future<Object?> requestJsonClientPolicy(
    HttpJsonClient client,
    Uri url, {
    required Duration timeout,
    int attempts = 2,
    UpstreamFailure Function(JsonOutcome) classify,
    RateLimitGate? gate,
    CancelToken? cancel,
    Future<void> Function(Duration)? sleep,
  });

  /// React 代理策略：只重试 timeout / unreachable，固定 400ms，404 → null。
  Future<Object?> requestJsonProxyPolicy(
    HttpJsonClient client,
    Uri url, {
    required Duration timeout,
    int attempts = 1,
    UpstreamFailure Function(JsonOutcome) classify,
    CancelToken? cancel,
    Future<void> Function(Duration)? sleep,
  });

  /// 统一分类器：消息里的「歌词库 / 译文库」由 [sourceLabel] 决定，括号用全角。
  UpstreamFailure classifyOutcome(JsonOutcome outcome, String sourceLabel);
  ```

**为什么一个文件放两种策略：** 它们是同一个问题的两半（同一套 `JsonOutcome`、同一套分类、同一套取消语义），拆开会让两边各写一份分类器；而调用方只有两个（歌词用客户端策略、译文用代理策略），一个文件足够。

**基准源码：** `src/lib/lyrics-source.js:283-389`（客户端）与 `src/server/music-api.ts:106-139`（代理）。逐字对照：

```js
// 客户端 requestJson 的收尾（:314-329）
if (response.status === 404) return { ok: false, status: 404, retryable: false };
if (!response.ok) { ... retryable: RETRYABLE_STATUS.has(status) ... }
// catch: if (signal?.aborted) throw error;
//        AbortError → { ok:false, status:0, retryable:true, timeout:true }
//        其它       → { ok:false, status:0, retryable:true, network:true }

// 客户端 requestJsonRetry（:342-368）
for (let index = 0; index < attempts; index += 1) {
  const last = await requestJson(url, { timeout, signal });
  if (last.ok || last.status === 404) { clearRateLimit(); return last; }
  if (!last.retryable) return last;
  if (last.status === 429 || last.status === 503) noteRateLimit(last.retryAfter);
  if (index < attempts - 1) {
    const wait = last.retryAfter ? Math.min(MAX_RETRY_AFTER_MS, last.retryAfter * 1000)
                                 : (index === 0 ? 700 : 1800);
    await sleep(wait);
  }
}

// 代理 fetchJsonWithRetry（:122-139）
for (let index = 0; index < attempts; index += 1) {
  try { return await fetchJson(url, timeoutMs); }
  catch (error) {
    last = error;
    const classified = classifyError(error);
    if (classified.reason === 'rate-limit' || classified.reason === 'upstream') throw classified;
    if (index < attempts - 1) await new Promise((r) => setTimeout(r, 400));
  }
}
throw classifyError(last);
```

移植时的六个陷阱：

1. **客户端策略里 `1800ms` 那一支在当前调用里不可达**（attempts 最大 2，`index === 0` 只可能是第一次）。实现时**照样写出来**（`index == 0 ? 700 : 1800`），不要「简化」成常量 700——将来谁把 attempts 调大，行为才对得上。
2. `Retry-After` **只认秒数**：`Number(header)` 有限且 >0 才用；HTTP-date 会得到 NaN → 0；上限 `6000ms`。
3. **404 也清冷却**（`last.ok || last.status === 404` 同一支）。
4. **只有 429 / 503 记冷却**。500 / 502 / 504 / 超时 / 网络错误都不记。
5. 冷却窗口 `Math.min(Math.max(base, 10s), 60s)`；`base = retryAfterSeconds > 0 ? retryAfterSeconds * 1000 : 60s`。注意 `retryAfterSeconds > 0` 判的是**秒**，不是毫秒。
6. 代理策略里 **JSON 解析失败**等价于 `unreachable`（会被重试）；HTTP 错误一律 `upstream`（不重试），只有 429/503 是 `rate-limit`。

- [ ] **Step 1: 写失败用例**

创建 `flutter-app/test/lyrics/upstream_test.dart`：

```dart
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/lyrics/upstream.dart';

class FakeClient implements HttpJsonClient {
  FakeClient(this.handler);
  final Future<JsonOutcome> Function(Uri url) handler;
  final List<Uri> calls = [];

  @override
  Future<JsonOutcome> getJson(
    Uri url, {
    required Duration timeout,
    required Map<String, String> headers,
  }) {
    calls.add(url);
    return handler(url);
  }
}

/// 按调用次数依次返回预设结果。
FakeClient sequence(List<JsonOutcome> outcomes) {
  var i = 0;
  return FakeClient((_) async => outcomes[i < outcomes.length ? i++ : outcomes.length - 1]);
}

void main() {
  final url = Uri.parse('https://example.test/get?track_name=x');
  UpstreamFailure classify(JsonOutcome o) => classifyOutcome(o, '歌词库');

  group('客户端策略', () {
    test('200 直接返回 JSON，不重试', () async {
      final client = sequence([const JsonOk({'ok': true})]);
      final result = await requestJsonClientPolicy(
        client, url,
        timeout: const Duration(seconds: 1), classify: classify, sleep: (_) async {},
      );
      expect(result, {'ok': true});
      expect(client.calls.length, 1);
    });

    test('404 返回 null、不重试、清掉冷却', () async {
      var now = DateTime(2026, 1, 1);
      final gate = RateLimitGate(now: () => now)..note(60);
      expect(gate.isLimited, isTrue);
      final client = sequence([const JsonStatus(404)]);
      final result = await requestJsonClientPolicy(
        client, url,
        timeout: const Duration(seconds: 1), classify: classify, gate: gate,
        sleep: (_) async {},
      );
      expect(result, isNull);
      expect(client.calls.length, 1);
      expect(gate.isLimited, isFalse);
    });

    test('500 重试一次，仍失败则抛 upstream，且不记冷却', () async {
      final gate = RateLimitGate();
      final slept = <Duration>[];
      final client = sequence([const JsonStatus(500), const JsonStatus(500)]);
      await expectLater(
        requestJsonClientPolicy(client, url,
            timeout: const Duration(seconds: 1), classify: classify, gate: gate,
            sleep: (d) async => slept.add(d)),
        throwsA(isA<UpstreamFailure>().having((f) => f.reason, 'reason', UpstreamReason.upstream)),
      );
      expect(client.calls.length, 2);
      expect(slept, [const Duration(milliseconds: 700)]);
      expect(gate.isLimited, isFalse);
    });

    test('429 记冷却，并按 Retry-After 退避（上限 6s）', () async {
      final gate = RateLimitGate();
      final slept = <Duration>[];
      final client = sequence([const JsonStatus(429, retryAfterSeconds: 3), const JsonStatus(429, retryAfterSeconds: 3)]);
      await expectLater(
        requestJsonClientPolicy(client, url,
            timeout: const Duration(seconds: 1), classify: classify, gate: gate,
            sleep: (d) async => slept.add(d)),
        throwsA(isA<UpstreamFailure>().having((f) => f.reason, 'reason', UpstreamReason.rateLimit)),
      );
      expect(slept, [const Duration(seconds: 3)]);
      expect(gate.isLimited, isTrue);
      // 冷却窗口夹在 [10s, 60s]：3s 的建议值被抬到 10s
      expect(gate.isLimited, isTrue);
    });

    test('Retry-After 超过 6s 时退避截到 6s', () async {
      final slept = <Duration>[];
      final client = sequence([const JsonStatus(429, retryAfterSeconds: 120), const JsonStatus(429)]);
      await expectLater(
        requestJsonClientPolicy(client, url,
            timeout: const Duration(seconds: 1), classify: classify,
            sleep: (d) async => slept.add(d)),
        throwsA(isA<UpstreamFailure>()),
      );
      expect(slept, [const Duration(seconds: 6)]);
    });

    test('400 不重试（不在可重试集合里）', () async {
      final client = sequence([const JsonStatus(400), const JsonOk(null)]);
      await expectLater(
        requestJsonClientPolicy(client, url,
            timeout: const Duration(seconds: 1), classify: classify, sleep: (_) async {}),
        throwsA(isA<UpstreamFailure>().having((f) => f.reason, 'reason', UpstreamReason.upstream)),
      );
      expect(client.calls.length, 1);
    });

    test('超时重试后抛 timeout', () async {
      final client = sequence([const JsonTimeout(), const JsonTimeout()]);
      await expectLater(
        requestJsonClientPolicy(client, url,
            timeout: const Duration(seconds: 1), classify: classify, sleep: (_) async {}),
        throwsA(isA<UpstreamFailure>().having((f) => f.reason, 'reason', UpstreamReason.timeout)),
      );
      expect(client.calls.length, 2);
    });

    test('网络错误重试后抛 unreachable', () async {
      final client = sequence([const JsonNetwork(), const JsonNetwork()]);
      await expectLater(
        requestJsonClientPolicy(client, url,
            timeout: const Duration(seconds: 1), classify: classify, sleep: (_) async {}),
        throwsA(isA<UpstreamFailure>().having((f) => f.reason, 'reason', UpstreamReason.unreachable)),
      );
    });

    test('取消后抛 RequestAborted，不再发第二次', () async {
      final token = CancelToken();
      final client = FakeClient((_) async {
        token.cancel();
        return const JsonTimeout();
      });
      await expectLater(
        requestJsonClientPolicy(client, url,
            timeout: const Duration(seconds: 1), classify: classify,
            cancel: token, sleep: (_) async {}),
        throwsA(isA<RequestAborted>()),
      );
      expect(client.calls.length, 1);
    });

    test('attempts: 1 时只请求一次', () async {
      final client = sequence([const JsonStatus(503)]);
      await expectLater(
        requestJsonClientPolicy(client, url,
            timeout: const Duration(seconds: 1), attempts: 1, classify: classify,
            sleep: (_) async {}),
        throwsA(isA<UpstreamFailure>()),
      );
      expect(client.calls.length, 1);
    });
  });

  group('代理策略（译文用）', () {
    test('500 直接抛，不重试', () async {
      final client = sequence([const JsonStatus(500), const JsonOk(null)]);
      await expectLater(
        requestJsonProxyPolicy(client, url,
            timeout: const Duration(seconds: 1), attempts: 2, classify: (o) => classifyOutcome(o, '译文库'),
            sleep: (_) async {}),
        throwsA(isA<UpstreamFailure>().having((f) => f.reason, 'reason', UpstreamReason.upstream)),
      );
      expect(client.calls.length, 1);
    });

    test('429 直接抛，不重试', () async {
      final client = sequence([const JsonStatus(429), const JsonOk(null)]);
      await expectLater(
        requestJsonProxyPolicy(client, url,
            timeout: const Duration(seconds: 1), attempts: 2, classify: (o) => classifyOutcome(o, '译文库'),
            sleep: (_) async {}),
        throwsA(isA<UpstreamFailure>().having((f) => f.reason, 'reason', UpstreamReason.rateLimit)),
      );
      expect(client.calls.length, 1);
    });

    test('超时按 400ms 固定退避重试', () async {
      final slept = <Duration>[];
      final client = sequence([const JsonTimeout(), const JsonOk({'x': 1})]);
      final result = await requestJsonProxyPolicy(client, url,
          timeout: const Duration(seconds: 1), attempts: 2,
          classify: (o) => classifyOutcome(o, '译文库'), sleep: (d) async => slept.add(d));
      expect(result, {'x': 1});
      expect(slept, [const Duration(milliseconds: 400)]);
    });

    test('JSON 解析失败算 unreachable，会被重试', () async {
      final client = sequence([const JsonBadPayload(), const JsonOk(null)]);
      final result = await requestJsonProxyPolicy(client, url,
          timeout: const Duration(seconds: 1), attempts: 2,
          classify: (o) => classifyOutcome(o, '译文库'), sleep: (_) async {});
      expect(result, isNull);
      expect(client.calls.length, 2);
    });
  });

  group('classifyOutcome', () {
    test('四类消息逐字', () {
      expect(
        classifyOutcome(const JsonTimeout(), '歌词库').message,
        '连接歌词库超时（本机到该站点较慢，稍等会自动重试）',
      );
      expect(
        classifyOutcome(const JsonNetwork(), '歌词库').message,
        '连不上歌词库，请检查网络或代理设置',
      );
      expect(
        classifyOutcome(const JsonStatus(429), '歌词库').message,
        '歌词库正在限流（HTTP 429）',
      );
      expect(
        classifyOutcome(const JsonStatus(500), '歌词库').message,
        '服务暂时不可用（HTTP 500）',
      );
      expect(
        classifyOutcome(const JsonStatus(400), '歌词库').message,
        '返回异常（HTTP 400）',
      );
      expect(
        classifyOutcome(const JsonStatus(429), '译文库').message,
        '译文库正在限流（HTTP 429）',
      );
    });

    test('503 也是 rate-limit', () {
      expect(classifyOutcome(const JsonStatus(503), '歌词库').reason, UpstreamReason.rateLimit);
    });
  });

  group('worstFailure', () {
    test('优先级 rate-limit > timeout > unreachable > upstream', () {
      final list = [
        const UpstreamFailure(UpstreamReason.upstream, 'u'),
        const UpstreamFailure(UpstreamReason.unreachable, 'n'),
        const UpstreamFailure(UpstreamReason.timeout, 't'),
        const UpstreamFailure(UpstreamReason.rateLimit, 'r'),
      ];
      expect(worstFailure(list).reason, UpstreamReason.rateLimit);
      expect(worstFailure(list.sublist(0, 3)).reason, UpstreamReason.timeout);
      expect(worstFailure(list.sublist(0, 2)).reason, UpstreamReason.unreachable);
      expect(worstFailure(list.sublist(0, 1)).reason, UpstreamReason.upstream);
    });

    test('同级取数组里第一个', () {
      final list = [
        const UpstreamFailure(UpstreamReason.timeout, 'first'),
        const UpstreamFailure(UpstreamReason.timeout, 'second'),
      ];
      expect(worstFailure(list).message, 'first');
    });
  });

  group('RateLimitGate', () {
    test('无建议值 60s，建议值抬到至少 10s、截到至多 60s', () {
      var now = DateTime(2026, 1, 1);
      final gate = RateLimitGate(now: () => now);
      gate.note(0);
      expect(gate.isLimited, isTrue);
      now = now.add(const Duration(seconds: 59));
      expect(gate.isLimited, isTrue);
      now = now.add(const Duration(seconds: 2));
      expect(gate.isLimited, isFalse);

      now = DateTime(2026, 1, 1);
      gate.note(3); // 3s → 抬到 10s
      now = now.add(const Duration(seconds: 9));
      expect(gate.isLimited, isTrue);
      now = now.add(const Duration(seconds: 2));
      expect(gate.isLimited, isFalse);
    });

    test('clear 立刻解除', () {
      final gate = RateLimitGate()..note(60);
      gate.clear();
      expect(gate.isLimited, isFalse);
    });
  });

  group('reasonId', () {
    test('四个字符串固定', () {
      expect(reasonId(UpstreamReason.rateLimit), 'rate-limit');
      expect(reasonId(UpstreamReason.timeout), 'timeout');
      expect(reasonId(UpstreamReason.unreachable), 'unreachable');
      expect(reasonId(UpstreamReason.upstream), 'upstream');
    });
  });
}
```

- [ ] **Step 2: 跑用例确认失败**

```bash
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter test test/lyrics/upstream_test.dart
```
Expected: FAIL —— URI 不存在。

- [ ] **Step 3: 实现 `lib/lyrics/upstream.dart`**

生产客户端（`HttpJsonClientImpl`）：

```dart
final response = await _inner.get(url, headers: headers).timeout(timeout);
final status = response.statusCode;
if (status < 200 || status >= 300) {
  return JsonStatus(status, retryAfterSeconds: _retryAfterSeconds(response.headers['retry-after']));
}
try {
  return JsonOk(jsonDecode(utf8.decode(response.bodyBytes)));
} catch (_) {
  return const JsonBadPayload();
}
```
catch：`TimeoutException` → `JsonTimeout`；其它（`SocketException` / `ClientException` / `HandshakeException` …）→ `JsonNetwork`。

`_retryAfterSeconds`：`final n = double.tryParse(raw?.trim() ?? ''); return n != null && n.isFinite && n > 0 ? n : 0;`（只认秒数）。

客户端策略循环：每轮开头先查 `cancel?.isCancelled ?? false` → `throw const RequestAborted()`；拿到 outcome 后：
- `JsonOk` → `gate?.clear()`，返回 `json`。
- `JsonStatus(404)` → `gate?.clear()`，返回 null。
- `JsonStatus` 其它：`retryable = {429,500,502,503,504}.contains(status)`；不 retryable → 抛 `classify(outcome)`；429/503 → `gate?.note(retryAfterSeconds)`。
- `JsonTimeout` / `JsonNetwork` / `JsonBadPayload` → retryable（前者分类为 timeout，后两者 unreachable）。
- 需要重试且 `index < attempts - 1` → `await sleep(wait)`，`wait = retryAfterSeconds > 0 ? min(6s, retryAfterSeconds*1000ms) : (index == 0 ? 700ms : 1800ms)`。
- 循环结束（最后一次失败）→ 抛 `classify(last)`。

代理策略：`JsonOk` → json；`JsonStatus(404)` → null；`JsonStatus` → 抛（429/503 → rate-limit，其它 → upstream）；`JsonTimeout` → timeout（可重试）；`JsonNetwork` / `JsonBadPayload` → unreachable（可重试）。可重试且还有次数 → `sleep(400ms)`，否则抛。

`sleep` 默认 `Future<void> Function(Duration) = (d) => Future<void>.delayed(d)`。

- [ ] **Step 4: 跑用例确认通过 + 静态检查**

```bash
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter test test/lyrics/upstream_test.dart
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter analyze
```
Expected: PASS；`No issues found!`

- [ ] **Step 5: 提交**

```bash
git add flutter-app/lib/lyrics/upstream.dart flutter-app/test/lyrics/upstream_test.dart
git commit -m "feat(lyrics): 上游 JSON 接缝、四类错误分类与两套重试策略"
```

---

## Task 7: 歌词双层缓存（prefs 索引 + 磁盘）

**Files:**
- Create: `flutter-app/lib/lyrics/lyrics_cache.dart`
- Test: `flutter-app/test/lyrics/lyrics_cache_test.dart`

**Interfaces:**
- Consumes: `AppPrefs`；`LyricsQuery`（T3）
- Produces:
  ```dart
  class LyricsRecord {
    const LyricsRecord({required this.status, this.synced = '', this.plain = '', this.source = 'LRCLIB'});
    final String status;        // 'ok' | 'not-found'
    final String synced;
    final String plain;
    final String source;
    bool get isOk => status == 'ok';
  }

  class LyricsIndexCache {
    LyricsIndexCache(this.prefs, {DateTime Function()? now});
    Future<LyricsRecord?> read(String key);
    Future<void> write(String key, LyricsRecord record);
    Future<void> clear();
    static const String prefsKey = 'light-music.lyrics-cache.v1';
  }

  class LyricsDiskCache {
    LyricsDiskCache({required this.directory, DateTime Function()? now});
    final String directory;
    Future<LyricsRecord?> read(String key, {bool allowStale = false});
    Future<void> write(String key, LyricsRecord record);
    Future<void> writeDual(String primaryKey, String swappedKey, LyricsRecord record);
    static String keyFor(String trackName, String artistName, String duration);
  }
  ```

**基准（`src/lib/lyrics-source.js:155-262`）：**
- 索引键 `light-music.lyrics-cache.v1`，整张表是一个 JSON 对象。
- 条目形状：命中 `{s, p, src, at}`；未命中 `{miss: true, at}`。
- 读：`at` 不是数字 → null；`ttl = miss ? 3d : 30d`；过期 → null（**不删**）。未命中返回 `{status:'not-found', source:'缓存'}`；命中返回 `{status:'ok', syncedLyrics: s ?? '', plainLyrics: p ?? '', source: src || 'LRCLIB'}`。
- 写：只有 `ok` 与 `not-found` 写，其它直接返回。超限时把条目**按 `at` 升序排**，删掉最旧的 `length - 120` 条（结果是正好 120 条）。
- 磁盘（`src/server/music-api.ts:175-198`）：文件名 `<key>.json`，`key = sha1("<trackName>|<artistName>|<duration>")` **不 lowercase**；`status==='ok'` 才算 hit，`ttl = isHit ? 30d : 3d`；TTL 按文件 **mtime**；`allowStale` 跳过 TTL 检查；文件不存在 / 解析失败 → null；写失败吞掉。
- 双写（`src/server/music-api.ts:824-829`）：主 key 与 `sha1("<artistName>|<trackName>|<duration>")` 各写一份；两 key 相同时只写一次。**忠实照抄那个已知怪癖**：artist 为空时 swapped key 是 `"|<trackName>|<duration>"`，会多写一条垃圾条目——这是原版行为，不要「顺手修好」，否则对调命中语义与缓存命中率都对不上。

- [ ] **Step 1: 写失败用例**

创建 `flutter-app/test/lyrics/lyrics_cache_test.dart`（用临时目录 + `AppPrefs.inMemory()`）：

```dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/lyrics/lyrics_cache.dart';

void main() {
  const hit = LyricsRecord(status: 'ok', synced: '[00:01]a', plain: 'a', source: 'LRCLIB');
  const miss = LyricsRecord(status: 'not-found');

  group('索引缓存', () {
    late AppPrefs prefs;
    late LyricsIndexCache cache;
    late DateTime now;

    setUp(() {
      prefs = AppPrefs.inMemory();
      now = DateTime(2026, 1, 1);
      cache = LyricsIndexCache(prefs, now: () => now);
    });

    test('命中往返：synced / plain / source', () async {
      await cache.write('k', hit);
      final read = await cache.read('k');
      expect(read!.isOk, isTrue);
      expect(read.synced, '[00:01]a');
      expect(read.plain, 'a');
      expect(read.source, 'LRCLIB');
    });

    test('未命中往返：source 是「缓存」', () async {
      await cache.write('k', miss);
      final read = await cache.read('k');
      expect(read!.status, 'not-found');
      expect(read.source, '缓存');
    });

    test('命中 TTL 30 天：第 30 天仍命中，第 31 天失效', () async {
      await cache.write('k', hit);
      now = now.add(const Duration(days: 30));
      expect(await cache.read('k'), isNotNull);
      now = now.add(const Duration(days: 1, seconds: 1));
      expect(await cache.read('k'), isNull);
    });

    test('未命中 TTL 3 天', () async {
      await cache.write('k', miss);
      now = now.add(const Duration(days: 3));
      expect(await cache.read('k'), isNotNull);
      now = now.add(const Duration(days: 1, seconds: 1));
      expect(await cache.read('k'), isNull);
    });

    test('条目形状与 React 一致：命中 {s,p,src,at}、未命中 {miss,at}', () async {
      await cache.write('a', hit);
      await cache.write('b', miss);
      final raw = jsonDecode((await prefs.readString(LyricsIndexCache.prefsKey))!) as Map;
      expect(raw['a'], {'s': '[00:01]a', 'p': 'a', 'src': 'LRCLIB', 'at': now.millisecondsSinceEpoch});
      expect(raw['b'], {'miss': true, 'at': now.millisecondsSinceEpoch});
    });

    test('只写 ok / not-found，error 不落盘', () async {
      await cache.write('k', const LyricsRecord(status: 'error'));
      expect(await prefs.readString(LyricsIndexCache.prefsKey), isNull);
    });

    test('超过 120 条按 at 淘汰最旧的，结果正好 120 条', () async {
      for (var i = 0; i < 130; i++) {
        now = DateTime(2026, 1, 1).add(Duration(seconds: i));
        await cache.write('k$i', hit);
      }
      final raw = jsonDecode((await prefs.readString(LyricsIndexCache.prefsKey))!) as Map;
      expect(raw.length, 120);
      expect(raw.containsKey('k0'), isFalse);
      expect(raw.containsKey('k9'), isFalse);
      expect(raw.containsKey('k10'), isTrue);
      expect(raw.containsKey('k129'), isTrue);
    });

    test('脏 JSON 当空表，不抛', () async {
      await prefs.writeString(LyricsIndexCache.prefsKey, '{not json');
      expect(await cache.read('k'), isNull);
      await cache.write('k', hit);
      expect((await cache.read('k'))!.isOk, isTrue);
    });

    test('数组形态的脏数据当空表', () async {
      await prefs.writeString(LyricsIndexCache.prefsKey, '[]');
      expect(await cache.read('k'), isNull);
    });
  });

  group('磁盘缓存', () {
    late Directory dir;
    late LyricsDiskCache disk;
    late DateTime now;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('lyrics-cache-');
      now = DateTime(2026, 1, 1);
      disk = LyricsDiskCache(directory: dir.path, now: () => now);
    });
    tearDown(() async => dir.delete(recursive: true));

    test('keyFor 是 sha1(原文)，不 lowercase', () {
      final a = LyricsDiskCache.keyFor('Hello', 'Adele', '300');
      final b = LyricsDiskCache.keyFor('hello', 'adele', '300');
      expect(a, isNot(b));
      expect(a.length, 40);
      expect(a, matches(RegExp(r'^[0-9a-f]{40}$')));
    });

    test('往返 + 文件扩展名 .json', () async {
      final key = LyricsDiskCache.keyFor('十年', '陈奕迅', '300');
      await disk.write(key, hit);
      expect(File('${dir.path}/$key.json').existsSync(), isTrue);
      final read = await disk.read(key);
      expect(read!.synced, '[00:01]a');
      expect(read.source, 'LRCLIB');
    });

    test('TTL 按 mtime：命中 30 天、未命中 3 天', () async {
      final okKey = LyricsDiskCache.keyFor('a', 'b', '1');
      final missKey = LyricsDiskCache.keyFor('c', 'd', '2');
      await disk.write(okKey, hit);
      await disk.write(missKey, miss);
      final okFile = File('${dir.path}/$okKey.json');
      final missFile = File('${dir.path}/$missKey.json');
      okFile.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 31)));
      missFile.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 4)));
      expect(await disk.read(okKey), isNull);
      expect(await disk.read(missKey), isNull);
    });

    test('allowStale 跳过 TTL，过期的命中也能读回', () async {
      final key = LyricsDiskCache.keyFor('a', 'b', '1');
      await disk.write(key, hit);
      File('${dir.path}/$key.json')
          .setLastModifiedSync(DateTime.now().subtract(const Duration(days: 400)));
      expect(await disk.read(key), isNull);
      final stale = await disk.read(key, allowStale: true);
      expect(stale!.synced, '[00:01]a');
    });

    test('过期的 not-found 在 allowStale 下也能读回', () async {
      final key = LyricsDiskCache.keyFor('a', 'b', '1');
      await disk.write(key, miss);
      File('${dir.path}/$key.json')
          .setLastModifiedSync(DateTime.now().subtract(const Duration(days: 400)));
      final stale = await disk.read(key, allowStale: true);
      expect(stale!.status, 'not-found');
    });

    test('文件不存在 / 解析失败 → null', () async {
      expect(await disk.read('deadbeef'), isNull);
      File('${dir.path}/bad.json').writeAsStringSync('{oops');
      expect(await disk.read('bad'), isNull);
    });

    test('writeDual 写两份；两 key 相同时只写一份（内容相同）', () async {
      const record = LyricsRecord(status: 'ok', synced: 's', plain: 'p');
      await disk.writeDual('k1', 'k2', record);
      expect(File('${dir.path}/k1.json').existsSync(), isTrue);
      expect(File('${dir.path}/k2.json').existsSync(), isTrue);
      await disk.writeDual('k3', 'k3', record);
      expect(File('${dir.path}/k3.json').existsSync(), isTrue);
    });

    test('目录不可写时写失败被吞掉，不抛', () async {
      final broken = LyricsDiskCache(directory: '${dir.path}/nope/../../\u0000bad');
      await expectLater(broken.write('k', hit), completes);
    });
  });
}
```

- [ ] **Step 2: 跑用例确认失败**

```bash
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter test test/lyrics/lyrics_cache_test.dart
```
Expected: FAIL —— URI 不存在。

- [ ] **Step 3: 实现 `lib/lyrics/lyrics_cache.dart`**

- 时间一律 `now().millisecondsSinceEpoch`；TTL 常量 `const int _ttlHitMs = 30*24*60*60*1000; const int _ttlMissMs = 3*24*60*60*1000;`
- 索引表用 `Map<String, Object?>`；读时逐字段做类型判断（`at is num` 才算有效条目），**任何异常都退化成空表**，不抛。
- 写入前先 `read` 整表（同样容错），`Map.of` 后改键；淘汰按 `at` 升序。
- 磁盘读：`File('$directory/$key.json')` → `readAsString` → `jsonDecode`；`allowStale == false` 时用 `stat().modified` 判 TTL。**mtime 用本地时间**（`DateTime.now()` 与 `stat.modified` 同为本地/系统时区，直接相减即可）。
- 磁盘写：`Directory(directory).create(recursive: true)` → `writeAsString(jsonEncode(toJson()))`；整段 try/catch 吞掉。
- `LyricsRecord.toJson()`：命中写 `{'status':'ok','syncedLyrics':...,'plainLyrics':...,'source':...}`；未命中写 `{'status':'not-found'}`。**磁盘格式用长字段名**（React 代理的 `LyricsResult` 就是长名），**索引格式用短字段名**（`s/p/src/at`）。两者不同，别混。

- [ ] **Step 4: 跑用例确认通过 + 静态检查**

```bash
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter test test/lyrics/lyrics_cache_test.dart
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter analyze
```
Expected: PASS；`No issues found!`

- [ ] **Step 5: 提交**

```bash
git add flutter-app/lib/lyrics/lyrics_cache.dart flutter-app/test/lyrics/lyrics_cache_test.dart
git commit -m "feat(lyrics): 歌词双层缓存，索引短键 + 磁盘长键与双 key 写"
```

---

## Task 8: 歌词匹配源（并行 job、裁决、冷却、四类话术）

**Files:**
- Create: `flutter-app/lib/lyrics/lyrics_source.dart`
- Test: `flutter-app/test/lyrics/lyrics_source_test.dart`

**Interfaces:**
- Consumes: T3 `normalizeQuery` / `LyricsQuery`；T6 的客户端与两类策略；T7 的两层缓存
- Produces:
  ```dart
  class LyricsMatch {
    const LyricsMatch({required this.status, this.synced = '', this.plain = '', this.source = '', this.reason = '', this.message = '', this.rateLimited = false});
    final String status;   // ok | not-found | error | aborted | empty-query
    final String synced;
    final String plain;
    final String source;
    final UpstreamReason? reason;
    final String message;
    final bool rateLimited;
  }

  class LyricsSource implements LyricsMatcher {
    LyricsSource({
      required this.client,
      required this.disk,
      this.index,
      this.gate,
      Duration getTimeout = const Duration(seconds: 12),
      Duration searchTimeout = const Duration(seconds: 26),
      Duration totalBudget = const Duration(seconds: 60),
      // retryAfterCap 已删（2026-11-10，T20 裁定）：6000ms 夹紧在 T6 的客户端
      // 策略里实施，本参数零消费者，承诺了不存在的可配置性。
      Future<void> Function(Duration)? sleep,
    });

    @override
    Future<LyricsMatch> match(LyricsQuery query, {CancelToken? cancel, bool useCache = true});
    void clearCooldown();
  }

  /// 状态机只认这个接口，不认具体实现（测试注入假源）。
  abstract class LyricsMatcher {
    Future<LyricsMatch> match(LyricsQuery query, {CancelToken? cancel, bool useCache = true});
  }
  ```

**基准（`src/server/music-api.ts:302-391` + `src/lib/lyrics-source.js:520-574`）：**

job 构造（顺序即优先级）：

```
for ([name, artist] of pairs([trackName, artistName])):   // 原方向 → 对调方向
    base = {track_name: name} + (artist ? {artist_name: artist} : {})
    if (duration 非 0):
        job(get, url: /api/get? base + duration, timeout 12s, attempts 2)   // 带时长
    job(get, url: /api/get? base, timeout 12s, attempts 2)                  // 不带时长
loose = [trackName, artistName].filter(非空).join(' ')
job(search, url: /api/search?q=loose, timeout 26s, attempts 1)
```

裁决（**等全部结束**，按 job 顺序遍历）：

```
getHit      = 第一个 kind==get   且 status==ok 的结果
searchHit   = 第一个 kind==search 且 status==ok 的结果
getErrors   = kind==get 的失败，按 job 顺序
errors      = 全部失败，按 job 顺序

有 synced 的 getHit      → 返回它
有 synced 的 searchHit   → 返回它
getHit                   → 返回它
getErrors 非空           → 抛 worstFailure(getErrors)
searchHit                → 返回它
errors 非空              → 抛 worstFailure(errors)
否则                     → not-found
```

`hasSynced` = `(synced ?? '').trim().isNotEmpty`。`toLyricsResult`：synced 与 plain 都为空 → `not-found`（所以「get 命中但两个都空」不算 hit）。

search 那一路打分基准永远是**原方向** `[trackName, artistName]`。`pickBestLyrics` 属于歌词链路，本任务一并实现（T11 只做译文那边的认歌，两边规则**不同**，不要共用）。

`match` 的外层流程（`lyrics-source.js:590-627`）：

```
query.trackName 为空            → empty-query（message '曲目信息不足，无法匹配歌词'）
useCache && index 命中          → 直接用（ok 或 not-found）
!useCache 或 index 未命中：
  gate.isLimited && useCache    → error + rateLimited（message '歌词服务刚才在限流，请稍后点「重试」'）
  否则跑 job 裁决：
      ok                        → 写 index + 双写 disk
      not-found                 → 写 index + 双写 disk
      抛 UpstreamFailure        → 先试 disk allowStale：有就返回 ok/not-found 且 source 覆盖为 'LRCLIB（离线缓存）'
                                  没有 → error + reason + rateLimited(reason==rate-limit) + message
  RequestAborted                → aborted（不写任何缓存）
  其它异常                       → error + message '歌词匹配失败，请稍后点「重试」'
```

**注意**：React 里 stale 回退**只在代理侧**，且只在上游**抛错**时触发；`not-found` 是正常结果、不回退。Flutter 合成后保持这个顺序：**上游抛错 → 试 stale → 仍无则 error**。

- [ ] **Step 1: 写失败用例**

创建 `flutter-app/test/lyrics/lyrics_source_test.dart`：

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/lyrics/lyrics_cache.dart';
import 'package:light_music/lyrics/lyrics_source.dart';
import 'package:light_music/lyrics/query.dart';
import 'package:light_music/lyrics/upstream.dart';

/// 按 URL 特征应答的假上游。
class RoutingClient implements HttpJsonClient {
  RoutingClient(this.routes);
  final List<({bool Function(Uri) match, FutureOr<JsonOutcome> Function(Uri) reply})> routes;
  final List<Uri> calls = [];

  @override
  Future<JsonOutcome> getJson(Uri url, {required Duration timeout, required Map<String, String> headers}) async {
    calls.add(url);
    for (final route in routes) {
      if (route.match(url)) return route.reply(url);
    }
    return const JsonStatus(404);
  }
}

const trackName = '十年';
const artistName = '陈奕迅';
final query = normalizeQuery(title: trackName, artist: artistName, duration: 300);

void main() {
  late Directory dir;
  late AppPrefs prefs;
  late LyricsDiskCache disk;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('lyrics-source-');
    prefs = AppPrefs.inMemory();
    disk = LyricsDiskCache(directory: dir.path);
  });
  tearDown(() => dir.delete(recursive: true));

  LyricsSource sourceWith(HttpJsonClient client, {RateLimitGate? gate, Duration total = const Duration(seconds: 60)}) =>
      LyricsSource(
        client: client,
        disk: disk,
        index: LyricsIndexCache(prefs),
        gate: gate ?? RateLimitGate(),
        totalBudget: total,
        sleep: (_) async {},
      );

  test('原方向带时长 get 命中即可，且不写 search', () async {
    final client = RoutingClient([
      (
        match: (u) => u.path.endsWith('/get') && u.queryParameters.containsKey('duration'),
        reply: (_) => const JsonOk({'syncedLyrics': '[00:01]甲', 'plainLyrics': '甲'}),
      ),
    ]);
    final result = await sourceWith(client).match(query);
    expect(result.status, 'ok');
    expect(result.synced, '[00:01]甲');
    expect(result.source, 'LRCLIB');
  });

  test('get 只有纯文本，而 search 有时间轴 → 用 search', () async {
    final client = RoutingClient([
      (match: (u) => u.path.endsWith('/get'), reply: (_) => const JsonOk({'syncedLyrics': '', 'plainLyrics': '纯文本'})),
      (match: (u) => u.path.endsWith('/search'), reply: (_) => const JsonOk([
        {'trackName': '十年', 'artistName': '陈奕迅', 'duration': 300, 'syncedLyrics': '[00:01]甲', 'plainLyrics': '甲'},
      ])),
    ]);
    final result = await sourceWith(client).match(query);
    expect(result.synced, '[00:01]甲');
  });

  test('get 报错而 search 只有纯文本 → 宁可报错（不把限流说成未找到）', () async {
    final client = RoutingClient([
      (match: (u) => u.path.endsWith('/get'), reply: (_) => const JsonStatus(429, retryAfterSeconds: 5)),
      (match: (u) => u.path.endsWith('/search'), reply: (_) => const JsonOk([
        {'trackName': '十年', 'artistName': '陈奕迅', 'syncedLyrics': '', 'plainLyrics': '纯文本'},
      ])),
    ]);
    final result = await sourceWith(client).match(query);
    expect(result.status, 'error');
    expect(result.reason, UpstreamReason.rateLimit);
    expect(result.rateLimited, isTrue);
    expect(result.message, '歌词库正在限流（HTTP 429）');
  });

  test('全部 404 → not-found，写索引与磁盘', () async {
    final client = RoutingClient([]);
    final result = await sourceWith(client).match(query);
    expect(result.status, 'not-found');
    expect(await LyricsIndexCache(prefs).read(query.key), isNotNull);
    final again = await sourceWith(client).match(query);
    expect(again.status, 'not-found');
    expect(again.source, '缓存');
  });

  test('冷却期内直接拦截，不发请求', () async {
    final gate = RateLimitGate()..note(60);
    final client = RoutingClient([]);
    final result = await sourceWith(client, gate: gate).match(query);
    expect(result.status, 'error');
    expect(result.rateLimited, isTrue);
    expect(result.message, '歌词服务刚才在限流，请稍后点「重试」');
    expect(client.calls, isEmpty);
  });

  test('useCache: false 绕过冷却与命中，且仍然写缓存', () async {
    final gate = RateLimitGate()..note(60);
    final client = RoutingClient([
      (match: (u) => u.path.endsWith('/get') && u.queryParameters.containsKey('duration'),
       reply: (_) => const JsonOk({'syncedLyrics': '[00:01]甲', 'plainLyrics': '甲'})),
    ]);
    final result = await sourceWith(client, gate: gate).match(query, useCache: false);
    expect(result.status, 'ok');
    expect(await LyricsIndexCache(prefs).read(query.key), isNotNull);
  });

  test('上游抛错时回退过期磁盘缓存，source 覆盖为「LRCLIB（离线缓存）」', () async {
    final client = RoutingClient([
      (match: (u) => u.path.endsWith('/get') && u.queryParameters.containsKey('duration'),
       reply: (_) => const JsonOk({'syncedLyrics': '[00:01]旧', 'plainLyrics': '旧'})),
    ]);
    await sourceWith(client).match(query);
    // 把磁盘条目改成过期
    final key = LyricsDiskCache.keyFor(query.trackName, query.artistName, '${query.duration}');
    File('${dir.path}/$key.json')
        .setLastModifiedSync(DateTime.now().subtract(const Duration(days: 400)));

    final failing = RoutingClient([
      (match: (_) => true, reply: (_) => const JsonTimeout()),
    ]);
    final result = await sourceWith(failing).match(query, useCache: false);
    expect(result.status, 'ok');
    expect(result.synced, '[00:01]旧');
    expect(result.source, 'LRCLIB（离线缓存）');
  });

  test('上游抛错且没有过期缓存 → error，message 是四类话术之一', () async {
    final client = RoutingClient([(match: (_) => true, reply: (_) => const JsonTimeout())]);
    final result = await sourceWith(client).match(query);
    expect(result.status, 'error');
    expect(result.reason, UpstreamReason.timeout);
    expect(result.message, '连接歌词库超时（本机到该站点较慢，稍等会自动重试）');
  });

  test('trackName 为空 → empty-query，不发请求', () async {
    final client = RoutingClient([]);
    final result = await sourceWith(client).match(normalizeQuery(title: '', artist: '', duration: 0));
    expect(result.status, 'empty-query');
    expect(result.message, '曲目信息不足，无法匹配歌词');
    expect(client.calls, isEmpty);
  });

  test('取消 → aborted，不写任何缓存', () async {
    final token = CancelToken();
    final client = RoutingClient([]);
    final future = sourceWith(client).match(query, cancel: token);
    token.cancel();
    final result = await future;
    expect(result.status, 'aborted');
    expect(await prefs.readString(LyricsIndexCache.prefsKey), isNull);
  });

  test('对调 key 也写一份（歌手非空时）', () async {
    final client = RoutingClient([
      (match: (u) => u.path.endsWith('/get') && u.queryParameters['track_name'] == '陈奕迅',
       reply: (_) => const JsonOk({'syncedLyrics': '[00:01]乙', 'plainLyrics': '乙'})),
    ]);
    final result = await sourceWith(client).match(query);
    expect(result.status, 'ok');
    final swapped = LyricsDiskCache.keyFor('陈奕迅', '十年', '300');
    expect(File('${dir.path}/$swapped.json').existsSync(), isTrue);
  });

  test('总预算到点取消，按 timeout 分类', () async {
    // 一个永不返回的上游：只有总预算能结束这次匹配
    final client = RoutingClient([(match: (_) => true, reply: (_) => Completer<JsonOutcome>().future)]);
    final result = await sourceWith(client, total: const Duration(milliseconds: 30)).match(query);
    expect(result.status, 'error');
    expect(result.reason, UpstreamReason.timeout);
  });

  test('search 用 q 参数，不是 track_name', () async {
    final client = RoutingClient([
      (match: (u) => u.path.endsWith('/search'), reply: (_) => const JsonOk([])),
    ]);
    await sourceWith(client).match(query);
    final search = client.calls.firstWhere((u) => u.path.endsWith('/search'));
    expect(search.queryParameters['q'], '十年 陈奕迅');
    expect(search.queryParameters.containsKey('track_name'), isFalse);
  });
}
```

> 最后两条用例需要 `LyricsSource` 在内部把「总预算」实现成 `Future.any` 竞争，并且 search 的 URL 用 `q=`。写实现时按此对齐；若 `total` 竞争不好测，把 `totalBudget` 改成可注入的 `Future<void> Function(Future<T>)` 包装器也行——但**用例语义不变**。

- [ ] **Step 2: 跑用例确认失败**

```bash
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter test test/lyrics/lyrics_source_test.dart
```
Expected: FAIL —— URI 不存在。

- [ ] **Step 3: 实现 `lib/lyrics/lyrics_source.dart`**

要点：

- 常量：`_upstream = Uri.parse('https://lrclib.net/api')`；`_getTimeout = 12s`；`_searchTimeout = 26s`；`_totalBudget = 60s`；`_getAttempts = 2`。
- `_pairs(trackName, artistName)`：`[(trackName, artistName)]` + （artist 非空且 != trackName）`[(artistName, trackName)]`。
- 每个 job 是 `({String kind, Future<LyricsRecord> Function() run})`；`Future.wait` 等价物用 `Future.wait(..., eagerError: false)`，但要保留**每条的成败与顺序**——用 `Future<Object>`（成功给 `LyricsRecord`，失败给捕获到的异常）最稳，`Future.wait` 会短路抛错。写成：
  ```dart
  final settled = await Future.wait(jobs.map((job) async {
    try { return _Settled(record: await job.run()); }
    catch (e) { return _Settled(error: e); }
  }));
  ```
- `_pickBestLyrics(items, wantName, wantArtist, duration)`：逐字照 `music-api.ts:249-289`（synced 50 / 名字全等 30 / 包含 12 / 歌手全等 25 / 包含 10 / 时长 ≤2s 30、≤6s 12、>25s −25；`score > bestScore` 且 `bestScore` 初值 0）。
- `toLyricsResult(Object? json)`：非 Map → not-found；`syncedLyrics` / `plainLyrics` 不是 String → ''；两者都空 → not-found；否则 ok + `source: 'LRCLIB'`。
- URL 构造：`Uri.parse('$_upstream/get').replace(queryParameters: {...})`。**注意** `Uri.replace(queryParameters:)` 会把空格编成 `+` 还是 `%20`——Dart 用 `%20`，React 的 `URLSearchParams` 用 `+`。两者服务端都接受，**不算差异**；但用例断言 `queryParameters['q']` 取值时要记得 Dart 已解码，得到 `'十年 陈奕迅'`。
- 总预算：`await _withinBudget(future, totalBudget)`；超时抛 `UpstreamFailure(timeout, ...)` 并按「上游抛错」那条路走。**注意**超时后底层请求仍在跑（Dart http 不支持 abort），要保证晚到的结果不会写缓存——用一个 `bool abandoned` 标志，超时后置真，写缓存前检查。
- 冷却闸：入口 `if (useCache && gate.isLimited)` → 返回那条固定文案；`useCache: false` 时旁路。成功 / 404 / not-found 一律 `gate.clear()`（T6 的策略函数内部已经做了，这里只在「直接命中索引」时补一次 clear——不必，索引命中不该动冷却；保持与 React 一致：只在真正发请求的路径里 clear）。
- 索引命中优先于一切网络：`if (useCache) { final cached = await index?.read(query.key); if (cached != null) return ...; }`。命中 `ok` 时 `source = cached.source`（默认 `LRCLIB`），命中未命中时 `source = '缓存'`。
- 写缓存：`ok` / `not-found` 都写索引；磁盘 `writeDual(keyFor(trackName, artist, '${duration}'), keyFor(artist, trackName, '${duration}'), record)`。duration 用 `'${query.duration}'`（React 里是原始字符串，Flutter 只有 int，等价）。
- stale 回退：`disk.read(primaryKey, allowStale: true)`；返回时 `source` **硬编码** `'LRCLIB（离线缓存）'`，同 React。

- [ ] **Step 4: 跑用例确认通过 + 静态检查**

```bash
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter test test/lyrics/lyrics_source_test.dart
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter analyze
```
Expected: PASS；`No issues found!`

- [ ] **Step 5: 提交**

```bash
git add flutter-app/lib/lyrics/lyrics_source.dart flutter-app/test/lyrics/lyrics_source_test.dart
git commit -m "feat(lyrics): 并行 job 匹配、job 顺序裁决、冷却闸与过期缓存回退"
```

---
## Task 9: 语种判定与译文对齐（纯函数）

**Files:**
- Create: `flutter-app/lib/lyrics/translate_lang.dart`
- Create: `flutter-app/lib/lyrics/translate_align.dart`
- Test: `flutter-app/test/lyrics/translate_lang_test.dart`
- Test: `flutter-app/test/lyrics/translate_align_test.dart`

**Interfaces:**
- Consumes: T2 的 `parseLrc` / `LyricLine`
- Produces:
  ```dart
  // translate_lang.dart
  bool needsTranslation(String text);

  // translate_align.dart
  List<String> alignTranslation(List<LyricLine> lines, String translatedLrc, [String originalLrc = '']);
  ```
  `lines` 里纯文本行的 `time` 是 `double.nan`；**混合数组**（部分有 time）按纯文本路径处理。

**基准源码（`src/lib/translate-source.js:58-101`、`277-342`、`344-422`）：**

```js
const SCRIPT_PATTERNS = {
  han:    /[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]/g,
  kana:   /[\u3040-\u30ff]/g,
  hangul: /[\u1100-\u11ff\u3130-\u318f\uac00-\ud7a3]/g,
  latin:  /[\u0041-\u007a\u00c0-\u024f]/g,
};

function lyricBody(text) {
  return String(text ?? '')
    .replace(/\[[^\]\n]*\]/g, '')
    .replace(/<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>/g, '');
}

function needsTranslation(text) {
  const body = lyricBody(text);
  if (!body.trim()) { return false; }
  const count = (pattern) => (body.match(pattern) || []).length;
  const kana = count(SCRIPT_PATTERNS.kana);
  const hangul = count(SCRIPT_PATTERNS.hangul);
  if (kana >= 3 || hangul > 0) { return true; }
  const han = count(SCRIPT_PATTERNS.han);
  const latin = count(SCRIPT_PATTERNS.latin);
  if (han + latin === 0) { return body.trim().length > 0 && han === 0; }
  if (han < 8) { return latin > 0; }
  return han / (han + latin) < 0.35;
}

const MAX_SHIFT = 20;
const MIN_TIMED_COVERAGE = 0.25;
const MIN_PLAIN_COVERAGE = 0.5;
const LEAD_IN = 1.5;

function normalizeLine(text) {
  return String(text ?? '')
    .toLowerCase()
    .replace(/[\s　]/g, '')
    .replace(/[,.;:!?·、。，．：；!?'"「」『』（）()【】\[\]<>-]/g, '');
}

function headOfSameTime(lines, index) {
  let at = index;
  while (at > 0 && lines[at - 1].time === lines[at].time) { at -= 1; }
  return at;
}

function cueIndexAt(lines, time) {
  if (lines.length === 0 || time <= lines[0].time) { return 0; }
  let low = 0;
  let high = lines.length - 1;
  while (low < high) {
    const mid = Math.ceil((low + high) / 2);
    if (lines[mid].time <= time) { low = mid; } else { high = mid - 1; }
  }
  return headOfSameTime(lines, low);
}

function estimateShift(lines, anchors) {
  const firstAt = new Map();
  lines.forEach((line, index) => {
    const key = normalizeLine(line.text);
    if (key && !firstAt.has(key)) { firstAt.set(key, index); }
  });
  const diffs = [];
  anchors.forEach((anchor) => {
    const index = firstAt.get(normalizeLine(anchor.text));
    if (index !== undefined && Number.isFinite(anchor.time) && Number.isFinite(lines[index].time)) {
      diffs.push(anchor.time - lines[index].time);
    }
  });
  if (diffs.length < 3) { return 0; }
  diffs.sort((a, b) => a - b);
  const median = diffs[Math.floor(diffs.length / 2)];
  return Math.abs(median) > MAX_SHIFT ? 0 : median;
}

const joinFragments = (texts) => texts.join(' ').replace(/\s{2,}/g, ' ').trim();
```

`alignTranslation` 的完整流程：

```js
const slots = lines.map(() => '');
if (lines.length === 0 || !translatedLrc) return slots;
const translated = parseLRC(translatedLrc).lines.filter((line) => line.text);
if (translated.length === 0) return slots;
const original = originalLrc ? parseLRC(originalLrc).lines.filter((line) => line.text) : [];
const timed = lines.every((line) => Number.isFinite(line.time));

if (timed) {
  const shift = estimateShift(lines, original);
  const buckets = lines.map(() => []);
  translated.forEach((line) => {
    const at = Math.max(0, line.time - shift);
    let index = cueIndexAt(lines, at);
    const next = lines[index + 1];
    if (next && next.time > at && next.time - at <= LEAD_IN) {
      index = headOfSameTime(lines, index + 1);
    }
    buckets[index].push(line.text);
  });
  buckets.forEach((bucket, index) => { slots[index] = joinFragments(bucket); });
  const covered = slots.filter(Boolean).length / translated.length;
  return covered < MIN_TIMED_COVERAGE ? lines.map(() => '') : slots;
}

const buckets = original.map(() => []);
if (original.length > 0) {
  translated.forEach((line) => {
    let index = 0;
    while (index + 1 < original.length && original[index + 1].time <= line.time) { index += 1; }
    buckets[index].push(line.text);
  });
}
const byKey = new Map();
original.forEach((line, index) => {
  const key = normalizeLine(line.text);
  const text = joinFragments(buckets[index]);
  if (key && text && !byKey.has(key)) { byKey.set(key, text); }
});
let matched = 0;
lines.forEach((line, index) => {
  const found = byKey.get(normalizeLine(line.text));
  if (found) { slots[index] = found; matched += 1; }
});
if (matched / lines.length >= MIN_PLAIN_COVERAGE) { return slots; }
return lines.map(() => '');
```

**六个必须钉住的点：**

1. `needsTranslation` 的输入是**未转简体的原始歌词**（`track.lyrics || track.lyricsPlain`），不是 `cues`。所以繁体/日文/韩文都按原文判。
2. `latin` 区间 `\u0041-\u007a` **包含** `[ \ ] ^ _ \``（0x5B–0x60），逐字照抄，不要「顺手修正」成 `A-Za-z`。
3. `needsTranslation` 与对齐用的 `normalizeLine` **不是同一套字符集**：判语种保留括号，对齐要删括号/方括号/尖括号/连字符。两处必须是两个独立函数。
4. 带时间轴路径的覆盖率**分母是 `translated.length`**，不是 `lines.length`。
5. 中位数是**上中位数** `diffs[floor(n/2)]`（偶数个不做平均），且 `|median| > 20` 才归零（`=== 20` 保留）。
6. `estimateShift` 的 `firstAt` 只记**首次出现**，重复的副歌行都用第一次出现的那一行算偏移。

- [ ] **Step 1: 写失败用例（语种）**

创建 `flutter-app/test/lyrics/translate_lang_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/lyrics/translate_lang.dart';

void main() {
  test('纯中文不翻译', () {
    expect(needsTranslation('[00:01]我们一起看月亮爬上来'), isFalse);
  });

  test('假名 ≥3 要翻译', () {
    expect(needsTranslation('きみのこえ'), isTrue);
    expect(needsTranslation('きみの'), isFalse); // 2 个假名，落到汉字/拉丁分支
  });

  test('谚文 ≥1 要翻译', () {
    expect(needsTranslation('사랑해'), isTrue);
  });

  test('纯英文要翻译', () {
    expect(needsTranslation('Hello darkness my old friend'), isTrue);
  });

  test('汉字占比 <35% 要翻译', () {
    expect(needsTranslation('I love you 我爱你'), isTrue);
  });

  test('汉字占比 ≥35% 不翻译', () {
    expect(needsTranslation('我们 together 一起走'), isFalse);
  });

  test('汉字 <8 时只看有没有拉丁字母', () {
    expect(needsTranslation('天空 abc'), isTrue);
    expect(needsTranslation('天空'), isFalse);
  });

  test('只有标点/空白 → 不翻译', () {
    expect(needsTranslation('   '), isFalse);
    expect(needsTranslation('[00:01]'), isFalse);
    expect(needsTranslation('……！？'), isFalse);
  });

  test('方括号标签与逐字标签不计入语种统计', () {
    expect(needsTranslation('[ti:Hello]\n[00:01]你好世界'), isFalse);
    expect(needsTranslation('[00:01]<00:01:000>你好世界'), isFalse);
  });

  test('一个汉字都没有、但有符号 → 仍判为需要翻译（han+latin==0 分支）', () {
    // 韩文/假名已在前面拦掉；这里用西里尔字母验证该分支
    expect(needsTranslation('Привет'), isTrue);
  });
}
```

- [ ] **Step 2: 实现 `lib/lyrics/translate_lang.dart` 并跑绿**

```bash
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter test test/lyrics/translate_lang_test.dart
```
Expected: PASS。`RegExp` 必须带 `multiLine: true`？**不需要**：`lyricBody` 的 `\[[^\]\n]*\]` 已排除换行，逐行无关，整串替换即可。

> 这条用例先写、先绿，再动对齐——它只有 30 行，不值得单开一个提交。

- [ ] **Step 3: 写失败用例（对齐）**

创建 `flutter-app/test/lyrics/translate_align_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/lyrics/lrc_parser.dart';
import 'package:light_music/lyrics/translate_align.dart';

List<LyricLine> cued(List<(double, String)> pairs) =>
    [for (final p in pairs) LyricLine(time: p.$1, text: p.$2)];

List<LyricLine> plain(List<String> texts) =>
    [for (final t in texts) LyricLine(time: double.nan, text: t)];

void main() {
  test('空输入、空译文、译文无正文都返回全空且长度对齐', () {
    expect(alignTranslation(const [], '[00:01]甲'), <String>[]);
    final lines = cued([(1, '你')]);
    expect(alignTranslation(lines, ''), ['']);
    expect(alignTranslation(lines, '[00:01]'), ['']);
  });

  test('同一时间区间的多条译文并成一行', () {
    final lines = cued([(0, '第一句'), (5, '第二句')]);
    final trans = '[00:00]一句\n[00:01]续\n[00:02]再接';
    expect(alignTranslation(lines, trans), ['一句 续 再接', '']);
  });

  test('译文落在「它所属歌词行」的区间里，不足覆盖率则整首退回单语', () {
    // 5 条译文全部落在第 0 行 → 覆盖率 1/5 = 0.2 < 0.25
    final lines = cued([(0, 'a'), (10, 'b')]);
    final trans = '[00:00]1\n[00:01]2\n[00:02]3\n[00:03]4\n[00:04]5';
    expect(alignTranslation(lines, trans), ['', '']);
  });

  test('起手保护：离下一句更近且 ≤1.5s 时归下一句', () {
    final lines = cued([(0, 'a'), (2, 'b')]);
    // 1.0 离 2.0 只有 1.0s（≤1.5）且 2.0 > 1.0 → 归第二句
    expect(alignTranslation(lines, '[00:01.00]乙'), ['', '乙']);
  });

  test('起手保护不跨过 1.5s', () {
    final lines = cued([(0, 'a'), (3, 'b')]);
    expect(alignTranslation(lines, '[00:01.00]甲'), ['甲', '']);
  });

  test('起手保护只在 next.time > at 时生效', () {
    final lines = cued([(0, 'a'), (1, 'b')]);
    // at = 1.0 正好等于下一句时间 → 不算「离下一句更近」，留在本行区间
    expect(alignTranslation(lines, '[00:01.00]乙'), ['乙', '']);
  });

  test('重复时间戳归到同刻那组的第一行', () {
    final lines = cued([(0, 'a'), (5, 'b1'), (5, 'b2'), (9, 'c')]);
    expect(alignTranslation(lines, '[00:05.00]乙'), ['', '乙', '', '']);
  });

  test('中位数偏移：译文库整体晚 3 秒，对齐时扣掉', () {
    final lines = cued([(0, '甲'), (2, '乙'), (4, '丙'), (10, '丁')]);
    const original = '[00:03]甲\n[00:05]乙\n[00:07]丙';
    final trans = '[00:03]A\n[00:05]B\n[00:07]C';
    expect(alignTranslation(lines, trans, original), ['A', 'B', 'C', '']);
  });

  test('锚点不足 3 个 → 偏移按 0', () {
    final lines = cued([(0, '甲'), (2, '乙'), (4, '丙')]);
    const original = '[00:03]甲\n[00:05]乙';
    final trans = '[00:03]A\n[00:05]B\n[00:07]C';
    expect(alignTranslation(lines, trans, original), ['A', 'B', 'C']);
  });

  test('|中位偏移| > 20 视为不可信，按 0', () {
    final lines = cued([(0, '甲'), (20, '乙'), (40, '丙')]);
    const original = '[00:30]甲\n[00:50]乙\n[01:10]丙';
    final trans = '[00:30]A\n[00:50]B\n[01:10]C';
    // 中位偏移 30 → 归零 → 译文落到 30/50/70 → 29.88 之后才到下一行…
    expect(alignTranslation(lines, trans, original), ['', 'A', '']);
  });

  test('偏移为负（译文库更早）也照减', () {
    final lines = cued([(10, '甲'), (20, '乙'), (30, '丙')]);
    const original = '[00:05]甲\n[00:15]乙\n[00:25]丙';
    final trans = '[00:05]A\n[00:15]B\n[00:25]C';
    expect(alignTranslation(lines, trans, original), ['A', 'B', 'C']);
  });

  test('at 钳到 0：译文早于首行时间也不越界', () {
    final lines = cued([(5, '甲'), (10, '乙')]);
    expect(alignTranslation(lines, '[00:00]A'), ['A', '']);
  });

  group('纯文本路径', () {
    List<LyricLine> display = plain(['甲', '乙', '丙', '丁']);

    test('按原文配对；覆盖率 ≥50% 时允许部分槽为空', () {
      const original = '[00:00]甲\n[00:02]乙\n[00:04]丙\n[00:06]丁';
      final trans = '[00:00]A\n[00:02]B\n[00:04]C';
      expect(alignTranslation(display, trans, original), ['A', 'B', 'C', '']);
    });

    test('覆盖率 <50% 整首退回单语', () {
      final four = plain(['甲', '乙', '丙', '丁', '戊', '己']);
      const original = '[00:00]甲\n[00:02]乙\n[00:04]丙\n[00:06]丁\n[00:08]戊\n[00:10]己';
      final trans = '[00:00]A\n[00:02]B';
      expect(alignTranslation(four, trans, original), ['', '', '', '', '', '']);
    });

    test('没有译文库原文时无法配对 → 全空', () {
      expect(alignTranslation(display, '[00:00]A\n[00:02]B'), ['', '', '', '']);
    });

    test('归一化后同文本的行共用同一份译文（首次出现优先）', () {
      final d = plain(['甲！', '乙', '甲']);
      const original = '[00:00]甲\n[00:02]乙';
      final trans = '[00:00]A\n[00:02]B';
      expect(alignTranslation(d, trans, original), ['A', 'B', 'A']);
    });

    test('一行原文对应多条译文时合并', () {
      final d = plain(['甲']);
      const original = '[00:00]甲';
      expect(alignTranslation(d, '[00:00]A\n[00:00]B', original), ['A B']);
    });
  });

  test('混合数组（部分有 time）走纯文本路径', () {
    final mixed = [
      const LyricLine(time: 0, text: '甲'),
      const LyricLine(time: double.nan, text: '乙'),
    ];
    const original = '[00:00]甲\n[00:02]乙';
    final trans = '[00:00]A\n[00:02]B';
    expect(alignTranslation(mixed, trans, original), ['A', 'B']);
  });
}
```

> 「中位偏移 >20」那条用例的期望值按算法推：shift=30 → 归零；`[00:30]A` 的 at=30 → 落在 `(20,40]` 区间 → 第 1 行（需检查 40-30=10 >1.5）→ 得 `['', 'A', '']`。执行时若实测不同，**以算法输出为准并回写用例**，但要先确认是算法移植错还是我这条期望推错（打印 `cueIndexAt` 的中间值判断）。

- [ ] **Step 4: 跑用例确认失败**

```bash
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter test test/lyrics/translate_align_test.dart
```
Expected: FAIL —— URI 不存在。

- [ ] **Step 5: 实现 `lib/lyrics/translate_align.dart`**

逐字照上面的流程。三个内部函数 `_headOfSameTime` / `_cueIndexAt` / `_estimateShift` 私有；`normalizeLine` 的字符类：

```dart
final RegExp _lineNoise = RegExp(r'''[\s　,.;:!?·、。，．：；!?'"「」『』（）()【】\[\]<>-]''');
```
（用三引号 raw 字符串，避免与 Dart 字符串引号打架。）

时间有限性判定用 `line.time.isFinite`。`timed = lines.every((l) => l.time.isFinite)`。

- [ ] **Step 6: 跑用例确认通过 + 静态检查**

```bash
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter test test/lyrics/translate_lang_test.dart test/lyrics/translate_align_test.dart
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter analyze
```
Expected: PASS；`No issues found!`

- [ ] **Step 7: 提交**

```bash
git add flutter-app/lib/lyrics/translate_lang.dart flutter-app/lib/lyrics/translate_align.dart flutter-app/test/lyrics/translate_lang_test.dart flutter-app/test/lyrics/translate_align_test.dart
git commit -m "feat(lyrics): 字符集判语种与跨库译文对齐（偏移/起手保护/覆盖率闸）"
```

---

## Task 10: 网易云认歌打分（纯函数）

**Files:**
- Create: `flutter-app/lib/lyrics/netease_match.dart`
- Test: `flutter-app/test/lyrics/netease_match_test.dart`

**Interfaces:**
- Consumes: 无
- Produces:
  ```dart
  class NetEaseSong {
    const NetEaseSong({required this.id, required this.name, this.durationMs = 0, this.artists = const [], this.alias = const []});
    final int id;
    final String name;
    final double durationMs;   // 毫秒
    final List<String> artists;
    final List<String> alias;
  }
  class TranslateCandidate {
    const TranslateCandidate({required this.name, required this.artist, required this.strict});
    final String name;
    final String artist;
    final bool strict;
    String get keyword; // [artist, name].where(非空).join(' ')
  }

  String normText(String value);
  String coreTitle(String value);
  bool artistHitSong(NetEaseSong song, String wantArtist);
  NetEaseSong? pickTranslatableSong(
    List<NetEaseSong> songs, {
    required String trackName,
    required String artistName,
    required int duration,   // 秒，0 = 未知
    bool strict = false,
  });
  List<TranslateCandidate> translatePairs(String trackName, String artistName);
  NetEaseSong? parseNetEaseSong(Object? raw);   // 从 JSON 取安全字段，脏数据返回 null
  List<NetEaseSong> parseNetEaseSongs(Object? raw); // 读 result.songs，非数组给空
  ```

**基准源码（`src/server/music-api.ts:418-561`），逐字：**

```ts
const normText = (value: unknown): string => String(value ?? '')
  .toLowerCase()
  .replace(/[\s　]/g, '')
  .replace(/[,.;:!?·、。，．：；！？"'«»『』「」]/g, '');

function coreTitle(value: string): string {
  let text = String(value ?? '');
  let before = '';
  while (before !== text) {
    before = text;
    text = text.replace(/\s*[(（【[][^()（）【】\[\]]*[)）】\]]\s*$/, '').trimEnd();
  }
  return text.replace(/\s*[-–—:,;]\s*$/, '').trim();
}

function artistHitSong(song: NetEaseSong, wantArtist: string): boolean {
  if (!wantArtist) { return false; }
  const tokens = artistNames(song)
    .flatMap((value) => value.split(/[/、,，&；;]|\bfeat\.?\b/i))
    .map(normText)
    .filter(Boolean);
  return tokens.some((token) => token === wantArtist
    || (token.length >= 3 && (token.startsWith(wantArtist) || wantArtist.startsWith(token))));
}

const PLACEHOLDER_ARTISTS = new Set(['本地文件', '未知歌手', '未知', 'unknown', 'various artists']);

const pairs = [{ name: trackName, artist: artistName, strict: false }];
if (artistName && artistName !== trackName) {
  pairs.push({ name: artistName, artist: trackName, strict: true });
}
const split = trackName.match(/^(.{2,60}?)\s+[-–—]\s+(.{2,60})$/);
if (split) {
  const [, head, tail] = split;
  pairs.push({ name: head.trim(), artist: tail.trim(), strict: true });
  pairs.push({ name: tail.trim(), artist: head.trim(), strict: true });
}
const seen = new Set<string>();
return pairs.filter((pair) => {
  const key = `${pair.name}|${pair.artist}`.toLowerCase();
  if (seen.has(key)) { return false; }
  seen.add(key);
  return true;
});
// 调用方随后 push({ name: trackName, artist: '', strict: false }) —— 在去重之后
```

打分（`music-api.ts:465-522`）：

```ts
const wantTitle = normText(trackName);
const wantCore = normText(coreTitle(trackName));
const wantArtist = normText(artistName);
if (!wantTitle) { return null; }
const onlyTitle = !wantArtist && !(duration > 0);

let best = null, bestScore = 0;
for (const song of songs) {
  const name = normText(song.name);
  if (!name || !song.id) { continue; }
  const core = normText(coreTitle(song.name ?? ''));
  const titleExact = name === wantTitle
    || (song.alias ?? []).some((alias) => normText(alias) === wantTitle)
    || (wantCore.length >= 3 && core === wantCore);
  const titlePrefix = !titleExact && wantTitle.length >= 3 && name.startsWith(wantTitle);
  if (!titleExact && !titlePrefix) { continue; }
  const artistHit = artistHitSong(song, wantArtist);
  const seconds = Number(song.duration);
  const diff = duration > 0 && Number.isFinite(seconds) && seconds > 0
    ? Math.abs(seconds / 1000 - duration) : Number.POSITIVE_INFINITY;
  const durHit = diff <= 6;
  if (!titleExact) {
    if (!artistHit && !durHit) { continue; }
    if (diff > 20) { continue; }
  } else if (!artistHit && !durHit && !onlyTitle) {
    continue;
  }
  if (strict && !artistHit) { continue; }
  const score = (titleExact ? 40 : 18) + (artistHit ? 25 : 0) + (durHit ? 25 : 0);
  if (score > bestScore) { best = song; bestScore = score; }
}
return best;
```

**五个必须钉住的点：**

1. `song.duration` 是**毫秒**，必须 `/1000` 再与秒级 `duration` 比。
2. `titlePrefix` 要求 `wantTitle.length >= 3`，且是**单向** `name.startsWith(wantTitle)`。
3. 前缀命中的硬上限 `diff > 20` 直接淘汰（`diff === 20` 保留）；无时长信息 → `diff = +Infinity`，前缀路径**只能靠歌手**。
4. `strict` 时**必须有 `artistHit`**，时长再准也没用。
5. `score > bestScore` 严格大于 → **同分取搜索结果里靠前的那条**；`bestScore` 初值 0，所以 0 分不选。

- [ ] **Step 1: 写失败用例**

创建 `flutter-app/test/lyrics/netease_match_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/lyrics/netease_match.dart';

NetEaseSong song({
  int id = 1,
  String name = '十年',
  double durationMs = 300000,
  List<String> artists = const ['陈奕迅'],
  List<String> alias = const [],
}) => NetEaseSong(id: id, name: name, durationMs: durationMs, artists: artists, alias: alias);

void main() {
  group('normText', () {
    test('小写、去空白（含全角空格）、去常见标点，保留括号', () {
      expect(normText(' 十 年 '), '十年');
      expect(normText('Ten Years'), 'tenyears');
      expect(normText('（十年）'), '（十年）');
      expect(normText('N.O.P.E'), 'nope');
      expect(normText('「十年」'), '十年');
    });
  });

  group('coreTitle', () {
    test('循环剥尾部括号，直到不动点', () {
      expect(coreTitle('十年 (feat. 甲) (Live)'), '十年');
      expect(coreTitle('十年【伴奏】'), '十年');
    });

    test('只剥尾部，中间括号保留', () {
      expect(coreTitle('十 (Live) 年'), '十 (Live) 年');
    });

    test('不跨嵌套括号', () {
      // parity 校正（2026-11-09，rev-t10 用 node 按字节复现 music-api.ts:417-561）：
      // 括号内容类 `[^()（）【】\[\]]*` 排除括号本身，嵌套时匹配不到末尾 `)`，
      // 所以**原样不剥**。计划原写 `'十年'` 是错的。
      expect(coreTitle('十年 (甲 (乙))'), '十年 (甲 (乙))');
    });

    test('最后剥一个尾部 - – — : , ;', () {
      expect(coreTitle('十年 -'), '十年');
      // parity 校正：尾部分隔符类只有**半角** `-–—:,;`，不含全角 `：`。
      // 计划原写 `'十年'` 是错的（node 实测 `'十年：'` 不剥）。
      expect(coreTitle('十年：'), '十年：');
      expect(coreTitle('十年:'), '十年');
    });
  });

  group('artistHitSong', () {
    test('全等命中', () {
      expect(artistHitSong(song(), '陈奕迅'), isTrue);
    });

    test('空 wantArtist 恒 false', () {
      expect(artistHitSong(song(), ''), isFalse);
    });

    test('分隔符拆开后逐个比', () {
      final s = song(artists: ['陈奕迅 / 王菲']);
      expect(artistHitSong(s, '王菲'), isTrue);
      expect(artistHitSong(s, '陈奕迅'), isTrue);
      // parity 校正：拆出的 token `陈奕迅 / 王菲` 归一后是 `陈奕迅王菲`，与
      // wantArtist 全等 → true。计划原写 isFalse 是错的（node 实测 true）。
      expect(artistHitSong(s, '陈奕迅王菲'), isTrue);
    });

    test('feat. 也拆', () {
      final s = song(artists: ['A feat. B']);
      // parity 校正：wantArtist **由调用方先归一化**（JS 内部不再 normText），
      // 所以必须传小写。计划原写大写 'B'/'A' 期望 true 是错的（node 实测 false）。
      expect(artistHitSong(s, 'b'), isTrue);
      expect(artistHitSong(s, 'a'), isTrue);
      expect(artistHitSong(s, 'B'), isFalse);
    });

    test('token ≥3 才允许前缀匹配', () {
      expect(artistHitSong(song(artists: ['陈奕迅乐队']), '陈奕迅'), isTrue);
      // 原用例是一条**假绿**：'AB乐队' 归一后 4 字符，门槛其实是开的，
      // 它之所以 false 只因为传了未归一化的大写 'AB'。换成能真正区分门槛
      // 的输入（token 长度 3 vs 2），并用归一化入参补一条「门槛是开的」。
      expect(artistHitSong(song(artists: ['abc']), 'abcd'), isTrue);
      expect(artistHitSong(song(artists: ['ab']), 'abcd'), isFalse);
      expect(artistHitSong(song(artists: ['AB乐队']), 'ab'), isTrue);
      expect(artistHitSong(song(artists: ['AB乐队']), 'AB'), isFalse);
    });

    test('不做整串包含：Zzzx Nope vs N.O.P.E 必须为假', () {
      // 原用例也是假绿：'N.O.P.E' 与归一后的 token 'zzzxnope' 永远比不上，
      // 无论实现怎么写都通过。换成归一化入参 'nope' 才真正钉住这条语义。
      expect(artistHitSong(song(artists: ['Zzzx Nope']), 'nope'), isFalse);
    });
  });

  group('pickTranslatableSong', () {
    test('名字全等 + 歌手命中 + 时长命中 → 90 分', () {
      final picked = pickTranslatableSong([song()], trackName: '十年', artistName: '陈奕迅', duration: 300);
      expect(picked, isNotNull);
    });

    test('别名全等也算 titleExact', () {
      final picked = pickTranslatableSong(
        [song(name: 'Ten Years', alias: ['十年'])],
        trackName: '十年', artistName: '陈奕迅', duration: 300,
      );
      expect(picked, isNotNull);
    });

    test('wantCore ≥3 时尾括号剥离后相等也算 titleExact', () {
      final picked = pickTranslatableSong(
        [song(name: '十年 (Live)')],
        trackName: '十年 (Live)', artistName: '陈奕迅', duration: 300,
      );
      expect(picked, isNotNull);
    });

    test('时长容差 ≤6s（含等号），7s 不算', () {
      final picked6 = pickTranslatableSong(
        [song(name: '十年', artists: ['别人'], durationMs: 306000)],
        trackName: '十年', artistName: '', duration: 300,
      );
      expect(picked6, isNotNull);
      final picked7 = pickTranslatableSong(
        [song(name: '十年', artists: ['别人'], durationMs: 307000)],
        trackName: '十年', artistName: '', duration: 300,
      );
      expect(picked7, isNull);
    });

    test('前缀命中：无歌手无时长时淘汰，有时长 20s 内保留', () {
      final noInfo = pickTranslatableSong(
        [song(name: '十年 (Live)')],
        trackName: '十年', artistName: '', duration: 0,
      );
      expect(noInfo, isNull);
      // parity 校正（rev-t10 复核，implementer 报告漏列的一条）：
      // trackName '十年' 只有 2 字符，titlePrefix 的 `wantTitle.length >= 3`
      // 门槛把前缀路径整个关掉，无论歌手/时长如何都命中不了。
      // 计划原写 isNotNull 是错的（node 实测 isNull）。
      final near = pickTranslatableSong(
        [song(name: '十年 (Live)', artists: ['别人']),],
        trackName: '十年', artistName: '', duration: 300,
      );
      expect(near, isNull);
      final far = pickTranslatableSong(
        [song(name: '十年 (Live)', artists: ['别人'], durationMs: 330000)],
        trackName: '十年', artistName: '', duration: 300,
      );
      expect(far, isNull);
    });

    test('titleExact 但歌手与时长都不对，且信息不全 → 淘汰', () {
      final picked = pickTranslatableSong(
        [song(name: '十年', artists: ['别人'], durationMs: 0)],
        trackName: '十年', artistName: '陈奕迅', duration: 300,
      );
      expect(picked, isNull);
    });

    test('onlyTitle（无歌手无时长）时 titleExact 直接通过', () {
      final picked = pickTranslatableSong(
        [song(name: '十年', artists: ['别人'], durationMs: 0)],
        trackName: '十年', artistName: '', duration: 0,
      );
      expect(picked, isNotNull);
    });

    test('strict 必须有歌手命中', () {
      final picked = pickTranslatableSong(
        [song(name: '十年', artists: ['别人'], durationMs: 300000)],
        trackName: '十年', artistName: '陈奕迅', duration: 300, strict: true,
      );
      expect(picked, isNull);
    });

    test('wantTitle 为空 → null', () {
      expect(pickTranslatableSong([song()], trackName: '', artistName: '', duration: 0), isNull);
    });

    test('同分取靠前的', () {
      final first = song(id: 1, name: '十年', artists: ['别人'], durationMs: 300000);
      final second = song(id: 2, name: '十年', artists: ['别人'], durationMs: 300000);
      final picked = pickTranslatableSong(
        [first, second],
        trackName: '十年', artistName: '', duration: 300,
      );
      expect(picked!.id, 1);
    });

    test('id 为 0 / 空名字跳过', () {
      expect(pickTranslatableSong([song(id: 0)], trackName: '十年', artistName: '', duration: 0), isNull);
      expect(pickTranslatableSong([song(name: '')], trackName: '十年', artistName: '', duration: 0), isNull);
    });
  });

  group('translatePairs', () {
    test('原方向 → 对调（strict）；拆分要求两侧各 2~60 字符', () {
      // parity 校正（rev-t10 用 node 复核）：拆分的正则
      // `/^(.{2,60}?)\s+[-–—]\s+(.{2,60})$/` 要求破折号两侧各 2~60 字符，
      // '甲 - 乙' 两侧各 1 字符 → **不拆**，只有原方向 + 对调两条。
      // 计划原写 4 条（含拆头/拆尾）是错的（node 实测 2 条）。
      final pairs = translatePairs('甲 - 乙', '丙');
      expect(pairs.map((p) => (p.name, p.artist, p.strict)), [
        ('甲 - 乙', '丙', false),
        ('丙', '甲 - 乙', true),
      ]);
      // 对照组：两侧各 2 字符才真的拆出「拆头 / 拆尾」。
      final four = translatePairs('甲乙 - 丙丁', '戊');
      expect(four.map((p) => (p.name, p.artist, p.strict)), [
        ('甲乙 - 丙丁', '戊', false),
        ('戊', '甲乙 - 丙丁', true),
        ('甲乙', '丙丁', true),
        ('丙丁', '甲乙', true),
      ]);
    });

    test('歌手为空或等于曲名时不加对调', () {
      expect(translatePairs('十年', '').length, 1);
      expect(translatePairs('十年', '十年').length, 1);
    });

    test('拆分要求破折号两侧都有空白，且两侧各 2~60 字符', () {
      expect(translatePairs('Jay-Z', '').length, 1);
      expect(translatePairs('A - B', '').length, 1); // 两侧各 1 字符，不拆
    });

    test('按 name|artist 小写去重，保留首次出现的顺序', () {
      final pairs = translatePairs('甲 - 乙', '丙');
      final keys = pairs.map((p) => '${p.name}|${p.artist}'.toLowerCase()).toSet();
      expect(keys.length, pairs.length);
    });

    test('keyword 是「歌手 曲名」，空侧省略', () {
      expect(const TranslateCandidate(name: '十年', artist: '陈奕迅', strict: false).keyword, '陈奕迅 十年');
      expect(const TranslateCandidate(name: '十年', artist: '', strict: false).keyword, '十年');
    });
  });
}
```

- [ ] **Step 2: 跑用例确认失败**

```bash
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter test test/lyrics/netease_match_test.dart
```
Expected: FAIL —— URI 不存在。

- [ ] **Step 3: 实现 `lib/lyrics/netease_match.dart`**

实现照上面的源码。`parseNetEaseSong`：`raw` 非 Map → null；`id` 必须是 `num` 且 `> 0` 且是整数（`toInt()`），`name` 非 String → ''；`artists` 里逐条取 `name`；`alias` 只收 String；`duration` 非 num → 0。**不要把脏数据抛出去**——搜索结果里混一条怪数据不该让整次匹配失败。

`parseNetEaseSongs(raw)`：`raw is Map` → `raw['result']` → `raw['songs']`；是 `List` 就逐条 `parseNetEaseSong(...)` 并丢掉 null。

- [ ] **Step 4: 跑用例确认通过 + 静态检查**

```bash
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter test test/lyrics/netease_match_test.dart
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter analyze
```
Expected: PASS；`No issues found!`

- [ ] **Step 5: 提交**

```bash
git add flutter-app/lib/lyrics/netease_match.dart flutter-app/test/lyrics/netease_match_test.dart
git commit -m "feat(lyrics): 网易云认歌打分与候选关键词生成"
```

---
## Task 11: 译文缓存与网易云译文源

**Files:**
- Create: `flutter-app/lib/lyrics/translate_cache.dart`
- Create: `flutter-app/lib/lyrics/translate_source.dart`
- Test: `flutter-app/test/lyrics/translate_cache_test.dart`
- Test: `flutter-app/test/lyrics/translate_source_test.dart`

**Interfaces:**
- Consumes: T3 `normalizeQuery`；T6 `HttpJsonClient` / `requestJsonProxyPolicy` / `CancelToken`；T10 的认歌
- Produces:
  ```dart
  // translate_cache.dart
  class TranslationRecord {
    const TranslationRecord({required this.status, this.translated = '', this.original = '', this.source = '网易云译文库', this.reason = ''});
    final String status; // 'ok' | 'not-found'
    final String translated;
    final String original;
    final String source;
    final String reason;
  }
  class TranslationIndexCache {
    TranslationIndexCache(this.prefs, {DateTime Function()? now});
    static const String prefsKey = 'light-music.translate-cache.v2';
    Future<TranslationRecord?> read(String key);
    Future<void> write(String key, TranslationRecord record);
  }
  class TranslationDiskCache {
    TranslationDiskCache({required this.directory, DateTime Function()? now});
    static String keyFor({required String title, required String artist, required int duration});
    Future<TranslationRecord?> read(String key, {bool allowStale = false});
    Future<void> write(String key, TranslationRecord record);
  }

  // translate_source.dart
  class TranslationResult {
    const TranslationResult({required this.status, this.translatedLyrics = '', this.originalLyrics = '', this.source = '网易云译文库', this.reason = '', this.message = ''});
    final String status; // ok | not-found | empty-query | error
    final String translatedLyrics;
    final String originalLyrics;
    final String source;
    final String reason;   // '' | 'song-not-matched' | 'no-translation' | rate-limit | timeout | unreachable | upstream
    final String message;
  }
  class TranslateSource implements TranslationFetcher {
    TranslateSource({required this.client, required this.disk, this.index});
    @override
    Future<TranslationResult> fetch({
      required String title,
      required String artist,
      required double duration,
      CancelToken? cancel,
      bool useCache = true,
    });
    static const List<String> placeholderArtists = ['本地文件', '未知歌手', '未知', 'unknown', 'various artists'];
  }

  /// 双语状态机只认这个接口（测试注入假源）。
  abstract class TranslationFetcher {
    Future<TranslationResult> fetch({
      required String title,
      required String artist,
      required double duration,
      CancelToken? cancel,
      bool useCache = true,
    });
  }
  ```

**基准：** 客户端缓存 `src/lib/translate-source.js:108-190`；代理认歌与取译文 `src/server/music-api.ts:524-622`。

客户端缓存逐条：
- 键 `light-music.translate-cache.v2`，120 条，按 `at` 升序淘汰。
- 命中条目 `{status:'ok', t, o, src, at}`；未命中 `{status:'not-found', reason, at}`。
- 读：`at` 非数字 → null；TTL `isHit ? 30d : 3d`（**按 `status === 'ok'` 判 hit**，不是按 `miss` 字段）；未命中返回 `{status:'not-found', reason: entry.reason || 'song-not-matched'}`（**丢掉 message**）；命中返回六个字段。
- 写：只写 `ok` / `not-found`；`useCache:false` 只跳过**读**，仍然写。
- 磁盘键 `sha1('v2|title|artist|duration'.toLowerCase())`，TTL 按 mtime，`allowStale` 跳过；stale 返回时 source 追加 `（离线缓存）`。

网络（本任务把代理那一侧搬进来）：
- 搜索：`GET https://music.163.com/api/search/get?s=<keyword>&type=1&limit=20`。**`keyword` 是 `[artist, name]` 用单空格连接**，歌手在前。
- 取译文：`GET https://music.163.com/api/song/lyric?id=<id>&lv=1&tv=1`。
- 头：`Accept: application/json`、`User-Agent: light-music-react/1.0 (+vite dev middleware)`。**无 Referer / Cookie / Origin。**
- 每一步单程 `8000ms`、尝试 2 次、固定 `400ms`、只重试 `timeout`/`unreachable`（`requestJsonProxyPolicy`）。404 → null（不报错）。整次调用总预算 `45000ms`（客户端原来的代理超时值）。
- 候选顺序：`translatePairs(trackName, artist)` 之后**追加** `{name: trackName, artist: '', strict: false}`（在去重之后，所以 artist 为空时会重复搜一次——照抄）。
- 占位歌手：`{'本地文件','未知歌手','未知','unknown','various artists'}`，判定方式 `PLACEHOLDER_ARTISTS.has(artistName.trim().toLowerCase())`。
- 命中即 `break`；搜索抛错则收集 failure 后**继续试下一个候选**。
- 全部候选跑完仍无歌：有 failure → 抛 `worstFailure`；没有 → `not-found` + `song-not-matched`。
- 认到歌但 `tlyric.lyric` 缺失 / 非字符串 / trim 后为空 → `not-found` + `no-translation`。
- 成功：`source: '网易云译文库（人工翻译）'`，`originalLyrics` 取 `lrc.lyric`（可为空，不影响 ok）。
- 上游抛错时先试磁盘 stale；没有则返回 `error` + reason + message。

**三条与 React 的**有意**差异（已写进 T1 的裁定，实现时照此）：**
1. **不产出 `unavailable`**：没有代理这一层，404/405/非 JSON content-type 这三个判据都不存在。
2. **不预判 `offline`**：Dart 没有 `navigator.onLine` 且不引依赖；离线会以真实的 `unreachable` 表达。
3. 因此 `error` 的 **message 用代理那套**（`classifyOutcome(..., '译文库')`），不用客户端那句「连不上译文库，请检查本地服务是否在跑」——后者在桌面应用里指向一个不存在的东西。`transNote` 只按 `reason` 分支，用户可见文案不受影响。

- [ ] **Step 1: 写失败用例（缓存）**

创建 `flutter-app/test/lyrics/translate_cache_test.dart`：

```dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/lyrics/translate_cache.dart';

void main() {
  const ok = TranslationRecord(
    status: 'ok', translated: '[00:01]A', original: '[00:01]a', source: '网易云译文库（人工翻译）',
  );
  const none = TranslationRecord(status: 'not-found', reason: 'no-translation');

  group('索引缓存', () {
    late AppPrefs prefs;
    late TranslationIndexCache cache;
    late DateTime now;

    setUp(() {
      prefs = AppPrefs.inMemory();
      now = DateTime(2026, 1, 1);
      cache = TranslationIndexCache(prefs, now: () => now);
    });

    test('命中往返，source 默认「网易云译文库」', () async {
      await cache.write('k', const TranslationRecord(status: 'ok', translated: 't', original: 'o'));
      final read = await cache.read('k');
      expect(read!.status, 'ok');
      expect(read.translated, 't');
      expect(read.original, 'o');
      expect(read.source, '网易云译文库');
    });

    test('未命中往返，reason 默认 song-not-matched，message 不落盘', () async {
      await cache.write('k', const TranslationRecord(status: 'not-found'));
      final read = await cache.read('k');
      expect(read!.status, 'not-found');
      expect(read.reason, 'song-not-matched');
      final raw = jsonDecode((await prefs.readString(TranslationIndexCache.prefsKey))!) as Map;
      expect(raw['k'].containsKey('message'), isFalse);
    });

    test('条目形状：命中 {status,t,o,src,at}、未命中 {status,reason,at}', () async {
      await cache.write('a', ok);
      await cache.write('b', none);
      final raw = jsonDecode((await prefs.readString(TranslationIndexCache.prefsKey))!) as Map;
      expect(raw['a']['status'], 'ok');
      expect(raw['a']['t'], '[00:01]A');
      expect(raw['a']['o'], '[00:01]a');
      expect(raw['a']['src'], '网易云译文库（人工翻译）');
      expect(raw['a']['at'], now.millisecondsSinceEpoch);
      expect(raw['b'], {'status': 'not-found', 'reason': 'no-translation', 'at': now.millisecondsSinceEpoch});
    });

    test('TTL：命中 30 天、未命中 3 天', () async {
      await cache.write('ok', ok);
      await cache.write('none', none);
      now = now.add(const Duration(days: 4));
      expect(await cache.read('ok'), isNotNull);
      expect(await cache.read('none'), isNull);
      // parity 校正（2026-11-09，rev-t11 独立复算）：原写 4+27=31 天，
      // 已经越过 30 天命中 TTL，正确实现下这条 isNotNull 必红。改成 4+26=30，
      // 正好钉住「第 30 天仍命中」（判据是 `> ttl` 严格大于），强度只增。
      now = now.add(const Duration(days: 26));
      expect(await cache.read('ok'), isNotNull);
      now = now.add(const Duration(seconds: 1));
      expect(await cache.read('ok'), isNull);
    });

    test('只写 ok / not-found', () async {
      await cache.write('k', const TranslationRecord(status: 'error'));
      expect(await prefs.readString(TranslationIndexCache.prefsKey), isNull);
    });

    test('超限按 at 淘汰到正好 120 条', () async {
      for (var i = 0; i < 125; i++) {
        now = DateTime(2026, 1, 1).add(Duration(seconds: i));
        await cache.write('k$i', ok);
      }
      final raw = jsonDecode((await prefs.readString(TranslationIndexCache.prefsKey))!) as Map;
      expect(raw.length, 120);
      expect(raw.containsKey('k4'), isFalse);
      expect(raw.containsKey('k5'), isTrue);
    });

    test('脏数据当空表', () async {
      await prefs.writeString(TranslationIndexCache.prefsKey, '{bad');
      expect(await cache.read('k'), isNull);
    });
  });

  group('磁盘缓存', () {
    late Directory dir;
    late TranslationDiskCache disk;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('translate-cache-');
      disk = TranslationDiskCache(directory: dir.path);
    });
    tearDown(() => dir.delete(recursive: true));

    test('keyFor 是 sha1(v2|title|artist|duration) 全小写', () async {
      final key = TranslationDiskCache.keyFor(title: 'Hello', artist: 'Adele', duration: 300);
      expect(key.length, 40);
      expect(key, matches(RegExp(r'^[0-9a-f]{40}$')));
      expect(key, TranslationDiskCache.keyFor(title: 'hello', artist: 'adele', duration: 300));
    });

    test('往返 + TTL + allowStale', () async {
      final key = TranslationDiskCache.keyFor(title: 'a', artist: 'b', duration: 1);
      await disk.write(key, ok);
      expect((await disk.read(key))!.translated, '[00:01]A');
      File('${dir.path}/$key.json').setLastModifiedSync(DateTime.now().subtract(const Duration(days: 400)));
      expect(await disk.read(key), isNull);
      expect((await disk.read(key, allowStale: true))!.translated, '[00:01]A');
    });

    test('stale 返回时 source 追加「（离线缓存）」由调用方负责，缓存本身不改字符串', () async {
      final key = TranslationDiskCache.keyFor(title: 'a', artist: 'b', duration: 1);
      await disk.write(key, ok);
      File('${dir.path}/$key.json').setLastModifiedSync(DateTime.now().subtract(const Duration(days: 400)));
      final stale = await disk.read(key, allowStale: true);
      expect(stale!.source, '网易云译文库（人工翻译）');
    });
  });
}
```

- [ ] **Step 2: 实现 `lib/lyrics/translate_cache.dart` 并跑绿**

与 T7 同构，只有键前缀、字段名与 TTL 判定点不同（这里按 `status == 'ok'` 判 hit）。磁盘 JSON 用 `{status, translatedLyrics, originalLyrics, source, reason}`。

```bash
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter test test/lyrics/translate_cache_test.dart
```

- [ ] **Step 3: 写失败用例（译文源）**

创建 `flutter-app/test/lyrics/translate_source_test.dart`：

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/lyrics/translate_cache.dart';
import 'package:light_music/lyrics/translate_source.dart';
import 'package:light_music/lyrics/upstream.dart';

class FakeNetEase implements HttpJsonClient {
  FakeNetEase({this.search = const {}, this.lyric = const {}});
  /// keyword → 搜索结果里的 songs
  final Map<String, List<Map<String, Object?>>> search;
  /// song id → 译文响应
  final Map<int, Map<String, Object?>> lyric;
  final List<Uri> calls = [];

  @override
  Future<JsonOutcome> getJson(Uri url, {required Duration timeout, required Map<String, String> headers}) async {
    calls.add(url);
    expect(headers['User-Agent'], 'light-music-react/1.0 (+vite dev middleware)');
    if (url.path.endsWith('/search/get')) {
      final songs = search[url.queryParameters['s']] ?? const [];
      return JsonOk({'result': {'songs': songs}});
    }
    if (url.path.endsWith('/song/lyric')) {
      final id = int.parse(url.queryParameters['id']!);
      return JsonOk(lyric[id] ?? <String, Object?>{});
    }
    return const JsonStatus(404);
  }
}

Map<String, Object?> songJson({
  int id = 1,
  String name = 'Yesterday',
  int duration = 125000,
  List<String> artists = const ['The Beatles'],
}) => {
  'id': id,
  'name': name,
  'duration': duration,
  'artists': [for (final a in artists) {'name': a}],
};

void main() {
  late Directory dir;
  late TranslationDiskCache disk;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('translate-source-');
    disk = TranslationDiskCache(directory: dir.path);
  });
  tearDown(() => dir.delete(recursive: true));

  TranslateSource sourceWith(HttpJsonClient client, {AppPrefs? prefs}) => TranslateSource(
    client: client,
    disk: disk,
    index: TranslationIndexCache(prefs ?? AppPrefs.inMemory()),
  );

  test('认到歌 → 取 tlyric → ok，source 是「网易云译文库（人工翻译）」', () async {
    final client = FakeNetEase(
      search: {'The Beatles Yesterday': [songJson()]},
      lyric: {1: {'lrc': {'lyric': '[00:01]Yesterday'}, 'tlyric': {'lyric': '[00:01]昨天'}}},
    );
    final result = await sourceWith(client).fetch(title: 'Yesterday', artist: 'The Beatles', duration: 125);
    expect(result.status, 'ok');
    expect(result.translatedLyrics, '[00:01]昨天');
    expect(result.originalLyrics, '[00:01]Yesterday');
    expect(result.source, '网易云译文库（人工翻译）');
  });

  test('关键词是「歌手 曲名」，歌手在前', () async {
    final client = FakeNetEase(search: {'The Beatles Yesterday': [songJson()]});
    await sourceWith(client).fetch(title: 'Yesterday', artist: 'The Beatles', duration: 125);
    final search = client.calls.firstWhere((u) => u.path.endsWith('/search/get'));
    expect(search.queryParameters['s'], 'The Beatles Yesterday');
    expect(search.queryParameters['type'], '1');
    expect(search.queryParameters['limit'], '20');
  });

  test('占位歌手（含大小写差异）不参与关键词', () async {
    // parity 校正（2026-11-10）：原稿只给 search 不给 lyric，「status 是 ok」
    // 在正确实现上必红（空 tlyric → not-found）。补上译文响应，其余一字不动。
    final client = FakeNetEase(
      search: {'Yesterday': [songJson()]},
      lyric: {1: {'tlyric': {'lyric': '[00:01]昨天'}}},
    );
    final result = await sourceWith(client).fetch(title: 'Yesterday', artist: 'Unknown', duration: 125);
    expect(result.status, 'ok');
  });

  test('tlyric 缺失 / 空白 → not-found + no-translation', () async {
    final client = FakeNetEase(
      search: {'The Beatles Yesterday': [songJson()]},
      lyric: {1: {'lrc': {'lyric': '[00:01]Yesterday'}, 'tlyric': {'lyric': '  '}}},
    );
    final result = await sourceWith(client).fetch(title: 'Yesterday', artist: 'The Beatles', duration: 125);
    expect(result.status, 'not-found');
    expect(result.reason, 'no-translation');
  });

  test('lrc.lyric 为空不影响 ok', () async {
    final client = FakeNetEase(
      search: {'The Beatles Yesterday': [songJson()]},
      lyric: {1: {'tlyric': {'lyric': '[00:01]昨天'}}},
    );
    final result = await sourceWith(client).fetch(title: 'Yesterday', artist: 'The Beatles', duration: 125);
    expect(result.status, 'ok');
    expect(result.originalLyrics, '');
  });

  test('所有候选都搜不到 → not-found + song-not-matched', () async {
    final client = FakeNetEase();
    final result = await sourceWith(client).fetch(title: 'Yesterday', artist: 'The Beatles', duration: 125);
    expect(result.status, 'not-found');
    expect(result.reason, 'song-not-matched');
    // 原方向 + 对调方向 + 只搜歌名（去重后追加，可能重复一次）
    expect(client.calls.length, greaterThanOrEqualTo(2));
  });

  test('某次搜索抛错但后一个候选命中 → 仍成功', () async {
    var call = 0;
    // parity 校正（2026-11-10）：原稿只给 search 不给 lyric，命中歌后取 tlyric
    // 是空表 → not-found + no-translation，「status 是 ok」在正确实现上必红。
    // 补上译文响应，其余一字不动。
    final client = FakeNetEase(
      search: {'Yesterday': [songJson()]},
      lyric: {1: {'tlyric': {'lyric': '[00:01]昨天'}}},
    );
    final flaky = _FlakyClient((url) {
      call += 1;
      if (call == 1) return const JsonStatus(500);
      return client.getJson(url, timeout: const Duration(seconds: 1), headers: const {});
    });
    final result = await TranslateSource(client: flaky, disk: disk, index: TranslationIndexCache(AppPrefs.inMemory()))
        .fetch(title: 'Yesterday', artist: 'The Beatles', duration: 125);
    expect(result.status, 'ok');
  });

  test('全部候选都抛错 → error，reason 是四类之一，且不写缓存', () async {
    final prefs = AppPrefs.inMemory();
    final client = _FlakyClient((_) => const JsonStatus(500));
    final result = await TranslateSource(client: client, disk: disk, index: TranslationIndexCache(prefs))
        .fetch(title: 'Yesterday', artist: 'The Beatles', duration: 125);
    expect(result.status, 'error');
    expect(result.reason, 'upstream');
    expect(result.message, '服务暂时不可用（HTTP 500）');
    expect(await prefs.readString(TranslationIndexCache.prefsKey), isNull);
  });

  test('trackName 为空 → empty-query，不发请求', () async {
    final client = FakeNetEase();
    final result = await sourceWith(client).fetch(title: '   ', artist: '', duration: 0);
    expect(result.status, 'empty-query');
    expect(client.calls, isEmpty);
  });

  test('缓存命中直接返回；useCache:false 跳过读但仍写', () async {
    final prefs = AppPrefs.inMemory();
    final client = FakeNetEase(
      search: {'The Beatles Yesterday': [songJson()]},
      lyric: {1: {'tlyric': {'lyric': '[00:01]昨天'}}},
    );
    final source = sourceWith(client, prefs: prefs);
    await source.fetch(title: 'Yesterday', artist: 'The Beatles', duration: 125);
    final callsAfterFirst = client.calls.length;
    await source.fetch(title: 'Yesterday', artist: 'The Beatles', duration: 125);
    expect(client.calls.length, callsAfterFirst);
    await source.fetch(title: 'Yesterday', artist: 'The Beatles', duration: 125, useCache: false);
    expect(client.calls.length, greaterThan(callsAfterFirst));
  });

  test('上游抛错时回退过期磁盘缓存，source 追加「（离线缓存）」', () async {
    final client = FakeNetEase(
      search: {'The Beatles Yesterday': [songJson()]},
      lyric: {1: {'tlyric': {'lyric': '[00:01]昨天'}}},
    );
    await sourceWith(client).fetch(title: 'Yesterday', artist: 'The Beatles', duration: 125);
    final key = TranslationDiskCache.keyFor(title: 'Yesterday', artist: 'The Beatles', duration: 125);
    File('${dir.path}/$key.json').setLastModifiedSync(DateTime.now().subtract(const Duration(days: 400)));

    final failing = _FlakyClient((_) => const JsonTimeout());
    final result = await TranslateSource(client: failing, disk: disk, index: TranslationIndexCache(AppPrefs.inMemory()))
        .fetch(title: 'Yesterday', artist: 'The Beatles', duration: 125);
    expect(result.status, 'ok');
    expect(result.translatedLyrics, '[00:01]昨天');
    expect(result.source, '网易云译文库（人工翻译）（离线缓存）');
  });

  test('取消 → 抛 RequestAborted', () async {
    final token = CancelToken()..cancel();
    final client = FakeNetEase(search: {'The Beatles Yesterday': [songJson()]});
    await expectLater(
      sourceWith(client).fetch(title: 'Yesterday', artist: 'The Beatles', duration: 125, cancel: token),
      throwsA(isA<RequestAborted>()),
    );
  });
}

class _FlakyClient implements HttpJsonClient {
  _FlakyClient(this.handler);
  // parity 校正（2026-11-10）：原写 `Future<JsonOutcome> Function(Uri url)`，
  // 但三处用例分别返回同步的 `JsonStatus(500)` / `JsonTimeout()` / 一个 Future，
  // 同步那两处与 `Future<JsonOutcome>` 不兼容，编译期就挂。改 FutureOr：
  // 三种写法都能原样保留，`Future.sync` 顺带把同步返回归一成 Future。
  final FutureOr<JsonOutcome> Function(Uri url) handler;
  @override
  Future<JsonOutcome> getJson(Uri url, {required Duration timeout, required Map<String, String> headers}) => Future.sync(() => handler(url));
}
```

> 上面 `test('''` 那一段是嵌套引号写错了。真实写法直接用三引号：`test('trackName 为空 → empty-query，不发请求', () async { ... });`。执行时按这个改。

- [ ] **Step 4: 跑用例确认失败**

```bash
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter test test/lyrics/translate_source_test.dart
```
Expected: FAIL —— URI 不存在。

- [ ] **Step 5: 实现 `lib/lyrics/translate_source.dart`**

```dart
const String _searchUrl = 'https://music.163.com/api/search/get';
const String _lyricUrl = 'https://music.163.com/api/song/lyric';
const Duration _stepTimeout = Duration(seconds: 8);
const Duration _totalBudget = Duration(seconds: 45);
const Map<String, String> _headers = {
  'Accept': 'application/json',
  'User-Agent': 'light-music-react/1.0 (+vite dev middleware)',
};
```

流程按上面的契约。几处实现细节：

- 每次 `requestJsonProxyPolicy` 都要传 `cancel`；取消时它抛 `RequestAborted`，**一路冒到 `fetch` 外**（用例就是这么断言的）。
- 总预算用 `_withinBudget` 包住整段候选循环；超时抛 `UpstreamFailure(UpstreamReason.timeout, '连接译文库超时（本机到该站点较慢，稍等会自动重试）')`。
- 搜索抛错要区分：`UpstreamFailure` → 收进 `failures` 并继续；`RequestAborted` → 直接 rethrow。
- 读 `tlyric`：`data is Map && data['tlyric'] is Map && ...['lyric'] is String` 才取值，否则 ''。
- 缓存：成功 / `not-found` 写索引与磁盘；磁盘 key 用 **normalizeQuery 之后**的 `trackName / artistName / duration`。
- stale：`disk.read(key, allowStale: true)`，命中时 `source = '${record.source}（离线缓存）'`。

- [ ] **Step 6: 跑用例确认通过 + 静态检查**

```bash
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter test test/lyrics/translate_cache_test.dart test/lyrics/translate_source_test.dart
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter analyze
```
Expected: PASS；`No issues found!`

- [ ] **Step 7: 提交**

```bash
git add flutter-app/lib/lyrics/translate_cache.dart flutter-app/lib/lyrics/translate_source.dart flutter-app/test/lyrics/translate_cache_test.dart flutter-app/test/lyrics/translate_source_test.dart
git commit -m "feat(lyrics): 网易云译文源与双层缓存，直连不带 Referer"
```

---

## Task 12: 手动 `.lrc` 导入与配对

**Files:**
- Create: `flutter-app/lib/lyrics/manual_lyrics.dart`
- Modify: `flutter-app/lib/playback/play_error.dart`（只加常量，不动音频白名单）
- Modify: `flutter-app/lib/core/file_picking.dart`（选择器允许 `.lrc`）
- Modify: `flutter-app/lib/library/import_service.dart`（`importPaths` 先分流 `.lrc`）
- Modify: `flutter-app/lib/state/library_state.dart`（`applyLyricsFiles` + 落库）
- Test: `flutter-app/test/lyrics/manual_lyrics_test.dart`
- Test: `flutter-app/test/library/import_service_test.dart`（追加用例）

**Interfaces:**
- Consumes: T2 `parseLrc`；T3 `splitArtistTitleOrNull`；`Playlist` / `Track`；`ToastSink`
- Produces:
  ```dart
  const int kMaxLyricsBytes = 512 * 1024;
  const Set<String> kLyricsExtensions = {'lrc'};
  bool isLyricsExtension(String extension);   // 小写比较

  class LyricsFileRead {
    const LyricsFileRead({this.text = '', this.lineCount = 0, this.error = ''});
    final String text;
    final int lineCount;
    final String error;
    bool get isError => error.isNotEmpty;
  }

  /// 文件名 → 目标曲目（按可信度 50/45/40/30）。
  Track? matchLyricsTrack(String fileName, List<Track> tracks);

  Future<LyricsFileRead> readLyricsFile(String path, {required String displayName});

  class ManualLyrics {
    ManualLyrics({required this.playlist, required this.toasts});
    /// 返回 (matched, unmatched)。不落库——调用方（LibraryState）在整批结束后落一次。
    Future<({int matched, int unmatched})> apply(List<String> paths);
  }
  ```

**基准（`src/state/lyrics-file.ts` + `src/state/library.tsx:69-108`）：**

打分逐字：

```
base = normalizeName(stripExtension(fileName))
split = splitArtistTitle(stripExtension(fileName))
titleOnly = split ? normalizeName(split.title) : ''
artistOnly = split ? normalizeName(split.artist) : ''

for track:
  title = normalizeName(track.title)
  artist = normalizeName(track.artist)
  hasArtist = artist 非空 && artist != '本地文件' && artist != '未知歌手'
  score = 0
  if (title === base) score = 40
  if (hasArtist && normalizeName('${track.artist} - ${track.title}') === base) score = max(score, 50)
  if (titleOnly 非空 && title === titleOnly) score = max(score, (artistOnly 非空 && hasArtist && artist === artistOnly) ? 45 : 30)
  if (score > bestScore) { best = track; bestScore = score }
return bestScore > 0 ? best : null
```

`normalizeName` = `trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ')`。`stripExtension` = `dot > 0 ? substring(0, dot) : name`。

读取：`> 512KB` → `歌词文件过大，已跳过：<name>`；读失败 → `读取歌词失败：<name>`；`parseLrc(text)` 解析出 0 行 → `「<name>」里没有可识别的时间轴歌词，已跳过`。

配对失败：前 2 个各一条 `未找到与「<name>」同名的曲目，已拒绝替换`（info，6000ms），其余汇总 `另有 N 个歌词文件没有找到对应曲目`（info，6000ms）。**不挂到当前曲目。**

配对成功：`track.lyrics = text`、`lyricsPlain = ''`、`lyricsSource = 'manual'`，落库 + 刷新，提示 `已为「<title>」加载 N 行歌词`（是当前曲目）或 `已为「<title>」配好 N 行歌词，切到这首即可查看`（不是），都是 info 6000ms。

- [ ] **Step 1: 写失败用例**

创建 `flutter-app/test/lyrics/manual_lyrics_test.dart`：

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/lyrics/manual_lyrics.dart';
import 'package:light_music/playback/playlist.dart';
import 'package:light_music/playback/track.dart';
import 'package:light_music/playback/transport_controller.dart' show ToastSink;

class RecordingToasts implements ToastSink {
  final List<(String, int)> items = [];
  @override
  void show(String message, {String key = '', int durationMs = 3200}) => items.add((message, durationMs));
  @override
  void info(String message) => items.add((message, 3200));
  @override
  void error(String message) => items.add((message, 3200));
}

Track t(String id, {required String title, String artist = '', String src = ''}) =>
    Track(id: id, src: src.isEmpty ? '/m/$title.flac' : src, title: title, artist: artist, isLocal: true);

void main() {
  group('matchLyricsTrack', () {
    final tracks = [
      t('1', title: '十年', artist: '陈奕迅', src: '/m/陈奕迅 - 十年.flac'),
      t('2', title: '孤勇者', artist: '陈奕迅', src: '/m/孤勇者.flac'),
      t('3', title: 'Yesterday', artist: 'The Beatles', src: '/m/The Beatles - Yesterday.flac'),
    ];

    test('「歌手 - 歌名」组合名一致 → 50', () {
      expect(matchLyricsTrack('陈奕迅 - 十年.lrc', tracks)!.id, '1');
    });

    test('拆出歌名且歌手一致 → 45', () {
      // 文件名「陈奕迅 - 孤勇者」与 track 2 的组合名不同，但拆出的歌名与歌手都对
      final only = [t('2b', title: '孤勇者', artist: '陈奕迅', src: '/m/x.flac')];
      expect(matchLyricsTrack('陈奕迅 - 孤勇者.lrc', only)!.id, '2b');
    });

    test('曲名完全一致 → 40', () {
      expect(matchLyricsTrack('孤勇者.lrc', tracks)!.id, '2');
    });

    test('只有拆出的歌名一致 → 30', () {
      expect(matchLyricsTrack('别人 - 十年.lrc', tracks)!.id, '1');
    });

    test('对不上 → null（不兜底到任何曲目）', () {
      expect(matchLyricsTrack('完全不存在的歌.lrc', tracks), isNull);
    });

    test('空文件名 → null', () {
      expect(matchLyricsTrack('.lrc', tracks), isNull);
    });

    test('同分取靠前的', () {
      final dup = [t('a', title: '十年'), t('b', title: '十年')];
      expect(matchLyricsTrack('十年.lrc', dup)!.id, 'a');
    });

    test('占位歌手不算 real artist，拿不到 50 分', () {
      // parity 校正（2026-11-09，rev-t12 用 node 逐字复现 lyrics-file.ts:17-76）：
      // 计划原写 `matchLyricsTrack('本地文件 - 十年.lrc', [p])` 为 isNull 是错的 ——
      // 拆出 titleOnly='十年' 与 p 的 title 相同 → 30 分 → **返回 p**。
      // 改成鉴别性写法：加一首整串同名 q（40 分），占位歌手只能拿 30 分，
      // 于是 40 压过 30、真正钉住「占位歌手不拿 50」的原意。
      final ph = [
        t('p', title: '十年', artist: '本地文件', src: '/m/x.flac'),
        t('q', title: '本地文件 - 十年', src: '/m/q.flac'),
      ];
      expect(matchLyricsTrack('本地文件 - 十年.lrc', ph)!.id, 'q');
      expect(matchLyricsTrack('十年.lrc', ph)!.id, 'p');
    });

    test('大小写与多余空白不影响', () {
      expect(matchLyricsTrack('the   beatles - yesterday.LRC', tracks)!.id, '3');
    });
  });

  group('readLyricsFile', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('lrc-'));
    tearDown(() => dir.delete(recursive: true));

    test('正常 LRC 返回文本与行数', () async {
      final file = File('${dir.path}/a.lrc')..writeAsStringSync('[00:01]甲\n[00:02]乙');
      final read = await readLyricsFile(file.path, displayName: 'a.lrc');
      expect(read.isError, isFalse);
      expect(read.lineCount, 2);
      expect(read.text, '[00:01]甲\n[00:02]乙');
    });

    test('没有时间轴 → 拒绝', () async {
      final file = File('${dir.path}/a.lrc')..writeAsStringSync('一行没有时间轴的歌词');
      final read = await readLyricsFile(file.path, displayName: 'a.lrc');
      expect(read.error, '「a.lrc」里没有可识别的时间轴歌词，已跳过');
    });

    test('超过 512KB → 拒绝', () async {
      final file = File('${dir.path}/big.lrc')..writeAsStringSync('x' * (kMaxLyricsBytes + 1));
      final read = await readLyricsFile(file.path, displayName: 'big.lrc');
      expect(read.error, '歌词文件过大，已跳过：big.lrc');
    });

    test('读不了 → 拒绝', () async {
      final read = await readLyricsFile('${dir.path}/missing.lrc', displayName: 'missing.lrc');
      expect(read.error, '读取歌词失败：missing.lrc');
    });

    test('GBK 字节按 UTF-8 替换解码后多半没有时间轴 → 拒绝而不是抛', () async {
      final file = File('${dir.path}/gbk.lrc')
        ..writeAsBytesSync([0xB8, 0xE8, 0xB4, 0xCA]); // GBK「歌词」
      final read = await readLyricsFile(file.path, displayName: 'gbk.lrc');
      expect(read.isError, isTrue);
    });
  });

  group('apply', () {
    test('命中：写回活对象、标 manual、清 plain、提示 6000ms', () async {
      final playlist = Playlist(tracks: [t('1', title: '十年', artist: '陈奕迅', src: '/m/陈奕迅 - 十年.flac')]);
      final toasts = RecordingToasts();
      final manual = ManualLyrics(playlist: playlist, toasts: toasts);
      final dir = await Directory.systemTemp.createTemp('lrc-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/陈奕迅 - 十年.lrc')..writeAsStringSync('[00:01]甲\n[00:02]乙');

      final result = await manual.apply([file.path]);
      expect(result.matched, 1);
      expect(result.unmatched, 0);
      final track = playlist.byId('1')!;
      expect(track.lyrics, '[00:01]甲\n[00:02]乙');
      expect(track.lyricsPlain, '');
      expect(track.lyricsSource, 'manual');
      expect(toasts.items.last.$2, 6000);
      expect(toasts.items.last.$1, '已为「十年」配好 2 行歌词，切到这首即可查看');
    });

    test('当前曲目 → 「加载」文案', () async {
      final playlist = Playlist(tracks: [t('1', title: '十年', artist: '陈奕迅', src: '/m/陈奕迅 - 十年.flac')]);
      playlist.setCurrentById('1');
      final manual = ManualLyrics(playlist: playlist, toasts: RecordingToasts());
      final dir = await Directory.systemTemp.createTemp('lrc-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/陈奕迅 - 十年.lrc')..writeAsStringSync('[00:01]甲');

      await manual.apply([file.path]);
      expect(playlist.byId('1')!.lyrics, '[00:01]甲');
    });

    test('前 2 个对不上逐条提示，其余汇总，且不改任何曲目', () async {
      final playlist = Playlist(tracks: [t('1', title: '十年')]);
      final toasts = RecordingToasts();
      final manual = ManualLyrics(playlist: playlist, toasts: toasts);
      final dir = await Directory.systemTemp.createTemp('lrc-');
      addTearDown(() => dir.delete(recursive: true));
      final paths = <String>[];
      for (var i = 0; i < 4; i++) {
        final f = File('${dir.path}/不存在$i.lrc')..writeAsStringSync('[00:01]甲');
        paths.add(f.path);
      }

      final result = await manual.apply(paths);
      expect(result.unmatched, 4);
      expect(playlist.byId('1')!.lyrics, '');
      final messages = toasts.items.map((e) => e.$1).toList();
      expect(messages.where((m) => m.startsWith('未找到与')).length, 2);
      expect(messages.last, '另有 2 个歌词文件没有找到对应曲目');
    });

    test('坏文件不影响后面的好文件', () async {
      final playlist = Playlist(tracks: [
        t('1', title: '十年', artist: '陈奕迅', src: '/m/陈奕迅 - 十年.flac'),
        t('2', title: '孤勇者', artist: '陈奕迅', src: '/m/陈奕迅 - 孤勇者.flac'),
      ]);
      final manual = ManualLyrics(playlist: playlist, toasts: RecordingToasts());
      final dir = await Directory.systemTemp.createTemp('lrc-');
      addTearDown(() => dir.delete(recursive: true));
      final bad = File('${dir.path}/坏.lrc')..writeAsStringSync('没有时间轴');
      final good = File('${dir.path}/陈奕迅 - 孤勇者.lrc')..writeAsStringSync('[00:01]甲');

      final result = await manual.apply([bad.path, good.path]);
      expect(result.matched, 1);
      expect(playlist.byId('2')!.lyricsSource, 'manual');
    });
  });
}
```

- [ ] **Step 2: 跑用例确认失败**

```bash
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter test test/lyrics/manual_lyrics_test.dart
```
Expected: FAIL —— URI 不存在。

- [ ] **Step 3: 实现 `lib/lyrics/manual_lyrics.dart`**

```dart
Future<LyricsFileRead> readLyricsFile(String path, {required String displayName}) async {
  final file = File(path);
  try {
    final length = await file.length();
    if (length > kMaxLyricsBytes) return LyricsFileRead(error: '歌词文件过大，已跳过：$displayName');
    final bytes = await file.readAsBytes();
    // Blob.text() 等价：UTF-8 解码、坏字节替换，不抛
    final text = utf8.decode(bytes, allowMalformed: true);
    final parsed = parseLrc(text);
    if (parsed.lines.isEmpty) {
      return LyricsFileRead(error: '「$displayName」里没有可识别的时间轴歌词，已跳过');
    }
    return LyricsFileRead(text: text, lineCount: parsed.lines.length);
  } catch (_) {
    return LyricsFileRead(error: '读取歌词失败：$displayName');
  }
}
```

`ManualLyrics.apply`：逐条读、逐条配；成功就改活对象并发提示；结束时若 `unmatched > 2` 再发汇总。**注意提示的级别与时长**（React 三处分别是 error/6000、info/6000）：

- 读取/解析失败 → `toasts.error(msg, durationMs: 6000)`（error 色）
- 配对失败 → `toasts.show(msg, durationMs: 6000)`（文案不含「失败/不支持/无法」，自然落在 info 色）
- 汇总 → `toasts.show(msg, durationMs: 6000)`
- 成功 → `toasts.show(msg, durationMs: 6000)`

为此需要给提示接口加一个可选的时长参数（**本任务唯一的 API 变更**）：

1. `lib/playback/transport_controller.dart` 的 `abstract class ToastSink`：`void error(String message, {int durationMs = 3200});`
2. `lib/state/toast_state.dart` 的 `ToastState.error`：`void error(String message, {int durationMs = 3200}) => _emit(message, ToastKind.error, key: 'error:$message', durationMs: durationMs);`
3. 两个 `_SilentToasts`（`lib/state/library_state.dart:505`、`lib/state/player_state.dart:266`）与测试里的 `RecordingToasts` 同步加同名可选参数（实现体为空）。

这是纯追加的可选参数，既有调用点（`import_service.dart` 的 `toasts.error(...)`）一行都不用改。

- [ ] **Step 4: 接上白名单与选择器**

1. `lib/playback/play_error.dart` 追加（**不动** `kAudioExtensions`）：
   ```dart
   /// 歌词文件扩展名（spec §11 手动 .lrc）。只用于导入分流，不参与「能不能播」。
   const Set<String> kLyricsExtensions = {'lrc'};
   bool isLyricsExtension(String extension) => kLyricsExtensions.contains(extension.toLowerCase());
   ```
2. `lib/core/file_picking.dart`：`pickAudioFiles` 的 `allowedExtensions` 改成 `[...kAudioExtensions, ...kLyricsExtensions].toList()..sort()`。
3. `lib/library/import_service.dart` 的 `importPaths`：在 `partitionByExtension(paths)` **之前**把 `.lrc` 挑出来，走 `manualLyrics?.apply(lyricsPaths)`；其余照原流程。`ImportService` 新增可选构造参数 `ManualLyrics? manualLyrics`。**`.lrc` 不进 `ImportResult.rejected`**，也不进 `added`。
4. `lib/state/library_state.dart` 新增：
   ```dart
   Future<int> applyLyricsFiles(List<String> paths) async {
     final result = await importer.manualLyrics!.apply(paths);
     if (result.matched > 0) {
       await persist();
       _changed();
     }
     return result.matched;
   }
   ```
   注意 `apply` 内部每成功一条就 `await onChanged`（即 `persist + _changed`），与 React 在循环里 `refresh(); persist();` 同序。`applyLyricsFiles` 末尾再落一次是幂等的，但**不要**在 `apply` 里也调 `onChanged` 之后又在外层重复——选择一种：**`ManualLyrics` 不持有 `onChanged`，由 `LibraryState` 在 `apply` 返回后统一落库一次**。React 是每条落一次；Flutter 批量落一次更省盘且语义等价（同一批导入的结果一起可见）。**决定：批量一次**，并在 `apply` 的注释里写明这与 React 的差异（React 逐条 persist，Flutter 批量收尾；用户可见行为一致）。

- [ ] **Step 5: 追加导入分流用例**

在 `flutter-app/test/library/import_service_test.dart` 末尾追加：

```dart
test('同一个导入批次里的 .lrc 走手动歌词，不计入拒绝也不计入新增', () async {
  final playlist = Playlist(tracks: [
    Track(id: '1', src: '/m/陈奕迅 - 十年.flac', title: '十年', artist: '陈奕迅', isLocal: true),
  ]);
  final toasts = RecordingToasts();
  final dir = await Directory.systemTemp.createTemp('mix-');
  addTearDown(() => dir.delete(recursive: true));
  final audio = File('${dir.path}/陈奕迅 - 孤勇者.flac')..writeAsBytesSync(const []);
  final lrc = File('${dir.path}/陈奕迅 - 十年.lrc')..writeAsStringSync('[00:01]甲');

  final service = ImportService(
    playlist: playlist,
    toasts: toasts,
    manualLyrics: ManualLyrics(playlist: playlist, toasts: toasts),
  );
  final result = await service.importPaths([audio.path, lrc.path]);

  expect(result.rejected, 0);
  expect(playlist.byId('1')!.lyricsSource, 'manual');
  expect(playlist.byId('1')!.lyrics, '[00:01]甲');
});
```

> `RecordingToasts` 已在那个文件里定义过，直接复用。`import_service_test.dart` 的 `RecordingToasts` 若没有 `info` 方法，按 `ToastSink` 的实际接口补齐。

- [ ] **Step 6: 跑用例确认通过 + 静态检查**

```bash
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter test test/lyrics/manual_lyrics_test.dart test/library
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter analyze
```
Expected: PASS；`No issues found!`

- [ ] **Step 7: 提交**

```bash
git add flutter-app/lib/lyrics/manual_lyrics.dart flutter-app/lib/playback/play_error.dart flutter-app/lib/core/file_picking.dart flutter-app/lib/library/import_service.dart flutter-app/lib/state/library_state.dart flutter-app/test/lyrics/manual_lyrics_test.dart flutter-app/test/library/import_service_test.dart
git commit -m "feat(lyrics): 手动 .lrc 导入、可信度配对与批量落库"
```

---
## Task 13: 歌词状态机

**Files:**
- Create: `flutter-app/lib/state/lyrics_state.dart`
- Test: `flutter-app/test/state/lyrics_state_test.dart`

**Interfaces:**
- Consumes: T3 `normalizeQuery`；T2 `parseLrc` / `plainLyricLines`；T5 `toSimplified`；T8 `LyricsMatcher`；`Track`
- Produces:
  ```dart
  enum LyricsLoad { idle, loading, ready, missing, error }

  class LyricsState extends ChangeNotifier {
    LyricsState({
      required LyricsMatcher source,
      bool Function()? isOnline,
      Duration slowHintDelay = const Duration(seconds: 4),
      Duration autoRetryDelay = const Duration(seconds: 25),
      Future<void> Function(Duration)? delay,
      Future<void> Function()? onChanged,   // 匹配成功后由装配层落库
    });

    Track? get track;
    LyricsLoad get state;
    String get status;
    bool get showRetry;
    bool get isManual;
    List<LyricLine> get cues;          // 已转简体（manual 不转）
    String get plain;                  // 已转简体（manual 不转）
    List<String> get plainLines;
    List<LyricLine> get displayLines;  // cues 或纯文本行（time = NaN）
    String get lyricsText;             // 原始文本，判语种与指纹用
    bool get translatable;

    void attach(Track? track);   // 切歌入口（装配层在 view 变化时调用）
    void retry();
    Future<void> settle();       // 等当前这批异步收尾（测试用）
  }
  ```

**状态机逐字（`src/state/lyrics.tsx:303-470`）：**

| 条件（按顺序） | 结果 |
| --- | --- |
| `track == null` | `idle`，status `''`，showRetry false |
| `track.lyrics` 或 `track.lyricsPlain` 非空 | `ready`；status = manual ? `已使用手动指定的歌词` : (有 lyrics ? `歌词自动匹配自 LRCLIB线上库` : `歌词匹配自 LRCLIB线上库 · 原文无时间轴，仅静态显示`)；showRetry false。若「无 lyrics、有 plain、非 manual、本会话未升级过」→ 后台升级：先 `useCache:true` 匹配，拿不到带时间轴的结果就再 `useCache:false` 匹配一次；成功则 `lyrics=… / lyricsPlain='' / lyricsSource='auto'` + 落库 + 重算 |
| `!isOnline()` | `missing`，status `当前离线，且这首歌还没有歌词`，showRetry false |
| `track.isLocal && !track.duration.isFinite` | `loading`，status `正在读取音频信息…`，showRetry false |
| 其余 | `loading`，status `正在按曲名与歌手匹配歌词…`；4s 后（仍是最新请求）改 `正在匹配歌词…首次查询较慢，成功后会缓存在本地`；发起匹配 |
| → ok 且有 synced 或 plain | 若当前不是 manual 且两个字段都空 → 写入（synced 优先，否则 plain）+ `lyricsSource='auto'` + 落库；`ready`；status 按有/无 lyrics 二选一 |
| → not-found | `missing`，status `未找到「<title>」的歌词`，showRetry true |
| → aborted | 什么都不做 |
| → 其它 | `error`，status = message 或 `歌词匹配失败`；showRetry true；若 reason ∈ {timeout,unreachable,rate-limit,upstream} 或 message 命中 `/限流|超时|暂时不可用/`，且本会话未自动补过 → status 追加 `（25 秒后自动重试）`，25s 后若仍是最新请求则重跑一次 |

`retry()`：清掉该曲目的「已自动重试」「已升级」记录，置 `force` 标记，重跑。

**三处与 React 的差异（都是有意的，写进代码注释）：**
1. `isOnline` 在 Flutter 没有平台 API（不引依赖），默认恒 true；那条离线分支保留并可注入，生产上离线会走真实的 `unreachable` 错误。
2. React 在 effect 依赖里监听 `track.lyrics`，靠 `tick` 触发重跑；Dart 侧在写入活对象后直接重算并 `notifyListeners()`，等价。
3. React 的 `retryTimer` 是 `window.setTimeout`；Dart 用注入的 `delay`，默认 `Future.delayed`。

- [ ] **Step 1: 写失败用例**

创建 `flutter-app/test/state/lyrics_state_test.dart`：

```dart
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/lyrics/lrc_parser.dart';
import 'package:light_music/lyrics/lyrics_source.dart';
import 'package:light_music/lyrics/query.dart';
import 'package:light_music/lyrics/upstream.dart';
import 'package:light_music/playback/track.dart';
import 'package:light_music/state/lyrics_state.dart';

class FakeMatcher implements LyricsMatcher {
  final List<({LyricsQuery query, bool useCache})> calls = [];
  Future<LyricsMatch> Function(LyricsQuery query, bool useCache)? handler;

  @override
  Future<LyricsMatch> match(LyricsQuery query, {CancelToken? cancel, bool useCache = true}) {
    calls.add((query: query, useCache: useCache));
    return handler!(query, useCache);
  }
}

class FakeDelay {
  final List<(Duration, Completer<void>)> pending = [];
  Future<void> call(Duration d) {
    final c = Completer<void>();
    pending.add((d, c));
    return c.future;
  }

  void fire(Duration d) {
    for (final entry in pending.where((e) => e.$1 == d).toList()) {
      if (!entry.$2.isCompleted) entry.$2.complete();
    }
    pending.removeWhere((e) => e.$1 == d);
  }
}

Track track({
  String id = 't1',
  String title = 'Yesterday',
  String artist = 'The Beatles',
  double duration = 125,
  bool isLocal = true,
  String lyrics = '',
  String lyricsPlain = '',
  String lyricsSource = '',
}) => Track(
  id: id, src: '/m/$id.flac', title: title, artist: artist,
  duration: duration, isLocal: isLocal,
  lyrics: lyrics, lyricsPlain: lyricsPlain, lyricsSource: lyricsSource,
);

const okSynced = LyricsMatch(status: 'ok', synced: '[00:01]甲\n[00:05]乙', plain: '甲\n乙');

void main() {
  late FakeMatcher matcher;
  late FakeDelay delay;
  late int changed;

  setUp(() {
    matcher = FakeMatcher();
    delay = FakeDelay();
    changed = 0;
  });

  LyricsState build({bool online = true}) => LyricsState(
    source: matcher,
    isOnline: () => online,
    delay: delay.call,
    onChanged: () async => changed++,
  );

  test('无曲目 → idle，不联网', () async {
    final state = build()..attach(null);
    expect(state.state, LyricsLoad.idle);
    expect(state.status, '');
    expect(state.showRetry, isFalse);
    expect(matcher.calls, isEmpty);
  });

  test('手动歌词 → ready + 手动文案，不联网，且不转简体', () async {
    final t = track(lyrics: '[00:01]妳好', lyricsSource: 'manual');
    final state = build()..attach(t);
    expect(state.state, LyricsLoad.ready);
    expect(state.status, '已使用手动指定的歌词');
    expect(state.isManual, isTrue);
    expect(state.cues.single.text, '妳好');
    expect(matcher.calls, isEmpty);
  });

  test('自动匹配的歌词 → ready，且显示时转简体', () async {
    final t = track(lyrics: '[00:01]妳好', lyricsSource: 'auto');
    final state = build()..attach(t);
    expect(state.status, '歌词自动匹配自 LRCLIB线上库');
    expect(state.cues.single.text, '你好');
    expect(matcher.calls, isEmpty);
  });

  test('纯文本歌词 → ready + 静态说明；displayLines 长度与行数一致', () async {
    final t = track(lyricsPlain: '甲\n乙', lyricsSource: 'auto');
    final state = build()..attach(t);
    expect(state.status, '歌词匹配自 LRCLIB线上库 · 原文无时间轴，仅静态显示');
    expect(state.displayLines.length, 2);
    expect(state.displayLines.first.time.isNaN, isTrue);
  });

  test('纯文本后台升级：先查缓存，再绕过缓存问一次，成功后替换并清 plain', () async {
    final t = track(lyricsPlain: '甲', lyricsSource: 'auto');
    matcher.handler = (q, useCache) async => useCache
        ? const LyricsMatch(status: 'not-found')
        : okSynced;
    final state = build()..attach(t);
    await state.settle();
    expect(matcher.calls.length, 2);
    expect(matcher.calls.first.useCache, isTrue);
    expect(matcher.calls.last.useCache, isFalse);
    expect(t.lyrics, '[00:01]甲\n[00:05]乙');
    expect(t.lyricsPlain, '');
    expect(t.lyricsSource, 'auto');
    expect(state.status, '歌词自动匹配自 LRCLIB线上库');
    expect(changed, 1);
  });

  test('纯文本升级每首每会话只试一次', () async {
    final t = track(lyricsPlain: '甲', lyricsSource: 'auto');
    matcher.handler = (q, useCache) async => const LyricsMatch(status: 'not-found');
    final state = build()..attach(t);
    await state.settle();
    final afterFirst = matcher.calls.length;
    state.attach(t); // 同一个对象再来一次（真实装配里会重复触发）
    await state.settle();
    expect(matcher.calls.length, afterFirst);
  });

  test('本地曲目时长未知 → 先等元数据，不联网', () async {
    final state = build()..attach(track(duration: double.nan));
    expect(state.state, LyricsLoad.loading);
    expect(state.status, '正在读取音频信息…');
    expect(matcher.calls, isEmpty);
  });

  test('离线且无歌词 → missing + 离线文案', () async {
    final state = build(online: false)..attach(track());
    expect(state.state, LyricsLoad.missing);
    expect(state.status, '当前离线，且这首歌还没有歌词');
  });

  test('匹配成功 → 写回活对象、标 auto、ready、落库一次', () async {
    final t = track();
    matcher.handler = (q, useCache) async => okSynced;
    final state = build()..attach(t);
    expect(state.state, LyricsLoad.loading);
    expect(state.status, '正在按曲名与歌手匹配歌词…');
    await state.settle();
    expect(t.lyrics, '[00:01]甲\n[00:05]乙');
    expect(t.lyricsSource, 'auto');
    expect(state.state, LyricsLoad.ready);
    expect(state.status, '歌词自动匹配自 LRCLIB线上库');
    expect(state.showRetry, isFalse);
    expect(changed, 1);
    expect(matcher.calls.single.useCache, isTrue);
  });

  test('只拿到纯文本 → 写 lyricsPlain，状态是静态说明', () async {
    final t = track();
    matcher.handler = (q, useCache) async => const LyricsMatch(status: 'ok', plain: '甲\n乙');
    final state = build()..attach(t);
    await state.settle();
    expect(t.lyrics, '');
    expect(t.lyricsPlain, '甲\n乙');
    expect(state.status, '歌词匹配自 LRCLIB线上库 · 原文无时间轴，仅静态显示');
  });

  test('未找到 → missing + 带曲名的文案 + 显示重试', () async {
    final state = build()..attach(track(title: 'Yesterday'));
    matcher.handler = (q, useCache) async => const LyricsMatch(status: 'not-found');
    await state.settle();
    expect(state.state, LyricsLoad.missing);
    expect(state.status, '未找到「Yesterday」的歌词');
    expect(state.showRetry, isTrue);
  });

  test('超时错误 → error + 自动重试文案，25s 后重跑一次', () async {
    var attempt = 0;
    matcher.handler = (q, useCache) async {
      attempt += 1;
      return attempt == 1
          ? const LyricsMatch(status: 'error', reason: UpstreamReason.timeout, message: '连接歌词库超时（本机到该站点较慢，稍等会自动重试）')
          : okSynced;
    };
    final t = track();
    final state = build()..attach(t);
    await state.settle();
    expect(state.state, LyricsLoad.error);
    expect(state.status, '连接歌词库超时（本机到该站点较慢，稍等会自动重试）（25 秒后自动重试）');
    expect(state.showRetry, isTrue);
    await delay.fire(const Duration(seconds: 25));
    await state.settle();
    expect(attempt, 2);
    expect(state.state, LyricsLoad.ready);
  });

  test('自动重试每首只补一次：第二次仍失败则不再排', () async {
    matcher.handler = (q, useCache) async => const LyricsMatch(
      status: 'error', reason: UpstreamReason.unreachable, message: '连不上歌词服务，请检查网络或代理设置',
    );
    final state = build()..attach(track());
    await state.settle();
    expect(state.status, endsWith('（25 秒后自动重试）'));
    await delay.fire(const Duration(seconds: 25));
    await state.settle();
    expect(state.status.endsWith('（25 秒后自动重试）'), isFalse);
    expect(matcher.calls.length, 2);
  });

  test('message 命中「限流」也能触发自动重试（reason 缺失时）', () async {
    matcher.handler = (q, useCache) async => const LyricsMatch(status: 'error', message: '歌词服务正在限流，请稍后点「重试」');
    final state = build()..attach(track());
    await state.settle();
    expect(state.status, endsWith('（25 秒后自动重试）'));
  });

  test('retry() 绕过缓存并允许再自动补一次', () async {
    matcher.handler = (q, useCache) async => const LyricsMatch(status: 'error', reason: UpstreamReason.timeout, message: '超时');
    final state = build()..attach(track());
    await state.settle();
    state.retry();
    await state.settle();
    expect(matcher.calls.last.useCache, isFalse);
  });

  test('切歌丢弃旧结果（旧请求晚到也不写新曲目）', () async {
    final first = Completer<LyricsMatch>();
    final t1 = track(id: 'a');
    final t2 = track(id: 'b');
    matcher.handler = (q, useCache) => first.future;
    final state = build()..attach(t1);
    state.attach(t2);
    first.complete(okSynced);
    await state.settle();
    expect(t1.lyrics, '');
  });

  test('4 秒慢提示只对最新请求生效', () async {
    final completer = Completer<LyricsMatch>();
    matcher.handler = (q, useCache) => completer.future;
    final state = build()..attach(track());
    await delay.fire(const Duration(seconds: 4));
    await Future<void>.delayed(Duration.zero);
    expect(state.status, '正在匹配歌词…首次查询较慢，成功后会缓存在本地');
    completer.complete(okSynced);
    await state.settle();
    expect(state.status, '歌词自动匹配自 LRCLIB线上库');
  });

  test('translatable：非中文且 displayLines 非空才为真', () async {
    final zh = build()..attach(track(lyrics: '[00:01]我们一起看月亮'));
    expect(zh.translatable, isFalse);
    final en = build()..attach(track(lyrics: '[00:01]Hello darkness'));
    expect(en.translatable, isTrue);
    final empty = build()..attach(track());
    expect(empty.translatable, isFalse);
  });
}
```

- [ ] **Step 2: 跑用例确认失败**

```bash
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter test test/state/lyrics_state_test.dart
```
Expected: FAIL —— URI 不存在。

- [ ] **Step 3: 实现 `lib/state/lyrics_state.dart`**

实现要点（逐条对应上表）：

- 每次 `attach` / `retry` / 定时回调都 `_generation++`；异步结果回来先比代数，不等就直接丢弃。
- 每次重跑前 `_cancel?.cancel()` 并新建 `CancelToken`，取消旧请求。
- `_recomputeLyrics()`：算 `_cues` / `_plain` / `_plainLines` / `_displayLines` / `_lyricsText` / `_translatable`，**只在 attach 与写回后调用**，不放进 getter（`toSimplified` 有缓存但 `parseLrc` 不便宜）。
- `attach` 的幂等键：`'${track.id}|${track.lyrics}|${track.lyricsPlain}|${track.lyricsSource}'` + 对象同一性。相同就 return（真实装配里 view 每次变化都会调 attach）。
- 写回活对象后同步更新幂等键，避免下一次 attach 误判成「歌词变了」而重跑。
- `settle()` 返回 `_pending ?? Future.value()`；`_pending` 是本次 `_run()` 的 Future，内部所有 await 都链在它上面（慢提示与自动重试是 detached 的，不进 `_pending`）。
- `dispose()` 里 `_cancel?.cancel()`、清掉注入的延时（`FakeDelay` 里未完成的 Completer 不必清，真实实现是 `Future.delayed` 无法取消，靠代数丢弃）。
- 慢提示与自动重试都用 `delay(...)`，**不要**直接 `Future.delayed`，否则测试跑 29 秒。

- [ ] **Step 4: 跑用例确认通过 + 静态检查**

```bash
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter test test/state/lyrics_state_test.dart
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter analyze
```
Expected: PASS；`No issues found!`

- [ ] **Step 5: 提交**

```bash
git add flutter-app/lib/state/lyrics_state.dart flutter-app/test/state/lyrics_state_test.dart
git commit -m "feat(lyrics): 歌词状态机，含纯文本升级、慢提示与一次性自动重试"
```

---

## Task 14: 双语状态机（三条生命周期规则）

**Files:**
- Create: `flutter-app/lib/state/bilingual_state.dart`
- Test: `flutter-app/test/state/bilingual_state_test.dart`

**Interfaces:**
- Consumes: T9 `alignTranslation`；T11 `TranslationFetcher` / `TranslationResult`；T13 `LyricsState`；`AppPrefs`
- Produces:
  ```dart
  enum TranslationState { idle, loading, ready, none, unavailable, error, off }

  class BilingualState extends ChangeNotifier {
    BilingualState({
      required LyricsState lyrics,
      required TranslationFetcher source,
      bool enabled = true,
      void Function(bool value)? persistEnabled,
    });

    bool get enabled;
    TranslationState get state;
    String get note;            // 状态行 / tooltip 文案
    List<String> get trans;     // 长度 == lyrics.displayLines.length
    bool get translatable;      // 转发 lyrics.translatable

    void setEnabled(bool value);
    Future<void> settle();
  }
  ```

**三条规则（spec §11，逐字）+ 状态机细节（`src/state/lyrics.tsx:185-278`）：**

1. **关掉只停显示、不丢数据**：`enabled=false` → `state = off`，`translation` 与 `reason` 原样保留；再打开立刻恢复显示，不重新等网络。
2. **换歌才清**：手上这份译文记着归属曲目 id；id 变了才清（并清归属）；同一首歌只是歌词文本升级（纯文本 → 带时间轴）要沿用。曲目为空或 `!translatable` 时一并清。
3. **重开是「先显示、后台刷新」**：`setEnabled(true)` 置 `force`；有缓存就先把旧译文摆出来、状态照旧，同时带 `useCache:false` 在后台再问一次；**后台刷新失败或查不到都不覆盖手上这份**，状态保持 `ready`。没有缓存才进 `loading`。结论写缓存的分寸：`none` / `unavailable` 记（短期不再问），网络类 `error` 不记。

其余：
- 会话缓存 key = `'${track.id}|${fingerprint(lyricsText)}'`，`fingerprint(text) = '${text.length}:${text.substring(0, min(24, len))}:${text.substring(max(0, len - 24))}'`。命中项连「没有译文」这个结论一起记。
- 缓存命中时的恢复：`translation`、`state`、`reason` 三者都还原；没有 `force` 就直接返回（**不打网络**）。
- `trans`：`!enabled || translation == null || displayLines.isEmpty` → 全空串；否则 `alignTranslation(displayLines, translatedLrc, originalLrc)`。
- `note`（逐字）：loading `正在匹配中文译文…`；none + `song-not-matched` `译文库没匹配到这首歌（曲名/歌手对不上）`；none + `no-translation` `这首歌还没有中文译文`；none 其它 `译文库里没有这首歌的中文译文`；unavailable `中文译文需要本地代理服务（npm run dev）`；error `中文译文获取失败，关掉再打开「双语」可重试`；其它 `''`。
- 开关的 `title`（tooltip）另有四档，见 T16；本任务只产出 `note`。

- [ ] **Step 1: 写失败用例**

创建 `flutter-app/test/state/bilingual_state_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/lyrics/lyrics_source.dart';
import 'package:light_music/lyrics/query.dart';
import 'package:light_music/lyrics/translate_source.dart';
import 'package:light_music/lyrics/upstream.dart';
import 'package:light_music/playback/track.dart';
import 'package:light_music/state/bilingual_state.dart';
import 'package:light_music/state/lyrics_state.dart';

class FakeMatcher implements LyricsMatcher {
  LyricsMatch result = const LyricsMatch(status: 'not-found');
  @override
  Future<LyricsMatch> match(LyricsQuery query, {CancelToken? cancel, bool useCache = true}) async => result;
}

class FakeFetcher implements TranslationFetcher {
  final List<bool> useCacheCalls = [];
  Future<TranslationResult> Function(bool useCache)? handler;
  int calls = 0;

  @override
  Future<TranslationResult> fetch({
    required String title,
    required String artist,
    required double duration,
    CancelToken? cancel,
    bool useCache = true,
  }) {
    calls += 1;
    useCacheCalls.add(useCache);
    return handler!(useCache);
  }
}

Track track({String id = 't1', String lyrics = '[00:01]Hello\n[00:05]Darkness'}) => Track(
  id: id, src: '/m/$id.flac', title: 'Yesterday', artist: 'The Beatles',
  duration: 125, isLocal: true, lyrics: lyrics, lyricsSource: 'auto',
);

const okTranslation = TranslationResult(
  status: 'ok',
  translatedLyrics: '[00:01]你好\n[00:05]黑暗',
  originalLyrics: '[00:01]Hello\n[00:05]Darkness',
  source: '网易云译文库（人工翻译）',
);

void main() {
  late FakeMatcher matcher;
  late FakeFetcher fetcher;
  late LyricsState lyrics;
  late List<bool> persisted;

  setUp(() {
    matcher = FakeMatcher();
    fetcher = FakeFetcher()..handler = (_) async => okTranslation;
    persisted = [];
    lyrics = LyricsState(source: matcher);
  });

  BilingualState build({bool enabled = true}) => BilingualState(
    lyrics: lyrics,
    source: fetcher,
    enabled: enabled,
    persistEnabled: persisted.add,
  );

  test('非中文歌词 → translatable 为真，自动取译文并对齐', () async {
    final t = track();
    lyrics.attach(t);
    final state = build();
    await state.settle();
    expect(state.translatable, isTrue);
    expect(state.state, TranslationState.ready);
    expect(state.trans, ['你好', '黑暗']);
  });

  test('中文歌词 → 不请求，trans 全空', () async {
    lyrics.attach(track(lyrics: '[00:01]我们一起看月亮'));
    final state = build();
    await state.settle();
    expect(state.translatable, isFalse);
    expect(fetcher.calls, 0);
    expect(state.state, TranslationState.idle);
  });

  test('规则 1：关掉只停显示，数据还在；再打开立刻恢复且不打网络', () async {
    lyrics.attach(track());
    final state = build();
    await state.settle();
    expect(state.trans.first, '你好');

    state.setEnabled(false);
    expect(state.state, TranslationState.off);
    expect(state.trans, ['', '']);
    expect(persisted.last, isFalse);

    final callsBefore = fetcher.calls;
    state.setEnabled(true);
    // 立刻恢复（同一帧），不需要等网络
    expect(state.trans.first, '你好');
    await state.settle();
    // 规则 3：重开会在后台刷新一次（useCache:false）
    expect(fetcher.calls, greaterThan(callsBefore));
    expect(fetcher.useCacheCalls.last, isFalse);
    expect(state.state, TranslationState.ready);
  });

  test('规则 2：换歌清掉上一首的译文', () async {
    final t1 = track(id: 'a');
    lyrics.attach(t1);
    final state = build();
    await state.settle();
    expect(state.trans.first, '你好');

    lyrics.attach(track(id: 'b', lyrics: '[00:01]Another\n[00:05]Song'));
    await state.settle();
    // 新歌的译文由 fake 返回同一份，但对齐用的是新行 → 仍应重算
    expect(state.trans.length, 2);
  });

  test('规则 2 续：同一首歌歌词从纯文本升级成带时间轴时沿用译文', () async {
    final t = track(lyrics: '[00:01]Hello\n[00:05]Darkness');
    lyrics.attach(t);
    final state = build();
    await state.settle();
    final callsBefore = fetcher.calls;

    t.lyrics = '[00:01]Hello\n[00:03]Darkness'; // 文本变了 → 指纹变 → 会再问一次（符合 React）
    lyrics.attach(t);
    await state.settle();
    expect(fetcher.calls, greaterThan(callsBefore));
  });

  test('规则 3：后台刷新失败不覆盖手上这份', () async {
    lyrics.attach(track());
    final state = build();
    await state.settle();
    expect(state.trans.first, '你好');

    var call = 0;
    fetcher.handler = (useCache) async {
      call += 1;
      return call == 1 ? okTranslation : const TranslationResult(status: 'error', reason: 'timeout', message: '超时');
    };
    state.setEnabled(false);
    state.setEnabled(true);
    await state.settle();
    expect(state.state, TranslationState.ready);
    expect(state.trans.first, '你好');
    expect(state.note, '');
  });

  test('规则 3：后台刷新查不到（not-found）同样不覆盖', () async {
    lyrics.attach(track());
    final state = build();
    await state.settle();
    var call = 0;
    fetcher.handler = (useCache) async {
      call += 1;
      return call == 1 ? okTranslation : const TranslationResult(status: 'not-found', reason: 'no-translation');
    };
    state.setEnabled(false);
    state.setEnabled(true);
    await state.settle();
    expect(state.state, TranslationState.ready);
    expect(state.trans.first, '你好');
  });

  test('没有译文：not-found + song-not-matched → none + 对应文案', () async {
    fetcher.handler = (_) async => const TranslationResult(status: 'not-found', reason: 'song-not-matched');
    lyrics.attach(track());
    final state = build();
    await state.settle();
    expect(state.state, TranslationState.none);
    expect(state.note, '译文库没匹配到这首歌（曲名/歌手对不上）');
  });

  test('没有译文：no-translation → 另一句文案', () async {
    fetcher.handler = (_) async => const TranslationResult(status: 'not-found', reason: 'no-translation');
    lyrics.attach(track());
    final state = build();
    await state.settle();
    expect(state.note, '这首歌还没有中文译文');
  });

  test('网络失败 → error + 文案，且结论不进会话缓存（再打开会重试）', () async {
    fetcher.handler = (_) async => const TranslationResult(status: 'error', reason: 'timeout', message: '超时');
    lyrics.attach(track());
    final state = build();
    await state.settle();
    expect(state.state, TranslationState.error);
    expect(state.note, '中文译文获取失败，关掉再打开「双语」可重试');
    final callsBefore = fetcher.calls;
    state.setEnabled(false);
    state.setEnabled(true);
    await state.settle();
    expect(fetcher.calls, greaterThan(callsBefore));
  });

  test('none 结论进会话缓存：关掉再开不重复问（除非 force）', () async {
    fetcher.handler = (_) async => const TranslationResult(status: 'not-found', reason: 'no-translation');
    lyrics.attach(track());
    final state = build();
    await state.settle();
    final callsBefore = fetcher.calls;
    // 同一首歌重新 attach（模拟 view 抖动），不应重复请求
    lyrics.attach(track());
    await state.settle();
    expect(fetcher.calls, callsBefore);
  });

  test('loading 文案', () async {
    final completer = Completer<TranslationResult>();
    fetcher.handler = (_) => completer.future;
    lyrics.attach(track());
    final state = build();
    expect(state.state, TranslationState.loading);
    expect(state.note, '正在匹配中文译文…');
    completer.complete(okTranslation);
    await state.settle();
  });

  test('enabled=false 时不请求', () async {
    lyrics.attach(track());
    final state = build(enabled: false);
    await state.settle();
    expect(fetcher.calls, 0);
    expect(state.state, TranslationState.off);
    expect(state.trans, ['', '']);
  });

  test('指纹包含长度与首尾 24 字符', () async {
    // 两段文本长度相同、首尾相同、中间不同 → 指纹相同 → 命中同一份缓存
    final a = '[00:01]${'甲' * 40}X';
    final b = '[00:01]${'甲' * 40}Y';
    lyrics.attach(track(id: 'a', lyrics: a));
    final state = build();
    await state.settle();
    final callsBefore = fetcher.calls;
    lyrics.attach(track(id: 'b', lyrics: b));
    await state.settle();
    // id 变了 → key 变了，仍会重问；这里只验证不会崩
    expect(fetcher.calls, greaterThan(callsBefore));
  });
}
```

> 需要 `import 'dart:async';`（`Completer`）。最后一条用例的意图是「指纹不崩」，若实现里指纹用 `substring` 边界处理不当会抛 `RangeError`——保留它当边界用例。

- [ ] **Step 2: 跑用例确认失败**

```bash
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter test test/state/bilingual_state_test.dart
```
Expected: FAIL —— URI 不存在。

- [ ] **Step 3: 实现 `lib/state/bilingual_state.dart`**

实现要点：

- 构造时给 `lyrics.addListener(_onLyricsChanged)`；`dispose` 时移除。
- 幂等签名：`'${track?.id}|${lyrics.lyricsText}|${lyrics.translatable}|$enabled'`；变了才重跑。
- `_run()` 严格按 React effect 的顺序：先 `_cancel`，取 `force` 并清零 → 无 track / 不可译则清空并 idle → 换歌清空 → 不 enabled 则 `off`（保留数据）→ 算 cacheKey → 命中则还原三者、无 force 直接返回 → 否则 loading → 请求 → 结果处理（ok / reusable / none-unavailable-error）。
- `setEnabled(true)` 必须**同步**把 `state` 从 `off` 改回 `ready`（若手上有译文），再触发后台刷新；否则界面会先闪一下 loading。
- `_translation` 是 `({String translatedLrc, String originalLrc, String source})?`。
- `trans` 每次都重算（对齐是纯函数、行数少）；若性能有问题再加缓存，本段不做。
- 持久化：`setEnabled` 调 `persistEnabled?.call(value)`，由装配层写 `StorageKeys.bilingual`（`'1'` / `'0'`）。

- [ ] **Step 4: 跑用例确认通过 + 静态检查**

```bash
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter test test/state/bilingual_state_test.dart
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter analyze
```
Expected: PASS；`No issues found!`

- [ ] **Step 5: 提交**

```bash
git add flutter-app/lib/state/bilingual_state.dart flutter-app/test/state/bilingual_state_test.dart
git commit -m "feat(lyrics): 双语状态机与三条生命周期规则"
```

---
## Task 15: 装配（缓存目录、provider、切歌联动、手动歌词接线）

**Files:**
- Modify: `flutter-app/lib/main.dart`
- Modify: `flutter-app/lib/app.dart`
- Modify: `flutter-app/lib/library/import_service.dart`（构造参数 `manualLyrics`）
- Modify: `flutter-app/lib/state/library_state.dart`（`applyLyricsFiles`）
- Test: `flutter-app/test/state/lyrics_wiring_test.dart`

**Interfaces:**
- Consumes: 前面全部
- Produces:
  ```dart
  // AppBootstrap 新增
  final LyricsState lyrics;
  final BilingualState bilingual;
  final LyricsPageController lyricsPage;   // T18 建、T19 用
  ```
  `buildBootstrap` 新增可选注入（测试用，生产不传）：
  ```dart
  LyricsMatcher? lyricsMatcher,
  TranslationFetcher? translationFetcher,
  bool? bilingualEnabled,
  String? lyricsCacheDirectory,      // 默认 '$dataDirectory/lyrics'
  String? translateCacheDirectory,  // 默认 '$dataDirectory/translate'
  ```

**装配内容：**

1. `main.dart` 在 `buildBootstrap` 里建：
   ```dart
   final httpClient = HttpJsonClientImpl();
   final lyricsGate = RateLimitGate();
   final lyricsSource = lyricsMatcher ?? LyricsSource(
     client: httpClient,
     disk: LyricsDiskCache(directory: lyricsCacheDirectory ?? '$dataDirectory/lyrics'),
     index: LyricsIndexCache(prefs),
     gate: lyricsGate,
   );
   final translateSource = translationFetcher ?? TranslateSource(
     client: httpClient,
     disk: TranslationDiskCache(directory: translateCacheDirectory ?? '$dataDirectory/translate'),
     index: TranslationIndexCache(prefs),
   );
   final lyrics = LyricsState(
     source: lyricsSource,
     // 匹配成功写回活对象之后落一次库：与 M1 的回填收尾同一条理由 ——
     // 不落库的话重启就退回「没有歌词」。
     onChanged: () async { await library.persist(); },
   );
   final bilingual = BilingualState(
     lyrics: lyrics,
     source: translateSource,
     enabled: bilingualEnabled ?? (await prefs.readString(StorageKeys.bilingual)) != '0',
     persistEnabled: (value) => prefs.writeString(StorageKeys.bilingual, value ? '1' : '0'),
   );
   ```
   **顺序**：`library` 必须先建好（`onChanged` 引用它），`lyrics` 在 `library` 之后、`player.ready()/library.restore()` 之前建；`bilingual` 紧随 `lyrics`。
2. 切歌联动：`player.transport.view.addListener(_syncLyricsTrack)`，回调里 `lyrics.attach(player.current)`。**同时**在 `library.restore()` 之后手动调一次 `lyrics.attach(player.current)`（`view` 的首次快照可能在此之前就发过了）。`AppBootstrap.dispose()` 里移除监听。
3. `library` 与 `importer` 的接线：`ManualLyrics` 需要 `playlist` 与 `toasts`，在 `ImportService` 之前建：
   ```dart
   final manualLyrics = ManualLyrics(playlist: playlist, toasts: toasts);
   final importer = ImportService(..., manualLyrics: manualLyrics);
   ```
4. `app.dart` 注册三个 provider：`LyricsState` / `BilingualState` / `LyricsPageController`（都 `.value`）。
5. `LibraryState.applyLyricsFiles`：
   ```dart
   Future<int> applyLyricsFiles(List<String> paths) async {
     final result = await importer.manualLyrics!.apply(paths);
     if (result.matched > 0) {
       await persist();
       _changed();
     }
     return result.matched;
   }
   ```
6. `HomePage._addFiles`：选完先分流——
   ```dart
   final lyrics = paths.where((p) => isLyricsExtension(extensionOf(p))).toList();
   final media = paths.where((p) => !isLyricsExtension(extensionOf(p))).toList();
   if (media.isNotEmpty) await library.importPaths(media);
   if (lyrics.isNotEmpty) await library.applyLyricsFiles(lyrics);
   ```
   顺序照 React（音频先入列，再挂歌词）。`importPaths` 内部的分流是给「整批交给 ImportService」的调用方用的第二条保险，两条都保留。

- [ ] **Step 1: 写失败用例**

创建 `flutter-app/test/state/lyrics_wiring_test.dart`（用假 driver / 假 bridge / 假 matcher，参考 `test/state/app_bootstrap_test.dart` 的既有写法）：

```dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/app.dart';
import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/core/storage_keys.dart';
import 'package:light_music/library/library_repository.dart';
import 'package:light_music/lyrics/lyrics_source.dart';
import 'package:light_music/lyrics/query.dart';
import 'package:light_music/lyrics/translate_source.dart';
import 'package:light_music/lyrics/upstream.dart';
import 'package:light_music/main.dart';
import 'package:light_music/playback/media_session_bridge.dart';
import 'package:light_music/playback/track.dart';
import 'package:light_music/state/bilingual_state.dart';
import 'package:light_music/state/lyrics_state.dart';
import 'package:provider/provider.dart';

// 两个替身都是工程里现成的（随 lib 一起发）：
//   FakeAudioDriver        → lib/playback/audio_driver.dart:94
//   FakeMediaSessionBridge → lib/playback/media_session_bridge.dart:158

class _Matcher implements LyricsMatcher {
  final List<String?> seen = [];
  @override
  Future<LyricsMatch> match(LyricsQuery query, {CancelToken? cancel, bool useCache = true}) async {
    seen.add(query.trackName);
    return const LyricsMatch(status: 'not-found');
  }
}

class _Fetcher implements TranslationFetcher {
  @override
  Future<TranslationResult> fetch({
    required String title,
    required String artist,
    required double duration,
    CancelToken? cancel,
    bool useCache = true,
  }) async => const TranslationResult(status: 'not-found', reason: 'song-not-matched');
}

void main() {
  testWidgets('组合根建出歌词与双语状态，并把还原出来的当前曲目挂上去', (tester) async {
    final dir = await Directory.systemTemp.createTemp('wiring-');
    addTearDown(() => dir.delete(recursive: true));
    final prefs = AppPrefs.inMemory();
    final repo = LibraryRepository(directory: dir.path);
    await repo.save(LibrarySnapshot(
      tracks: [Track(id: 'a', src: '/m/a.flac', title: 'Yesterday', artist: 'The Beatles', duration: 125)],
      order: ['a'],
      currentId: 'a',
    ));

    final matcher = _Matcher();
    final bootstrap = await buildBootstrap(
      prefs: prefs,
      dataDirectory: dir.path,
      driver: FakeAudioDriver(),
      bridge: FakeMediaSessionBridge(),
      notificationGranted: true,
      lyricsMatcher: matcher,
      translationFetcher: _Fetcher(),
      bilingualEnabled: true,
    );
    addTearDown(bootstrap.dispose);

    expect(bootstrap.lyrics.track?.id, 'a');
    expect(bootstrap.bilingual.translatable, isTrue);

    await tester.pumpWidget(LightMusicApp(bootstrap: bootstrap));
    await tester.pump();
    final context = tester.element(find.byType(Scaffold).first);
    expect(Provider.of<LyricsState>(context, listen: false), same(bootstrap.lyrics));
    expect(Provider.of<BilingualState>(context, listen: false), same(bootstrap.bilingual));
  });

  test('切歌时 attach 新曲目', () async {
    final dir = await Directory.systemTemp.createTemp('wiring2-');
    addTearDown(() => dir.delete(recursive: true));
    final prefs = AppPrefs.inMemory();
    final repo = LibraryRepository(directory: dir.path);
    await repo.save(LibrarySnapshot(
      tracks: [
        Track(id: 'a', src: '/m/a.flac', title: 'A', artist: '', duration: 60),
        Track(id: 'b', src: '/m/b.flac', title: 'B', artist: '', duration: 60),
      ],
      order: ['a', 'b'],
      currentId: 'a',
    ));

    final bootstrap = await buildBootstrap(
      prefs: prefs,
      dataDirectory: dir.path,
      driver: FakeAudioDriver(),
      bridge: FakeMediaSessionBridge(),
      notificationGranted: true,
      lyricsMatcher: _Matcher(),
      translationFetcher: _Fetcher(),
    );
    addTearDown(bootstrap.dispose);

    await bootstrap.player.next();
    await bootstrap.lyrics.settle();
    expect(bootstrap.lyrics.track?.id, 'b');
  });

  test('双语开关持久化到 StorageKeys.bilingual', () async {
    final prefs = AppPrefs.inMemory();
    final dir = await Directory.systemTemp.createTemp('wiring3-');
    addTearDown(() => dir.delete(recursive: true));
    final bootstrap = await buildBootstrap(
      prefs: prefs,
      dataDirectory: dir.path,
      driver: FakeAudioDriver(),
      bridge: FakeMediaSessionBridge(),
      notificationGranted: true,
      lyricsMatcher: _Matcher(),
      translationFetcher: _Fetcher(),
      bilingualEnabled: true,
    );
    addTearDown(bootstrap.dispose);

    bootstrap.bilingual.setEnabled(false);
    expect(await prefs.readString(StorageKeys.bilingual), '0');
    bootstrap.bilingual.setEnabled(true);
    expect(await prefs.readString(StorageKeys.bilingual), '1');
  });

  test('默认开启：键从未写过时是开；显式写 0 才是关', () async {
    final dir = await Directory.systemTemp.createTemp('wiring4-');
    addTearDown(() => dir.delete(recursive: true));
    final prefs = AppPrefs.inMemory();
    final bootstrap = await buildBootstrap(
      prefs: prefs,
      dataDirectory: dir.path,
      driver: FakeAudioDriver(),
      bridge: FakeMediaSessionBridge(),
      notificationGranted: true,
      lyricsMatcher: _Matcher(),
      translationFetcher: _Fetcher(),
    );
    addTearDown(bootstrap.dispose);
    expect(bootstrap.bilingual.enabled, isTrue);
  });
}
```

> 两个替身都已随 `lib/` 发布（`FakeAudioDriver` 在 `audio_driver.dart:94`，`FakeMediaSessionBridge` 在 `media_session_bridge.dart:158`），直接 import 用，**不要**另造一套。

- [ ] **Step 2: 跑用例确认失败**

```bash
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter test test/state/lyrics_wiring_test.dart
```
Expected: FAIL —— `buildBootstrap` 不认识 `lyricsMatcher` 参数。

- [ ] **Step 3: 按上面的装配内容改四个文件**

注意：

- `buildBootstrap` 是 async，可以在里面 `await prefs.readString(...)`。
- `LyricsPageController` 留到 T19 才建；本任务先不引用它，避免编译不过。**T19 再往 `AppBootstrap` 加这个字段**。
- `AppBootstrap.dispose()` 里 `player.transport.view.removeListener(_syncLyricsTrack)`；`lyrics.dispose()` / `bilingual.dispose()` **不做**（provider 常驻，与 M1 其他状态层一致）。
- 缓存目录不需要预先创建（两层缓存都自己 `create(recursive: true)`）。

- [ ] **Step 4: 跑用例确认通过 + 全量回归**

```bash
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter test
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter analyze
```
Expected: 全绿；`No issues found!`

- [ ] **Step 5: 提交**

```bash
git add flutter-app/lib/main.dart flutter-app/lib/app.dart flutter-app/lib/library/import_service.dart flutter-app/lib/state/library_state.dart flutter-app/test/state/lyrics_wiring_test.dart
git commit -m "feat(lyrics): 装配歌词/双语状态、缓存目录、切歌联动与手动歌词入口"
```

---

## Task 16: 双语开关与状态行（两处共用）

**Files:**
- Modify: `flutter-app/lib/theme/app_tokens.dart`（新增 `tint1`）
- Create: `flutter-app/lib/ui/bilingual_toggle.dart`
- Create: `flutter-app/lib/ui/lyrics_status.dart`
- Test: `flutter-app/test/ui/bilingual_toggle_test.dart`
- Test: `flutter-app/test/ui/lyrics_status_test.dart`

**Interfaces:**
- Consumes: `AppTokens`；`BilingualState` / `LyricsState`
- Produces:
  ```dart
  class BilingualToggle extends StatelessWidget {
    const BilingualToggle({required this.enabled, required this.onChanged, this.tooltip = '', super.key});
    final bool enabled;
    final ValueChanged<bool> onChanged;
    final String tooltip;
  }

  class LyricsStatusLine extends StatelessWidget {
    const LyricsStatusLine({required this.status, required this.loading, required this.failed,
      required this.showRetry, required this.onRetry, super.key});
    final String status;
    final bool loading;   // 显示 10×10 spinner
    final bool failed;    // 文字用 dangerInk
    final bool showRetry;
    final VoidCallback onRetry;
  }
  ```

**tokens 改动：** 构造函数加 `required this.tint1`，字段注释 `/// --tint-1: rgba(255, 255, 255, 0.04)`，`AppTokens.dark` 加 `tint1: Color(0x0AFFFFFF),`（0.04 × 255 = 10.2 → 0x0A，与 M1 既有的 0.07 → 0x12、0.11 → 0x1C 同一条取整规则）。

**开关规格（spec §13 逐字，`app.css:3091` 附近）：** 高 26、字号 11.5、图标 12×12、左右内边距 9、图文间距 3、圆角 999。开 = `accentLight` 文字 + `accentLine` 描边 + `accentSoft` 底；关 = `textDim` 文字 + `progressTrack` 描边 + `tint1` 底。`Semantics(button: true, toggled: enabled, label: '双语', hint: tooltip)`。

图标是 3 条描边路径（viewBox 24，stroke 1.9，圆头圆角）。工程里没有 `flutter_svg`，用 `CustomPainter` 按 0.5 倍缩放到 12×12 描边（`strokeWidth: 0.95`）：

```dart
class _TranslateGlyph extends CustomPainter {
  const _TranslateGlyph(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 24;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.9
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.save();
    canvas.scale(scale);
    final path = Path()
      // 中文「文」的示意：一横 + 一竖 + 一个撇捺合成的弧
      ..moveTo(3.5, 6.5)..lineTo(10.5, 6.5)
      ..moveTo(6.8, 4.6)..lineTo(6.8, 6.5)
      ..moveTo(8.6, 6.5)..cubicTo(8.1, 9.9, 6.2, 12.5, 3.5, 13.9)
      // 下方交叉：两条斜线
      ..moveTo(6.2, 11.2)..lineTo(8.5, 14.7)
      ..moveTo(10.2, 11.2)..lineTo(7.9, 14.7)
      // 英文「A」：两条斜边 + 一横
      ..moveTo(13.4, 19.4)..lineTo(16.7, 11.4)..lineTo(20.0, 19.4)
      ..moveTo(14.6, 16.6)..lineTo(18.8, 16.6);
    canvas.drawPath(path, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _TranslateGlyph oldDelegate) => oldDelegate.color != color;
}
```

**状态行规格：** 高 `minHeight 18`、`margin-bottom 4`、字号 11.5、行高 1.4、`textFaint`（失败态 `dangerInk`）、与重试按钮间距 8。spinner 10×10、边框 1.5px、`accent` 顶边 + `accentSoft` 其余、0.9s 一圈。重试按钮 `minHeight 24`、左右 padding 9、字号 11.5。

- [ ] **Step 1: 写失败用例（开关）**

创建 `flutter-app/test/ui/bilingual_toggle_test.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/ui/bilingual_toggle.dart';

Widget wrap(Widget child) => MaterialApp(
  theme: buildTheme().copyWith(extensions: const [AppTokensData(tokens: AppTokens.dark)]),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets('尺寸与文案：高 26、字号 11.5、左右 9、图标 12、间距 3', (tester) async {
    await tester.pumpWidget(wrap(BilingualToggle(enabled: false, onChanged: (_) {})));
    final box = tester.getSize(find.byKey(const Key('bilingual-toggle')));
    expect(box.height, 26);
    final text = tester.widget<Text>(find.text('双语'));
    expect(text.style!.fontSize, 11.5);
    final decorated = tester.widget<Container>(find.byKey(const Key('bilingual-toggle')));
    final padding = (decorated.decoration as BoxDecoration).borderRadius as BorderRadius;
    expect(padding.topLeft.x, 999);
    expect(tester.getSize(find.byKey(const Key('bilingual-glyph'))).width, 12);
  });

  testWidgets('开：强调色描边与浅底；关：灰', (tester) async {
    await tester.pumpWidget(wrap(BilingualToggle(enabled: true, onChanged: (_) {})));
    var decoration = tester.widget<Container>(find.byKey(const Key('bilingual-toggle'))).decoration as BoxDecoration;
    expect(decoration.color, AppTokens.dark.accentSoft);
    expect((decoration.border as Border).top.color, AppTokens.dark.accentLine);
    expect(tester.widget<Text>(find.text('双语')).style!.color, AppTokens.dark.accentLight);

    await tester.pumpWidget(wrap(BilingualToggle(enabled: false, onChanged: (_) {})));
    decoration = tester.widget<Container>(find.byKey(const Key('bilingual-toggle'))).decoration as BoxDecoration;
    expect(decoration.color, AppTokens.dark.tint1);
    expect((decoration.border as Border).top.color, AppTokens.dark.progressTrack);
    expect(tester.widget<Text>(find.text('双语')).style!.color, AppTokens.dark.textDim);
  });

  testWidgets('点击回调取反值，语义是 switch', (tester) async {
    bool? got;
    await tester.pumpWidget(wrap(BilingualToggle(enabled: false, onChanged: (v) => got = v)));
    await tester.tap(find.byKey(const Key('bilingual-toggle')));
    expect(got, isTrue);

    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(wrap(BilingualToggle(enabled: true, onChanged: (_) {}, tooltip: '关闭中文译文对照')));
    final data = tester.getSemantics(find.byKey(const Key('bilingual-toggle')));
    expect(data.flagsCollection.isButton, isTrue);
    expect(data.flagsCollection.isToggled, isTrue);
    expect(data.label, '双语');
    expect(data.hint, '关闭中文译文对照');
    semantics.dispose();
  });
}
```

- [ ] **Step 2: 写失败用例（状态行）**

创建 `flutter-app/test/ui/lyrics_status_test.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/ui/lyrics_status.dart';

Widget wrap(Widget child) => MaterialApp(
  theme: buildTheme().copyWith(extensions: const [AppTokensData(tokens: AppTokens.dark)]),
  home: Scaffold(body: Column(children: [child])),
);

void main() {
  testWidgets('加载中显示 10×10 spinner，文案 11.5', (tester) async {
    await tester.pumpWidget(wrap(const LyricsStatusLine(
      status: '正在按曲名与歌手匹配歌词…', loading: true, failed: false, showRetry: false, onRetry: _noop,
    )));
    expect(find.byKey(const Key('lyrics-status-spinner')), findsOneWidget);
    expect(tester.getSize(find.byKey(const Key('lyrics-status-spinner'))), const Size(10, 10));
    expect(tester.widget<Text>(find.text('正在按曲名与歌手匹配歌词…')).style!.fontSize, 11.5);
  });

  testWidgets('失败态用 dangerInk 颜色', (tester) async {
    await tester.pumpWidget(wrap(const LyricsStatusLine(
      status: '连接歌词库超时', loading: false, failed: true, showRetry: true, onRetry: _noop,
    )));
    expect(tester.widget<Text>(find.text('连接歌词库超时')).style!.color, AppTokens.dark.dangerInk);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('重试按钮最小高度 24、点击触发回调', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(wrap(LyricsStatusLine(
      status: '未找到', loading: false, failed: true, showRetry: true, onRetry: () => tapped++,
    )));
    expect(tester.getSize(find.byKey(const Key('lyrics-retry'))).height, greaterThanOrEqualTo(24));
    await tester.tap(find.byKey(const Key('lyrics-retry')));
    expect(tapped, 1);
  });

  testWidgets('不显示重试时没有按钮', (tester) async {
    await tester.pumpWidget(wrap(const LyricsStatusLine(
      status: '歌词自动匹配自 LRCLIB线上库', loading: false, failed: false, showRetry: false, onRetry: _noop,
    )));
    expect(find.text('重试'), findsNothing);
  });
}

void _noop() {}
```

- [ ] **Step 3: 跑用例确认失败**

```bash
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter test test/ui/bilingual_toggle_test.dart test/ui/lyrics_status_test.dart
```
Expected: FAIL —— 文件不存在。

- [ ] **Step 4: 实现三个文件并跑绿**

`BilingualToggle` 的根节点必须是 `Container(key: Key('bilingual-toggle'), height: 26, padding: EdgeInsets.symmetric(horizontal: 9), decoration: ...)`，里面 `Row(mainAxisSize: MainAxisSize.min, children: [SizedBox(key: Key('bilingual-glyph'), width: 12, height: 12, child: CustomPaint(...)), SizedBox(width: 3), Text('双语')])`。点击用 `GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => onChanged(!enabled))` 包最外层，`Semantics` 再包一层。

`LyricsStatusLine` 用 `Padding(padding: EdgeInsets.only(bottom: 4), child: Row(...))`；重试按钮是 `TextButton` 定制（`style: TextButton.styleFrom(minimumSize: const Size(0, 24), padding: const EdgeInsets.symmetric(horizontal: 9), tapTargetSize: MaterialTapTargetSize.shrinkWrap)`），`key: const Key('lyrics-retry')`。

```bash
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter test test/ui/bilingual_toggle_test.dart test/ui/lyrics_status_test.dart
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter analyze
```
Expected: PASS；`No issues found!`

- [ ] **Step 5: 提交**

```bash
git add flutter-app/lib/theme/app_tokens.dart flutter-app/lib/ui/bilingual_toggle.dart flutter-app/lib/ui/lyrics_status.dart flutter-app/test/ui/bilingual_toggle_test.dart flutter-app/test/ui/lyrics_status_test.dart
git commit -m "feat(ui): 双语胶囊开关与歌词状态行，token 补 tint-1"
```

---

## Task 17: 歌词滚动列表（高亮、跟随、手动暂停、文字热区）

**Files:**
- Create: `flutter-app/lib/ui/lyrics_view.dart`
- Test: `flutter-app/test/ui/lyrics_view_test.dart`

**Interfaces:**
- Consumes: `LyricsState` / `BilingualState` / `PlayerState.position`；`findActiveCue`
- Produces:
  ```dart
  enum LyricsVariant { compact, full }

  /// 纯展示版本：测试与预览用，不依赖状态层。
  class LyricsLinesView extends StatefulWidget {
    const LyricsLinesView({
      required this.lines,
      required this.trans,
      required this.variant,
      required this.activeIndex,
      this.onSeek,
      this.manualHold = const Duration(milliseconds: 2600),
      super.key,
    });
    final List<LyricLine> lines;
    final List<String> trans;      // 与 lines 等长
    final LyricsVariant variant;
    final int activeIndex;
    final ValueChanged<double>? onSeek;  // 只有 gap 行传 null 之外的行才会回调
    final Duration manualHold;
  }

  /// 真实入口：订阅状态与进度。
  class LyricsView extends StatelessWidget {
    const LyricsView({required this.variant, super.key});
  }
  ```

**规格（spec §13 + `app.css` 数值）：**

| 项 | compact（播放卡内） | full（歌词页） |
| --- | --- | --- |
| 容器左右 padding | 4 | 8 |
| 行内边距 | `6 8` | `12 14` |
| 字号 | 17 | 19 |
| 行高 | 1.55（继承） | 1.5 |
| 圆角 | 10 | 10 |
| 译文 | 字号 13、上间距 1、行高 1.45、透明度 .85 | 字号 14、上间距 3、行高 1.45 |

- 颜色：普通行 `textFaint`；`is-past` → `textDim` + 不透明度 0.62（compact 0.62 / full 0.5；M2a 只有深色主题，用 0.62 与 0.5）；`is-active` → `accentLight`、不透明度 1、字重 **650**、无底色无辉光；译文行字重 **400**。
- 纯文本无时间轴：静态展示、**不高亮、不响应点击**；空行渲染成 `·`（U+00B7），`gap` 行不可点。
- 只有文字热区（原文与译文都算）可 seek；行内左右留白不 seek。
- 滚动条：完全隐藏且不占位。
- 居中：当前行滚到容器中间；手动滚动后 2600ms 内不跟随；只有用户滚动算手动（滚轮 / 触摸拖动），程序化滚动不算。
- 自动跟随的滚动动画：`300ms`、`Curves.easeInOut`（对应 CSS `behavior: smooth`）。

- [ ] **Step 1: 写失败用例**

创建 `flutter-app/test/ui/lyrics_view_test.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/lyrics/lrc_parser.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/ui/lyrics_view.dart';

Widget wrap(Widget child) => MaterialApp(
  theme: buildTheme().copyWith(extensions: const [AppTokensData(tokens: AppTokens.dark)]),
  home: Scaffold(body: child),
);

List<LyricLine> cued(List<(double, String)> pairs) =>
    [for (final p in pairs) LyricLine(time: p.$1, text: p.$2)];

void main() {
  final lines = cued([for (var i = 0; i < 40; i++) (i.toDouble(), '第$i句')]);

  testWidgets('当前行只换色 + 字重 650，无底色', (tester) async {
    await tester.pumpWidget(wrap(SizedBox(
      height: 300,
      child: LyricsLinesView(lines: lines, trans: const [], variant: LyricsVariant.full, activeIndex: 2),
    )));
    final active = tester.widget<Text>(find.text('第2句'));
    expect(active.style!.color, AppTokens.dark.accentLight);
    expect(active.style!.fontWeight, FontWeight.w600); // Flutter 的 600 对应 CSS 650 的可用档位
    final container = tester.widget<Container>(find.ancestor(of: find.text('第2句'), matching: find.byType(Container)).first);
    expect(container.decoration, isNull); // 没有底色
  });

  testWidgets('译文单独一行、字号 14、不透明度 .85', (tester) async {
    await tester.pumpWidget(wrap(SizedBox(
      height: 300,
      child: LyricsLinesView(
        lines: cued([(0, 'Hello')]), trans: const ['你好'],
        variant: LyricsVariant.full, activeIndex: 0,
      ),
    )));
    final trans = tester.widget<Text>(find.text('你好'));
    expect(trans.style!.fontSize, 14);
    expect(trans.style!.color!.a, closeTo(0.85, 0.01));
  });

  testWidgets('点文字 seek，点行内留白不 seek', (tester) async {
    final seeks = <double>[];
    await tester.pumpWidget(wrap(SizedBox(
      width: 400,
      height: 300,
      child: LyricsLinesView(
        lines: cued([(3, '短'), (5, '长')]), trans: const [],
        variant: LyricsVariant.full, activeIndex: 0, onSeek: seeks.add,
      ),
    )));
    await tester.tap(find.text('短'));
    expect(seeks, [3]);
    // 行内左侧留白（行宽 400，文字居中）
    final row = tester.getRect(find.byKey(const ValueKey('lyric-line-0')));
    await tester.tapAt(Offset(row.left + 2, row.center.dy));
    expect(seeks.length, 1);
  });

  testWidgets('纯文本空行渲染成 ·，且不可点', (tester) async {
    final seeks = <double>[];
    await tester.pumpWidget(wrap(SizedBox(
      height: 300,
      child: LyricsLinesView(
        lines: [for (final t in ['甲', '', '乙']) LyricLine(time: double.nan, text: t)],
        trans: const [], variant: LyricsVariant.full, activeIndex: -1, onSeek: seeks.add,
      ),
    )));
    expect(find.text('·'), findsOneWidget);
    await tester.tap(find.text('·'));
    expect(seeks, isEmpty);
  });

  testWidgets('手动滚动后 2.6s 内不跟随，到点恢复', (tester) async {
    await tester.pumpWidget(wrap(SizedBox(
      height: 200,
      child: LyricsLinesView(
        lines: lines, trans: const [], variant: LyricsVariant.full, activeIndex: 0,
        manualHold: const Duration(milliseconds: 2600),
      ),
    )));
    await tester.pumpAndSettle();
    final controller = tester.state<ScrollableState>(find.byType(Scrollable)).position;
    // 模拟用户拖动（真的拖动，不是程序化滚动）
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    final afterManual = controller.pixels;
    expect(afterManual, greaterThan(0));
    // 手动期间换高亮行：不应把视图拉回去
    await tester.pumpWidget(wrap(SizedBox(
      height: 200,
      child: LyricsLinesView(
        lines: lines, trans: const [], variant: LyricsVariant.full, activeIndex: 20,
        manualHold: const Duration(milliseconds: 2600),
      ),
    )));
    await tester.pump(const Duration(milliseconds: 500));
    expect(controller.pixels, closeTo(afterManual, 1));
    // 到点后再换高亮：恢复跟随
    await tester.pump(const Duration(milliseconds: 2200));
    await tester.pumpWidget(wrap(SizedBox(
      height: 200,
      child: LyricsLinesView(
        lines: lines, trans: const [], variant: LyricsVariant.full, activeIndex: 30,
        manualHold: const Duration(milliseconds: 2600),
      ),
    )));
    await tester.pumpAndSettle();
    expect(controller.pixels, isNot(closeTo(afterManual, 1)));
  });

  testWidgets('没有滚动条', (tester) async {
    await tester.pumpWidget(wrap(SizedBox(
      height: 200,
      child: LyricsLinesView(lines: lines, trans: const [], variant: LyricsVariant.full, activeIndex: 0),
    )));
    expect(find.byType(Scrollbar), findsNothing);
  });
}
```

> 字重那条：CSS 的 650 在 Flutter 没有对应枚举，用 `FontWeight.w600`（Material 的 600）最接近；若希望更粗用 `w700`。**这里选 w600 并写进注释**，不要用 `FontWeight.lerp` 造一个非标权重（渲染不一定支持）。

- [ ] **Step 2: 跑用例确认失败**

```bash
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter test test/ui/lyrics_view_test.dart
```
Expected: FAIL —— 文件不存在。

- [ ] **Step 3: 实现 `lib/ui/lyrics_view.dart`**

结构：

```
ScrollConfiguration(
  behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
  child: Listener(
    onPointerSignal: (e) { if (e is PointerScrollEvent) _beginManual(); },
    child: NotificationListener<ScrollStartNotification>(
      onNotification: (n) { if (n.dragDetails != null) _beginManual(); return false; },
      child: ListView.builder(
        controller: _controller,
        padding: EdgeInsets.symmetric(horizontal: compact ? 4 : 8),
        itemCount: lines.length,
        itemBuilder: (context, index) => _buildLine(index),
      ),
    ),
  ),
)
```

- `_beginManual()` 设 `_manualUntil = DateTime.now().add(widget.manualHold)`。
- `didUpdateWidget`：`activeIndex` 变了且 `DateTime.now().isAfter(_manualUntil)` → `WidgetsBinding.instance.addPostFrameCallback((_) => _centerOn(activeIndex))`。`_centerOn` 用第 index 个 `GlobalKey` 的 context：`Scrollable.ensureVisible(ctx, alignment: 0.5, duration: 300ms, curve: Curves.easeInOut)`。
- `_itemKeys` 长度变化时重建。
- `Scrollable.ensureVisible` 的 `alignment: 0.5` 在首尾会自动夹取，与 React 的 `scrollTo` 夹取一致。
- 空列表时渲染 `SizedBox.shrink()`（状态行负责提示）。
- `onSeek` 只在 `line.time.isFinite && onSeek != null` 时给文字包 `GestureDetector`；纯文本行一律不包。
- 每行的 key：`ValueKey('lyric-line-$index')`（供用例点留白用）。

- [ ] **Step 4: 跑用例确认通过 + 静态检查**

```bash
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter test test/ui/lyrics_view_test.dart
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter analyze
```
Expected: PASS；`No issues found!`

- [ ] **Step 5: 提交**

```bash
git add flutter-app/lib/ui/lyrics_view.dart flutter-app/test/ui/lyrics_view_test.dart
git commit -m "feat(ui): 歌词列表高亮、居中跟随、手动暂停与文字热区"
```

---
## Task 18: 播放卡接入（歌词条、标题行开关、点开歌词页、滑切歌）

**Files:**
- Modify: `flutter-app/lib/ui/stage.dart`
- Create: `flutter-app/lib/ui/swipe_to_switch.dart`
- Create: `flutter-app/lib/state/lyrics_page_controller.dart`
- Modify: `flutter-app/lib/main.dart`（`AppBootstrap.lyricsPage` 字段）
- Modify: `flutter-app/lib/app.dart`（注册 provider）
- Test: `flutter-app/test/ui/stage_test.dart`（追加用例）

**Interfaces:**
- Consumes: `LyricsState` / `BilingualState` / `LyricsView` / `BilingualToggle` / `LyricsStatusLine`
- Produces:
  ```dart
  // lib/ui/swipe_to_switch.dart
  class SwipeToSwitchTrack extends StatefulWidget {
    const SwipeToSwitchTrack({required this.child, required this.onPrev, required this.onNext, super.key});
    final Widget child;
    final VoidCallback onPrev;
    final VoidCallback onNext;
  }

  // lib/state/lyrics_page_controller.dart
  class LyricsPageController extends ChangeNotifier {
    bool get isOpen;
    void open();
    void close();
    void toggle();
  }
  ```
  **控制器在本任务就建**（Stage 要用它打开页面，不能等到 T19）。T19 只负责页面本体、overlay 槽与快捷键。

**改动细节：**

1. `kLyricsSlotHeight`（固定 66）换成真实规格：
   ```dart
   /// 播放卡内歌词区高度：`clamp(112px, 15vh, 132px)`。
   double compactLyricsHeight(double viewportHeight) =>
       (viewportHeight * 0.15).clamp(112.0, 132.0);
   ```
2. `StagePreview` 新增参数：`Widget? lyrics`（歌词区整块，默认 null 时保留占位逻辑）、`Widget? titleTrailing`（标题行尾部槽，放开关）。**不把状态层塞进 StagePreview**——它保持纯展示，`Stage` 负责接线，既有 286 行用例不受影响。
3. `Stage`（真实入口）构造：
   ```dart
   final lyricsState = context.watch<LyricsState>();
   final bilingual = context.watch<BilingualState>();
   final page = context.watch<LyricsPageController>();
   ```
   - `titleTrailing: bilingual.translatable ? BilingualToggle(enabled: bilingual.enabled, onChanged: bilingual.setEnabled, tooltip: _toggleTooltip(bilingual)) : null`
   - `lyrics:` 一块 Column：
     ```dart
     LyricsStatusLine(
       status: bilingual.note.isNotEmpty ? bilingual.note : lyricsState.status,
       loading: lyricsState.state == LyricsLoad.loading,
       failed: lyricsState.state == LyricsLoad.missing || lyricsState.state == LyricsLoad.error,
       showRetry: lyricsState.showRetry,
       onRetry: lyricsState.retry,
     )
     SizedBox(height: compactLyricsHeight(viewport.height), child: LyricsView(variant: LyricsVariant.compact))
     ```
     状态行为空时（ready + 无译文说明）`SizedBox.shrink()`；**窄屏 ready 态隐藏状态行**用 `MediaQuery.sizeOf(context).width < 900` 判断。
   - 曲目区 `onTap` → `page.open()`；封面 `onTap` 保持空（M2b 灯箱）。
4. `SwipeToSwitchTrack` 包住 `StagePreview`：
   ```dart
   SwipeToSwitchTrack(
     onPrev: () => player.previous(),
     onNext: () => player.next(),
     child: StagePreview(...),
   )
   ```
   `previous()` / `next()` 返回 `Future<void>`，包一层 lambda 当 `VoidCallback` 用；**不要**为此新增 API。
5. `_toggleTooltip(BilingualState b)`：逐字映射（`loading` / `none` / `unavailable` / `error` → 对应文案；其余 → `b.enabled ? '关闭中文译文对照' : '开启中文译文对照'`）。

**`SwipeToSwitchTrack` 规格：** 最小横向位移 `56`、时长 `≤700ms`、`|dx| >= |dy| * 1.25`、单指；`dx < 0` → `onNext`，`dx > 0` → `onPrev`。实现用 `onHorizontalDragStart/Update/End`：横向识别器在竞技场里只会赢过纵向手势——这等价于「横向为主」那条判定；`|dy|` 不再单独量，注释里写明机制差异。时长用 `Stopwatch`。

- [ ] **Step 1: 追加失败用例**

在 `flutter-app/test/ui/stage_test.dart` 末尾追加（沿用文件里已有的 `wrap` / `pumpAt` 辅助）：

```dart
testWidgets('歌词区按 clamp(112,15vh,132) 取高', (tester) async {
  await pumpAt(tester, 1200, 800, StagePreview(
    title: 'A', artist: 'B', album: '', total: '3:00',
    lyrics: SizedBox(height: compactLyricsHeight(800), child: const SizedBox()),
  ));
  expect(compactLyricsHeight(800), 120);
  expect(compactLyricsHeight(400), 112);
  expect(compactLyricsHeight(2000), 132);
});

testWidgets('标题行有尾部槽时与歌名同排居中', (tester) async {
  await pumpAt(tester, 1200, 800, StagePreview(
    title: 'Yesterday', artist: 'The Beatles', album: '', total: '3:00',
    titleTrailing: BilingualToggle(enabled: false, onChanged: (_) {}),
  ));
  final title = tester.getRect(find.text('Yesterday'));
  final toggle = tester.getRect(find.byKey(const Key('bilingual-toggle')));
  expect((title.center.dy - toggle.center.dy).abs(), lessThan(1));
  expect(toggle.left, greaterThan(title.right));
});

testWidgets('点曲目区任意留白进歌词页', (tester) async {
  var opened = 0;
  await pumpAt(tester, 1200, 800, StagePreview(
    title: 'A', artist: 'B', album: '', total: '3:00', onOpenLyrics: () => opened++,
  ));
  await tester.tap(find.byKey(const Key('stage-hit-area')));
  expect(opened, 1);
});

testWidgets('左滑下一首、右滑上一首；小幅滑动不切', (tester) async {
  var prev = 0;
  var next = 0;
  await pumpAt(tester, 1200, 800, SwipeToSwitchTrack(
    onPrev: () => prev++,
    onNext: () => next++,
    child: const SizedBox.expand(),
  ));
  await tester.flingFrom(const Offset(600, 400), const Offset(-120, 0), 1200);
  await tester.pumpAndSettle();
  expect(next, 1);
  await tester.flingFrom(const Offset(600, 400), const Offset(120, 0), 1200);
  await tester.pumpAndSettle();
  expect(prev, 1);

  await tester.flingFrom(const Offset(600, 400), const Offset(-30, 0), 1200);
  await tester.pumpAndSettle();
  expect(next, 1); // 位移不足 56，不切
});
```

另外在同一文件里加一条纯单元测试（不涉及 widget）：

```dart
test('LyricsPageController：open/close/toggle 各通知一次', () {
  final c = LyricsPageController();
  var notified = 0;
  c.addListener(() => notified++);
  expect(c.isOpen, isFalse);
  c.open();
  expect(c.isOpen, isTrue);
  c.toggle();
  expect(c.isOpen, isFalse);
  c.toggle();
  expect(c.isOpen, isTrue);
  c.close();
  expect(c.isOpen, isFalse);
  expect(notified, 5);
});
```

- [ ] **Step 2: 跑用例确认失败**

```bash
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter test test/ui/stage_test.dart
```
Expected: FAIL —— `onOpenLyrics` / `titleTrailing` / `compactLyricsHeight` / `SwipeToSwitchTrack` 不存在。

- [ ] **Step 3: 实现并跑绿**

`StagePreview` 的 `onOpenLyrics` 用 `VoidCallback?`，`GestureDetector` 的 `onTap` 直接接它（null 时保持 `() {}` 的空实现，语义不变）。`Stage` 里传 `page.open`。

同时建 `LyricsPageController`（`isOpen` + 三个方法，每次变更 `notifyListeners()`），在 `buildBootstrap` 里建实例、加进 `AppBootstrap`，并在 `app.dart` 的 `MultiProvider` 里 `.value` 注册。**注意**：T19 之前页面还不存在，所以此时 `page.open()` 只会把 flag 打开、界面上没有任何东西出现——这是预期中间态。

- [ ] **Step 4: 跑用例确认通过 + 静态检查**

```bash
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter test test/ui/stage_test.dart
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter analyze
```
Expected: PASS；`No issues found!`

- [ ] **Step 5: 提交**

```bash
git add flutter-app/lib/ui/stage.dart flutter-app/lib/ui/swipe_to_switch.dart flutter-app/lib/state/lyrics_page_controller.dart flutter-app/lib/main.dart flutter-app/lib/app.dart flutter-app/test/ui/stage_test.dart
git commit -m "feat(ui): 播放卡接入歌词条与双语开关，补左右滑切歌"
```

---

## Task 19: 完整歌词页、页面控制器与 L / Esc

**Files:**
- Create: `flutter-app/lib/ui/lyrics_page.dart`
- Modify: `flutter-app/lib/ui/shell.dart`（新增 `overlay` 槽）
- Modify: `flutter-app/lib/ui/home_page.dart`
- Modify: `flutter-app/lib/core/shortcuts.dart`
- Modify: `flutter-app/lib/app.dart`（快捷键回调）
- Test: `flutter-app/test/ui/lyrics_page_test.dart`
- Test: `flutter-app/test/ui/shell_overlay_test.dart`

**Interfaces:**
- Consumes: `LyricsPageController`（T18 已建并注册）、`LyricsState` / `BilingualState` / `PlayerState` / `LyricsView(full)` / `BilingualToggle` / `LyricsStatusLine`
- Produces:
  ```dart
  class LyricsPage extends StatefulWidget {
    const LyricsPage({this.onClose, super.key});
  }
  ```

**页面结构（spec §13）：**

- 头部：左上角「返回」按钮（图标 + 文案，`Semantics(label: '关闭歌词页')`）；中间是 `title-row`：歌名 + `BilingualToggle`（与播放卡同一组件、同一规格）；下一行 `artist · album`（都空时 `未知歌手`）。右上角**本段留空**——波形样式下拉属 M3，不要凭空造一个。
- 正文：宽 ≥900 时两列 `minmax(0,560px) clamp(240px,26vw,360px)`、间距 32；左列歌词、右列封面（正圆/方图按现有 `CoverDisc` 的静态形态，**不旋转**，点它留空——灯箱是 M2b）。宽 <900 单列，封面隐藏。
- 左列：`state` 为 loading/missing/error 且 `cues.isEmpty && plainLines.isEmpty` 时显示状态块（居中的一句话 + 重试按钮，文案 `status` 或 `正在加载歌词…`）；否则 `LyricsView(variant: LyricsVariant.full)`。**两种情况都保留顶部状态行**（只要 `note || status` 非空）。
- 控制条不在此页内——它由 `HomeLayout` 留在下方（见下）。
- `Esc` 与「返回」都关页；关闭后焦点还给 `Stage` 的曲目区（用 `FocusNode`：打开时记住 `FocusManager.instance.primaryFocus`，关闭后 `requestFocus`；拿不到就退到 `stage-hit-area` 的节点）。

**`HomeLayout` 的改法（最小加法）：**

```dart
class HomeLayout extends StatelessWidget {
  const HomeLayout({
    required this.header,
    required this.stage,
    required this.panel,
    required this.transport,
    this.overlay,
    super.key,
  });
  final Widget? overlay;
  ...
}
```

- 桌面：`Expanded(child: overlay ?? Row(...))`
- 窄屏：`overlay != null ? Expanded(child: overlay!) : ...(stage/panel...)`，`transport` 始终留在最后。

**快捷键：** `shortcuts.dart` 里新增
```dart
class ToggleLyricsPageIntent extends Intent { const ToggleLyricsPageIntent(); }
class CloseOverlayIntent extends Intent { const CloseOverlayIntent(); }
```
`L` → `ToggleLyricsPageIntent`，`Escape` → `CloseOverlayIntent`；在 `withAppShortcuts` 的 `playerCallback` 里加两个 case（`'toggleLyricsPage'` / `'closeOverlay'`），由 `app.dart` 接到 `bootstrap.lyricsPage`。**输入框聚焦时让位**的逻辑沿用 M1 已有实现，不要另写一套。

- [ ] **Step 1: 写失败用例（控制器 + 页面）**

创建 `flutter-app/test/ui/lyrics_page_test.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:light_music/lyrics/lyrics_source.dart';
import 'package:light_music/lyrics/query.dart';
import 'package:light_music/lyrics/translate_source.dart';
import 'package:light_music/lyrics/upstream.dart';
import 'package:light_music/playback/track.dart';
import 'package:light_music/state/bilingual_state.dart';
import 'package:light_music/state/lyrics_state.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/ui/lyrics_page.dart';

class _Matcher implements LyricsMatcher {
  @override
  Future<LyricsMatch> match(LyricsQuery query, {CancelToken? cancel, bool useCache = true}) async =>
      const LyricsMatch(status: 'ok', synced: '[00:01]Hello\n[00:05]Darkness', plain: '');
}

class _Fetcher implements TranslationFetcher {
  @override
  Future<TranslationResult> fetch({
    required String title, required String artist, required double duration,
    CancelToken? cancel, bool useCache = true,
  }) async => const TranslationResult(
    status: 'ok',
    translatedLyrics: '[00:01]你好\n[00:05]黑暗',
    originalLyrics: '[00:01]Hello\n[00:05]Darkness',
  );
}

Widget harness({required LyricsState lyrics, required BilingualState bilingual, required Widget child}) =>
    MultiProvider(
      providers: [
        ChangeNotifierProvider<LyricsState>.value(value: lyrics),
        ChangeNotifierProvider<BilingualState>.value(value: bilingual),
      ],
      child: MaterialApp(
        theme: buildTheme().copyWith(extensions: const [AppTokensData(tokens: AppTokens.dark)]),
        home: Scaffold(body: child),
      ),
    );

void main() {
  late LyricsState lyrics;
  late BilingualState bilingual;

  setUp(() {
    lyrics = LyricsState(source: _Matcher());
    bilingual = BilingualState(lyrics: lyrics, source: _Fetcher());
  });

  testWidgets('头部：返回、歌名、双语开关；正文有歌词行', (tester) async {
    lyrics.attach(Track(
      id: 't', src: '/m/t.flac', title: 'Yesterday', artist: 'The Beatles', album: 'Help!',
      duration: 125, isLocal: true,
    ));
    await bilingual.settle();

    await tester.pumpWidget(harness(lyrics: lyrics, bilingual: bilingual, child: const LyricsPage()));
    await tester.pumpAndSettle();

    expect(find.text('返回'), findsOneWidget);
    expect(find.text('Yesterday'), findsOneWidget);
    expect(find.text('The Beatles · Help!'), findsOneWidget);
    expect(find.byKey(const Key('bilingual-toggle')), findsOneWidget);
    expect(find.text('Hello'), findsOneWidget);
    expect(find.text('你好'), findsOneWidget);
    expect(find.byKey(const Key('lyrics-page-cover')), findsOneWidget);
  });

  testWidgets('窄屏隐藏封面', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(700, 900);
    lyrics.attach(Track(id: 't', src: '/m/t.flac', title: 'A', artist: 'B', duration: 60, isLocal: true));
    await bilingual.settle();

    await tester.pumpWidget(harness(lyrics: lyrics, bilingual: bilingual, child: const LyricsPage()));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('lyrics-page-cover')), findsNothing);
  });

  testWidgets('没有歌词时显示状态块与重试', (tester) async {
    final failing = LyricsState(source: _NotFoundMatcher());
    final b = BilingualState(lyrics: failing, source: _Fetcher());
    failing.attach(Track(id: 't', src: '/m/t.flac', title: 'A', artist: 'B', duration: 60, isLocal: true));
    await b.settle();

    await tester.pumpWidget(harness(lyrics: failing, bilingual: b, child: const LyricsPage()));
    await tester.pumpAndSettle();
    expect(find.text('未找到「A」的歌词'), findsOneWidget);
    expect(find.byKey(const Key('lyrics-retry')), findsOneWidget);
  });
}

class _NotFoundMatcher implements LyricsMatcher {
  @override
  Future<LyricsMatch> match(LyricsQuery query, {CancelToken? cancel, bool useCache = true}) async =>
      const LyricsMatch(status: 'not-found');
}
```

- [ ] **Step 2: 写失败用例（overlay 槽）**

创建 `flutter-app/test/ui/shell_overlay_test.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/ui/shell.dart';

Widget harness({Widget? overlay}) => MaterialApp(
  home: Scaffold(
    body: HomeLayout(
      header: const SizedBox(key: Key('h'), height: 40),
      stage: const SizedBox(key: Key('s')),
      panel: const SizedBox(key: Key('p')),
      transport: const SizedBox(key: Key('t'), height: 60),
      overlay: overlay,
    ),
  ),
);

void main() {
  testWidgets('桌面：overlay 替换两列，transport 仍在', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 900);
    await tester.pumpWidget(harness(overlay: const Text('歌词页')));
    await tester.pump();
    expect(find.text('歌词页'), findsOneWidget);
    expect(find.byKey(const Key('s')), findsNothing);
    expect(find.byKey(const Key('p')), findsNothing);
    expect(find.byKey(const Key('h')), findsOneWidget);
    expect(find.byKey(const Key('t')), findsOneWidget);
  });

  testWidgets('窄屏：overlay 替换 stage + panel，transport 仍在', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 900);
    await tester.pumpWidget(harness(overlay: const Text('歌词页')));
    await tester.pump();
    expect(find.byKey(const Key('s')), findsNothing);
    expect(find.byKey(const Key('p')), findsNothing);
    expect(find.byKey(const Key('t')), findsOneWidget);
  });

  testWidgets('没有 overlay 时结构不变', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 900);
    await tester.pumpWidget(harness());
    await tester.pump();
    expect(find.byKey(const Key('s')), findsOneWidget);
    expect(find.byKey(const Key('p')), findsOneWidget);
  });
}
```

- [ ] **Step 3: 跑用例确认失败**

```bash
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter test test/ui/lyrics_page_test.dart test/ui/shell_overlay_test.dart
```
Expected: FAIL —— 文件 / 参数不存在。

- [ ] **Step 4: 实现五个文件并跑绿**

`HomePage` 接线：

```dart
final page = context.watch<LyricsPageController>();
...
child: HomeLayout(
  header: AppHeader(...),
  stage: const Stage(),
  panel: const Panel(),
  transport: const TransportBar(),
  overlay: page.isOpen ? const LyricsPage() : null,
),
```

`app.dart` 的 `playerCallback` 加两个 case（`bootstrap.lyricsPage` 已在 T18 建好并注册）：

```dart
case 'toggleLyricsPage':
  bootstrap.lyricsPage.toggle();
case 'closeOverlay':
  if (bootstrap.lyricsPage.isOpen) bootstrap.lyricsPage.close();
```

- [ ] **Step 5: 跑用例确认通过 + 全量回归 + 静态检查**

```bash
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter test
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter analyze
```
Expected: 全绿；`No issues found!`

- [ ] **Step 6: 提交**

```bash
git add flutter-app/lib/ui/lyrics_page.dart flutter-app/lib/ui/shell.dart flutter-app/lib/ui/home_page.dart flutter-app/lib/core/shortcuts.dart flutter-app/lib/app.dart flutter-app/test/ui/lyrics_page_test.dart flutter-app/test/ui/shell_overlay_test.dart
git commit -m "feat(ui): 完整歌词页、overlay 槽与 L/Esc 快捷键"
```

---

## Task 20: 验收闸口

**Files:**
- Create: `flutter-app/docs/M2A-ACCEPTANCE.md`
- Modify: `docs/superpowers/specs/2026-11-06-flutter-port-design.md`（§8 追加 M2a 落地记录，与 M1 的写法一致）

**Interfaces:**
- Consumes: 全部
- Produces: 验收记录（含真实网络探测结果与未验项）

- [ ] **Step 1: 四条闸口**

```bash
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter analyze
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter test
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter build windows --debug
cd flutter-app && PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter build apk --debug
```
每条都要**现场取产物尾行与文件字节数**，不许引用上一次的结论。

- [ ] **Step 2: 真实上游探测（三条，各自记录时间与状态）**

```bash
curl -sS -o "$TEMP/lrclib-get.json" -w '%{http_code} %{time_total}\n' \
  'https://lrclib.net/api/get?track_name=Yesterday&artist_name=The%20Beatles&duration=125'
curl -sS -o "$TEMP/ne-search.json" -w '%{http_code} %{time_total}\n' \
  -H 'Accept: application/json' -H 'User-Agent: light-music-react/1.0 (+vite dev middleware)' \
  'https://music.163.com/api/search/get?s=The%20Beatles%20Yesterday&type=1&limit=20'
curl -sS -o "$TEMP/ne-lyric.json" -w '%{http_code} %{time_total}\n' \
  -H 'Accept: application/json' -H 'User-Agent: light-music-react/1.0 (+vite dev middleware)' \
  'https://music.163.com/api/song/lyric?id=536622304&lv=1&tv=1'
```
把三行状态码与耗时写进验收文档。**用带时间戳的临时文件名**，不要复用固定名（M1 有过陈旧文件造成假结论的事故）。

- [ ] **Step 3: 写 `flutter-app/docs/M2A-ACCEPTANCE.md`**

必含四节：

1. **闸口结果**：四条命令的尾行 + 产物路径与字节数。
2. **自动化覆盖**：列出 T2–T19 的用例文件与条数，以及 spec §16 点名的那几类（LRC 多时间戳/offset/逐字/署名行、认歌与对齐、双语三条生命周期、当前行居中、带初速度的滑切歌）。
3. **真实链路**：Step 2 的三条结果；以及「Windows 真机跑一次在线歌词 + 双语」的实际命中情况（歌名、是否有时间轴、译文行数、对齐覆盖率）。**若网络当天不通，如实写「未验」并写明原因，不要写「通过」。**
4. **未验项 / 已知差异**：至少包含——
   - Android 真机上的在线歌词与译文（M1 已验过播放链路，但歌词网络未在真机跑）；
   - OpenCC 转简体只在 Node 黄金样本上对表，未与线上大量真实歌词做回归；
   - 波形样式下拉、T 高亮色、频谱、黑胶旋转、灯箱（M2b / M3）；
   - `isOnline` 恒 true（无平台通道），离线只能以 `unreachable` 表达；
   - `unavailable` 档不可达；
   - 播放卡歌名字号仍是 M1 的 16px，spec §13 写的是 `clamp(19px, 4.8vw, 26px)` —— 本段没有改它（避免主题/排版返工混进歌词交付），留到 M3 的视觉收口一起对齐，这里如实记录。

- [ ] **Step 4: spec §8 追加记录**

在 §8（M1 落地记录那节）末尾按同样格式追加一段「M2a 落地」，写清：新增文件清单、四处有意差异（topology/韧性合并、无 offline 预判、无 unavailable、批量落库）、以及 OpenCC 纯 Dart 移植的许可证与生成器位置。

- [ ] **Step 5: 提交**

```bash
git add flutter-app/docs/M2A-ACCEPTANCE.md docs/superpowers/specs/2026-11-06-flutter-port-design.md
git commit -m "docs: M2a 验收记录与设计文档 §8 落地记录"
```

---

## Self-Review 结果（写计划时已逐条过）

**Spec 覆盖**

| spec 要求 | 落在 |
| --- | --- |
| §11 LRCLIB 多路 / 对调 / 双 key | T8 |
| §11 抗抖动（重试、Retry-After、404、冷却、自动重试文案） | T6 + T8 + T13 |
| §11 双层缓存 30d/3d | T7 + T11 |
| §11 四类失败与中文话术 | T6 + T8 + T13 |
| §11 LRC 格式兼容 / offset / 逐字 / 署名行 | T2 |
| §11 纯文本降级 | T2 + T13 + T17 |
| §11 双语（判语种、认歌、对齐、覆盖率） | T9 + T10 + T11 |
| §11 三条生命周期规则 | T14 |
| §11 转简体 | T4 + T5 |
| §11 手动 .lrc 批量配对 / 不被联网覆盖 | T12 + T13（manual 分支不联网） |
| §13 两处开关、26px 规格、只在非中文时出现 | T16 + T18 + T19 |
| §13 当前行只换色、译文 400 | T17 |
| §13 歌词无滚动条、手动暂停 2.6s | T17 |
| §13 歌词区弹性填满（歌词页） | T19（`Expanded` + `LyricsView(full)`） |
| §13 滑切歌 56px / 700ms / 方向 | T18 |
| §13 完整歌词页（左歌词右封面、返回、控制条在下方） | T19 |
| §14 L / Esc | T19 |
| §16 测试文件命名与断言类别 | T2/T9/T11/T17 + T13/T14 |
| §17 M2a 范围 | 全局约束「范围」 |
| §19 不新增控件、不改 React | 全局约束 |

**占位符扫描：** 无 TBD / TODO。T12 里 `ToastSink.error` 的时长参数给了确定的改法；T15 的两个替身名与所在文件都已核实（随 `lib/` 发布）。

**类型一致性：** `LyricsRecord`（T7）与 `TranslationRecord`（T11）字段不同、名字不同；`LyricsMatcher` / `TranslationFetcher` 两个接口在 T8/T11 定义、T13/T14 消费、T15 注入，签名一致；`LyricsQuery.duration` 全程 `int` 秒，磁盘键拼接用 `'${duration}'`；`LyricLine.time` 全程 `double`（未知为 `NaN`）。

**已知的计划内取舍（执行时不要「顺手修好」）：**
- 歌词链路的 job 数与顺序、`getErrors` 优先于 `searchHit`、search 按原方向打分 —— 全部照抄代理。
- 空气手时写一条 swapped 垃圾缓存条目 —— 照抄。
- 25s 自动重试会被 60s 冷却拦掉 —— 照抄（真实行为）。
- 候选列表在去重之后追加「只搜歌名」，artist 为空时会重复搜一次 —— 照抄。