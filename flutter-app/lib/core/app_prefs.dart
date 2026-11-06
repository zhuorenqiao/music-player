// lib/core/app_prefs.dart
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 带容错的键值读写：任何解析失败都回退默认值并清掉脏数据，绝不抛出。
///
/// 对译 React 版 src/lib/storage.js —— 那里每次读写都包着 try/catch，
/// 因为「隐私模式、配额超限、用户手动改坏存档」都可能抛错。
/// 本类是同一份契约：界面层拿到的永远是可用值或 null，不需要再包 try。
class AppPrefs {
  AppPrefs._(this._backing);

  /// 同步构造：走 shared_preferences 后端，但**不保证已经预热**。
  /// 只有在 [ready] 完成之后读取才有值，否则读取按「无存档」返回 null。
  /// 新代码请优先用 [ready]。
  factory AppPrefs.shared() => AppPrefs._(_SharedBacking());

  /// 异步工厂：先预热 shared_preferences，再返回实例。
  ///
  /// 预热之后 backing 的读取全部同步命中缓存，界面任何位置都能零成本取值，
  /// 不必把 async 散落到 UI 里。
  ///
  /// 为什么「未预热先读」会返回 null：[_SharedBacking.read] 调的是
  /// `SharedPreferences.getString`，一个**同步** API，它只能读到已经缓存好的
  /// 插件句柄；句柄还没准备好时它没有可同步返回的东西，于是读出 null。
  /// 这里刻意不抛错也不阻塞——抛错会污染界面层，阻塞会拖慢首帧，
  /// 而 null 恰好等价于「首次使用、无存档」，调用方自然走默认分支。
  /// 所以 `main()` 必须先 `await AppPrefs.ready()` 再把实例发下去。
  static Future<AppPrefs> ready() async {
    await _SharedBacking.warmUp();
    return AppPrefs._(_SharedBacking());
  }

  /// 测试用，不碰插件。
  factory AppPrefs.inMemory() => AppPrefs._(_MemoryBacking({}));

  final _Backing _backing;

  /// 唯一读取入口：底层任何异常都吞掉，按「无存档」处理。
  String? _raw(String key) {
    try {
      return _backing.read(key);
    } catch (_) {
      return null;
    }
  }

  /// 清理脏数据：删除失败只影响存储，不影响本次播放。
  void _removeQuietly(String key) {
    try {
      _backing.remove(key);
    } catch (_) {
      // 存储不可用：忽略
    }
  }

  void debugSeed(String key, String value) => _backing.write(key, value);

  bool debugContains(String key) => _backing.read(key) != null;

  Future<String?> readString(String key) async => _raw(key);

  Future<void> writeString(String key, String value) async {
    try {
      _backing.write(key, value);
    } catch (_) {
      // 存储不可用：不影响当前播放，与原版一致（原版提示「刷新后需要重新添加」）
    }
  }

  /// 非数值 / 非有限值算脏数据：清理后返回 null；合法值按 min/max 夹紧。
  Future<num?> readNumber(String key, {num? min, num? max}) async {
    final raw = _raw(key);
    if (raw == null) return null;
    final value = num.tryParse(raw);
    if (value == null || !value.isFinite) {
      _removeQuietly(key);
      return null;
    }
    num clamped = value;
    if (min != null && clamped < min) clamped = min;
    if (max != null && clamped > max) clamped = max;
    return clamped;
  }

  Future<void> writeNumber(String key, num value) =>
      writeString(key, value.toString());

  /// 只认字面量 'true' / 'false'；其它值都算脏数据，清理后回退 fallback。
  Future<bool> readBool(String key, {bool fallback = false}) async {
    final raw = _raw(key);
    if (raw == 'true') return true;
    if (raw == 'false') return false;
    if (raw != null) _removeQuietly(key);
    return fallback;
  }

  Future<void> writeBool(String key, bool value) =>
      writeString(key, value ? 'true' : 'false');

  /// 解析失败即清理脏数据并返回 null（调用方走默认分支）。
  Future<Object?> readJson(String key) async {
    final raw = _raw(key);
    if (raw == null) return null;
    try {
      return jsonDecode(raw);
    } catch (_) {
      _removeQuietly(key);
      return null;
    }
  }

  Future<void> writeJson(String key, Object value) async {
    String encoded;
    try {
      encoded = jsonEncode(value);
    } catch (_) {
      // 不可序列化的值：放弃这次写入（与原版一致），不抛给调用方。
      return;
    }
    await writeString(key, encoded);
  }

  Future<void> remove(String key) async => _removeQuietly(key);
}

abstract class _Backing {
  String? read(String key);
  void write(String key, String value);
  void remove(String key);
}

class _MemoryBacking implements _Backing {
  _MemoryBacking(this._store);
  final Map<String, String> _store;

  @override
  String? read(String key) => _store[key];

  @override
  void write(String key, String value) => _store[key] = value;

  @override
  void remove(String key) => _store.remove(key);
}

class _SharedBacking implements _Backing {
  _SharedBacking();

  /// 进程级缓存的插件句柄：[AppPrefs.ready] 预热后，同步读取全部走它。
  static SharedPreferences? _cached;

  /// 拉一次 SharedPreferences 并缓存句柄；存储不可用时静默失败，
  /// 后续读取按「无存档」返回 null，不把异常带到启动流程。
  static Future<void> warmUp() async {
    try {
      _cached ??= await SharedPreferences.getInstance();
    } catch (_) {
      // 同上：读时自然回退默认值。
    }
  }

  @override
  String? read(String key) => _cached?.getString(key);

  @override
  void write(String key, String value) {
    warmUp().then((_) {
      _cached?.setString(key, value);
    }).catchError((Object _) {});
  }

  @override
  void remove(String key) {
    warmUp().then((_) {
      _cached?.remove(key);
    }).catchError((Object _) {});
  }
}
