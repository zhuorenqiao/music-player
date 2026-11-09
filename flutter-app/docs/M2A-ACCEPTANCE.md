# M2a 验收记录（歌词与双语）

> 采集时间：2026-11-09 20:19~20:25（Asia/Shanghai）。
> 本文件所有尾行、字节数、状态码都是**当次现场取回**的，不引用上一轮的结论。
> 命令一律带 `PUB_HOSTED_URL=https://pub.flutter-io.cn` /
> `FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn`，在 `flutter-app/` 内执行。
> 分支：`feat/flutter-m2a-lyrics-bilingual`，HEAD `2491e13`。

---

## A. 四条闸口

| # | 命令 | 尾行（原文） | 产物 |
| --- | --- | --- | --- |
| 1 | `flutter analyze` | `No issues found! (ran in 6.8s)` | — |
| 2 | `flutter test` | `00:36 +787: All tests passed!` | — |
| 3 | `flutter build windows --debug` | `√ Built build\windows\x64\runner\Debug\light_music.exe`（139.3s） | `light_music.exe`，**1,031,680 bytes**，20:20:56 |
| 4 | `flutter build apk --debug` | `√ Built build\app\outputs\flutter-apk\app-debug.apk`（256.4s） | `app-debug.apk`，**216,730,493 bytes**，20:23:27 |

说明：Windows 构建日志里的 `Nuget.exe not found, trying to download or use cached version.`
是 Flutter 工具链首次取 NuGet 的提示，不是失败 —— 以 `√ Built` 与产物字节数为准。
`flutter.bat` 在 PowerShell 下会把镜像提示写进 stderr，导致 `[exit code: 1]`；
四条闸口**全部以 stdout 尾行为准**（与 M1 验收同一口径）。

### 测试构成

`flutter test` 的 787 是运行时计数（含 `group` / 循环参数化），静态 `test(` /
`testWidgets(` 声明数 575，差额来自参数化用例。M2a 本段新增/扩展的用例文件：

| 任务 | 用例文件 | 声明数 |
| --- | --- | --- |
| T2 | `test/lyrics/lrc_parser_test.dart` | 26 |
| T3 | `test/core/name_split_test.dart` / `test/lyrics/query_test.dart` | 9 / 15 |
| T4 | `test/lyrics/opencc_trie_test.dart` | 15 |
| T5 | `test/lyrics/opencc_converter_test.dart` | 6 |
| T6 | `test/lyrics/upstream_test.dart` | 21 |
| T7 | `test/lyrics/lyrics_cache_test.dart` | 21 |
| T8 | `test/lyrics/lyrics_source_test.dart` | 19 |
| T9 | `test/lyrics/translate_lang_test.dart` / `translate_align_test.dart` | 11 / 26 |
| T10 | `test/lyrics/netease_match_test.dart` | 50 |
| T11 | `test/lyrics/translate_cache_test.dart` / `translate_source_test.dart` | 11 / 17 |
| T12 | `test/lyrics/manual_lyrics_test.dart` / `test/library/import_service_test.dart` | 22 / 29 |
| T13 | `test/state/lyrics_state_test.dart` | 22 |
| T14 | `test/state/bilingual_state_test.dart` | 28 |
| T15 | `test/state/lyrics_wiring_test.dart` | 4 |
| T16 | `test/ui/bilingual_toggle_test.dart` / `lyrics_status_test.dart` | 3 / 5 |
| T17 | `test/ui/lyrics_view_test.dart` | 25 |
| T18 | `test/ui/stage_test.dart` | 20 |
| T19 | `test/ui/lyrics_page_test.dart` / `shell_overlay_test.dart` / `test/core/shortcuts_test.dart` | 3 / 3 / 8 |

spec §16 点名的类别逐条对上：

- **LRC 多时间戳 / `[offset:]` / 逐字标签 / 署名行**：`lrc_parser_test.dart`（T2），另
  `translate_lang_test.dart` 有「方括号标签与逐字标签不计入语种统计」。
- **认歌与对齐**：`netease_match_test.dart`（T10，50 例，reviewer 另以 16,559 例差分
  模糊测试对 React 逐字实现零语义偏差）、`translate_align_test.dart`（T9，中位数偏移 /
  `>20s` 不可信 / 1.5s 起手保护 / 0.25 与 0.5 覆盖率闸 / 首次出现优先）。
- **双语三条生命周期规则**：`bilingual_state_test.dart`（T14，28 例 —— 关掉再开立刻恢复且
  不打网络、换歌清掉上一首、重开后台刷新失败不覆盖手上这份）。
- **当前行居中 / 只换色 / 译文 400 / 无滚动条 / 手动暂停 2.6s**：
  `lyrics_view_test.dart`（T17，25 例，含「程序化居中不算手动」）。
- **带初速度的滑切歌**：`stage_test.dart`（T18，`flingFrom` 带初速度、`56px / 700ms /
  |dx| >= |dy|*1.25 / 单指 / dx>0 → playPrevTrack`）。
- **手动 `.lrc` 批量配对**：`manual_lyrics_test.dart`（T12，含 512KB **字节**闸用中文内容
  钉住、`normalizeName` 压缩空白用 `a b` vs `ab` 钉住、`dot > 0` 鉴别性用例）。

---

## B. 真实链路探测（Step 2 的三条 curl）

带时间戳临时文件（`m2a-<时间戳>-<名字>.json`），不复用固定名（M1 有过陈旧文件造成假结论的事故）：

| # | 目标 | 结果 | 响应体 | 临时文件 |
| --- | --- | --- | --- | --- |
| 1 | `lrclib.net/api/get?track_name=Yesterday&artist_name=The Beatles&duration=125` | **200 / 19.075329s** | 9,326 bytes | `%TEMP%\m2a-20261109-201915-lrclib-get.json` |
| 2 | `music.163.com/api/search/get?s=The Beatles Yesterday&type=1&limit=20` | **200 / 0.755219s** | 15,414 bytes | `%TEMP%\m2a-20261109-201915-ne-search.json` |
| 3 | `music.163.com/api/song/lyric?id=536622304&lv=1&tv=1` | **200 / 0.357485s** | 4,538 bytes | `%TEMP%\m2a-20261109-201915-ne-lyric.json` |

第 2、3 条带 `Accept: application/json` 与
`User-Agent: light-music-react/1.0 (+vite dev middleware)`，**不带** Referer / Cookie /
浏览器 UA —— 与 `TranslateSource` 的请求头一致（`upstream.dart` 的 `_upstreamHeaders`）。

三条都是 **200**，与 spec §18 的 2026-11-07 实测口径一致；LRCLIB `get` 本次 19.1s，
落在 `get` 单程预算 12s 之外但仍在整次匹配 60s 总预算内（真实链路里 `get` 路只占一个
job，另有并行 job 与冷却闸，见 §11「直连合并裁定」）。

⚠️ **「Windows 真机跑一次在线歌词 + 双语」：未验**。本会话只做到四条自动闸口 + 三条
curl 探测，没有在 Windows 真机上用真实曲目跑一遍在线歌词命中 → 双语对齐 → 高亮滚动的
完整链路。真实性状（歌名、是否有时间轴、译文行数、对齐覆盖率）**没有采集**，不写「通过」。
理由：GUI 会话里没有真机交互通道；这一项留给人工按 `docs/M1-ACCEPTANCE.md` B 节的格式补。

---

## C. 未验项 / 已知差异

| 项 | 现状 |
| --- | --- |
| **Android 真机上的在线歌词与译文** | 未验。M1 已验过播放链路，但歌词的 Dart 直连网络没有在真机跑；`app-debug.apk` 已构建成功，只证明可打包。 |
| **Windows 真机在线歌词 + 双语全链路** | 未验（见 B 节末）。 |
| **OpenCC 转简体** | 只在 Node 黄金样本（`test/fixtures/opencc_golden.json`，32 条）上对表；未与线上大量真实繁体歌词做回归。词典由 `tool/gen_opencc_dicts.mjs` 从 `node_modules/opencc-js` 生成，五份内嵌词典与 upstream 逐字节相同（6,157 条）。 |
| **波形样式下拉 / T 高亮色 / 频谱 / 黑胶旋转 / 灯箱** | 明确不做（M2b / M3，spec §19）。歌词高亮本段用 `accentLight`。 |
| **`isOnline` 恒 true** | Flutter 没有平台连通性 API、本段不引依赖；离线分支保留且可注入，生产上离线只会走真实的 `unreachable` 错误，不会说「当前离线」。 |
| **`unavailable` 档不可达** | 直连无 Node 代理，枚举与话术保留以便对照，但实现永不产出它。 |
| **播放卡歌名字号** | 仍是 M1 的 16px；spec §13 写的是 `clamp(19px, 4.8vw, 26px)`。本段没改它（避免主题/排版返工混进歌词交付），留到 M3 视觉收口一起对齐。 |
| **歌词 `search` 单程 45s 实测** | spec §18 的 2026-11-07 记录是 `api/search` 45.0s 才回 200；本段单程预算取代理值 26s（与 React 带代理时同口径），慢搜索会按 `timeout` 说实话并回退过期缓存。列为已知差异。 |
| **`retryAfterCap` 死参数** | T8 的公开参数零消费者（钳制在 T6 内部）；T20 未删，作为发布代码里的已知冗余记录（计划原定 T20 处理，本会话按「不改已验收接口」保留）。 |
| **计划文档里 8 处错误的用例期望** | **已回写**（commit `4c9214c`，2026-11-09）：`plan.md` L2905 / L2910 / L2927 / L2932-2933 / L2938 / L2942 / **L2991** / L3045-3051（T10 reviewer 用 node 逐字复核判 implementer 全对）；另连同 T3 两处、T4 R14 散文、T12 D2、T11 TTL 算术共 15 处一并结清。逐处写明「brief 说 X / 实测 Y / 依据」。 |

---

## D. M2a 落地摘要（供 spec §8 追加）

**新增**（`flutter-app/` 下）：`lib/core/name_split.dart`、`lib/lyrics/` 下
`lrc_parser.dart` / `query.dart` / `opencc/{trie,dicts,converter}.dart` /
`upstream.dart` / `lyrics_cache.dart` / `lyrics_source.dart` /
`translate_lang.dart` / `translate_align.dart` / `netease_match.dart` /
`translate_cache.dart` / `translate_source.dart` / `manual_lyrics.dart`；
`lib/state/{lyrics_state,bilingual_state,lyrics_page_controller}.dart`；
`lib/ui/{lyrics_view,lyrics_status,bilingual_toggle,swipe_to_switch,lyrics_page}.dart`；
`tool/{gen_opencc_dicts,opencc_oracle}.mjs`、`test/fixtures/opencc_golden.json`、
`third_party/{opencc-js-LICENSE.txt,opencc-LICENSE.txt}`；以及上述 20 个测试文件。

**修改**：`lib/main.dart` / `lib/app.dart`（装配 + provider + 快捷键回调）、
`lib/theme/app_tokens.dart`（`tint1`）、`lib/playback/play_error.dart` /
`lib/core/file_picking.dart` / `lib/library/import_service.dart` /
`lib/state/library_state.dart`（`.lrc` 分流与批量落库）、
`lib/ui/{stage,shell,home_page}.dart` / `lib/core/shortcuts.dart`、
`lib/playback/transport_controller.dart` / `lib/state/toast_state.dart`
（`ToastSink.error` 加可选 `durationMs`，10 个实现点同步）。

**四处有意差异**（相对 React 工作区现状）：

1. **拓扑与韧性合并**：React 的 Vite 中间件代理**不移植**，Dart 直连上游，于是代理侧的
   「2~5 路 job 并行 + 等全部结束按 job 顺序裁决 + 四类错误分类 + 过期缓存回退」由
   `lib/lyrics/lyrics_source.dart` 自己承担，与客户端侧的「冷却闸 + 退避 + 自动重试
   文案」合并在同一条链里。歌词 `get` 12s / `search` 26s / 总预算 60s；译文 8s / 2 次
   / 固定 400ms / 只重试 timeout+unreachable。
2. **无离线预判**：`isOnline` 恒 true（不引平台依赖），离线只能以 `unreachable` 表达。
3. **无 `unavailable` 档**：直连无代理，枚举与话术保留以便对照，实现永不产出。
4. **批量落库**：`ManualLyrics.apply` 不落库，整批结束后由
   `LibraryState.applyLyricsFiles` 统一 `persist() + _changed()`（React 逐条 persist），
   用户可见行为一致、省下几十次整库重写。

**OpenCC**：纯 Dart 移植（码位 Trie + IDS 步长 + 两级转换 + `toSimplified` 的 FIFO 64
缓存与「妳 / 甚么」后处理），不引依赖。词典由
`tool/gen_opencc_dicts.mjs` 从 `node_modules/opencc-js` 生成，`tool/opencc_oracle.mjs`
产出 32 条 Node 黄金样本；许可全文在 `third_party/opencc-js-LICENSE.txt`（MIT）与
`third_party/opencc-LICENSE.txt`（Apache-2.0）。**注意 R14**：`loadDictGroup` 的实际
优先级是「数组里靠前的词典赢」，与计划散文写的相反，实现忠于 upstream。

---

## 签核

- 四条自动闸口：**全绿**（2026-11-09 20:19~20:25，HEAD `2491e13`）。
- 三条真实上游探测：**全 200**。
- 真机在线歌词 + 双语链路：**未验**（如实记录，不冒充通过）。
- ledger：`.superpowers/sdd/2026-11-07-flutter-m2a-lyrics-bilingual/progress.md`。
