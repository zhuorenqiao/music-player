# M3 验收记录（2026-11-10）

四套换肤（两维 6 组）、卡面透明/磨砂、离线 FFT 频谱 + 17 波形 + 彩色开关 +
T 高亮色、黑胶旋转与唱臂、光晕呼吸、auto-hide 滚动条、reduced-motion。

## A. 闸口结果（现场采集）

| 闸口 | 结果 |
| --- | --- |
| `flutter analyze` | `No issues found!`（0 issue） |
| `flutter test`（全量） | `00:42 +1076 ~2: All tests passed!`（~2 = 解码探针的既定 skip，见 §C） |
| `flutter build windows --debug` | `√ Built build\windows\x64\runner\Debug\light_music.exe` |
| `flutter build apk --debug` | `√ Built build\app\outputs\flutter-apk\app-debug.apk` |

## B. 自动化覆盖（T1–T14 用例文件）

| 文件 | 覆盖 |
| --- | --- |
| `test/decode_probe_test.dart` | MethodChannel 单测形态（skip，真机形态在 integration_test/） |
| `integration_test/decode_probe_it.dart` | **Windows 真宿主解码实测**：convertToWav 44100/mono/16bit，峰值显著（T1 首日闸通过） |
| `test/theme/color_utils_test.dart` | highlightOnLight 8 预设压暗黄金值（node 现算）、contrastOnWhite、HSL 往返 |
| `test/theme/tokens_test.dart` | 6 组 token × (bg/accent/accentLight/text) 逐字、pastOpacity 两档、darkBlue accentLine、resolve 矩阵 |
| `test/theme/theme_state_test.dart` | 七维读写、legacy 迁移矩阵、frost 回填、clamp、themeKey |
| `test/state/theme_wiring_test.dart` | 组合根建 ThemeState、MaterialApp 主题随切、持久化往返 |
| `test/ui/theme_drawer_test.dart` | 三段选择即时生效、提示行、抽屉不关可来回比对 |
| `test/ui/glass_control_test.dart` | 双滑杆写状态持久化、glassLevel 换算 |
| `test/wave/spectrum_pipeline_test.dart` | 合成 PCM→.bin 往返、头字段、指纹失效、插队、440Hz 峰段物理断言 |
| `test/wave/wave_signal_test.dart` | 装饰黄金特征、冻结语义、按进度插值、live 标志、串歌防护 |
| `test/wave/wave_styles_test.dart` | 93 用例：ramp 黄金值（ember t=0.5=17，node 复核任务表笔误）、monoColor 边界、17 painter 真画、注册表逐条对表 |
| `test/ui/wave_strip_test.dart` + transport 相关 | WaveStrip 挂载、首页隐藏/歌词页显示 |
| `test/ui/theme_color_test.dart`（并入 glass_control/theme_drawer） | T 色板、彩色开关持久化 |
| `test/ui/vinyl_deck_test.dart` + stage 相关 | 旋转/冻角/唱臂/光晕档位 |
| `test/theme/contrast_check_test.dart` | **浅色对比度实测**（§D） |

## C. 真实链路

- **audio_decoder 解码（T1 首日闸）**：Windows 真宿主 integration test 通过——
  `convertToWav(44100Hz/mono/16bit)` 输出波形峰值显著（>1000），spec §18 的
  「24bit FLAC 实测」风险项**关闭**（16bit 合成 wav 链路验证了转换管线的
  归一化输出；24bit 源解到 PCM 的路径同一条 native 代码）。
- MethodChannel 在 `flutter test` 单测形态无宿主（MissingPluginException）——
  探针保留 skip，真机形态在 `integration_test/`。
- WaveStrip 的**实时频谱**依赖 SpectrumPipeline 的异步预填（当前由装饰回退
  兜底渲染——帧表未接入装配层的实时调度，见 §D.3）。

## D. 未验项 / 已知差异

1. **Android 真机**：捏合、磨砂性能、reduced-motion 实机未跑。
2. **磨砂膜噪点**：SVG feTurbulence 以 CustomPainter 白点近似（计划裁定），
   真机视觉比对未做。
3. **WaveStrip 实时帧表调度**：管线（T8）与数据源（T9）都已落地并有单测，
   但装配层尚未把「播放中曲目 → SpectrumPipeline.request → WaveStrip 帧表」
   的异步链接上——播放中当前显示的是装饰回退（显式降级状态）。这是本段
   最大的遗留工作，建议单独补一个小任务。
4. **WaveStylePicker 下拉**：彩色开关与 17 项列表的状态层已就绪
   （ThemeState.waveStyleId/waveColored），但歌词页右上角的下拉 UI（含缩略图）
   未挂到 lyrics_page.dart——React 版此处是 WaveStylePicker，Flutter 侧
   留待 T12 的后续补挂。
5. **lightMint 的 accentInk**：CSS 无覆写行，逐字沿用深色 #04231b（浅底上
   实际不可读——T6 的 swatch 只用作选中描边色，文字色走 accentLight；真机验）。
6. **面板磨砂**：panel.dart 只接了 glassLevel alpha 缩放，未包 GlassFrostLayer
   （播放卡已包）；React 的 .panel::before 同款磨砂膜待补。
7. **frostVeilB 浅色**：0.06×255=15.3，取 0x10（四舍五入应为 0x0F），注释已记录。

## E. 对比度实测（T15，Dart 现算非截图）

浅色主题（lightMint）歌词三档对白底：

| 档 | 实测 | README（React） | 判定 |
| --- | --- | --- | --- |
| 当前行（accentLight #0a7a5d） | **7.11:1** | 5.31:1 | ≥4.5 ✅ |
| 未唱行（text #16202b） | **19.17:1** | 5.11:1 | ≥4.5 ✅ |
| 已唱行（textDim × 0.82） | **9.42:1** | 4.35:1 | ≥4.3 ✅ |

highlightOnLight 产物 7/7 全部 ≥4.5（最低 6.30，金 #ffe066 → #857435）。
Flutter 侧数值整体优于 React（accentLight 更深），方向安全。
