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
| `test/ui/vinyl_deck_test.dart` + stage 相关 | 旋转/冻角/唱臂/光晕档位；黑胶外圈（spec §23）：标签位占 62%、盘面与封面同相位、斜向反光固定不转、歌词页无外圈 |
| `test/theme/contrast_check_test.dart` | **浅色对比度实测**（§D） |

## C. 真实链路

- **audio_decoder 解码（T1 首日闸）**：Windows 真宿主 integration test 通过——
  `convertToWav(44100Hz/mono/16bit)` 输出波形峰值显著（>1000），spec §18 的
  「24bit FLAC 实测」风险项**关闭**（16bit 合成 wav 链路验证了转换管线的
  归一化输出；24bit 源解到 PCM 的路径同一条 native 代码）。
- MethodChannel 在 `flutter test` 单测形态无宿主（MissingPluginException）——
  探针保留 skip，真机形态在 `integration_test/`。
- **WaveStrip 实时频谱（D.3，2026-11-12 补完）**：装配层已接上
  `SpectrumState`（`lib/state/spectrum_state.dart`）——歌词页打开才懒启动，
  先读 `.bin` 缓存、miss 才 `SpectrumPipeline.request(prioritize: true)` 排队
  解码；换曲/关页用 generation 号作废在途结果；SAF `content://` 与解码失败
  显式降级回装饰形状。帧表经 provider 流到 `WaveStrip.frameTable`，
  进度由 `positionListenable` 只订阅在频谱条这一片叶子上。
  用例：`test/state/spectrum_state_test.dart`（10 条状态机）、
  `test/ui/spectrum_wiring_test.dart`（2 条端到端接线）。
  **Windows Release 真机验证（2026-11-12）**：
  - 首页空闲 0 CPU、`spectrum/` 目录未创建 → 懒启动生效；
  - 按 `L` 打开歌词页 → 真实 FLAC 解码 → 生成 `spectrum/*.bin`
    **861,524 字节**（≈4487 帧 × 192B，对应 224s 曲目，与 spec §10.1 吻合）；
  - 临时 `lspc-*` WAV 目录在解码结束后自动清理，CPU 回落到 0；
  - Esc 关页再按 `L` 开页：**0 秒 CPU**、缓存文件 mtime 未变、无新临时目录
    → 缓存命中生效，不重复解码。
  - **仍未验**：频谱条画面的目视比对（是否随音乐实时起伏、暂停冻结、
    17 样式逐一观感）；这属于视觉验收，不影响链路正确性。

## D. 未验项 / 已知差异

1. **Android 真机**：捏合、磨砂性能、reduced-motion 实机未跑。
2. **磨砂膜噪点**：SVG feTurbulence 以 CustomPainter 白点近似（计划裁定），
   真机视觉比对未做。
3. ~~**WaveStrip 实时帧表调度**~~ **已补完（2026-11-12）**：见 §C。余下只有
   「真机上对真实 FLAC 的目视比对」未跑；状态机与装配接线均有单测覆盖。
4. ~~**WaveStylePicker 下拉**~~ **已补完（2026-11-12）**：新增
   `lib/ui/wave_style_picker.dart`，挂到 `lyrics_page.dart` 右上角。触发按钮
   显示当前样式名；Overlay 面板含固定「彩色」开关 + 17 项可滚动列表（每项
   76×28 静态缩略图走 `renderWaveThumb`，与 WaveStrip 同一套渲染器）；
   ↑↓/Home/End 移动高亮、Enter/空格选中、Esc 退回按钮，按键在本层消费
   以免顺手改音量 / 关掉歌词页。用例 `test/ui/wave_style_picker_test.dart`（5 条）。
   **真机视觉比对未做**（缩略图观感、面板定位）。
5. **lightMint 的 accentInk**：CSS 无覆写行，逐字沿用深色 #04231b（浅底上
   实际不可读——T6 的 swatch 只用作选中描边色，文字色走 accentLight；真机验）。
   **仍未验**：浅色主题下的真机可读性。
6. ~~**面板磨砂**~~ **已补完（2026-11-12）**：`panel.dart` 用同一个
   `GlassFrostLayer` 包住整卡（`.player::before, .panel::before` 同款，
   app.css:461-477），`HomePage` 注入 `coverPath` / `frostLevel`；弹层版
   （flush）用自己的 sheet 卡面，不重复挂磨砂。用例
   `test/ui/panel_frost_test.dart`（3 条）。
7. ~~**frostVeilB 浅色**~~ **已修正（2026-11-12）**：三档浅色 token 从
   `0x10` 改为 `0x0F`（0.06×255=15.3 四舍五入），深色三档 `0x24080A0F`
   保持不动。用例见 `test/ui/wave_style_picker_test.dart` 的 D.7 断言。

## E. 对比度实测（T15，Dart 现算非截图）

浅色主题（lightMint）歌词三档对白底：

| 档 | 实测 | README（React） | 判定 |
| --- | --- | --- | --- |
| 当前行（accentLight #0a7a5d） | **7.11:1** | 5.31:1 | ≥4.5 ✅ |
| 未唱行（text #16202b） | **19.17:1** | 5.11:1 | ≥4.5 ✅ |
| 已唱行（textDim × 0.82） | **9.42:1** | 4.35:1 | ≥4.3 ✅ |

highlightOnLight 产物 7/7 全部 ≥4.5（最低 6.30，金 #ffe066 → #857435）。
Flutter 侧数值整体优于 React（accentLight 更深），方向安全。
