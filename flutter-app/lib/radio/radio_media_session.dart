// lib/radio/radio_media_session.dart
//
// 电台 → 系统媒体卡片的装配层。
//
// 为什么单独一个文件：`RadioState` 是纯播放状态（不认 Android / Windows），
// `MediaSessionCoordinator` 是纯会话协调（不认电台模型）。两边都不该互相
// import，于是把「台 → 快照」的翻译放在这里，由 App 的 provider 装配时接上。
//
// 卡片信息与界面大卡同源：
//   * 标题 = 台名（国际新闻）；
//   * 副标题 = 台面那行 detail + 「直播」（资讯 · 网络台 · 直播）；
//   * 专辑位 = 「流光音乐 · 电台」（Windows SMTC 的第二行）；
//   * 直播 = true → 没有进度条、没有 seek、没有上一台 / 下一台；
//   * 封面色相固定落在品牌绿附近，与 App 内电台卡的渐变同族。
import '../playback/media_session_bridge.dart';
import 'radio_state.dart';
import 'radio_station.dart';

/// 电台封面的色相（#2EE6A8 落在 HSL 约 158°）。
///
/// 生成卡按「歌手名哈希」取色，电台没有歌手可哈希；不指定的话同一台可能
/// 变成蓝紫卡，和 App 里的绿卡对不上。固定 158° 之后，通知栏那张方形卡
/// 与界面大卡是同一种绿。
const int kRadioArtworkHue = 158;

/// 把 [RadioState] 接到系统媒体会话上：状态变化推快照，系统按键回状态机。
class RadioMediaSessionBinding {
  RadioMediaSessionBinding({required this.session, required this.radio});

  final MediaSessionCoordinator session;
  final RadioState radio;

  bool _attached = false;

  /// 接上：注册监听与三个系统动作，并立刻推一次当前台。
  ///
  /// 只在 App 装配时调一次；重复调用幂等（provider 重建也不会挂两条监听）。
  void attach() {
    if (_attached) return;
    _attached = true;
    radio.addListener(_sync);
    session.onRadioPlay = radio.resume;
    session.onRadioPause = radio.pause;
    session.onRadioStop = radio.stop;
    _sync();
  }

  void dispose() {
    if (!_attached) return;
    _attached = false;
    radio.removeListener(_sync);
    session.onRadioPlay = null;
    session.onRadioPause = null;
    session.onRadioStop = null;
  }

  /// 当前台 → 快照。null = 没有台（关台后卡片交还音乐）。
  void _sync() {
    final station = radio.current;
    session.publishRadio(
      station == null ? null : snapshotForStation(station, radio.playing),
    );
  }
}

/// 电台快照的唯一构造点（测试也用它，避免两处文案漂移）。
PublishedSnapshot snapshotForStation(RadioStation station, bool playing) =>
    PublishedSnapshot(
      kind: MediaKind.radio,
      title: station.name,
      // 与界面卡片的副标题同一套字段：detail 在有频率时是「FM97.4 · 北京」，
      // 网络台是「资讯 · 网络台」。后面加「直播」是因为系统卡片没有独立
      // 的 LIVE 徽标，只能把直播语义写进这行小字。
      artist: '${station.detail} · 直播',
      album: '流光音乐 · 电台',
      playing: playing,
      live: true,
      artworkHue: kRadioArtworkHue,
    );
