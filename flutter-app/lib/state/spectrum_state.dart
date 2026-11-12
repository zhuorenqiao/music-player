// lib/state/spectrum_state.dart
//
// 实时频谱的**调度层**（M3 验收文档 D.3 的遗留项）。
//
// T8 的 [SpectrumPipeline] 已经能把一个音频文件解成 [SpectrumFrameTable]，
// T9 的 WaveSource 也能按 positionSeconds 取帧，T11 的 WaveStrip 也留好了
// `frameTable` 入参 —— 缺的只是「谁在什么时候去要这张表」。本件就是那个人：
//
//   歌词页可见 + 有本地曲目
//     → 先读磁盘缓存（异步、但不解码、不排队）
//     → 没命中才 request(prioritize: true) 排队解码
//     → 结果回来后 notifyListeners()，WaveStrip 换成真实帧表
//
// 四条约束（每条都有用例钉）：
//
// 1. **懒**。只有歌词页真的打开才解析。首页那颗 WaveStrip 是隐藏的，
//    为一个看不见的东西去解一整首 FLAC 是纯粹的浪费（解码在主 isolate 调平台
//    通道，compute 里再跑一遍 FFT，4 分钟曲目要几十 MB 的临时 WAV）。
//
// 2. **换曲立刻作废在途结果**。用单调递增的 generation 号：请求发出后立刻切歌，
//    旧歌的解码 Future 回来时世代已经变了，绝不能把旧表挂到新歌上（WaveSource
//    虽有 trackId 判等，但 frameTable 本身还得是「当前这首」的）。
//
// 3. **缓存优先**。`cached()` 只读 .bin、不入队列、不解码；命中就直接用，
//    这样第二次打开同一首歌是毫秒级。只有 miss 才走 request。
//
// 4. **降级不打扰**。SAF / content:// 这类 dart:io 读不到的句柄直接跳过
//    （audio_decoder 的 Windows 实现接的是文件路径，喂 URI 必定抛）；
//    解码失败返回 null，[isFallback] 置真，WaveStrip 继续画装饰形状。
//    状态行由此可以明示「当前非真实频谱」（spec §10.2 的显式降级语义）。
//
// 帧表本身不进 ChangeNotifier 的 value：它是纯数据，由 [frameTableFor] 按
// 曲目 id 取，界面用 `watch<SpectrumState>()` 只在「表到货 / 被清掉」时重建。
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../playback/track.dart';
import '../playback/track_handle.dart';
import '../wave/spectrum_pipeline.dart';

/// 哪些句柄值得交给离线解码器。
///
/// `FilePathHandle.canProbeDuration` 是现成的同款能力位（audio_decoder 在
/// Windows 上走 Media Foundation SourceReader，只认本地文件路径），复用它，
/// 不另造一套判据。SAF 的 `content://` 会返回 false。
bool canDecodeSpectrum(TrackHandle handle) => handle.canProbeDuration;

/// 频谱帧表的调度状态。应用生命周期内常驻，由组合根持有、经 provider 下发。
class SpectrumState extends ChangeNotifier {
  SpectrumState({required this.source});

  /// 解析源（生产是 [SpectrumPipeline]，测试注入假源）。
  final SpectrumSource source;

  /// 当前该显示的那张表；null = 装饰回退。
  SpectrumFrameTable? _table;

  /// 这张表属于哪首曲目（防止把旧表挂到新歌上）。
  String _tableTrackId = '';

  /// 单调递增的世代。每次换曲/关页都 +1，在途结果回来时比对。
  int _generation = 0;

  /// 当前曲目是否处于「明确降级」状态（没有句柄 / 解码失败）。
  bool _fallback = false;

  /// 歌词页是否可见；只有可见时才解析。
  bool _visible = false;

  /// 当前曲目（可能为 null）。
  Track? _current;

  /// 正在排队/解码的曲目 id，避免同一首重复入队。
  String _inFlightId = '';

  /// 当前显示用的帧表。null = 走装饰回退。
  SpectrumFrameTable? get frameTable => _table;

  /// [frameTable] 所属曲目 id；空串表示没有表。
  String get tableTrackId => _tableTrackId;

  /// 是否处于显式降级（spec §10.2：状态行可以据此说明「当前非真实频谱」）。
  bool get isFallback => _fallback;

  /// 是否正在解析（供状态行/测试观察，不驱动动画）。
  bool get isLoading => _inFlightId.isNotEmpty;

  /// 取某首曲目该用的帧表：id 不匹配一律给 null。
  ///
  /// WaveStrip 用它而不是直接读 [frameTable]，这样换曲那一帧即使新表还没到，
  /// 也绝不会短暂画出上一首歌的频谱（串歌）。
  SpectrumFrameTable? frameTableFor(String trackId) =>
      trackId.isNotEmpty && trackId == _tableTrackId ? _table : null;

  /// 歌词页开合变化。装配层把它接到 [LyricsPageController] 上。
  ///
  /// 关页时**清掉表**并作废在途请求：下次打开重新走一遍「缓存 → 解码」，
  /// 顺带让这次会话内被换掉的文件（mtime/size 变了）能重新命中正确的指纹。
  /// 表留在内存里也就几十 KB，但留着它等于让「打开别首歌 → 旧表还在」有了
  /// 可乘之机，不如清干净。
  void setVisible(bool visible) {
    if (_visible == visible) return;
    _visible = visible;
    if (!visible) {
      _bumpGeneration();
      _clearTable();
      return;
    }
    _ensureForCurrent();
  }

  /// 当前曲目变化（播放视图的语义快照变了）。
  ///
  /// 同一个活对象、同一份句柄就跳过 —— 标签回填会原地改 Track 的字段，
  /// 那不是换歌，不该把已经到货的帧表作废。
  void setCurrent(Track? track) {
    final oldId = _current?.id ?? '';
    final newId = track?.id ?? '';
    final oldPath = _current == null ? '' : _audioPathOf(_current!);
    final newPath = track == null ? '' : _audioPathOf(track);
    _current = track;
    if (oldId == newId && oldPath == newPath) return;
    _bumpGeneration();
    _clearTable();
    if (_visible) _ensureForCurrent();
  }

  /// 手动清缓存后重算（将来接「重新分析」入口用）。
  void invalidate() {
    _bumpGeneration();
    _clearTable();
    if (_visible) _ensureForCurrent();
  }

  void _bumpGeneration() {
    _generation += 1;
    _inFlightId = '';
  }

  void _clearTable() {
    final had = _table != null;
    _table = null;
    _tableTrackId = '';
    _fallback = false;
    if (had) notifyListeners();
  }

  /// 播控视图的语义变化都会走到这里；只有 id/句柄真的变了才重排。
  void _ensureForCurrent() {
    final track = _current;
    if (track == null || !_visible) return;
    final path = _audioPathOf(track);
    if (path.isEmpty || !canDecodeSpectrum(track.handle)) {
      // 没有可解码的本地来源：显式降级，别排队白等。
      _inFlightId = '';
      _fallback = true;
      notifyListeners();
      return;
    }
    final id = track.id;
    if (_inFlightId == id || frameTableFor(id) != null) return;

    final generation = _generation;
    _inFlightId = id;
    // 不 await：解析是后台的事，界面照常先画装饰形状。
    unawaited(_load(track, path, generation));
  }

  Future<void> _load(Track track, String path, int generation) async {
    final id = track.id;
    SpectrumFrameTable? table;
    try {
      // 缓存优先：只读 .bin，不解码、不排队。
      table = await source.cached(id, path);
      // 缓存没有才真的去解（当前曲目插队到队首）。
      table ??= await source.request(id, path, prioritize: true);
    } catch (_) {
      // 源自己已经保证不抛，这里只兜「假源/平台通道意外抛」这一种。
      table = null;
    }
    // 世代变了（换曲 / 关页 / invalidate）：结果作废，绝不挂上去。
    if (generation != _generation || _inFlightId != id || !_visible) return;
    _inFlightId = '';
    _table = table;
    _tableTrackId = table == null ? '' : id;
    _fallback = table == null;
    notifyListeners();
  }

  /// 交给解码器的音频路径。
  ///
  /// 用 `handle.pathish` 而不是 `track.src`：前者对 FilePathHandle 是真实路径、
  /// 对 SAF 是 content:// 串（会被能力位挡掉），后者只是展示用的来源字符串。
  String _audioPathOf(Track track) => track.handle.pathish;

  @override
  void dispose() {
    // 作废在途结果，避免 dispose 之后还调 notifyListeners。
    _bumpGeneration();
    super.dispose();
  }
}
