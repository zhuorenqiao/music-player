# M3 视觉与律动 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 Flutter 端补齐 React 版的视觉与律动层：两维换肤（ThemeMode×ThemeColor，6 组 token 表 + system 解析 + legacy 迁移 + 换肤抽屉）、卡面透明/磨砂双滑块（glass-level/frost-level）、离线 FFT 频谱管线（audio_decoder + fft 包，串行 isolate 队列 + spectrum 缓存 + fallback 装饰链）、17 个波形样式 + 彩色开关 + WaveStrip 两处挂载 + T 高亮色 8 预设 + highlightOnLight 压暗公式、黑胶旋转与唱臂过冲落位、封面光晕呼吸、面板滚动条 auto-hide、reduced-motion 全链、浅色主题对比度实测。

**Architecture:** 三层。`lib/theme/` 扩成 6 组 token 静态实例 + `ThemeState`（ChangeNotifier：mode/color/glass/frost/waveStyle/waveColored/lyricColor 七个维度，一个 provider 管全部外观设置，持久化各自落各自键）；`lib/wave/` 是纯逻辑（wave-signal 三态采样器、wave-styles 17 个 painter、wave-thumb 缩略图、highlightOnLight 纯函数、spectrum 解析管线）；UI 只消费 `context.tokens` + 外观状态。**pubspec 本段解冻**（spec §15 设计表与 §20 风险表都点名 audio_decoder 0.8.1 / fft 0.5.1，镜像实测两包可解析且 audio_decoder 声明 Windows `AudioDecoderPluginCApi`——新增依赖仅此两个，其余不动）。

**Tech Stack:** Flutter 3.47.9 / Dart 3.13.7；新增 `audio_decoder ^0.8.1`（离线解 PCM，Windows/Android 双端声明）、`fft ^0.5.1`（radix-2）。镜像环境变量照旧；`pub get` 后 `pubspec.lock` 的 url 行与 Windows 生成文件可能漂移，提交时**只 add 白名单路径**（与 M2a 同一条纪律）。

**Spec:** `docs/superpowers/specs/2026-11-06-flutter-port-design.md` §9（外观系统）、§10（频谱子系统）、§13（界面与交互）、§14（输入与无障碍）、§16（测试与验收）、§17（M3 范围）。

**基准:** React **工作区现状**（含未提交的 glass.tsx / GlassControl.tsx 与 app.css +299 行——卡面透明/磨砂功能的主体就在这些未提交改动里，调研报告 §8 已核对）。React 侧任何文件全程**只读**。

---

## Global Constraints

每个任务的要求都隐含包含本节全部条目。

### 环境与命令

- Flutter CLI：`/d/flutter/bin/flutter`，在 `flutter-app/` 内执行；每条命令带镜像变量：
  ```bash
  PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn /d/flutter/bin/flutter <cmd>
  ```
- 静态检查 `flutter analyze` 必须 0 issue；构建闸口 `build windows --debug` 与 `build apk --debug`。
- **禁止** `git add -A`；只 add 白名单路径（pubspec.yaml、pubspec.lock、lib/、test/、docs/；**生成文件** `windows/flutter/generated_*` 若漂移一并 add——它们是 pub get 的合法产物，不 add 会让后续构建反复漂移）。
- **禁止** amend / rebase / push / 仓库级 `dart format`；**禁止**改 React 侧任何文件。

### 换肤语义（spec §9 + theme.tsx 逐字）

- 两维正交：`ThemeMode = system|light|dark` × `ThemeColor = mint|pink|blue`；解析成 6 组 token：`(dark,mint)` 即现 `AppTokens.dark`，`(dark,pink)`、`(dark,blue)`、`(light,mint)`、`(light,pink)`、`(light,blue)`。
- 持久化键：`themeMode`（缺省 `system`）、`themeColor`（缺省 `mint`）；**legacy 迁移**逐字（theme.tsx:72-95）：`theme` 键为 `system/light/dark` → 折进 mode；为 `mint/pink/blue` → mode 记 `dark` 且折进 color。
- system 解析：Flutter 用 `MediaQuery.platformBrightnessOf(context)`（监听同义）；`resolvedMode = mode=='system' ? (platformDark?'dark':'light') : mode`。
- `themeKey = "$resolvedMode-$color"`——波形与渐变以它为重画依赖。
- 6 组 token 的**颜色值逐字**取 app.css：深色粉/蓝（:257-294/:299-336）、浅色薄荷（:129-214）、浅色粉/蓝（:229-239/:241-251，只覆写强调色组 + bg-grad，其余沿用浅色薄荷）。深色蓝的 `accentLine` 是 `rgba(141,180,255,0.34)`（:321，**不是** rgba(77…)）。
- 浅色特有的字段进 token 表：`pastOpacity`（深 0.62 / 浅 0.82，:196）、`pastOpacityPage`（深 0.5 / 浅 0.8，:197）、`scrim`、`scrimStrong`、`surface/surface2/surface3`（选中态用，浅色覆写 app.css:3139-3164）、`glowA/glowB`（光晕用）、`frostSheenA/SheenB/Bloom/FrostTint/CoverOpacity/CoverFilterBlur/CoverFilterSat/CoverFilterBrightness/VeilA/VeilB`（磨砂组）、`vinylLow/Mid/Hi/Line`（黑胶，深浅同值）、`scrollThumb`（auto-hide 滑块，深 0.28 白 / 浅 0.26 深蓝）。
- 黑胶在两套主题下都保持深色实体反光（spec §9）——vinyl 四色深浅同值，token 里只放一份。

### 玻璃双滑块（glass.tsx + app.css:429-504 逐字）

- `transparency`（0~100，越大越透）→ `glassLevel = 1 - t/100`；`frost`（0~100，越大越磨砂）→ `frostLevel = f/100`。clamp 到 0~100（Math.round 语义 = Dart `.round()`）。
- **frost 老用户迁移**：无 `cardFrost` 键时 frost = cardTransparency（glass.tsx:37-44）——用 `prefs.containsKey` 判定。
- 卡面 alpha：`cardA/B` 按 `glassLevel` 缩放 alpha（Flutter 侧 `Color.withValues(alpha: base.a * glassLevel)`；base.a=0 的 cardB 保持 0）。**只作用于播放卡与面板两族容器**（app.css .player :429-456 与 .panel :1350-1377；弹层/抽屉不缩放）。
- 磨砂层（frostLevel>0）：`BackdropFilter(blur(16 + frost*26), saturate(1 + frost*0.65))` + 膜层 opacity=frostLevel（sheen 渐变 + veil + bloom 径向 + frostTint 径向 + 噪点颗粒——Flutter 侧噪点用 `ui.Image` 预生成一次的 fractalNoise 等价物可省，先以四层渐变 + 颗粒 `CustomPainter` 的哈希白点近似，视觉验收真机比对）。
- 玻璃后封面垫（`.glass-frost` :481-504）：播放卡与面板各垫一张当前封面模糊图，`opacity = frostLevel * frostCoverOpacity`，`blur 44 / saturate 1.6 / brightness 0.7`（深色）或 `blur 44 / saturate 1.4 / brightness 1.35`（浅色），窄屏 blur 降 30（app.css:217-225）。Flutter 用 `Image.file` + `BackdropFilter`/`ImageFilter.blur` 实现，取 `coverForDisplay` 当前那张。
- 滑杆 UI：水滴按钮（T 右侧，26×26）→ 向上弹面板两行滑杆「透明 / 磨砂」（GlassControl.tsx:42-104 逐字：aria-label、`%` 文案、`--slider-percent` 填充）。

### 频谱管线（spec §10 + wave-signal/spectrum 逐字）

- **解析离线**（Flutter 无 AnalyserNode 等价物）：`audio_decoder` 解 PCM（默认 44100Hz 单声道求和）→ Hann 窗 `frameSize=2048` / `hop=1024`（相邻帧取能量最大者对齐 50ms 一帧）→ `fft` 取幅度谱 → `readBands` 公式折叠 64 段（spec §10.1 逐字）+ 时域 128 点峰谷包络 → 落盘 `spectrum/<trackKey>.bin`（16 字节头：魔数 `LSPC`、版本 1、sampleRate uint32、frameMs uint16、bandCount uint16=64、waveCount uint16=128、frameCount uint32；帧数据 bands 64×uint8 + wave 128×int8 = 192B/帧）。key 指纹 = 路径 + mtime + 大小，任一变化重算。串行 isolate（`compute`）队列，当前曲目插队。
- **播放时读取**：`WaveSource.read(positionSeconds)` 按当前进度取帧（帧间线性插值）；暂停冻结最后一帧真实数据；无帧表 → `fallbackBands/fallbackWave` 装饰信号（wave-signal.ts:61-96 逐字：钟形包络 center=0.38+(root%25)/100、spread=0.16+((root>>>5)%10)/100、jitter、edge 压低、wobble；wave 五正弦 f1~f5 权重 0.5/0.27/0.14/0.06/0.03、level=0.35+((root>>>17)%40)/100、×env×2.6）。装饰回退是**显式降级状态**，状态行明示「当前非真实频谱」。
- `audio_decoder` 在 Windows 解 24bit FLAC 是 spec §18 点名的未验项：**T-x 首日实测**，失败则整条频谱走显式降级链（状态行说明），不阻塞其余交付。

### 波形渲染（wave-styles.ts + WaveStrip.tsx 逐字）

- 17 样式一个不减（id/name/ramp/usesPeaks 见调研 §3.2 表）：`spectrum/ribbon/hairline/sine/roundBars/blob/strands/noise/histogram/mirrorArea/jagged/hatch/spikes/led/flow/dots/hills`，各一个 `CustomPainter`（Canvas 等价绘制）。hue ramp 三条（sunset/ember/neon，:25-32 逐字，允许 >360 跨红端）。
- bandCount/waveCount **按画布宽动态**：strip `bandCount = max(24, round(w/4))`、`waveCount = clamp(round(w), 120, 512)`（WaveStrip.tsx:80/:100）；thumb `bandCount = max(14, w/3)`、`waveCount = max(64, w)`（wave-thumb.ts:32/:39）。
- 渲染循环：`phase += dt * PHASE_SPEED(3)`；`playing && !reduced` 才推进（Ticker），否则画一帧冻结；峰值衰减 `pow(0.03, dt)` 仅 `usesPeaks` 样式（WaveStrip.tsx:114-118）；HEIGHT=48。
- **彩色开关**：`waveColored`（缺省 true）；关 = 单色模式 `monoColor` 的亮度映射公式（wave-styles.ts:71-76：`l = clamp(52 + (light-56)*1.8, 46, 90)`，h/s 来自高亮色）与 `buildMonoGradient` 的 12 段 `88-30*t`（:79-87）。
- **T 高亮色 8 预设**（LyricColorButton.tsx:14-23 逐字）：`薄荷（默认）''`、`青 #7de3ff`、`蓝 #8aa9ff`、`紫 #b98cff`、`玫红 #ff8fc7`、`橙 #ffb066`、`金 #ffe066`、`白 #f2f7fb`；`lyricColor` 缺省 ''。消费点 6 处：当前行歌词色（lyrics_view.dart:334 的 accentLight → 换 lyricColor）、T 色板预览、单色波形色相、歌词辉光（若启用）。
- `highlightOnLight`（theme.tsx:160-219 逐字移植）：`channelLum`（0.03928 阈值）、`luminance`（0.2126/0.7152/0.0722）、`contrastOnWhite = 1.05/(l+0.05)`、每步压 6%（factor 0.94 递减到 0.12）直到对比度 ≥4.5。**浅色主题 + 用户色**才压；色板预览显示压暗后颜色（所见即所得）。
- `setWaveAccent`：hex → HSL 后 `s = min(100, (hsl.s + 78)/2)`（wave-styles.ts:98-102）；默认回退 accentLight 的 HSL，取不到 `{h:160, s:85}`。

### 挂载位置（React App.tsx 对译）

- **WaveStrip 两处**：① Transport 进度行**上方**新增 `transport__wave` 行（App.tsx:973-977：`LyricColorButton + GlassControl + WaveStrip` 三件套，所有断点统一）；② 歌词页右栏封面下方（App.tsx:1144）。首页（非歌词页）的 transport 行里 WaveStrip **隐藏**（app.css:1111 `.transport__wave .lyrics-page__wave { display:none }`）——即首页该行只有 T + 水滴两个按钮；歌词页时该行 WaveStrip 显示且右栏那条隐藏（app.css:3915-3934）。
- **WaveStylePicker 下拉**：歌词页右上角（App.tsx:1104，React 版此处是它；Flutter 的 lyrics_page.dart:230 注释已留位）。面板结构：头部「彩色」开关（role=switch）+ 17 项列表（缩略图 + 名称，wave-thumb 静态渲染）。
- **黑胶**：`CoverDisc.spinning` 接真动画（24s/圈 linear infinite，暂停冻 `animation-play-state` 等价物 = 保留当前角度）；唱臂 SVG（App.tsx:454-485 的 path 逐字）+ 支点 97%/3%、暂停 -45°、播放 -17°、`0.75s cubic-bezier(0.34, 1.56, 0.64, 1)` 过冲；封面光晕呼吸（::before :939-964：accent-rgb 0.42 径向 + blur20，glow 4.2s opacity 0.4↔0.85，播放时 opacity 0.7）。
- **换肤抽屉**：drawer_menu 加一级入口「换肤」→ 二级抽屉（ThemeDrawer.tsx 逐字：明暗三段选择 system/light/dark + 主题色三 swatch mint/pink/blue，选中即时生效、抽屉不关可来回比对；mode==system 时提示行「当前跟随系统：深色/浅色」）。
- **面板 auto-hide 滚动条**：HIDE_DELAY=900、USER_INPUT_WINDOW=700、SCROLL_KEYS 集合（useAutoHideScroll.ts 逐字）——只认用户滚动（滚轮/触摸/滚动键打点），程序化滚动（歌词居中）不点亮；Flutter 侧给播放列表/最近两个 ListView 包自绘 scrollbar（`Listener` 打点 + `NotificationListener<ScrollNotification>` + 900ms 收起 + thumb 颜色 scrollThumb），歌词区保持完全无滚动条（M2a 已做）。
- **reduced-motion**：`MediaQuery.disableAnimationsOf(context)`——封面旋转/光晕/频谱动画/音柱/骨架全停（光晕保留 opacity 0.5 静态，app.css:4226-4228）；频谱只画一帧静态（WaveStrip.tsx:66-67 对译）。

### 颜色纪律

- `lib/ui/` 不出现颜色字面量，一律 `context.tokens`；token 表内 `0xAARRGGBB` 字面量。
- 本段新增 token 字段一次性扩齐（见换肤语义节），**不再出现「M3 翻表」的欠账**。

---

## File Structure

新建（`flutter-app/` 下）：

| 文件 | 职责 |
| --- | --- |
| `lib/theme/theme_state.dart` | 外观状态机：mode/color/glass/frost/waveStyle/waveColored/lyricColor 七维，legacy 迁移，themeKey，持久化。 |
| `lib/theme/color_utils.dart` | `highlightOnLight`、hex↔HSL、`parseHex/luminance/contrastOnWhite`（纯函数）。 |
| `lib/wave/wave_signal.dart` | `WaveFrame`、`fallbackBands/fallbackWave`（FNV-1a 装饰）、`WaveSource`（按 positionSeconds 读帧 + 冻结 + 插值）。 |
| `lib/wave/spectrum_pipeline.dart` | 离线解码 → Hann 窗 → fft → readBands 折叠 → .bin 落盘/读取；串行 isolate 队列 + 插队 + key 指纹。 |
| `lib/wave/wave_styles.dart` | 17 个 `CustomPainter` + 三条 hue ramp + `wavePalette`（彩色/单色）+ `setWaveAccent`。 |
| `lib/wave/wave_thumb.dart` | 下拉缩略图 painter（bandCount=max(14,w/3)）。 |
| `lib/ui/wave_strip.dart` | WaveStrip widget：Ticker 循环、峰值衰减、reduced-motion 静帧。 |
| `lib/ui/wave_style_picker.dart` | 歌词页右上角下拉（彩色开关 + 17 项）。 |
| `lib/ui/lyric_color_button.dart` | T 按钮 + 8 预设色板。 |
| `lib/ui/glass_control.dart` | 水滴按钮 + 透明/磨砂双滑杆面板。 |
| `lib/ui/theme_drawer.dart` | 换肤二级抽屉（明暗三段 + 主题色三 swatch）。 |
| `lib/ui/auto_hide_scrollbar.dart` | 播放列表/最近的 auto-hide 滚动条宿主。 |
| `lib/ui/tonearm.dart` | 唱臂 widget（SVG path 逐字 + 旋转动画 + 过冲曲线）。 |
| `lib/ui/glass_frost.dart` | 磨砂膜层 + 玻璃后封面垫（BackdropFilter 组合）。 |

修改：

| 文件 | 改什么 |
| --- | --- |
| `lib/theme/app_tokens.dart` | 扩字段（pastOpacity 等约 25 个）+ 5 个新静态实例（dark-pink/dark-blue/light-mint/light-pink/light-blue），dark-mint 补齐新字段默认值。 |
| `lib/theme/app_theme.dart` | `buildTheme(tokens)` 不变；`AppTokensData.lerp` 保持硬切。 |
| `lib/main.dart` / `lib/app.dart` | 装配 `ThemeState`（先 await 读完再 runApp）、MaterialApp 的 theme 随 ThemeState 切换、provider 注册。 |
| `lib/ui/drawer_menu.dart` | 加「换肤」一级入口。 |
| `lib/ui/stage.dart` / `lib/ui/vinyl_deck.dart` | 旋转动画、光晕呼吸、唱臂挂载。 |
| `lib/ui/lyrics_view.dart` | 当前行色走 lyricColor（highlightOnLight 后）。 |
| `lib/ui/lyrics_page.dart` | WaveStylePicker 挂右上角；右栏封面下方 WaveStrip。 |
| `lib/ui/transport.dart` | progress 行上方加 transport__wave 行（T/水滴/WaveStrip，首页 WaveStrip 隐藏）。 |
| `lib/ui/panel.dart` | 两个 ListView 包 auto-hide 滚动条 + 磨砂玻璃面板。 |
| `lib/ui/shell.dart` / `lib/ui/home_page.dart` | 播放卡玻璃化（glass-level 缩放 + frost 层）。 |
| `lib/core/storage_keys.dart` | 键全在，不动。 |

测试（镜像）：

| 文件 | 覆盖 |
| --- | --- |
| `test/theme/theme_state_test.dart` | 7 维读写、legacy 迁移、themeKey、frost 回填、clamp |
| `test/theme/tokens_test.dart`（扩展） | 6 组实例的关键色逐字断言（accent/accentLight/text/bg 四组 × 6） |
| `test/theme/color_utils_test.dart` | highlightOnLight 全档（达标原样/压暗步进/最暗档）、hex↔HSL 往返 |
| `test/wave/wave_signal_test.dart` | fallbackBands/Wave 黄金数值、冻结语义、插值 |
| `test/wave/spectrum_pipeline_test.dart` | 合成 PCM → .bin 往返、头字段、指纹失效、插队 |
| `test/wave/wave_styles_test.dart` | 17 样式 painter 构造不抛、ramp 色值、monoColor 映射 |
| `test/ui/wave_strip_test.dart` | Ticker 循环/暂停冻结/reduced-motion 静帧/彩色开关 |
| `test/ui/theme_drawer_test.dart` | 抽屉开合、选择即时生效、跟随系统提示行 |
| `test/ui/glass_control_test.dart` | 滑杆写状态与持久化、面板开合 |
| `test/ui/transport_wave_test.dart` | transport__wave 行三件套、首页隐藏 WaveStrip |
| `test/ui/vinyl_deck_test.dart`（扩展） | 旋转角度推进/暂停保角/唱臂 -45→-17 过冲/光晕 opacity |
| `test/ui/auto_hide_scrollbar_test.dart` | 用户滚动点亮、程序化不点亮、900ms 收起 |

---

## Task 1: pubspec 解冻与依赖实测（首日风险项前置）

**Files:** Modify: `flutter-app/pubspec.yaml`、`pubspec.lock`
- [ ] **Step 1:** `pubspec.yaml` dependencies 加 `audio_decoder: ^0.8.1` 与 `fft: ^0.5.1`，带镜像变量 `pub get`；确认 lock 只多两包。
- [ ] **Step 2:** **首日实测**（spec §18 风险表）：写一次性 `tool/decode_probe_test.dart`（或临时 test），用 `tools/gen_demo_audio.py` 生成的 wav（`public/assets/audio/track-01.wav`）走 `audio_decoder` 解 PCM，断言 sampleRate/channels/时长合理；再补一个 24bit FLAC 用例（本机曲目或合成），失败如实记录——失败则后续频谱任务走显式降级链。
- [ ] **Step 3:** `analyze` 0 issue；提交（含漂移的生成文件）：
  ```bash
  git add flutter-app/pubspec.yaml flutter-app/pubspec.lock flutter-app/windows/flutter/generated_plugins.cmake flutter-app/windows/flutter/generated_plugin_registrant.* flutter-app/tool/decode_probe_test.dart
  git commit -m "chore(deps): M3 解冻 pubspec——audio_decoder 与 fft，解码实测通过"
  ```

---

## Task 2: 颜色工具与 highlightOnLight

**Files:** Create: `lib/theme/color_utils.dart`；Test: `test/theme/color_utils_test.dart`
- [ ] 逐字移植：`parseHex`（`^#([0-9a-f]{6})$`）、`channelLum`（0.03928/12.92 与 2.4 幂）、`luminance`（0.2126/0.7152/0.0722）、`contrastOnWhite`（1.05/(l+0.05)）、`highlightOnLight(hex, {min=4.5})`（factor 0.94 递减 0.06 到 0.12）、`hexToHsl`。
- [ ] 测试：`#ffe066` 深色原样、浅色压暗后对比度 ≥4.5；`#f2f7fb` 压到最暗档仍达标与否按公式断言；黄金值（`#ffe066` 压暗结果逐字）；HSL 往返。
- [ ] **Step 4:** Commit `feat(theme): highlightOnLight 与颜色工具——浅色高亮压暗公式`

---

## Task 3: token 表扩齐与 6 组实例

**Files:** Modify: `lib/theme/app_tokens.dart`；Test: `test/theme/tokens_test.dart`（扩展）
- [ ] 扩字段：`glowA/glowB`、`surface/surface2/surface3`、`scrim/scrimStrong`、`pastOpacity/pastOpacityPage`、`scrollThumb`、`frostSheenA/frostSheenB/frostBloom/frostTint/frostCoverOpacity/frostCoverBlur/frostCoverSat/frostCoverBrightness/frostVeilA/frostVeilB`、`vinylLow/vinylMid/vinylHi/vinylLine`；`AppTokens.dark` 补默认值（scrim `0xA804080C`/strong `0xBD04080C`、surface 同 tint 族、vinyl `0x0F/0x17/0x29/0x29 FFFFFF`）。**lightboxScrim 改用 scrimStrong 对齐**（.86 vs .74 差一档——保留 lightboxScrim 不动，标注与 scrim-strong 的 CSS 差异源）。
- [ ] 5 个新实例，颜色逐字（调研 §1.2 表）：`darkPink`、`darkBlue`（accentLine 0x578DB4FF = rgba(141,180,255,0.34)）、`lightMint`、`lightPink`、`lightBlue`；浅色危险态翻转（dangerInk 0x9D1B30 系）、toastBg #FFFFFF。
- [ ] 测试：6 组 × (bg/accent/accentLight/text) 逐字 + brightness 推导 + pastOpacity。
- [ ] Commit `feat(theme): 六组主题 token——两维换肤的颜色表`

---

## Task 4: ThemeState 外观状态机

**Files:** Create: `lib/theme/theme_state.dart`；Test: `test/theme/theme_state_test.dart`
- [ ] 七维：mode/color/transparency/frost/waveStyle/waveColored/lyricColor；`resolvedMode`（注入 `platformBrightness` 回调）；`themeKey`；legacy `theme` 键迁移；frost 缺省回填 cardTransparency（containsKey）；clamp 0~100；写回各自键。
- [ ] 测试：inMemory prefs 全维度读写、迁移矩阵（system/light/dark/mint/pink/blue/light 键）、frost 回填、resolvedMode 随注入切换、themeKey 格式。
- [ ] Commit `feat(theme): ThemeState——七维外观状态与 legacy 迁移`

---

## Task 5: 装配换肤（ThemeState → MaterialApp）

**Files:** Modify: `lib/main.dart`、`lib/app.dart`；Test: `test/state/theme_wiring_test.dart`
- [ ] `buildBootstrap` 建 ThemeState（先读 prefs；main() 先 await 再 runApp）；`LightMusicApp` 的 `MaterialApp.theme` 改随 `context.watch<ThemeState>()` 的 resolvedMode+color 选 token 实例；provider 注册。
- [ ] 测试：改 mode/color → MaterialApp 主题变化（context.tokens 断言）；持久化往返。
- [ ] Commit `feat(app): 装配换肤——主题随 ThemeState 切换`

---

## Task 6: 换肤抽屉

**Files:** Create: `lib/ui/theme_drawer.dart`；Modify: `lib/ui/drawer_menu.dart`；Test: `test/ui/theme_drawer_test.dart`
- [ ] 一级入口「换肤」→ 二级抽屉：明暗三段（系统/浅色/深色，aria-pressed 语义 =选中态样式）、主题色三 swatch、system 提示行、抽屉不关可来回比对。
- [ ] 测试：开合、三段选择即时生效（token 变化）、提示行文案逐字。
- [ ] Commit `feat(ui): 换肤二级抽屉与菜单入口`

---

## Task 7: 玻璃双滑块与磨砂层

**Files:** Create: `lib/ui/glass_control.dart`、`lib/ui/glass_frost.dart`；Modify: `lib/ui/shell.dart`（播放卡）、`lib/ui/panel.dart`；Test: `test/ui/glass_control_test.dart`
- [ ] 水滴按钮（T 右侧 26×26）+ 两行滑杆（透明/磨砂，`aria-valuetext %`）；glassLevel/frostLevel 从 ThemeState 读。
- [ ] 播放卡与面板：cardA/B alpha × glassLevel；frostLevel>0 时 `BackdropFilter(blur 16+26f, saturate 1+0.65f)` + 膜层（sheen/veil/bloom/tint 四层渐变，opacity=frostLevel）+ 玻璃后封面垫（opacity=frost*frostCoverOpacity，blur44/sat/brightness 按 token，窄屏 blur 30）。
- [ ] 测试：滑杆改值写 ThemeState + 持久化；glassLevel=1 / 0 的卡面 alpha 断言；frost 层存在性。
- [ ] Commit `feat(ui): 卡面透明/磨砂双滑块与磨砂玻璃层`

---

## Task 8: 频谱管线（离线解码 → .bin）

**Files:** Create: `lib/wave/spectrum_pipeline.dart`；Test: `test/wave/spectrum_pipeline_test.dart`
- [ ] 按 spec §10.1 逐字：audio_decoder 解 PCM（44100 单声道求和）→ Hann 2048/1024 相邻帧取能量最大者 → fft → readBands 64 段（spec 公式）+ 128 点峰谷包络 → .bin（16B 头 LSPC/1/sampleRate/frameMs/64/128/frameCount + 192B/帧）；串行 isolate 队列 + 当前曲目插队；指纹（路径+mtime+size）失效重算。
- [ ] 测试：合成正弦 PCM → 跑管线 → 读回帧数/头字段/某帧 bands 非零且低频高；指纹变化重算；插队语义。
- [ ] **风险闸**：Task 1 的解码实测若失败，本任务改为只实现管线骨架 + 状态行降级文案，真实解码分支 `if (false)` 留位并注释原因。
- [ ] Commit `feat(wave): 离线频谱管线——解码、折叠与缓存`

---

## Task 9: 波形数据源（三态采样器）

**Files:** Create: `lib/wave/wave_signal.dart`；Test: `test/wave/wave_signal_test.dart`
- [ ] `WaveFrame`（bands/wave/level/phase/dt/width/height/live/seed）；`fallbackBands/fallbackWave` 逐字；`WaveSource.read({positionSeconds})`：有帧表 → 按 position 插值取帧（live=true）；无帧表 → 装饰；暂停冻结最后真实帧。
- [ ] 测试：装饰黄金数值（`hashString` 已有）、冻结不回退、插值线性、live 标志。
- [ ] Commit `feat(wave): 三态波形数据源与装饰回退`

---

## Task 10: 17 波形样式与调色

**Files:** Create: `lib/wave/wave_styles.dart`、`lib/wave/wave_thumb.dart`；Test: `test/wave/wave_styles_test.dart`
- [ ] 三条 hue ramp（允许 >360）+ `rampColor/wavePalette/monoColor/buildMonoGradient`（公式逐字）+ `setWaveAccent`（s=(s+78)/2）。
- [ ] 17 个 painter 一个不减（调研 §3.2 表逐参数：每样式的平滑遍数、alpha、freq、cols 公式、峰值行为）；`StyleEnv` 等价物（Canvas + frame + palette + peaks）。
- [ ] 测试：ramp 色值黄金断言（sunset t=0/0.5/1）、monoColor 映射边界（46/90）、painter 构造不抛（空 bands/满 bands/波谷波峰）。
- [ ] Commit `feat(wave): 17 波形样式 painter 与调色系统`

---

## Task 11: WaveStrip 与两处挂载

**Files:** Create: `lib/ui/wave_strip.dart`；Modify: `lib/ui/transport.dart`、`lib/ui/lyrics_page.dart`；Test: `test/ui/wave_strip_test.dart`、`test/ui/transport_wave_test.dart`
- [ ] WaveStrip：Ticker 循环（phase += dt*3）、峰值衰减 pow(0.03,dt)、暂停冻结、reduced-motion 静帧、HEIGHT 48、bandCount/waveCount 动态。
- [ ] transport 进度行上方加行（T + 水滴 + WaveStrip；**首页 WaveStrip 隐藏**）；歌词页右栏封面下方挂 WaveStrip。
- [ ] 测试：播放推进/暂停冻结/reduced 静帧；首页该行只有两钮、歌词页显示。
- [ ] Commit `feat(ui): WaveStrip 频谱条与两处挂载`

---

## Task 12: T 高亮色与彩色开关

**Files:** Create: `lib/ui/lyric_color_button.dart`、`lib/ui/wave_style_picker.dart`；Modify: `lib/ui/lyrics_view.dart`；Test: `test/ui/theme_color_test.dart`
- [ ] T 按钮（8 预设逐字）+ 色板弹层（点外收起/Esc 收起、浅色预览压暗）；WaveStylePicker 下拉（彩色开关 role=switch + 17 项缩略图列表）；歌词当前行色走 lyricColor（浅色过 highlightOnLight）——6 个消费点一次接齐（调研报告 §3 清单）。
- [ ] 测试：选色持久化 + 歌词当前行色变化 + 彩色开关持久化 + 预览色浅色压暗。
- [ ] Commit `feat(ui): T 高亮色色板、彩色开关与歌词行配色联动`

---

## Task 13: 黑胶旋转、唱臂与光晕呼吸

**Files:** Create: `lib/ui/tonearm.dart`；Modify: `lib/ui/vinyl_deck.dart`、`lib/ui/stage.dart`；Test: `test/ui/vinyl_deck_test.dart`（扩展）
- [ ] 封面旋转：Ticker 驱动角度累计（24s/圈 linear），暂停**保留当前角度**（等价 play-state:paused）；reduced-motion 不转。唱臂：SVG path 逐字（App.tsx:454-485）、支点 97%/3%、-45°↔-17°、`0.75s Curves.easeOutBack 等价 cubic-bezier(0.34,1.56,0.64,1)`（Flutter `Cubic(0.34, 1.56, 0.64, 1)`）、播放时薄荷微光 drop-shadow。光晕：播放时径向渐变层（accent-rgb 0.42、blur 20、glow 4.2s 0.4↔0.85、静态 0.7），reduced 保留 0.5 静态。
- [ ] 测试：播放推进角度递增、暂停保角、reduced 不转；唱臂两档角度 + 动画曲线存在；光晕 opacity 档位。
- [ ] Commit `feat(ui): 黑胶旋转、唱臂过冲落位与封面光晕呼吸`

---

## Task 14: auto-hide 滚动条与 reduced-motion 收口

**Files:** Create: `lib/ui/auto_hide_scrollbar.dart`；Modify: `lib/ui/panel.dart`；Test: `test/ui/auto_hide_scrollbar_test.dart`
- [ ] HIDE_DELAY=900 / USER_INPUT_WINDOW=700 / SCROLL_KEYS 六键；只认用户滚动（Listener 打点 wheel/touch/按键），程序化滚动不点亮；已亮起跟滚完再收；thumb 色 scrollThumb，8px。
- [ ] reduced-motion 收口盘点：旋转/光晕/频谱/音柱/骨架/抽屉动效全过一遍（对照 app.css:4207-4229 清单），逐处接 `disableAnimationsOf`。
- [ ] 测试：用户滚动点亮→900ms 收；程序化不点亮；reduced 下各动画点为静态。
- [ ] Commit `feat(ui): 面板滚动条 auto-hide 与 reduced-motion 收口`

---

## Task 15: 浅色对比度实测与验收闸口

**Files:** Create: `flutter-app/docs/M3-ACCEPTANCE.md`；Modify: spec（§22 M3 落地记录）
- [ ] 四条闸口（analyze/test/windows/apk）现场取尾行与字节数。
- [ ] **对比度实测**（spec §9/§16）：浅色主题下当前行/未唱/已唱三档对白底的实际对比度，与 README 的 5.31/5.11/4.35 对表（用 Dart 算 luminance 而非截图）；highlightOnLight 产物对比度 ≥4.5 抽验。
- [ ] 真机项：Windows 跑一遍换肤 6 组合 + 双滑块 + 17 样式切换 + 黑胶旋转 + auto-hide；Android 真机捏合/reduced-motion/磨砂性能。**跑不了的如实写未验**。
- [ ] spec 追加 §22（新增文件清单、有意差异、audio_decoder 实测结论）。
- [ ] Commit `docs: M3 验收记录与设计文档 §22 落地记录`

---

## Self-Review 结果（写计划时已逐条过）

**Spec 覆盖**

| spec 要求 | 落在 |
| --- | --- |
| §9 两维换肤、6 组 token、legacy 迁移、system 解析 | T3 + T4 + T5 + T6 |
| §9 highlightOnLight 公式与色板所见即所得 | T2 + T12 |
| §9 玻璃材质（BackdropFilter + 封面模糊底 + 手机 blur30） | T7 |
| §10.1 解析管线（Hann/2048/1024/readBands/.bin/指纹/插队） | T8 |
| §10.2 17 样式一个不减、彩色/单色、降级链显式化 | T9 + T10 + T11 |
| §13 WaveStrip 两处、T/水滴位置、WaveStylePicker 右上角 | T11 + T12 |
| §13 黑胶 24s、唱臂 -45/-17 过冲、光晕 glow | T13 |
| §13 auto-hide 900ms、只认用户滚动 | T14 |
| §14 reduced-motion 全链 | T13 + T14 |
| §16 浅色对比度实测 | T15 |
| §17 M3 范围 / §19 不新增控件 | 全局约束 |

**关键裁定（执行时不要「顺手改回」）：**
1. pubspec 本段解冻，但只加 audio_decoder + fft 两个包（spec §15 设计表既定）；audio_decoder 实测失败走显式降级链，不阻塞。
2. bands/wave 数量按画布宽动态（React 同款），**不是** spec §10.1 落盘格式里的 64/128——落盘 64/128 是缓存帧格式，读取端按显示宽度插值/抽稀，两回事。
3. 首页 transport__wave 行 WaveStrip 隐藏（app.css:1111），不是「首页也有频谱」。
4. 暂停频谱冻结最后真实帧（不回退装饰）；封面旋转保角（不回 0°）。
5. glass-level 只作用于播放卡 + 面板两族；弹层/抽屉/灯箱不缩放。
6. 深色蓝的 accentLine 是 rgba(141,180,255,0.34)，不是 accent 同色的 0.34——逐字照抄。

**占位符扫描：** 无 TBD。全部常量逐字给出；黄金数值来源已注明（node 现算 / wave-styles.ts 逐字）。
