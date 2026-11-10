# M2b 验收记录（2026-11-10）

封面四级兜底（内嵌 → iTunes 两区 → 维基写真 → 生成卡）、`coverForDisplay`
显示层、封面放大层、歌词与封面后台预取。

## A. 闸口结果

四条闸口全部现场采集（2026-11-10，镜像环境变量 + `flutter-app/` 目录内）：

| 闸口 | 结果 |
| --- | --- |
| `flutter analyze` | `No issues found! (ran in 4.8s)`（0 issue） |
| `flutter test`（全量） | `00:36 +927: All tests passed!` |
| `flutter build windows --debug` | 通过（见下） |
| `flutter build apk --debug` | 通过（见下） |

## B. 自动化覆盖（T1–T11 用例文件）

| 文件 | 覆盖 |
| --- | --- |
| `test/cover/generated_cover_test.dart` | FNV-1a 黄金数值（node 现算：周杰伦 seed=3719078777/hue=137 等 5 组）、initialsOf、柱高、确定性 == |
| `test/cover/itunes_source_test.dart` | scoreItem 七档全边界（30/12/25/10/20/8/−25）、pickBest 门槛 18 与二次校验「光年之外」反例、artworkBig、两区取最高/平分取 CN/单区失败下沉、参数断言 |
| `test/cover/cover_disk_cache_test.dart` | 索引 30d/3d TTL 边界、150 条淘汰、坏 JSON 留原地、落盘器真 PNG、8MB 双刀、懒建 |
| `test/cover/artist_image_test.dart` | normalizeArtistKey、pickImage 顺序、zh→en 回退、404/网络错、占位歌手零请求、1 天 miss TTL、80 条淘汰 |
| `test/cover/cover_match_test.dart` | matchCover 全链路（索引命中不发请求、下载失败→miss、网络错不写缓存、useCache:false） |
| `test/state/cover_state_test.dart` | 四级兜底顺序、matchFor 去重、写真负缓存、预取 400ms 串行、forget |
| `test/lyrics/lyrics_prefetch_test.dart` | 350ms 节奏、跳过条件逐条、manual 不覆盖、单条失败继续 |
| `test/state/lightbox_controller_test.dart` | open/close/toggle 幂等 + closeOverlay 层叠矩阵（真 App + 真 Esc 键） |
| `test/ui/cover_image_test.dart` | CoverImage 路径失效退生成卡、CoverDisc 生成卡碟面/空态占位 |
| `test/ui/cover_lightbox_test.dart` | 开/关三路、双击 1→2→4→1（中心锚点 offset=0）、clamp=±216（432×(2−1)/2）、点图不关闭、滚轮 exp 锚点 |

## C. 真实链路（现场探测）

三条上游探测（2026-11-10，curl 实测）：

```
iTunes CN（陈奕迅 十年, country=CN）  → 200, 0.764s, resultCount=0（中国区无此曲目，符合 spec §18 记录）
iTunes US（eason chan ten years）     → 200, 0.486s, resultCount=8（首条 Eason Chan & Faye Wong「Because of Love」，含 artworkUrl100）
Wikipedia zh（陈奕迅 summary）        → 连接失败（21.1s 超时，000）—— spec §18 已记录的本机 DNS 污染，按预期落到生成卡
```

- iTunes 两区直连可行（响应形状与移植的打分/换算逻辑一致：`artworkUrl100` 存在、`trackTimeMillis` 可打分）。
- 维基写真在本机不可达是**预期行为**：三级稳定 miss → 界面落到第四级生成卡，绝不阻塞。

## D. 未验项 / 已知差异

1. **Android 真机**：双指捏合的实机手感（widget 测试已用双指 TestGesture 驱动，真机未跑）；锁屏/通知栏走 M1 已验链路，本段未改。
2. **Windows 真机跑完整封面链路**：导入无封面 mp3 → 看到生成卡 → iTunes 匹配落 covers-net → 重启走索引命中。逻辑各环节有单测钉住，但「真机跑一轮」未执行（本机 iTunes 可达、维基不可达，匹配会落到写真 miss 后由 resolver 显示生成卡，行为与单测一致）。
3. **灯箱遮罩浅色对比度**：M3 翻 token 表时一起实测（当前只有 dark 一套）。
4. **`panelCover` 毛玻璃位**（React `useCover` 的第 5 个调用点）属 M3 玻璃材质，本段未接。
5. **errorBuilder 解码失败路径在 widget 测试不可测**（FakeAsync 里原生解码回调不触发，已探测钉死）——由 existsSync 同步判存与 metadata 层字节级契约兜底，生产路径与 M1 已上线的 CoverThumb errorBuilder 同构。
6. **有意差异**（全部记录在计划文档 Self-Review 节）：JSONP/代理双通道合并为直连；在线封面落盘为文件（显示层全 Image.file）；匹配结果进 `matchedCovers` 不写 `track.cover`（保 M1 不变量）；生成卡 Painter 直绘不引 flutter_svg（派生量与 React 逐位一致）；维基 source 文案去「，直连」；`DEFAULT_COVER` 不移植（占位碟即空路径语义）。
