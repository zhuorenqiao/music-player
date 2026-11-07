// lib/library/library_repository.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../playback/play_mode.dart';
import '../playback/track.dart';

/// 存档格式版本。只记录不迁移：读到未来版本仍按现有字段尽力解析，
/// 认不出的字段直接忽略（短字段一律走默认值，绝不因此丢掉整份歌单）。
const int _snapshotVersion = 1;

/// 曲库存档：曲目元数据 + 播放顺序 + 当前曲目 + 模式。
///
/// 取代原版 IndexedDB（spec §6.3）——音频字节从不进这里，只存 `Track.toJson()`
/// 描述的文件位置 / SAF URI 与标签信息。
///
/// **音量与静音不在这里**（终审 minor 4 / A1）：原版只把它们写成两个独立的
/// localStorage 键（`src/state/player.tsx:333` / `:338`），Dart 侧对应
/// `AppPrefs` 的 `StorageKeys.volume` / `StorageKeys.muted`，读写都在
/// `PlayerState`（`setVolume` / `toggleMute` 写、`ready()` 读）。这两个字段从前
/// 在这里只是「`toJson` 白写、没人读」的死字段 —— 留着就是第二套真相，将来谁
/// 拿它覆盖 prefs 就会出现「文件仓重建后音量悄悄回到 0.7」。字段删掉，
/// 读档仍旧忽略老存档里残留的这两个键（`fromJson` 是总函数）。
class LibrarySnapshot {
  LibrarySnapshot({
    this.tracks = const [],
    this.order = const [],
    this.currentId,
    this.mode = PlayMode.list,
    this.corrupted = false,
  });

  final List<Track> tracks;

  /// 播放顺序（曲目 id）；构造时不做校验，[LibraryRepository.load] 会把
  /// 与 [tracks] 对齐后的版本交回来。
  final List<String> order;

  final String? currentId;
  final PlayMode mode;

  /// 会话态：本次 [LibraryRepository.load] 走了 `.bak` 回退或两份文件都读不出来。
  /// 与 `Track.broken` 同理，不进 [toJson]。
  bool corrupted;

  Map<String, Object?> toJson() => {
    'version': _snapshotVersion,
    'tracks': tracks.map((t) => t.toJson()).toList(),
    'order': order,
    'currentId': currentId,
    'mode': playModeId(mode),
  };

  /// 总函数：字段缺失、类型不对、单条曲目坏掉都只影响那一部分（原版对
  /// IndexedDB 里脏数据的容忍度相同）。
  static LibrarySnapshot fromJson(Map<String, Object?> json) {
    final tracks = <Track>[];
    final validIds = <String>{};
    final rawTracks = json['tracks'];
    if (rawTracks is List) {
      for (final raw in rawTracks) {
        final track = _trackFromJson(raw);
        // 同 id 只留第一条：id 是播放列表的主键，重复会让选曲语义含糊
        if (track != null && validIds.add(track.id)) tracks.add(track);
      }
    }

    final order = <String>[];
    final ordered = <String>{};
    final rawOrder = json['order'];
    if (rawOrder is List) {
      for (final raw in rawOrder) {
        if (raw is String && validIds.contains(raw) && ordered.add(raw)) {
          order.add(raw);
        }
      }
    }
    // order 里缺的曲目补到末尾，避免脏数据把歌单「变小」
    for (final track in tracks) {
      if (ordered.add(track.id)) order.add(track.id);
    }

    final rawCurrent = json['currentId'];
    return LibrarySnapshot(
      tracks: tracks,
      order: order,
      currentId: rawCurrent is String && validIds.contains(rawCurrent)
          ? rawCurrent
          : null,
      mode: playModeFromId(json['mode']),
    );
  }

  static Track? _trackFromJson(Object? raw) {
    if (raw is! Map) return null;
    try {
      return Track.fromJson(raw.cast<String, Object?>());
    } catch (_) {
      // 一条脏数据不该让整份存档作废
      return null;
    }
  }
}

/// `<directory>/<fileName>` 上的 JSON 存档仓。
///
/// 写盘顺序（spec §6.3）：写 `.tmp` → 把正式文件 rename 成 `.bak`（保住上一份）
/// → 把 `.tmp` rename 成正式文件。首次保存会把新文件同时留一份 `.bak`，
/// 这样「刚存完就坏」也有得回退。任何文件系统异常都被吞掉：存档失败只丢历史，
/// 不能反过来打断正在播放的曲目（原版对 IndexedDB 配额不足也是同一路处理）。
///
/// 唯一例外：上次 [load] 发现正式文件解析不了（回退过 `.bak`）时，正式文件是脏的，
/// 把它轮转进 `.bak` 会顶掉唯一一份好存档——这种保存只写 `.tmp` 再就位，
/// 不碰 `.bak`；正式文件被修好后恢复常规轮转。
class LibraryRepository {
  LibraryRepository({required this.directory, this.fileName = 'library.json'});

  final String directory;
  final String fileName;

  static const String _tmpSuffix = '.tmp';
  static const String _bakSuffix = '.bak';

  bool _corrupted = false;

  /// 最近一次 [load] 是否没能用上正式文件（回退 `.bak` 或两份都读不出）。
  bool get corrupted => _corrupted;

  /// 正式文件内容已确认不可用（上次 [load] 时盘上有文件却解析不出来）。
  /// 为真时保存不能轮转：那份脏文件会顶掉 `.bak` 里的唯一好存档。
  bool _primaryKnownBad = false;

  /// 测试用接缝：正式文件就位（rename/copy）之前的钩子，用于验证写入顺序。
  /// 生产代码从不赋值，行为与没有它时完全一致。
  @visibleForTesting
  Future<void> Function()? beforeRename;

  String get _path => '$directory/$fileName';
  String get _bakPath => '$_path$_bakSuffix';
  String get _tmpPath => '$_path$_tmpSuffix';

  /// 写入闸门：同一实例上的 save 严格串行，rename 不会交叉。
  Completer<void>? _writing;

  Future<LibrarySnapshot> load() async {
    _corrupted = false;
    final primaryPresent = await _exists(_path);
    final primary = await _readJson(_path);
    final loaded = primary == null ? null : _parse(primary);
    if (loaded != null) {
      _primaryKnownBad = false;
      return loaded;
    }

    final backupPresent = await _exists(_bakPath);
    final backup = await _readJson(_bakPath);
    final fallback = backup == null ? null : _parse(backup);
    // 盘上有文件却用不上 = 脏存档；连文件都没有（首次启动）不算
    _corrupted = primaryPresent || backupPresent;
    // 正式文件在盘上却读不出/解析不出：记住它，下次保存别拿它换掉 `.bak`
    _primaryKnownBad = primaryPresent;
    if (fallback != null) return fallback..corrupted = true;
    return LibrarySnapshot(corrupted: _corrupted);
  }

  Future<void> save(LibrarySnapshot snapshot) async {
    // 用 while 而不是 if：前一个写完之后，所有等待者会被同时唤醒，
    // 先醒的那个占住闸门，其余必须回到循环再等一轮。
    while (_writing != null) {
      await _writing!.future;
    }
    final gate = Completer<void>();
    _writing = gate;
    try {
      await _write(snapshot);
    } catch (_) {
      // 兜底：落盘异常一律不外抛，播放不受影响
    } finally {
      _writing = null;
      gate.complete();
    }
  }

  Future<void> deleteTracks(Iterable<String> ids) async {
    final removed = ids.toSet();
    if (removed.isEmpty) return;
    final snapshot = await load();
    final currentId = snapshot.currentId;
    await save(
      LibrarySnapshot(
        tracks: snapshot.tracks.where((t) => !removed.contains(t.id)).toList(),
        order: snapshot.order.where((id) => !removed.contains(id)).toList(),
        currentId: currentId != null && removed.contains(currentId)
            ? null
            : currentId,
        mode: snapshot.mode,
      ),
    );
  }

  Future<void> _write(LibrarySnapshot snapshot) async {
    final String content;
    try {
      content = jsonEncode(snapshot);
    } catch (_) {
      // 快照里有序列化不了的值（脏 handle 之类），这次不写，也不留半截文件
      return;
    }
    final tmp = File(_tmpPath);
    // 快照：本次写入要不要轮转备份，只由进入时已知的状态决定
    final primaryKnownBad = _primaryKnownBad;
    try {
      await Directory(directory).create(recursive: true);
      await tmp.writeAsString(content, flush: true);
      await beforeRename?.call();
      final primary = File(_path);
      // 已知脏的正式文件绝不轮转：那会把 `.bak` 里唯一的好存档删掉
      if (!primaryKnownBad && await primary.exists()) {
        await _rotateBackup(primary);
      }
      if (await _promote(tmp)) {
        _primaryKnownBad = false; // 正式文件已换成新内容，脏标记作废
      }
      await _ensureBackup();
    } catch (_) {
      // 目录不可写、配额不足、文件被占用……静默放弃本次保存
    } finally {
      await _deleteQuietly(tmp);
    }
  }

  /// 正式文件 → `.bak`：先删旧备份再 rename；rename 不成就退化为复制，
  /// 无论如何都尽力把「上一份」留下来。
  Future<void> _rotateBackup(File primary) async {
    try {
      final backup = File(_bakPath);
      if (await backup.exists()) await backup.delete();
      await primary.rename(_bakPath);
    } catch (_) {
      try {
        await primary.copy(_bakPath);
      } catch (_) {
        // 备份是 best effort：连复制都失败也继续写正式文件
      }
    }
  }

  /// 正式文件就位；成功返回 true（`_write` 据此决定能不能清掉「正式文件已知脏」）。
  Future<bool> _promote(File tmp) async {
    try {
      await tmp.rename(_path);
      return true;
    } catch (_) {
      // 个别平台 rename 不能覆盖已存在的目标：退回复制，
      // 临时文件由 `_write` 的 finally 清理
      try {
        await tmp.copy(_path);
        return true;
      } catch (_) {
        return false;
      }
    }
  }

  /// 首次保存时正式文件还没有「上一份」，先把新内容复制一份当备份，
  /// 否则第一次崩溃就无档可回退。已有 `.bak` 时绝不动它（那是上一代）。
  Future<void> _ensureBackup() async {
    try {
      if (await File(_bakPath).exists()) return;
      await File(_path).copy(_bakPath);
    } catch (_) {
      // 同上，best effort
    }
  }

  Future<Map<String, Object?>?> _readJson(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final text = await file.readAsString();
      if (text.trim().isEmpty) return null;
      final decoded = jsonDecode(text);
      if (decoded is! Map) return null;
      return decoded.cast<String, Object?>();
    } catch (_) {
      return null;
    }
  }

  LibrarySnapshot? _parse(Map<String, Object?> json) {
    try {
      return LibrarySnapshot.fromJson(json);
    } catch (_) {
      // 兜底：解析层自己也是总函数，这里只是保证 load 绝不抛
      return null;
    }
  }

  Future<bool> _exists(String path) async {
    try {
      return await File(path).exists();
    } catch (_) {
      return false;
    }
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 临时文件删不掉不影响正确性：下次写入会覆盖它
    }
  }
}
