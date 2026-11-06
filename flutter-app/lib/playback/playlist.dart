// lib/playback/playlist.dart
import 'dart:math';

import 'play_mode.dart';
import 'track.dart';

/// addMany 的返回结构（对译 playlist.js:255-268）。
class AddManyResult {
  AddManyResult({
    required this.added,
    required this.firstIndex,
    required this.loadedFirst,
  });
  final int added;
  final int firstIndex;
  final bool loadedFirst;
}

/// removeById 的返回结构（对译 playlist.js:276-297）。
class RemoveResult {
  RemoveResult({this.removed, this.currentChanged = false});
  final Track? removed;
  final bool currentChanged;
}

/// 对译原版 clamp（playlist.js:32-37）：非有限值退到 min。
/// Dart 侧索引必须是整数，故在区间内取整（原版 JS 的索引本就是整数）。
int _clamp(num value, int min, int max) {
  if (!value.isFinite) return min;
  return value.clamp(min, max).round();
}

/// 建表时的原始条目：既接受 localStorage/demo 的 Map，也接受已构造好的 Track。
/// Track 走 toJson→normalizeTrack 克隆往返（与原版 normalizeTrack 重建对象一致）。
Track? _toTrack(Object? raw) =>
    normalizeTrack(raw is Track ? raw.toJson() : raw);

/// 播放列表模型（对译 playlist.js:97-461 全部公开方法与私有洗牌实现）。
///
/// 随机播放使用「洗牌队列」：维护一份索引排列，切歌时按队列推进，
/// 一轮内不会重复；一轮结束后重新洗牌开始新一轮。
class Playlist {
  Playlist({
    List<Object?>? tracks,
    PlayMode mode = PlayMode.list,
    int? currentIndex,
    Random? random,
  }) : _tracks =
            (tracks ?? const []).map(_toTrack).whereType<Track>().toList(),
        _currentIndex = -1,
        _rng = random ?? Random() {
    // 命名参数无法写作私有初始化形参（prefer_initializing_formals 不适用），在体内赋值。
    _mode = mode;
    if (_tracks.isEmpty) {
      _currentIndex = -1;
    } else {
      _currentIndex = _clamp(currentIndex ?? 0, 0, _tracks.length - 1);
    }
    _rebuildShuffle();
  }

  /// 直接用已构造好的 Track 列表建表（还原路径用，避免二次克隆）。
  Playlist.fromTracks(
    List<Track> tracks, {
    PlayMode mode = PlayMode.list,
    int? currentIndex,
    Random? random,
  }) : _tracks = tracks.toList(),
       _currentIndex = -1,
       _rng = random ?? Random() {
    _mode = mode;
    if (_tracks.isEmpty) {
      _currentIndex = -1;
    } else {
      _currentIndex = _clamp(currentIndex ?? 0, 0, _tracks.length - 1);
    }
    _rebuildShuffle();
  }

  final List<Track> _tracks;
  final Random _rng;
  PlayMode _mode = PlayMode.list;
  int _currentIndex;
  List<int> _shuffleQueue = [];
  int _shufflePos = -1;

  List<Track> get tracks => _tracks;
  int get size => _tracks.length;
  PlayMode get mode => _mode;
  int get currentIndex => _currentIndex;
  bool get isShuffle => _mode == PlayMode.shuffle;

  /// 列表里的活对象，不是副本：回填元数据必须走这里（spec §8）。
  Track? byId(String id) {
    final at = indexOfId(id);
    return at < 0 ? null : _tracks[at];
  }

  Track? get current =>
      _currentIndex < 0 || _currentIndex >= _tracks.length
          ? null
          : _tracks[_currentIndex];

  /// 未知时长不参与累加（原版 totalDuration，playlist.js:159-163）。
  double get totalDuration {
    var total = 0.0;
    for (final track in _tracks) {
      if (track.duration.isFinite) total += track.duration;
    }
    return total;
  }

  /// 洗牌队列快照。仅供测试断言洗牌语义，界面层不得调用。
  List<int> get shuffleOrderForTest => List<int>.from(_shuffleQueue);

  int indexOfId(String id) {
    for (var i = 0; i < _tracks.length; i++) {
      if (_tracks[i].id == id) return i;
    }
    return -1;
  }

  PlayMode setMode(PlayMode mode) {
    _mode = mode;
    if (mode == PlayMode.shuffle) _rebuildShuffle();
    return _mode;
  }

  PlayMode cycleMode() {
    final at = kModeOrder.indexOf(_mode);
    return setMode(kModeOrder[(at + 1) % kModeOrder.length]);
  }

  Track? setCurrentIndex(int index) {
    if (_tracks.isEmpty) {
      _currentIndex = -1;
      return null;
    }
    _currentIndex = _clamp(index, 0, _tracks.length - 1);
    _syncShuffleCursor();
    return current;
  }

  /// 清掉「当前曲目」指针，但**保留全部曲目**。
  ///
  /// 停止播放用：界面与系统侧都回到空态（快照没有标题 / 封面），列表里的歌
  /// 一首不少，下一次 [nextIndex] / [prevIndex] 从队首重新开始。
  void clearCurrent() {
    _currentIndex = -1;
    _syncShuffleCursor();
  }

  /// 找不到时返回当前 current，不改状态（原版 setCurrentById）。
  Track? setCurrentById(String id) {
    final at = indexOfId(id);
    if (at < 0) return current;
    return setCurrentIndex(at);
  }

  Track? addAt(Track track, {int? at}) {
    final normalized = _toTrack(track);
    if (normalized == null) return null;
    final insertAt = _clamp(at ?? _tracks.length, 0, _tracks.length);
    _tracks.insert(insertAt, normalized);
    if (_currentIndex < 0) {
      _currentIndex = insertAt;
    } else if (insertAt <= _currentIndex) {
      _currentIndex += 1;
    }
    _rebuildShuffle();
    return normalized;
  }

  /// 注意：克隆对象。返回的 normalized 才是列表里的活对象。
  AddManyResult addMany(List<Track> tracks) {
    final normalized = tracks.map(_toTrack).whereType<Track>().toList();
    if (normalized.isEmpty) {
      return AddManyResult(added: 0, firstIndex: -1, loadedFirst: false);
    }
    final firstIndex = _tracks.length;
    final wasEmpty = _currentIndex < 0;
    _tracks.addAll(normalized);
    if (wasEmpty) _currentIndex = firstIndex;
    _rebuildShuffle();
    return AddManyResult(
        added: normalized.length,
        firstIndex: firstIndex,
        loadedFirst: wasEmpty);
  }

  RemoveResult removeById(String id) {
    final at = indexOfId(id);
    if (at < 0) return RemoveResult();
    final removed = _tracks.removeAt(at);
    var currentChanged = false;
    if (_tracks.isEmpty) {
      _currentIndex = -1;
      currentChanged = true;
    } else if (at < _currentIndex) {
      _currentIndex -= 1;
    } else if (at == _currentIndex) {
      // 删的是当前项：索引保持不动，即自动落到下一首；越界则退到末尾
      _currentIndex = _clamp(_currentIndex, 0, _tracks.length - 1);
      currentChanged = true;
    }
    _rebuildShuffle();
    return RemoveResult(removed: removed, currentChanged: currentChanged);
  }

  bool move(String id, int delta) {
    final at = indexOfId(id);
    final to = at + delta;
    if (at < 0 || to < 0 || to >= _tracks.length) return false;
    final track = _tracks.removeAt(at);
    _tracks.insert(to, track);
    if (_currentIndex == at) {
      _currentIndex = to;
    } else if (at < _currentIndex && to >= _currentIndex) {
      _currentIndex -= 1;
    } else if (at > _currentIndex && to <= _currentIndex) {
      _currentIndex += 1;
    }
    _rebuildShuffle();
    return true;
  }

  List<Track> clear() {
    final old = List<Track>.from(_tracks);
    _tracks.clear();
    _currentIndex = -1;
    _shuffleQueue = [];
    _shufflePos = -1;
    return old;
  }

  /// 计算下一首索引。**不改** `_currentIndex`，但随机模式下会推进洗牌游标
  /// （原版 JSDoc 明确记录的有意副作用，playlist.js:345-347）。
  /// [auto] 为 true 且处于单曲循环时返回当前索引（原地重播）。
  int nextIndex({bool auto = false}) {
    if (_tracks.isEmpty) return -1;
    if (auto && _mode == PlayMode.one) return _currentIndex;
    if (_mode == PlayMode.shuffle) return _advanceShuffle(1);
    if (_currentIndex < 0) return 0;
    return (_currentIndex + 1) % _tracks.length;
  }

  int prevIndex() {
    if (_tracks.isEmpty) return -1;
    if (_mode == PlayMode.shuffle) return _advanceShuffle(-1);
    if (_currentIndex < 0) return 0;
    return (_currentIndex - 1 + _tracks.length) % _tracks.length;
  }

  int _advanceShuffle(int step) {
    if (_tracks.isEmpty) return -1;
    _syncShuffleCursor();
    var pos = _shufflePos + step;
    if (pos >= _shuffleQueue.length) {
      // 一轮放完：重新洗牌开始新一轮（避免立刻重复刚放完的那首）
      _rebuildShuffle(keepCurrentFirst: false);
      pos = 0;
    }
    if (pos < 0) pos = _shuffleQueue.length - 1;
    _shufflePos = _clamp(pos, 0, _shuffleQueue.length - 1);
    // 原版 Number.isInteger 兜底（playlist.js:409）在 Dart 里由「非空列表 ⇒
    // 队列与列表等长（_syncShuffleCursor 保证）+ 游标已夹回区间」等价覆盖。
    return _shuffleQueue[_shufflePos];
  }

  void _syncShuffleCursor() {
    if (_shuffleQueue.length != _tracks.length) {
      _rebuildShuffle();
      return;
    }
    if (_currentIndex < 0) {
      _shufflePos = -1;
      return;
    }
    final at = _shuffleQueue.indexOf(_currentIndex);
    if (at >= 0) {
      _shufflePos = at;
    } else {
      _rebuildShuffle();
    }
  }

  void _rebuildShuffle({bool keepCurrentFirst = true}) {
    final size = _tracks.length;
    final order = List<int>.generate(size, (i) => i);
    for (var i = size - 1; i > 0; i--) {
      final j = _rng.nextInt(i + 1);
      final tmp = order[i];
      order[i] = order[j];
      order[j] = tmp;
    }
    if (size > 1 && keepCurrentFirst && _currentIndex >= 0) {
      final at = order.indexOf(_currentIndex);
      if (at > 0) {
        order.removeAt(at);
        order.insert(0, _currentIndex);
      }
    } else if (size > 1 && !keepCurrentFirst && order[0] == _currentIndex) {
      final j = 1 + _rng.nextInt(size - 1);
      final tmp = order[0];
      order[0] = order[j];
      order[j] = tmp;
    }
    _shuffleQueue = order;
    _shufflePos =
        keepCurrentFirst && _currentIndex >= 0 && size > 0 ? 0 : -1;
  }
}
