// lib/radio/radio_state.dart
//
// 电台状态：当前在收听哪一台 + 在响 / 在缓冲 / 出错三件事。
//
// 薄壳一层，真正的出声在内核 [RadioEngine]；界面只读这里。三条约定：
//   1. **同一台再点一次是暂停 / 续播**（不是重新开流 —— 直播流重开要重新缓冲，
//      用户体验上是「卡一下」）；
//   2. 换台先置 loading、清掉上一台的错误，再 open + play；open 失败要落回
//      「没在响」的稳定态，界面据此显示「这台暂时连不上」；
//   3. 离开电台页**不停流**：电台继续在后台放，音乐页底部那条迷你电台条
//      显示「正在收听」；要么点那条回到电台页，要么按暂停 / 关闭。两条音频链路
//      仍然互斥：谁开声，另一边就让位（开台与续播都走 [onTuned]，
//      反向见 `_onMusicStateChanged`）。
//   4. **断流自己接上**：直播流是长连接，上游 CDN 会在播到十几分钟时把连接
//      掐掉（mpv 报 `completed` 或直接落 `playing=false`）。从前这里什么都不做，
//      用户听到的就是「播一会儿就停了」，再往下就只剩音乐链路还在响、看起来
//      像「自动切去放音乐」。现在只要不是用户自己按的暂停，就按退避重连同一台，
//      次数用尽才落回「已暂停 + 连不上」。
//   5. **在播时按钮不转圈**：mpv 的 `core-idle` 会让 `buffering` 在正常出声时
//      反复翻 true/false（直播流每补一小段数据就空转一下）。所以 loading 只在
//      「起播 / 续播 / 重连，且声音还没真的往前走」时成立；播放头（position）
//      一动就收掉，按钮保持暂停图形。真卡死交给下面的看门狗。
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'radio_engine.dart';
import 'radio_station.dart';

class RadioState extends ChangeNotifier {
  RadioState({
    RadioEngine? engine,
    this.onTuned,
    Listenable? musicPlaying,
    bool Function()? isMusicPlaying,
    Duration Function(int attempt)? reconnectDelay,
    this.maxReconnects = 8,
    this.stallTimeout = const Duration(seconds: 12),
  }) : engine = engine ?? MediaKitRadioEngine(),
       reconnectDelay = reconnectDelay ?? defaultReconnectDelay {
    _playingSub = this.engine.playingStream.listen((value) {
      if (_disposed) return;
      if (_playing == value) return;
      _playing = value;
      // 真出声了就一定不在缓冲：把 loading 一起收掉，免得按钮停在转圈。
      if (value) {
        _loading = false;
        _disarmStallWatchdog();
        // 接上了：额度归零，下一次断流还能从头退避。
        _reconnects = 0;
        _reconnecting = false;
        _error = null;
      }
      // 断流也走这条路：mpv 掉线时 `playing` 直接落 false，与「按下暂停」
      // 长得一样 —— 只有我们自己知道用户到底按没按过暂停键。
      if (!value && _shouldAutoReconnect) _scheduleReconnect();
      notifyListeners();
    });
    _completedSub = this.engine.completedStream.listen((value) {
      if (_disposed || !value) return;
      if (_shouldAutoReconnect) _scheduleReconnect();
    });
    _loadingSub = this.engine.loadingStream.listen((value) {
      if (_disposed) return;
      if (value) {
        // 缓冲里卡住也要有人管：mpv 在网络断掉时经常只发 `buffering=true`、
        // 迟迟不给 error（`--network-timeout` 默认 60 秒），从前这里就一直是
        // 「连接中」，用户耳朵里却早就没声了。
        _armStallWatchdog();
        // 用户自己按的暂停 / 起播重连已经打开了 loading：不重复改写。
        if (_userPaused || _reconnecting || _loading) return;
        // 播放头还在走 = 声音没断。mpv 在正常出声时也会反复报 buffering
        //（core-idle 每次补数据都空转一下），不能把播放键翻成转圈。
        if (_playing && _positionIsFresh) return;
        _loading = true;
        notifyListeners();
        return;
      }
      _disarmStallWatchdog();
      // 只认「确实出过声」之后的 buffering=false：起播阶段的 false 可能只是
      // open 完成，声音还没下来，不能把「连接中」提前收掉。
      if (_loading && !_reconnecting && _playing) {
        _loading = false;
        notifyListeners();
      }
    });
    _positionSub = this.engine.positionStream.listen((position) {
      if (_disposed || !_opened) return;
      final previous = _lastPosition;
      _lastPosition = position;
      if (previous != null && position <= previous) return;
      _lastProgressAt = DateTime.now();
      // 声音在往前走：任何「连接中」的残留都在这里收掉（与 React 的 timeupdate 同义）。
      if (_loading && !_reconnecting) {
        _loading = false;
        notifyListeners();
      }
    });
    _errorSub = this.engine.errorStream.listen((message) {
      if (_disposed) return;
      // 直播流的错误文案对用户没有意义（mpv 原文），界面只显示一句人话。
      _lastError = message.trim().isEmpty ? 'unknown' : message.trim();
      _loading = false;
      _playing = false;
      // 网络打嗝也走重连，别把一次抖动当成「这台连不上」。重连期间**不挂**
      // 错误文案（界面上那行「这台暂时连不上」会让人以为只能换台），
      // 次数用尽才把最后一条原文交给界面。
      if (_shouldAutoReconnect) {
        _error = null;
        _scheduleReconnect();
      } else {
        _error = _lastError;
        notifyListeners();
      }
    });
    // 反方向的互斥：用户在音乐页按下播放（或上一首 / 下一首、或列表里点歌），
    // 电台要先让位 —— 当前台**保留**（迷你条显示「已暂停」，点一下能续播），
    // 不是停掉：后台继续放的前提是「切回音乐才算换台」，而不是「电台被清空」。
    _musicPlaying = musicPlaying;
    _isMusicPlaying = isMusicPlaying;
    if (musicPlaying != null && isMusicPlaying != null) {
      musicPlaying.addListener(_onMusicStateChanged);
    }
  }

  /// 出声内核（生产是 media_kit，测试注入替身）。
  final RadioEngine engine;

  /// 自动重连的次数上限：用尽就落回「已暂停 + 这台连不上」，把决定权交回用户。
  final int maxReconnects;

  /// 卡在缓冲多久算断流（与 React `STALL_TIMEOUT` 同一档：12 秒）。
  final Duration stallTimeout;

  /// 第 [attempt] 次重连前等多久（attempt 从 0 起算）。测试传 0 延时。
  final Duration Function(int attempt) reconnectDelay;

  /// 生产用的退避（与 React `RECONNECT_DELAYS` 逐条一致）：
  /// 0.8s / 2s / 4s / 8s / 12s 封顶。
  ///
  /// 首次只等 0.8 秒：这是一条**已经断开**的长连接，晚开一秒用户就多一秒静默；
  /// 真正「上游还在掐」的情况，后面的档位自己会拉开。次数给到 8，
  /// 是因为直播流断一次接一次是常态，4 次往往在用户还没抬头时就耗尽了。
  static Duration defaultReconnectDelay(int attempt) {
    const delays = [800, 2000, 4000, 8000, 12000];
    final ms = delays[attempt.clamp(0, delays.length - 1)];
    return Duration(milliseconds: ms);
  }

  /// 出声前的钩子：装配层用它把音乐暂停（两条链路不能同时出声）。
  /// 换台开流与同台续播都会走它，并且**等它做完**再出声 —— 不 await 的话
  /// 音乐淡出的那几帧会和电台叠在一起。
  final FutureOr<void> Function(RadioStation station)? onTuned;

  /// 音乐播放状态（装配层注入 `PlayerState`）：它一开声，电台就让位。
  Listenable? _musicPlaying;
  bool Function()? _isMusicPlaying;

  late final StreamSubscription<bool> _playingSub;
  late final StreamSubscription<bool> _loadingSub;
  late final StreamSubscription<String> _errorSub;
  late final StreamSubscription<bool> _completedSub;
  late final StreamSubscription<Duration> _positionSub;

  RadioStation? _current;
  bool _playing = false;
  bool _loading = false;
  String? _error;
  String? _lastError;
  bool _opened = false;
  bool _disposed = false;

  /// 用户侧决定的暂停（自己按 / 音乐开声让位 / 睡眠定时器到点）：
  /// 只有它们能让「断流重连」闭嘴。
  bool _userPaused = false;

  /// 正在重连 / 已排上重连。
  bool _reconnecting = false;
  int _reconnects = 0;
  Timer? _reconnectTimer;

  /// 卡死看门狗：从 mpv 报 `buffering` 起算，到点还没出声就自己重开。
  Timer? _stallTimer;

  /// 播放头最后一次位置与「最近一次真的往前走」的时间（判断流还有没有气）。
  Duration? _lastPosition;
  DateTime? _lastProgressAt;

  /// 看门狗上表那一刻的播放头：到点还没变，说明这 12 秒里一点没往前走。
  Duration? _positionAtArm;

  /// 播放头多久没动就算这条流没在出声（看门狗与按钮 loading 共用一档）。
  static const Duration _positionFreshWindow = Duration(seconds: 2);

  /// 播放头最近 [_positionFreshWindow] 内有没有往前走。
  bool get _positionIsFresh {
    final at = _lastProgressAt;
    if (at == null) return false;
    return DateTime.now().difference(at) < _positionFreshWindow;
  }

  /// 当前选中的台；null = 还没选过（或刚 [stop] 过）。
  RadioStation? get current => _current;

  /// 是否真的在响。
  bool get playing => _playing;

  /// 是否在重连（界面把「连接中」说得更准确一点，也用来抑制错误文案）。
  bool get reconnecting => _reconnecting;

  /// 是否在缓冲（刚换台 / 网络卡住）。
  bool get loading => _loading;

  /// 最后一次内核错误原文；界面只用来判断「要不要显示连不上的提示」。
  String? get error => _error;

  /// 这一台是不是正在响（界面据此画均衡条 / 高亮卡）。
  bool isLive(RadioStation station) =>
      _current?.id == station.id && _playing;

  /// 点一台：同台切换暂停 / 续播，异台换流开播。
  Future<void> tune(RadioStation station) async {
    if (_current?.id == station.id && _opened) {
      await toggle();
      return;
    }
    _current = station;
    _error = null;
    _lastError = null;
    _playing = false;
    _loading = true;
    _opened = false;
    _userPaused = false;
    // 换台等于换一条流：上一台的播放头不能拿来给这一台作证。
    _lastPosition = null;
    _lastProgressAt = null;
    _positionAtArm = null;
    _cancelReconnect();
    notifyListeners();

    // 先让音乐让位（同一条装配层的钩子），再开流 —— 顺序反了会有一瞬间两路
    // 声音叠在一起。这里要等暂停真的落下去，不能只发个信号就往下走。
    await onTuned?.call(station);
    if (_disposed) return;
    final opened = await engine.open(station.streamUrl);
    if (_disposed) return;
    if (!opened) {
      _loading = false;
      _playing = false;
      _error = _error ?? 'stream unreachable';
      notifyListeners();
      return;
    }
    _opened = true;
    // 开流这段时间里，睡眠定时器到点 / 用户回音乐页按了播放：流可以开，
    // 但绝不能再出声（`pause()` 会把 `_userPaused` 置位并取消重连）。
    if (_userPaused) {
      _loading = false;
      notifyListeners();
      return;
    }
    await engine.play();
    if (_disposed) return;
    // 内核的 playing 流通常紧随其后；这里兜一层，避免按钮一直转圈。
    _loading = false;
    notifyListeners();
  }

  /// 暂停 / 续播当前台。
  Future<void> toggle() async {
    final station = _current;
    if (station == null || !_opened) return;
    if (_playing) {
      _userPaused = true;
      _cancelReconnect();
      // 暂停是稳定态：不能把上一段缓冲的「连接中」留在按钮上。
      if (_loading) {
        _loading = false;
        notifyListeners();
      }
      await engine.pause();
    } else {
      _userPaused = false;
      _cancelReconnect();
      _error = null;
      _lastError = null;
      _loading = true;
      notifyListeners();
      // 续播也要让音乐先让位：电台可能正是被「音乐开声」挤停的，用户此刻在
      // 音乐页点迷你条上的播放键，音乐往往还在响 —— 少了这一步两路声音就叠住。
      await onTuned?.call(station);
      if (_disposed) return;
      // 续播前这几帧里定时器到点了 / 音乐又开声了：别再出声。
      if (_userPaused) {
        _loading = false;
        notifyListeners();
        return;
      }
      await engine.play();
      if (_disposed) return;
      _loading = false;
      notifyListeners();
    }
  }

  /// 续播当前台（系统卡片上的「播放」走这里）。
  ///
  /// 与 [toggle] 的区别：这个不看当前在不在响，永远往「出声」走 ——
  /// 通知栏 / 锁屏按播放时，状态可能因为重连或缓冲晚到一拍，不能反过来
  /// 把电台按成暂停。已经在响就什么都不做；没开过流（上次 open 失败）就
  /// 重新走一次 [tune]，让用户点一下真的能听见。
  Future<void> resume() async {
    final station = _current;
    if (_disposed || station == null || _playing) return;
    if (!_opened) {
      await tune(station);
      return;
    }
    await toggle();
  }

  /// 暂停当前台（保留当前台，迷你条仍在）。
  ///
  /// 与 [toggle] 的区别：这个不看当前是否在响，永远往「暂停」走 —— 用户在音乐页
  /// 按了播放、睡眠定时器到点，电台都必须无条件让位，不能因为状态晚到一拍
  /// 而反过来把音乐切了，也不能在「等下一次重连」的空档里被定时器放过。
  ///
  /// 幂等：没开过台只把状态收干净；已经暂停时再调一次不会重复出声。
  Future<void> pause() async {
    if (_disposed) return;
    // 让位是**用户侧**的决定（自己按 / 音乐开声 / 睡眠定时器到点）：
    // 断流重连不许把它推翻，否则「定时结束 → 暂停 → 重连又开声」会成死循环。
    _userPaused = true;
    final hadReconnect = _reconnecting;
    final hadLoading = _loading;
    _cancelReconnect();
    _loading = false;
    if (hadReconnect || hadLoading) notifyListeners();
    if (!_opened) return;
    await engine.pause();
    if (_disposed) return;
    // 内核没补 pause 事件时也要把界面落到「已暂停」。
    if (_playing) {
      _playing = false;
      notifyListeners();
    }
  }

  void _onMusicStateChanged() {
    if (_disposed) return;
    final musicPlaying = _isMusicPlaying?.call() ?? false;
    if (musicPlaying) unawaited(pause());
  }

  /// 这一次「声停」该不该自己接回去。
  ///
  /// 四个否：没选台 / 流没开过 / 用户自己按的暂停 / 正在重连。外加额度用尽。
  /// `_loading` 也否掉 —— 换台过程中 mpv 本就会先报一帧 playing=false。
  bool get _shouldAutoReconnect =>
      !_disposed &&
      _current != null &&
      _opened &&
      !_userPaused &&
      !_reconnecting &&
      !_loading &&
      _reconnects < maxReconnects;

  /// 排一次重连（同退避值只排一次）。
  ///
  /// [delay] 传值用于「不等退避」的场合：回到前台、网络刚恢复 —— 这时候已经
  /// 白等了整个后台的时间，再按退避排一次就是把静默又拉长几秒。
  void _scheduleReconnect({Duration? delay}) {
    _cancelReconnect();
    // 这一路已经没声了（error / completed / 看门狗抓到的卡死）：先落回「没在响」，
    // 免得重连的那几秒里状态还亮着、按钮却按不下去。
    _playing = false;
    _reconnecting = true;
    _loading = true;
    notifyListeners();
    _reconnectTimer = Timer(delay ?? reconnectDelay(_reconnects), _reconnectNow);
  }

  /// 起了缓冲就上表（幂等）：到点还停在 `_playing == false` 才真的算卡死。
  void _armStallWatchdog() {
    if (_stallTimer != null || _disposed) return;
    _positionAtArm = _lastPosition;
    _stallTimer = Timer(stallTimeout, () {
      _stallTimer = null;
      // 用户自己按的暂停 / 已经停台 / 正在重连，都不该被看门狗推翻。
      if (_disposed || _userPaused || !_opened || _reconnecting) return;
      // 播放头在这 12 秒里往前走、而且刚才还在走 = 这条流是活的 ——
      // 哪怕 mpv 刚报过 buffering 也不能重开。`_lastPosition == null` 兜住
      // 「内核不报位置」的情况：那时只能信 playing。
      final advanced = _lastPosition != null && _lastPosition != _positionAtArm;
      if (_playing && (_lastPosition == null || (advanced && _positionIsFresh))) {
        return;
      }
      // 不等 mpv 报错：`--network-timeout` 默认 60 秒，用户耳朵里已经静默一分钟。
      _scheduleReconnect();
    });
  }

  void _disarmStallWatchdog() {
    _stallTimer?.cancel();
    _stallTimer = null;
  }

  Future<void> _reconnectNow() async {
    _reconnectTimer = null;
    final station = _current;
    if (_disposed || station == null || !_reconnecting) return;
    _reconnects += 1;
    // 重连也要让音乐先让位：用户可能在被断流的空档里点了歌单。
    await onTuned?.call(station);
    if (_disposed) return;
    // 新开一条流：旧的播放头不再作数，从 0 重新看。
    _opened = false;
    _lastPosition = null;
    _lastProgressAt = null;
    _positionAtArm = null;
    final opened = await engine.open(station.streamUrl);
    if (_disposed) return;
    if (!opened) {
      _reconnecting = false;
      _loading = false;
      if (_reconnects < maxReconnects) {
        _scheduleReconnect();
      } else {
        _error = _lastError ?? 'stream unreachable';
        notifyListeners();
      }
      return;
    }
    _opened = true;
    // 重连期间定时器到点：重开的流不推、不播，留在暂停态。
    if (_userPaused) {
      _reconnecting = false;
      _loading = false;
      notifyListeners();
      return;
    }
    await engine.play();
    if (_disposed) return;
    // 内核的 playing 流随后就到；这里先落「不在连接中」，别让按钮一直转圈。
    _reconnecting = false;
    _loading = false;
    notifyListeners();
  }

  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnecting = false;
    _disarmStallWatchdog();
  }

  /// 回到前台时由装配层的生命周期监听调用。
  ///
  /// 后台期间系统可能已经把这条长连接掐掉（或直接冻住了 mpv），而 Flutter 侧
  /// 拿不到任何「断流」事件 —— 只能回来时自己看一眼：没在响就立刻重接一次。
  /// 幂等：正在响 / 已在重连 / 用户自己暂停 / 没开过台，都直接返回。
  void recover() {
    if (_disposed || _userPaused || !_opened || _current == null) return;
    if (_reconnecting) return;
    // 「在响」不能只看 playing：mpv 被系统冻住时 pause 还是 false，但播放头不动。
    if (_playing && (_lastPosition == null || _positionIsFresh)) return;
    _reconnects = 0;
    _error = null;
    _lastError = null;
    _scheduleReconnect(delay: Duration.zero);
  }

  /// 停流并清空当前台（迷你条上的「关闭」调用）。
  Future<void> stop() async {
    if (_disposed) return;
    _cancelReconnect();
    await engine.stop();
    _current = null;
    _opened = false;
    _playing = false;
    _loading = false;
    _error = null;
    _lastError = null;
    _userPaused = false;
    _lastPosition = null;
    _lastProgressAt = null;
    _positionAtArm = null;
    notifyListeners();
  }

  /// 音量与音乐共用同一个 0~1 标度（界面暂不暴露滑杆，留给后续接音量条）。
  Future<void> setVolume(double value) => engine.setVolume(value);

  /// 用户可读的错误文案（内核原文不进界面）。
  String errorMessage() {
    if (_error == null) return '';
    return '这台暂时连不上，换一台试试';
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelReconnect();
    if (_musicPlaying != null) {
      _musicPlaying!.removeListener(_onMusicStateChanged);
    }
    unawaited(_playingSub.cancel());
    unawaited(_loadingSub.cancel());
    unawaited(_errorSub.cancel());
    unawaited(_completedSub.cancel());
    unawaited(_positionSub.cancel());
    unawaited(engine.dispose());
    super.dispose();
  }
}
