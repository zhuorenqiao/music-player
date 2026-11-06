// lib/library/recent_store.dart
//
// 「最近播放」存档，对译 src/lib/recent-store.js。只记录播放历史本身：
// 曲目快照（标题 / 歌手 / 封面 / 时长）+ id + 播放时间，最多 50 条。
// 不碰界面，也不知道播放列表长什么样；调用方负责把 id 映射回真实曲目。
//
// 三条与原版一致的硬约束：
//   - 同一首歌重播只置顶，绝不产生重复条目（recent-store.js:93-98）；
//   - 同一首在 500ms 内的重复触发直接忽略（NOOP_WINDOW），只防事件级抖动；
//     窗口必须小，否则用户快速切回刚播过的歌时不会被置顶；
//   - 读档容忍脏数据：单条结构不完整只丢那一条，整份坏掉回退空列表。
import 'dart:async';

import '../core/app_prefs.dart';
import '../core/storage_keys.dart';
import '../playback/track.dart';
// 只借接口与去抖常量：kRecentDedupeMs 是 T14 定下的那份 500ms，
// 这里不再另立一个同名常量（两处同名会让同时 import 的文件产生歧义）。
import '../playback/transport_controller.dart'
    show RecentRecorder, kRecentDedupeMs;

/// 最近播放最多保留的条数（recent-store.js MAX_ENTRIES）。
const int kRecentLimit = 50;

/// 一条最近播放记录。标题 / 歌手 / 封面是写入时的快照，
/// 曲目被删掉之后列表里仍能显示得出来。
///
/// [inPlaylist] 是会话态：读档时乐观置 true（见 [RecentStore.restore]），
/// 界面随后用 [RecentStore.markInPlaylist] 刷新；不进 [toJson]。
class RecentEntry {
  RecentEntry({
    required this.id,
    required this.title,
    required this.artist,
    required this.at,
    this.cover = '',
    this.duration,
    this.inPlaylist = true,
  });

  final String id;
  final String title;
  final String artist;
  final String cover;

  /// 秒；未知为 null（`Track` 里未知是 NaN，写盘一律落 null）。
  final double? duration;

  /// 这次播放的时间戳（毫秒）。
  int at;

  bool inPlaylist;

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'cover': cover,
    'duration': duration,
    'at': at,
  };

  /// 对译原版 `isEntryLike`（recent-store.js:30-36）：id 非空字符串、
  /// playedAt 是有限数字，缺一条就算结构不完整，整条丢掉。
  /// 其余字段只做类型兜底，不因此丢掉记录。
  static RecentEntry? fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final title = json['title'];
    final at = json['at'];
    if (id is! String || id.isEmpty || title is! String) return null;
    if (at is! num || !at.isFinite) return null;
    final duration = json['duration'];
    final cover = json['cover'];
    final artist = json['artist'];
    return RecentEntry(
      id: id,
      title: title,
      artist: artist is String ? artist : '',
      cover: cover is String ? cover : '',
      duration: duration is num && duration.isFinite
          ? duration.toDouble()
          : null,
      at: at.toInt(),
    );
  }
}

/// 最近播放存储。构造一次注入给 `TransportController`（它只认
/// [RecentRecorder] 接口），界面层通过 `RecentState`（T23）读。
class RecentStore implements RecentRecorder {
  RecentStore(this._prefs, {int Function()? now})
    : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final AppPrefs _prefs;
  final int Function() _now;
  final List<RecentEntry> _entries = [];

  /// 只读视图：外部拿到的是快照，改不了内部列表。
  List<RecentEntry> get entries => List.unmodifiable(_entries);

  /// 冷启动读档。顺序即存档顺序（写入时永远是「最新在前」），
  /// 单条坏掉只丢那一条，超过上限丢掉尾部（最旧的）。
  ///
  /// [RecentEntry.inPlaylist] 一律先置 true：这一步读档时没有必要去问
  /// 播放列表，界面的刷新会把失效条目标出来（原版也是先渲染再校正）。
  /// 归一化之后立刻写回，避免每次启动都重复过滤同一份脏数据。
  Future<void> restore() async {
    _entries.clear();
    final raw = await _prefs.readJson(StorageKeys.recent);
    // 无存档，或整份 JSON 坏掉（readJson 已顺手清掉脏值）：按空列表处理
    if (raw is! List) return;
    final seen = <String>{};
    for (final item in raw.whereType<Map>()) {
      final entry = RecentEntry.fromJson(item.cast<String, Object?>());
      // 同一 id 只留第一条：重复项会让「置顶且永不重复」的约定失效
      if (entry == null || !seen.add(entry.id)) continue;
      entry.inPlaylist = true;
      _entries.add(entry);
    }
    if (_entries.length > kRecentLimit) {
      _entries.removeRange(kRecentLimit, _entries.length);
    }
    await _persist();
  }

  /// 记一次播放。同一首重播：挪到最前并刷新时间；500ms 内的重复事件
  /// （暂停后又恢复这类抖动）直接忽略，不重排也不写盘。
  @override
  void record(Track track, {DateTime? at}) {
    final timestamp = at?.millisecondsSinceEpoch ?? _now();
    final newest = _entries.isEmpty ? null : _entries.first;
    // 只看「已经排在最前的那条」：原版先置顶再比时间，所以超过窗口的
    // 重播必须重新置顶，而不是被旧条目挡住。
    if (newest != null &&
        newest.id == track.id &&
        timestamp - newest.at < kRecentDedupeMs) {
      return;
    }
    _entries.removeWhere((e) => e.id == track.id);
    _entries.insert(
      0,
      RecentEntry(
        id: track.id,
        title: track.title.isEmpty ? kUnknownTitle : track.title,
        artist: track.artist,
        cover: track.cover,
        // 时长未知时写 null：NaN 不是合法 JSON，读回来也只是噪声
        duration: track.hasDuration ? track.duration : null,
        at: timestamp,
      ),
    );
    if (_entries.length > kRecentLimit) {
      _entries.removeRange(kRecentLimit, _entries.length);
    }
    // 落盘不挡播放路径：一次播放不该等磁盘
    unawaited(_persist());
  }

  /// 播放列表变化后校正失效标记（不在 [ids] 里的条目显示为「已失效」）。
  Future<void> markInPlaylist(Set<String> ids) async {
    for (final entry in _entries) {
      entry.inPlaylist = ids.contains(entry.id);
    }
    await _persist();
  }

  Future<void> remove(String id) async {
    _entries.removeWhere((e) => e.id == id);
    await _persist();
  }

  Future<void> clear() async {
    _entries.clear();
    await _persist();
  }

  /// 等最近一次落盘完成。仅测试与冷启动收尾用，界面不调。
  Future<void> flushForTest() => _persist();

  Future<void> _persist() => _prefs.writeJson(
    StorageKeys.recent,
    _entries.map((e) => e.toJson()).toList(),
  );
}

/// 把时间戳格式化成中文相对时间，对译 recent-store.js:139-175。
///
/// `刚刚 / N 分钟前 / N 小时前 / 昨天 / N 天前`；超过一周直接给日期
/// `M月D日`，跨年再带 `YYYY年`。未来时间（时钟回拨）按「刚刚」兜底，
/// 不出现负数。
///
/// [localeDate] 只用于测试注入时区：默认按本地时区把毫秒转成日历日。
String formatRelativeTime(
  int timestamp, {
  int? now,
  DateTime Function(int millis)? localeDate,
}) {
  final current = now ?? DateTime.now().millisecondsSinceEpoch;
  final diff = current - timestamp;
  if (diff < 0) return '刚刚';

  const int minute = 60 * 1000;
  const int hour = 60 * minute;
  const int day = 24 * hour;

  if (diff < minute) return '刚刚';
  if (diff < hour) return '${diff ~/ minute} 分钟前';
  if (diff < day) return '${diff ~/ hour} 小时前';
  if (diff < 2 * day) return '昨天';
  if (diff < 7 * day) return '${diff ~/ day} 天前';

  final toDate = localeDate ?? _localDate;
  final date = toDate(timestamp);
  final monthDay = '${date.month}月${date.day}日';
  return date.year == toDate(current).year
      ? monthDay
      : '${date.year}年$monthDay';
}

DateTime _localDate(int millis) => DateTime.fromMillisecondsSinceEpoch(millis);
