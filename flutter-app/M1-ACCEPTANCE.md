# M1 验收记录：核心播放（T30 收口）

范围：spec §3「M1 范围内」的全部条目 —— 本地文件/文件夹导入、内嵌标签与封面、
播放控制与三种模式、进度与缓冲、音量与静音、两个 tab 与列表内搜索、桌面快捷键、
系统媒体会话、原版异常矩阵里 M1 相关行、持久化键语义。**不含**歌词与双语、
封面 2–4 级兜底、放大层、换肤/玻璃/波形（M2/M3）。

记录分两半：**A 是机器已经跑过的**（命令与真实输出直接抄在下面，任何人重跑
同样四条命令 —— analyze / test / build windows / build apk —— 就能复核）；
**B 是必须真人上手的**（出声、系统控件、息屏这类断言写不进 widget test）。
每条 B 都写了具体动作，打勾时把结果就地填进「结果」列。

---

## A. 已自动执行

工作目录 `flutter-app/`，Flutter 3.47.9 / Dart 3.13.7，
分支 `feat/flutter-m1-core-playback`，采集时间 2026-11-07。

### A1 四条闸口的真实尾巴（终审修复波收尾重新采集）

工作目录 `flutter-app/`，Flutter 3.47.9 / Dart 3.13.7，
分支 `feat/flutter-m1-core-playback`，采集时间 2026-11-07，代码状态到本文件
所在的那条 docs 提交（其前一条是 `45badbe`，即终审修复波最后一笔代码改动）。

`flutter analyze --no-fatal-infos`：

```text
Analyzing flutter-app...
No issues found! (ran in 8.8s)
```

`flutter test`：

```text
00:34 +380: All tests passed!
```

测试数轨迹：T30 收口 324 → 第 1 段末（C1/C2 + I1–I5）361 → 本波收尾
（A1/A2 + minor 1–6 全部落地后）**380 全绿**；中间各段的数字没有逐段采集，
只有首尾这三个是实测抄下来的。本波没有删除任何既有用例；唯一被改写的既有
断言是 I2 的 `expect(driver.calls, contains('seek:12.0'))`（旧断言记录的正是
缺陷本身）与 `test/core/shortcuts_test.dart` 的键表（六组→八组）。

`flutter build windows`：

```text
Building Windows application...
Nuget.exe not found, trying to download or use cached version.
Building Windows application...                                   108.2s
√ Built build\windows\x64\runner\Release\light_music.exe
```

产物实测：`light_music.exe` 92,160 字节（启动器本身没重编，时间戳不变属正常）、
`data/app.so` 7,095,176 字节（跟着构建更新）、整个 `Release/` 目录 44 MB。

`flutter build apk --debug`：**本波这一条没过**（两次重跑各卡在一步，原文照抄）。
第一次（SDK 平台没装全）：

```text
Warning: The plugin permission_handler_android requires Android SDK version 37 or higher.
...
* What went wrong:
Could not determine the dependencies of task ':permission_handler_android:compileDebugJavaWithJavac'.
> Failed to find target with hash string 'android-37' in: C:\Users\Administrator\AppData\Local\Android\Sdk

BUILD FAILED in 1m 43s
Gradle task assembleDebug failed with exit code 1
```

工具链当场接受许可证并装了 `platforms/android-37.0`，第二条命令重跑后走过那一步，
落在 AAR metadata 检查：

```text
Your project is configured to compile against Android SDK 36, but the following plugin(s) require to be compiled against a higher Android SDK version:
- permission_handler_android compiles against Android SDK 37

* What went wrong:
Execution failed for task ':app:checkDebugAarMetadata'.
> A failure occurred while executing com.android.build.gradle.internal.tasks.CheckAarMetadataWorkAction
   > An issue was found when checking AAR metadata:

       1.  Dependency ':permission_handler_android' requires libraries and applications that
           depend on it to compile against version 37 or later of the Android APIs.

           :app is currently compiled against android-36.

           Also, the maximum recommended compile SDK version for Android Gradle
           plugin 9.1.0 is 36.

BUILD FAILED in 2m 11s
Gradle task assembleDebug failed with exit code 1
```

归因（写在这里免得被当成本波的代码缺陷）：`permission_handler` 13.0.2 /
`permission_handler_android` 14.1.1 是 **T22**（`f8d5c9f`）引入的，本波一条 commit
都没碰 `flutter-app/pubspec.yaml`、`pubspec.lock`、`android/`（`git diff --stat` 为空）。
上一次 `build apk --debug` 通过是工具链刚装完那次（progress.md 记的 175 MB，
**早于** T22），此后各段只跑 analyze + test，没再跑过这条闸口。
修法（换 `permission_handler` 版本 / 升 AGP 到支持 compileSdk 37 的那一档 /
调 `android/app/build.gradle.kts`）都超出「本波不改依赖与构建配置」的授权范围，
留待裁定；因此 B8（Android 真机段）连构建产物一起仍是 pending。

`data/app.so` 的时间戳跟着构建更新，启动器 exe 本身没重编，
所以它的时间戳不变 —— 这是正常的，别当成「没构建」。

### A2 每条自动验收对应哪些用例

| 验收条目 | 用例位置 |
| --- | --- |
| 八个键的映射与步长（±5 秒 / ±5%，另 N=下一首、P=上一首） | `test/core/shortcuts_test.dart`「快捷键表覆盖八组键，且不抢媒体键与歌词页的 L / Esc」「八个 Intent 的步长与 README 一致：±5 秒 / ±5%」「N 下一首、P 上一首」 |
| 空格切播放、←→ 快进快退、↑↓ 调音量、M 静音 | 同上「空格切播放、左右 ±5 秒、上下 ±5%、M 静音」 |
| 输入框聚焦时整套让位 | 同上「输入框聚焦时快捷键全部让位」 |
| 滑块聚焦时方向键不双触发 | 同上「滑块聚焦时方向键交回原生，不双触发」 |
| 空格不滚页面（= 原版 preventDefault） | 同上「空格被快捷键层消费，列表不滚动」 |
| 焦点在按钮上时空格归按钮 | 同上「焦点在按钮上时空格交给按钮本身…」 |
| 快捷键接到真 PlayerState 四个动作 | `test/integration/m1_smoke_test.dart` 第 3–7 步 |
| T25–T29 每颗控件都有读屏名 | 同上第 2 步（15 个控件的语义审计表） |
| 播放/暂停可 Tab 到、控制条顺序与视觉一致 | 同上第 8 步 |
| 模态路由（抽屉）开着时快捷键不穿透 | 同上第 9 步 |
| `ToastsHost` 的 liveRegion 仍生效 | 同上第 10 步 + `test/ui/toasts_test.dart` |
| 减少动态效果：音柱静止 | `test/ui/track_row_test.dart`「减少动态效果时音柱不建动画，直接静止」 |
| 减少动态效果：加载转圈不走动画 | `test/ui/transport_test.dart`「减少动态效果时加载转圈不走动画…」 |
| 导入 / 标签解析 / 播放编排 / 持久化 / 异常矩阵 | T1–T29 的 315 条存量用例（`test/metadata`、`test/playback`、`test/state`、`test/library`、`test/ui`） |

自动化覆盖不到的东西没有打勾，全部列在 B。

### A3 终审修复波：一条缺陷 ↔ 改在哪 ↔ 哪条测试守着

编号用 `final-review-fix-brief.md` 的原编号（A1/A2 是第 2 段 brief 的收尾项，
与 minor 4 同源）。测试名逐条从 `test/` 里 grep 出来，与 `flutter test` 的输出行
一致；commit 列是本波的提交链，`87318d3` 是终审前的 HEAD。

| 编号 | 缺陷一句话 | 改在哪 | 守它的测试 | commit |
| --- | --- | --- | --- | --- |
| C1 | 回填批次不落库（标签/封面/时长只在内存里），且冷启动不自愈 | `lib/library/import_service.dart`、`lib/state/library_state.dart`、`lib/main.dart` | `test/state/library_state_test.dart`「导入回填完成后会再落一次库：重启读档带标签、时长与封面」「一批导入的回填只多落一次库，不是每首一次」「回填批次收尾会通知界面（不只是改了内存对象）」「冷启动还原把缺元数据的旧记录补跑回填，并再落一次库」「还原时元数据齐备的曲目不重复回填，也不多落库」 | `a25b968` |
| C2 | 「最近播放」整场会话不刷新（只在冷启动画一次） | `lib/library/recent_store.dart`、`lib/state/recent_state.dart`、`lib/main.dart` | `test/state/recent_state_test.dart`「store.record 之后监听者收到一次通知，条目真的变长」「remove / clear / markInPlaylist 同样通知订阅者」「RecentState.dispose 之后不再被 store 回调（不泄漏）」「RecentState.fake 也接上同一条通知链」＋`test/state/app_bootstrap_test.dart`「播放推进就刷「最近播放」；删掉已听过的歌，失效标记跟着变（C2）」 | `a25b968` |
| I1 | `durationProbe` 从未接上，无标签曲目时长永远缺失 | `lib/library/duration_probe.dart`（新）、`lib/library/import_service.dart`、`lib/playback/media_kit_driver.dart`、`lib/main.dart` | `test/library/duration_probe_test.dart`「预算默认 3000ms，与原版 DURATION_PROBE_TIMEOUT 同值」「探到正值就用；非有限 / 0 / 负数一律归成 NaN」「opener 超时不返回：到点给 NaN，不许把调用方扣住」「opener 抛异常：吞掉并给 NaN，绝不冒泡」「并发调用也只一次开一个媒体：队列串行，不雪崩」「一条超时或抛错不会卡住后面的探测」＋`test/library/import_service_test.dart`「时长探测成功则填，探不出保持未知」＋`test/state/app_bootstrap_test.dart`「组合根给导入服务接上时长探测（I1）」「注入的探测接缝真的接到导入：无时长曲目落库时带上了时长」 | `1fbcf6f` |
| I2 | 界面播放按钮走重载：暂停再点播放会从 0:00 重来 | `lib/playback/transport_controller.dart` | `test/playback/transport_controller_test.dart`「暂停再点是重放同一条 resume：load 次数不增加、位置不变（I2）」「内核里没有这一首时 togglePlay 才加载」 | `1fbcf6f` |
| I3 | 音量拖到 0 被持久化成「静音」，重启后解不掉 | `lib/state/player_state.dart`（`setVolume` 只写 `volume`）、`lib/playback/audio_player.dart`（`setVolume(>0)` 顺手清 muted） | `test/state/player_state_persist_test.dart`「音量拖到 0 只写音量：重启读回 volume=0 且 muted=false」「静音状态下拖音量会解掉静音，prefs 里的 muted 跟着改对」 | `1fbcf6f` |
| I4 | prefs 的 `currentId`/`order` 只写不读，过期 currentId 永不清除 | `lib/state/library_state.dart`（`restore()` / `_restoreCursor()` / `_syncPrefsTrace()`）、`lib/state/player_state.dart`（`flushPersist`）；规则同步写进 `lib/state/library_state.dart` 的注释与设计文档 §8 | `test/state/library_state_test.dart`「落库时 currentId 跟着列表走：换曲写、删空清」「还原以文件仓为准：陈旧 order 被纠正、过期 currentId 被清掉」「还原时光标仍在列表里就保留，两边一起指向同一首」「现场自洽而文件仓没记光标：prefs 那份 currentId 也要接住」「两边都指不到曲目：保持无光标，过期 currentId 被清掉而不是复活队首」＋`test/state/player_state_persist_test.dart`「停止播放之后 flushPersist 清掉 currentId，重启不复活已停的曲目」「当前曲目后来变坏：旧的 currentId 要被清掉」 | `1fbcf6f`（`feb2f88` 补对称写点） |
| I5 | 缺 `KeyN`/`KeyP`；被自动播放拦住时只有播放按钮能重试 | `lib/core/shortcuts.dart`、`lib/app.dart`、`lib/ui/autoplay_gate.dart`（新）、`lib/playback/transport_controller.dart` | `test/core/shortcuts_test.dart`「N 下一首、P 上一首」「快捷键表覆盖八组键，且不抢媒体键与歌词页的 L / Esc」「八个 Intent 的步长与 README 一致：±5 秒 / ±5%」「输入框聚焦时快捷键全部让位」＋`test/integration/m1_smoke_test.dart`「N 下一首 / P 上一首接到播放器；搜索框里打 n 不切歌」＋`test/ui/autoplay_gate_test.dart`「blocked 状态下点一下空白就重试一次」「没被拦时点空白什么都不做」「重试仍受上限约束：用完 3 次就不再碰内核」「键盘也算一次手势，但空格与回车让给按钮本身」＋`test/playback/transport_controller_test.dart`「手势重试是原地续播，不重载也不丢进度（I5）」＋`test/ui/panel_test.dart`「「继续播放」按下去就是一次 userGesture 重试」 | `8a8e153` |
| A1（＝minor 4） | 音量/静音两套存档；`LibrarySnapshot.volume/muted` 是死字段 | `lib/library/library_repository.dart`（删两字段）、`lib/state/player_state.dart`、`lib/state/library_state.dart`、`lib/app.dart`、`lib/main.dart` | `test/library/library_repository_test.dart`「存档不携带音量：文件仓只存曲目、顺序、光标与模式」「旧档案里残留的 volume / muted 被忽略，不影响曲目还原」「保存后读回，曲目、顺序、光标与模式都在」＋`test/state/player_state_persist_test.dart`「设音量 0.33 之后用同一份存档重建，读回 0.33」「静音存档重启后仍是静音，取消静音恢复的是记忆音量而不是默认 0.7」＋`test/state/app_bootstrap_test.dart`「文件仓重建（空目录）也照原样读回 prefs 里的音量」「旧档案里残留的 volume / muted 不参与还原：仍以 prefs 为准」 | `feb2f88` |
| A2 | 时长探测内核（原生 `Player`）没有释放点 | `lib/library/duration_probe.dart`（`close()` / `closeOpener`）、`lib/main.dart`、`lib/app.dart` | `test/library/duration_probe_test.dart`「close 排到队列尾部：在飞的探测先跑完，之后一律 NaN 且只关一次」「closeOpener 抛异常也不冒泡：退出收尾绝不因原生库而炸」「没给 closeOpener 时 close 仍然可用（纯逻辑探针没有原生资源）」＋`test/state/app_bootstrap_test.dart`「AppBootstrap.dispose 关掉时长探测内核（探针持有释放接缝）」「应用根卸载时释放探测内核（dispose 链接到界面层）」（`testWidgets`）「生产那份探针在测试环境里起不来原生库，dispose 依然不抛」 | `feb2f88` |
| Minor 1 | `ui/progress_slider.dart` 里写死 `Colors.white` | `lib/theme/app_tokens.dart`（新增 `sliderThumb`）、`lib/theme/app_theme.dart`（四套主题各给值）、`lib/ui/progress_slider.dart` | `test/theme/tokens_test.dart`「边框 / 危险 / 提示 / 面板层同样逐字节对齐」（`sliderThumb == Color(0xFFFFFFFF)`）、「主题装配把 token 挂到 ThemeExtension 上，滑杆 / 分隔线 / 去水波纹都接上」（`theme.sliderTheme.thumbColor` 从 token 取）。`lib/ui/library_sheet.dart:40` 是 `Colors.transparent`，非颜色用法，按终审确认保留 | `878aa87` |
| Minor 2 | `TransportView.operator==` 只比 `current?.id`，回填后不重绘 | `lib/playback/transport_controller.dart`（`==` / `hashCode` 纳入 title/artist/cover/album/broken） | `test/playback/transport_controller_test.dart`「同一首歌回填后封面 / 标题变化，视图身份要跟着变并通知订阅者」「被标损坏的同 id 曲目同样算身份变化」「时长未知（NaN）不许参与「永远不相等」：同字段两份视图仍旧相等」 | `dc2f1e6` |
| Minor 3 | 舞台总时长只看标签，内核已报到时长也显示 `--:--` | `lib/ui/stage.dart`（有限则用标签，否则回退 `transport.duration`） | `test/ui/stage_test.dart`「标签没时长时回退内核报的时长；两处都未知才是 --:--」「时长行只订阅那两片叶子，position 走动不重建整卡」 | `dc2f1e6` |
| Minor 5 | `lib/app.dart` 文件末尾缺换行 | 无改动：`feb2f88` 动这个文件时已顺带补上（`git show feb2f88:flutter-app/lib/app.dart \| tail -c 1` = `0x0A`，`dc2f1e6`/`HEAD` 同样以换行结尾）；本波又逐文件扫过 `lib/`＋`test/` 全部 `.dart`，没有一个缺末换行。纯字节层面，没有测试可守 | —（由 `feb2f88` 携带） |
| Minor 6 | 「昨天」按经过 24~48 小时算，不是按日历日 | `lib/library/recent_store.dart`（`formatRelativeTime` 用 `_sameCalendarDay`，保留「不足 24 小时先走小时前」的原版顺序） | `test/library/recent_store_test.dart`「「昨天」按日历日判定，不是按经过的小时数」「不足 24 小时一律走「小时前」，与原版同一顺序」 | `45badbe` |
| Minor 7 | 本验收文件停在 324 条那一版 | 本节（A1/A2/A3）＋ B2 2.3/2.5/2.6、B3 3.9/3.10、B6 6.3–6.6、B8 8.9/8.10、签核表 | 文档，无测试 | 本条 docs commit |

---

## B. 需要真人验

Windows 侧先跑 `flutter run -d windows`（或直接用 A1 构建出来的 Release 目录）。
「结果」列填 `通过 / 不通过 + 现象`，别只打勾。

### B1 导入真实 FLAC（文件与文件夹两条路）

| # | 动作 | 期望 | 结果 |
| --- | --- | --- | --- |
| 1.1 | 菜单 → 「添加音乐」，一次选 3 个真实 FLAC | 列表出现 3 行；歌名/歌手来自**内嵌标签**，不是文件名原样 | 待验 |
| 1.2 | 菜单 → 「添加整个文件夹」，选一个含若干音频的目录 | 目录里的支持格式一次进完；不支持的格式被静默跳过 | 待验 |
| 1.3 | 选择器里点「取消」 | 什么都不发生，不弹提示、不清空原列表 | 待验 |
| 1.4 | 有内嵌封面的那几首 | 行左侧是圆角缩略图；无封面的退回占位碟而不是空白 | 待验 |

### B2 播放与进度

| # | 动作 | 期望 | 结果 |
| --- | --- | --- | --- |
| 2.1 | 点第一行 | 出声；进度填充走动；缓冲层画在填充之外的前方；时间文字每秒刷新 | 待验 |
| 2.2 | 把进度条拖到**未缓冲**位置 | 不卡顿、不回退到起点、不闪成 0（seek 守卫生效） | 待验 |
| 2.3 | 播放中点暂停再点播放 | **原地续播**：进度不跳回 0:00、不出现静音间隙、播放键不闪转圈（终审 I2 修的就是「点了重载」） | 待验 |
| 2.4 | 加载较慢的那首 | 播放键位置显示转圈，而不是无声等待 | 待验 |
| 2.5 | 播几首后切到「最近播放」tab（不重开应用） | 刚听过的那首**当场**出现在最上面，时间写「刚刚」；从前要重开应用才刷新（终审 C2） | 待验 |
| 2.6 | 标签里没有时长的曲目（如只有 ID3v1 的 mp3）导入后播放 | 舞台与控制条的总时长由内核探出来补上（`--:--` 只是第一帧，几秒内变真实时长；终审 I1 + minor 3） | 待验 |

### B3 快捷键（M1 的桌面输入）

| # | 动作 | 期望 | 结果 |
| --- | --- | --- | --- |
| 3.1 | 空格里按 `空格` | 播放/暂停切换；页面**不**被空格滚走 | 待验 |
| 3.2 | `←` / `→` | 各 5 秒，连按连续叠加 | 待验 |
| 3.3 | `↑` / `↓` | 各 5%，夹在 0~100% | 待验 |
| 3.4 | `M` | 静音与取消静音；图标跟着换档 | 待验 |
| 3.5 | 点进搜索框打「周杰 伦」这类带空格的关键字 | 空格打进去的是空格，不出声、不动音量 | 待验 |
| 3.6 | Tab 到音量滑轨后按 `←` / `→` | 滑块自己挪一格，音量**不**被快捷键再叠一次 | 待验 |
| 3.7 | Tab 到「模式」按钮后按 `空格` | 切模式（按钮自己响应），不会同时在背后切播放 | 待验 |
| 3.8 | 打开菜单抽屉后按 `空格` / `↑↓` | 播放器完全不响应（与原版「弹层开着只认 Esc」同一意图） | 待验 |
| 3.9 | 按 `N` / `P` | `N` 下一首、`P` 上一首（`P` 同样受 4.1/4.2 的 3 秒规则约束）；`M` 仍是静音，三者互不冲突（终审 I5） | 待验 |
| 3.10 | 点进搜索框打「n」「p」这类字母 | 字母进关键字，**不**切歌（快捷键层在文本焦点里整套让位） | 待验 |

### B4 上一首的 3 秒规则与三种模式

| # | 动作 | 期望 | 结果 |
| --- | --- | --- | --- |
| 4.1 | 播过 3 秒后点「上一首」 | 回到**本曲**开头 | 待验 |
| 4.2 | 前 3 秒内点「上一首」 | 切到上一曲 | 待验 |
| 4.3 | 列表循环听 3 首 | 到尾后回到第一首 | 待验 |
| 4.4 | 单曲循环 | 到末尾原地重播；此时点「下一首」仍能切歌 | 待验 |
| 4.5 | 随机播放听一整轮 | 一轮内不重复；换轮重洗 | 待验 |

### B5 损坏文件与熔断

| # | 动作 | 期望 | 结果 |
| --- | --- | --- | --- |
| 5.1 | 暂停中把其中一首临时改名（或挪走） | 该行出现「损坏」角标，1.4 秒后自动跳下一首 | 待验 |
| 5.2 | 把列表里**每一首**都改坏 | 弹一条常驻提示「连续多首无法播放，已停止自动切歌」，不再无限跳转 | 待验 |
| 5.3 | 恢复文件后重新播放 | 熔断自动解除（`canplay` 那一下清零计数） | 待验 |
| 5.4 | 只支持部分格式的混和目录 | 不支持的格式导入时被拒并给出可读原因，不进列表 | 待验 |

### B6 重启恢复

| # | 动作 | 期望 | 结果 |
| --- | --- | --- | --- |
| 6.1 | 播几首、切一次模式、拖一次音量，然后关掉进程重开 | 歌单顺序、当前曲目、音量、模式、最近播放**全部原样** | 待验 |
| 6.2 | 上一次正在播损坏曲时退出 | 重启不试图加载那首坏文件（currentId 不写损坏曲目） | 待验 |
| 6.3 | 音量拖到 0 后重开 | 读回来是「**音量 0、没有静音**」；静音只由 `M` / 静音按钮决定，从前这里会被写坏成 muted=true 且解不掉（终审 I3） | 待验 |
| 6.4 | 加完整批歌以后什么都不动（不点播放、不改列表）直接退出重开 | 标签、歌手、封面、时长**都还在**，不会退回「只有文件名、无封面、`--:--`」—— 回填批次结束时那一次落库守着它（终审 C1） | 待验 |
| 6.5 | 静音状态下重开 | 仍是静音；取消静音恢复的是**记忆里的音量**，不是默认 0.7。音量/静音只有 prefs 一处真相，文件仓重建也不清（终审 A1 / minor 4） | 待验 |
| 6.6 | 播到第 3 首直接退出重开；再把当前那首删掉重开 | 前者接住退出时那一首（prefs 与文件仓自洽时以 prefs 的 `currentId` 为准）；后者**不复活**已删曲目、也不硬指队首，界面是「无光标」状态（终审 I4） | 待验 |

### B7 Windows 系统集成（SMTC + 媒体键 + 锁屏）

| # | 动作 | 期望 | 结果 |
| --- | --- | --- | --- |
| 7.1 | 播放中开 Windows「音量合成器/媒体控制面板」（`Win` 搜「媒体」或用锁屏） | 显示曲名、歌手、封面 | 待验 |
| 7.2 | 系统控件按「下一首 / 上一首 / 暂停」 | 与界面同步切换，界面反过来也同步 | 待验 |
| 7.3 | 键盘媒体键（`Play/Pause`、`NextTrack`、`PrevTrack`） | 生效，且**不**与键盘快捷键层重复触发 | 待验 |
| 7.4 | 锁屏界面 | 控件可见可点，曲名歌手正确 | 待验 |

### B8 Android 真机（**待设备**：本机 `flutter devices` 只有 Windows / Chrome / Edge）

> 采集本记录时这台机器上没有连任何 Android 设备或模拟器，所以 B8 整段是
> **pending-device**，一条都没有实跑过。插好设备后按下面顺序补：
> `flutter devices` 确认 → `flutter run -d android`（或 `flutter build apk --debug`
> 后 `flutter install` / `adb install -r build/app/outputs/flutter-apk/app-release.apk`）。

| # | 动作 | 期望 | 结果 |
| --- | --- | --- | --- |
| 8.1 | 「添加音乐」用系统文件选择器多选 3 首 | 三首进列表，标签与封面正确 | pending-device |
| 8.2 | 「添加整个文件夹」选一个目录 | SAF 一次授权整个目录，整目录导入成功 | pending-device |
| 8.3 | 播一首，息屏 20 分钟 | 不断播（前台服务活着），进度与通知栏一致 | pending-device |
| 8.4 | 通知栏与锁屏的四个按钮 | 播放/暂停、上一首、下一首、停止都可用且正确 | pending-device |
| 8.5 | 播放中来电 | 暂停；挂断后**不**自动续播，等用户点播放；界面提示条与「被拦」语义一致 | pending-device |
| 8.6 | 系统设置里拒绝通知权限后启动 | 仍能出声播放；提示条是权限说明文案而不是错误 | pending-device |
| 8.7 | 窄屏（<900，任选一台小屏） | 单列堆叠；控制条贴底；音量整块隐藏；五颗按钮等距；列表按钮弹底部 sheet | pending-device |
| 8.8 | 杀掉进程重开 | SAF 授权仍在（不用重新选目录），歌单/模式/音量原样恢复 | pending-device |
| 8.9 | 系统自动播放策略拦住首播（冷启动后面板显示「被拦」提示条）后，**点一下界面空白处**（不打到任何按钮） | 立刻重试一次播放；每次真实手势只花一格额度、最多 3 格，用完后提示条与「继续播放」按钮仍可手动重试（终审 I5 的 `AutoplayGestureGate`；原版 `src/App.tsx:1557-1579` 的 document 级监听） | pending-device |
| 8.10 | 被拦状态下改按手机音量键以外的**任意按键/触摸**（如列表行、播放按钮） | 同样算一次手势并原地续播：进度不回 0:00（重试走 `resume()`，不是 `load`）。代价是这些点击各消耗一格额度，属已裁定的可接受残留 | pending-device |

### B9 无障碍与减少动态效果（真人确认部分）

| # | 动作 | 期望 | 结果 |
| --- | --- | --- | --- |
| 9.1 | Windows 讲述人（或 NVDA）从头 Tab 一遍 | 每颗控件都念得出中文名字，不念图标、不重复念两遍 | 待验 |
| 9.2 | 焦点进搜索框打字 | 读屏念输入的字符，不抢着念「播放」 | 待验 |
| 9.3 | 触发一条提示（例如删掉正在播的歌） | 读屏以 live 的方式补念这条提示 | 待验 |
| 9.4 | 系统「设置 → 辅助功能 → 视觉效果 → 消除动画」打开后播放 | 当前行音柱静止在三根定格高度；加载转圈不转（1/4 弧定格） | 待验 |

### B10 已知未决项（M1 收口时仍然开着）

1. **800×600 窗口里的面板高度**。`Panel` 有一个「舒适高度」下限
   （`minComfortableHeight = 240`），低于它整块面板切成可滚动兜底布局。
   代码在（`lib/ui/panel.dart` 的 `LayoutBuilder` 分支），但**这一条分支
   既没有专门用例，也没让真人看过**：`test/ui/panel_test.dart` 只覆盖到
   「过滤时固定行不塌陷」，小窗口里列表还剩几行、统计行与搜索行会不会被
   挤得难看，全是未知。要么接受兜底样式并补一条用例，要么给面板补一档
   真正的紧凑布局。
2. **时长兜底**。标签里没有时长时，第一帧显示 `--:--`，等内核回报 duration
   才补齐（`TransportBar._totalOf` 的两级取值）。真机上要确认的是：
   这种文件在**导入瞬间**（元数据探测）与**播放瞬间**分别显示什么、
   进度条点轨道能否用（总长未知时按 0 处理，不响应）。
3. **键盘可达性缺口**（有语义、无焦点）：行的「移除」按钮、进度条、
   播放卡的两块热区都是 `GestureDetector` —— 读屏能激活，Tab 走不到。
   原版给它们的是真 `<button>`。M2 做歌词页/放大层时一并补 `Focus` +
   `ActivateIntent`，现在不改动是因为改了要连带重排整份 Tab 顺序断言。
4. **原版的 skip-link 没移植**。Flutter 里视觉顺序 = 遍历顺序，
   「跳到播放控制」那条捷径没有存在理由，属于刻意不移除的差异（B9.1 时
   按 18 次 Tab 能走完全程，无需捷径）。
5. **方向键不再移动焦点**（被快进/音量占用，与原版浏览器行为一致），
   焦点遍历只认 `Tab` / `Shift+Tab`。

---

## 签核

| 项 | 状态 |
| --- | --- |
| A（自动化闸口） | analyze 无问题（8.8s）/ `flutter test` **380 全绿** / `build windows` 成功（app.so 7,095,176 B）；**`build apk --debug` 本波是红的**：`permission_handler_android` 14.1.1 要 compileSdk 37，而 AGP 9.1.0 上限 36（原文与归因见 A1 末），本波未碰依赖与构建配置，留待裁定 |
| B1–B7（Windows 真人段） | 待真人跑 |
| B8（Android 段） | pending-device：无设备，一条未跑；且当前没有可用的 debug apk（同上） |
| B9（读屏与系统减动效） | 待真人跑 |
| B10（两个未决项 + 三个已知差异） | 开着，M2 收 |
