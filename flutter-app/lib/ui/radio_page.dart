// lib/ui/radio_page.dart
//
// 电台页（2026-11-20 重构）：问候语 + 大标题 → 一张铺满整宽的播放卡 → 播放状线 →
// **分类页签**（音乐台 / 交通台 / 网络电台）→ 单列行表 → 页脚一句话。
//
// 「所属分类」写在播放卡顶部那行小字里（`传统 FM · 音乐台`），换台时跟着换；
// 下方页签只负责筛台表，两者共用 `radioTabOf()` 那一份分类元数据。
//
// 在播时大卡上的同心环会一圈圈慢慢向外扩散（暂停就冻在原地，不跳回）；
// 列表缩略图不参与 —— 40px 里再扩散只会像噪点。
//
// 颜色一个都不写死：全部走 [AppTokens]，换肤 / 明暗切换时整页跟着翻。
// 与 React `src/components/RadioPage.tsx` 逐项对齐（文案、尺寸、圆角、字号、间距），
// 改一处必须改另一处。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/breakpoints.dart';
import '../radio/radio_station.dart';
import '../radio/radio_state.dart';
import '../theme/app_tokens.dart';
import 'more_menu.dart';

/// 播放卡圆角：与音乐页那张卡同档（`--radius-xl`）。
const double _radius = 24;

/// 桌面版心：参考图是手机版式，宽屏把它摊成一张长表会很空。
const double _maxContent = 760;

class RadioPage extends StatefulWidget {
  const RadioPage({required this.onBack, super.key});

  /// 回音乐播放器（通常是 `Navigator.pop`；电台不停流）。
  final VoidCallback onBack;

  @override
  State<RadioPage> createState() => _RadioPageState();
}

class _RadioPageState extends State<RadioPage> {
  /// 当前页签：进页面时跟着「正在收听的台」走，没台就落在音乐台。
  late RadioCategory _active;

  @override
  void initState() {
    super.initState();
    _active =
        context.read<RadioState>().current?.category ?? RadioCategory.music;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final radio = context.watch<RadioState>();
    final stations = radioStationsOf(_active);
    // 窄屏：右上角两颗（音乐 / 更多）浮在页头之外，落位与音乐页顶栏同源
    // （`app.css` 小屏媒体块 + `shell.dart` 的 `Positioned`）。insets 要在
    // [SafeArea] 外面读 —— SafeArea 里 MediaQuery 的 padding 已经被吃掉。
    final narrow = !isDesktop(MediaQuery.sizeOf(context).width);
    final insets = MediaQuery.paddingOf(context);
    return Scaffold(
      backgroundColor: tokens.bg,
      body: DecoratedBox(
        // `body::before`：与音乐页同一张对角渐变，只是两端的色落在 token 上。
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [tokens.bgGradA, tokens.bgGradB],
          ),
        ),
        child: Stack(
          // 窄屏时「音乐 / 更多」浮在页头之上（与音乐页顶栏同一个落位），
          // 宽屏仍留在页头那一行里，所以这里只多一层叠加，不动原有排版。
          fit: StackFit.expand,
          children: [
            SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth;
                  final desktop = isDesktop(width);
                  final maxWidth = desktop
                      ? math.min(
                          _maxContent,
                          contentMaxWidth(MediaQuery.sizeOf(context).width),
                        )
                      : width;
                  return Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: maxWidth),
                      child: SingleChildScrollView(
                        physics: const BouncingScrollPhysics(),
                        padding: desktop
                            ? const EdgeInsets.fromLTRB(28, 24, 28, 32)
                            : EdgeInsets.fromLTRB(
                                16,
                                12,
                                16,
                                24 + MediaQuery.paddingOf(context).bottom,
                              ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _Header(onBack: widget.onBack),
                            _Greeting(desktop: desktop),
                            SizedBox(height: desktop ? 24 : 20),
                            _HeroCard(radio: radio, desktop: desktop),
                            const SizedBox(height: 14),
                            _StatusLine(radio: radio),
                            SizedBox(height: desktop ? 22 : 18),
                            _TabBar(
                              active: _active,
                              onChanged: (category) =>
                                  setState(() => _active = category),
                            ),
                            const SizedBox(height: 4),
                            _StationList(
                              stations: stations,
                              radio: radio,
                              desktop: desktop,
                            ),
                            const SizedBox(height: 26),
                            _FootLine(text: '让声音，慢一点。'),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            // 窄屏：两颗按钮浮在视口右上角，横向落位与音乐页顶栏同源；
            // 竖直方向跟左侧品牌块居中对齐 —— 品牌行从「安全区 + 12」起、40 高
            // （中心 = 安全区 + 32），按钮 32 高，所以 top = 安全区 + 16。
            if (narrow)
              Positioned(
                top: insets.top + 16,
                right: insets.right + 10,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _MusicBackChip(onBack: widget.onBack),
                    const SizedBox(width: 8),
                    MoreMenu(showLibraryActions: false, iconOnly: true),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 页头：左侧「电台」标识；宽屏右侧再排「音乐」回退胶囊 + 「更多」。
///
/// 「更多」与音乐页顶栏那颗是同一个 [MoreMenu]，但这里只留「换肤」
/// （`showLibraryActions: false`）：电台是另一条音频链路，页头不提供
/// 添加 / 清空播放列表，免得听着电台误操作了音乐曲库。
/// 窄屏右侧两颗不在这行里 —— 由 [RadioPage] 的 Stack 浮到视口右上角，
/// 横向与音乐页顶栏同一落位，竖直方向跟这一行的品牌块居中对齐
/// （`_MusicBackChip` / [MoreMenu] 都收成 32×32 图标）。
class _Header extends StatelessWidget {
  const _Header({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final narrow = !isDesktop(MediaQuery.sizeOf(context).width);
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: tokens.accentLine),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [tokens.accentSoft, tokens.cardB],
            ),
          ),
          alignment: Alignment.center,
          child: CustomPaint(
            size: const Size.square(20),
            painter: _BroadcastPainter(color: tokens.accent),
          ),
        ),
        const SizedBox(width: 10),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '电台',
              style: TextStyle(
                fontSize: 15,
                height: 1.1,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.0,
                color: tokens.text,
              ),
            ),
            // 中文站名与英文之间留 4px：两行都压着 1.1 的行高，不加这一档
            // 英文几乎贴着「电台」的下缘（与 React `.radio-head__text` 的 gap 同值）。
            const SizedBox(height: 4),
            Text(
              'LIVE RADIO',
              style: TextStyle(
                fontSize: 10,
                height: 1.1,
                letterSpacing: 1.7,
                color: tokens.textFaint,
              ),
            ),
          ],
        ),
        // 窄屏：这两颗由 [RadioPage] 的 Stack 叠在视口右上角，横向与音乐页顶栏
        // 同一落位，竖直方向跟下面这组品牌内容居中对齐；页头这一行只留品牌。
        if (!narrow) ...[
          const Spacer(),
          _MusicBackChip(onBack: onBack),
          const SizedBox(width: 10),
          MoreMenu(showLibraryActions: false, iconOnly: false),
        ],
      ],
    );
  }
}

/// 回音乐播放器：桌面是「音符 + 音乐」胶囊，窄屏只剩音符图标。
class _MusicBackChip extends StatelessWidget {
  const _MusicBackChip({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final narrow = !isDesktop(MediaQuery.sizeOf(context).width);
    return Semantics(
      button: true,
      label: '返回音乐播放器',
      excludeSemantics: true,
      onTap: onBack,
      child: InkWell(
        key: const Key('radio-back-button'),
        onTap: onBack,
        borderRadius: BorderRadius.circular(999),
        overlayColor: WidgetStatePropertyAll<Color>(tokens.accentSoft),
        child: Container(
          height: narrow ? 32 : 36,
          width: narrow ? 32 : null,
          padding: narrow
              ? EdgeInsets.zero
              : const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: narrow ? null : Border.all(color: tokens.border),
            color: narrow ? Colors.transparent : tokens.surface,
          ),
          alignment: Alignment.center,
          child: narrow
              ? CustomPaint(
                  size: const Size.square(18),
                  painter: _MusicNotePainter(color: tokens.textDim),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CustomPaint(
                      size: const Size.square(16),
                      painter: _MusicNotePainter(color: tokens.text),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '音乐',
                      style: TextStyle(fontSize: 12.5, color: tokens.text),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

/// 问候语 + 大标题（与 React 的 `.radio-greet` 同尺寸）。
class _Greeting extends StatelessWidget {
  const _Greeting({required this.desktop});

  final bool desktop;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Padding(
      padding: EdgeInsets.only(top: desktop ? 30 : 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            radioGreeting(DateTime.now().hour),
            style: TextStyle(
              fontSize: 13,
              height: 1.1,
              fontWeight: FontWeight.w500,
              letterSpacing: 1.4,
              color: tokens.accent,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '想听点什么？',
            style: TextStyle(
              fontSize: desktop ? 34 : 30,
              height: 1.24,
              fontWeight: FontWeight.w500,
              letterSpacing: 1.2,
              color: tokens.text,
            ),
          ),
        ],
      ),
    );
  }
}

/// 大播放卡：没选台时先拿目录第一台当门面，点一下就从它开始。
class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.radio, required this.desktop});

  final RadioState radio;
  final bool desktop;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final station = radio.current ?? kRadioStations.first;
    final tab = radioTabOf(station.category);
    final playing = radio.playing;
    final loading = radio.loading;
    final height = desktop ? 248.0 : 226.0;
    final inset = desktop ? 22.0 : 18.0;
    final playSize = desktop ? 58.0 : 52.0;
    final stemTop = desktop ? 52.0 : 46.0;
    // 压底层的落点色 = 台面渐变自己的收尾色（与 radioArtMix 同源）。
    // 不能落回 tokens.bg：浅色主题里 bg 是冷调灰蓝，压到暖色卡面上，
    // 下半张会拐出一道灰带（粉 → 灰 → 冷白），渐变成了两截。
    final (_, mixEnd) = radioArtMix(station);
    final veilEnd = Color.lerp(tokens.panelB, tokens.accent, mixEnd)!;

    return Semantics(
      container: true,
      label: '当前电台：${station.name}',
      child: Container(
        height: height,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(_radius),
          border: Border.all(color: tokens.border),
          color: tokens.surface,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final h = constraints.maxHeight;
            return Stack(
              children: [
                Positioned.fill(
                  child: _StationArt(
                    station: station,
                    tokens: tokens,
                    playing: playing,
                  ),
                ),
                // 压一层底：文字落在这一层上，浅色模式也不会糊在亮绿上。
                // 落点色取自台面收尾色，两层同支色，只加深、不换调。
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          veilEnd.withValues(alpha: 0.0),
                          veilEnd.withValues(alpha: 0.14),
                          veilEnd.withValues(alpha: 0.44),
                          veilEnd.withValues(alpha: 0.76),
                          veilEnd,
                        ],
                        stops: const [0.14, 0.40, 0.64, 0.85, 1.0],
                      ),
                    ),
                  ),
                ),
                // 顶部两行小字：左「所属分类」，右英文角标
                Positioned(
                  top: desktop ? 20 : 16,
                  left: inset,
                  right: inset,
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          tab.section,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            height: 1.1,
                            letterSpacing: 2.4,
                            color: tokens.text.withValues(alpha: 0.60),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        tab.en,
                        style: TextStyle(
                          fontSize: 10,
                          height: 1.1,
                          letterSpacing: 2.4,
                          color: tokens.text.withValues(alpha: 0.44),
                        ),
                      ),
                    ],
                  ),
                ),
                // 参考图里那枚「播放头」：一根竖线 + 末端小点，在播时点亮
                Positioned(
                  top: stemTop,
                  left: inset,
                  width: 1,
                  height: h * 0.44,
                  child: _PlayheadStem(color: tokens.accent, lit: playing),
                ),
                // 底部：大字台名 + 副标题（右侧留给圆形播放键）
                Positioned(
                  left: inset,
                  right: inset + playSize + 8,
                  bottom: inset,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        station.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: desktop ? 30 : 26,
                          height: 1.16,
                          fontWeight: FontWeight.w500,
                          letterSpacing: desktop ? 2.4 : 2.0,
                          color: tokens.text,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        station.detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.2,
                          letterSpacing: 0.4,
                          color: tokens.textDim,
                        ),
                      ),
                      if (radio.error != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          radio.errorMessage(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10.5,
                            height: 1.2,
                            color: tokens.dangerInk,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Positioned(
                  right: inset,
                  bottom: inset,
                  child: _PlayCircle(
                    playing: playing,
                    loading: loading,
                    size: playSize,
                    onTap: () {
                      if (radio.current == null) {
                        radio.tune(station);
                      } else {
                        radio.toggle();
                      }
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 播放头：竖线末端一枚小圆点（在播时更亮、带一圈微光）。
class _PlayheadStem extends StatelessWidget {
  const _PlayheadStem({required this.color, required this.lit});

  final Color color;
  final bool lit;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: Container(width: 1, color: color.withValues(alpha: 0.34)),
        ),
        Positioned(
          left: -2.5,
          bottom: -2.5,
          child: Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: lit ? 1.0 : 0.62),
              boxShadow: lit
                  ? [
                      BoxShadow(
                        color: color.withValues(alpha: 0.85),
                        blurRadius: 12,
                      ),
                    ]
                  : null,
            ),
          ),
        ),
      ],
    );
  }
}

/// 播放状线：左侧状态（点 + 文案），右侧 LIVE / IDLE，底线一根发丝线。
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.radio});

  final RadioState radio;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final playing = radio.playing;
    // 断流自动重连（radio_state.dart 的 `_scheduleReconnect`）：这里要说「重连中」
    // 而不是干巴巴的「连接中」—— 用户刚才明明在听，突然静音再自己接上，
    // 界面得让他知道是流断了、不是自己点错了。
    final status = radio.reconnecting
        ? '重连中'
        : (radio.loading
              ? '连接中'
              : (playing ? '正在收听' : (radio.current != null ? '已暂停' : '还没在听')));
    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tokens.border)),
      ),
      child: Row(
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: playing ? tokens.accent : tokens.textFaint,
            ),
          ),
          const SizedBox(width: 7),
          Text(
            status,
            style: TextStyle(
              fontSize: 11,
              height: 1.1,
              letterSpacing: 0.6,
              color: tokens.text.withValues(alpha: 0.62),
            ),
          ),
          const Spacer(),
          Text(
            playing ? 'LIVE' : 'IDLE',
            style: TextStyle(
              fontSize: 9,
              height: 1.1,
              letterSpacing: 1.8,
              color: playing ? tokens.accent : tokens.textFaint,
            ),
          ),
        ],
      ),
    );
  }
}

/// 分类页签：短名 + 台数，选中走 accent 与一根短下划线。
class _TabBar extends StatelessWidget {
  const _TabBar({required this.active, required this.onChanged});

  final RadioCategory active;
  final ValueChanged<RadioCategory> onChanged;

  @override
  Widget build(BuildContext context) {
    final desktop = isDesktop(MediaQuery.sizeOf(context).width);
    return Padding(
      padding: EdgeInsets.only(top: desktop ? 22 : 18),
      child: Row(
        children: [
          for (final tab in radioTabs())
            Padding(
              padding: EdgeInsets.only(right: tab == radioTabs().last ? 0 : 24),
              child: _TabButton(
                key: Key('radio-tab-${tab.id.name}'),
                tab: tab,
                selected: tab.id == active,
                onTap: () => onChanged(tab.id),
              ),
            ),
        ],
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.tab,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final RadioTab tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Semantics(
      button: true,
      selected: selected,
      label: '${tab.label} ${radioStationsOf(tab.id).length} 台',
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        overlayColor: WidgetStatePropertyAll<Color>(tokens.accentSoft),
        child: Container(
          padding: const EdgeInsets.only(bottom: 9),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                width: 2,
                color: selected ? tokens.accent : Colors.transparent,
              ),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                tab.label,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.1,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.6,
                  color: selected ? tokens.text : tokens.textDim,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                '${radioStationsOf(tab.id).length}',
                style: TextStyle(
                  fontSize: 9,
                  height: 1.1,
                  letterSpacing: 1.0,
                  color: selected
                      ? tokens.accent.withValues(alpha: 0.8)
                      : tokens.textFaint,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 单列台表：缩略 + 台名 / 频率城市 + 右侧角标，发丝线分隔。
class _StationList extends StatelessWidget {
  const _StationList({
    required this.stations,
    required this.radio,
    required this.desktop,
  });

  final List<RadioStation> stations;
  final RadioState radio;
  final bool desktop;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < stations.length; i++) ...[
          if (i > 0) Divider(height: 1, thickness: 1, color: tokens.border),
          _StationRow(
            key: Key('radio-row-${stations[i].id}'),
            station: stations[i],
            live: radio.isLive(stations[i]),
            selected: radio.current?.id == stations[i].id,
            desktop: desktop,
            onTap: () => radio.tune(stations[i]),
          ),
        ],
      ],
    );
  }
}

/// 一行台：48（窄屏 44）缩略方块 + 台名 / 频率城市 + 右侧角标（在播时换成静息柱）。
class _StationRow extends StatelessWidget {
  const _StationRow({
    required this.station,
    required this.live,
    required this.selected,
    required this.desktop,
    required this.onTap,
    super.key,
  });

  final RadioStation station;
  final bool live;
  final bool selected;
  final bool desktop;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final thumb = desktop ? 48.0 : 44.0;
    return Semantics(
      button: true,
      selected: selected,
      label: '${station.name} ${station.detail}',
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        overlayColor: WidgetStatePropertyAll<Color>(tokens.accentSoft),
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: desktop ? 14 : 12),
          child: Row(
            children: [
              Container(
                width: thumb,
                height: thumb,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(desktop ? 13 : 12),
                  border: Border.all(color: tokens.borderStrong),
                ),
                child: CustomPaint(
                  painter: _StationArtPainter(station: station, tokens: tokens),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      station.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        height: 1.15,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.6,
                        color: selected ? tokens.accent : tokens.text,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      station.detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.15,
                        letterSpacing: 0.2,
                        color: tokens.textDim,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              if (live)
                _EqualizerBars(color: tokens.accent)
              else
                Text(
                  station.kind,
                  style: TextStyle(
                    fontSize: 10,
                    height: 1.1,
                    letterSpacing: 0.8,
                    color: tokens.textFaint,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 页脚：一句轻话，前面一根短横。
class _FootLine extends StatelessWidget {
  const _FootLine({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Row(
      children: [
        Container(
          width: 26,
          height: 1,
          color: tokens.accent.withValues(alpha: 0.34),
        ),
        const SizedBox(width: 10),
        Text(
          text,
          style: TextStyle(
            fontSize: 10.5,
            height: 1.2,
            letterSpacing: 1.6,
            color: tokens.textFaint,
          ),
        ),
      ],
    );
  }
}

/// 大卡台面：静止台面 + 在播时不断外扩的水波。
///
/// 没播过时是三道静止环；播过一次就把静止环淡出，只剩四道等相位的水波：
/// 每道 16s 从最内圈推到 2.6 倍再淡掉、彼此错开 4s —— 任何时刻都有三、四圈
/// 在向外走，像水面一圈圈荡开。暂停用 `stop()` 把相位留在原地（和 React 端
/// `.radio-art__waves` 的 `animation-play-state: paused` 同一套语义）。
class _StationArt extends StatefulWidget {
  const _StationArt({
    required this.station,
    required this.tokens,
    required this.playing,
  });

  final RadioStation station;
  final AppTokens tokens;
  final bool playing;

  @override
  State<_StationArt> createState() => _StationArtState();
}

class _StationArtState extends State<_StationArt>
    with TickerProviderStateMixin {
  /// 与 React `radio-wave-*` 同一个时长：16 秒一圈，四道相位各差 1/4。
  late final AnimationController _ripple = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 16),
  );

  /// 静止环→水波的交替：0 是三道静止环，1 是只剩水波。
  /// 与 React 的 `opacity 0.36s` 过渡同档；暂停后停在 1，不再退回静止环。
  late final AnimationController _ringsFade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 360),
  );

  late final Listenable _ticks = Listenable.merge([_ripple, _ringsFade]);

  /// 播过至少一次才让水波接管；暂停后它留在冻结的那一帧上。
  bool _armed = false;

  bool get _reduceMotion => MediaQuery.of(context).disableAnimations;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant _StationArt oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (_reduceMotion) {
      _ripple.stop();
      _armed = false;
      _ringsFade.value = 0;
      return;
    }
    if (widget.playing) {
      if (!_armed) {
        _armed = true;
        _ringsFade.forward();
      }
      if (!_ripple.isAnimating) {
        _ripple.repeat();
      }
      return;
    }
    _ripple.stop();
  }

  @override
  void dispose() {
    _ripple.dispose();
    _ringsFade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _StationArtPainter(
        station: widget.station,
        tokens: widget.tokens,
        wave: _armed ? _ripple : null,
        ringsFade: _ringsFade,
        ticks: _ticks,
      ),
    );
  }
}

/// 站台卡面：主题色渐变 + 右上光晕 + 同心底纹（静止环 / 水波）+ 底部一根波段。
///
/// 完全由 token 派生（accent / panelB / text），没有一张外部图片：换肤、
/// 切明暗之后整页的卡面会跟着一起换调子，不用准备 6 套图。
class _StationArtPainter extends CustomPainter {
  _StationArtPainter({
    required this.station,
    required this.tokens,
    this.wave,
    this.ringsFade,
    this.ticks,
  }) : super(repaint: ticks);

  final RadioStation station;
  final AppTokens tokens;

  /// 在播时由 [_StationArt] 传入的循环相位（0→1）；null 就只画静止台面。
  final Animation<double>? wave;

  /// 静止环让位给水波的进度（0→1）；列表缩略图不传，永远显示静止环。
  final Animation<double>? ringsFade;

  /// 两个控制器合在一起的重绘信号。
  final Listenable? ticks;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    // 分类 / seed 只调「混色比例」，不引入色相：三种电台看起来是同族的三档。
    final (mixStart, mixEnd) = radioArtMix(station);
    final base = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Color.lerp(tokens.panelB, tokens.accent, mixStart)!,
        Color.lerp(tokens.panelB, tokens.accent, mixEnd)!,
      ],
    );
    canvas.drawRect(rect, Paint()..shader = base.createShader(rect));

    // 右上光晕
    final glowCenter = Offset(size.width * 0.82, size.height * 0.16);
    final glowRadius = size.shortestSide * 0.62;
    canvas.drawCircle(
      glowCenter,
      glowRadius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            tokens.accent.withValues(alpha: 0.30),
            tokens.accent.withValues(alpha: 0.0),
          ],
        ).createShader(Rect.fromCircle(center: glowCenter, radius: glowRadius)),
    );

    // 三道静止环（圆心随 seed 微微走位）。播过一次后整体淡出，
    // 把画面让给水波；列表缩略图没有 ringsFade，永远保持这三道。
    final ringCenter = Offset(
      size.width * (0.74 + station.seed * 0.08),
      size.height * (0.26 + station.seed * 0.05),
    );
    final ringsAlpha = 1 - (ringsFade?.value ?? 0.0);
    if (ringsAlpha > 0) {
      for (var i = 0; i < 3; i++) {
        canvas.drawCircle(
          ringCenter,
          size.shortestSide * (0.18 + i * 0.13),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.0
            ..color = tokens.accent.withValues(alpha: (0.32 - i * 0.09) * ringsAlpha),
        );
      }
    }

    // 在播的水波：四道同尺寸，从最内圈（0.18 * 最短边）匀速推到 2.6 倍再淡出，
    // 相位各差 1/4 —— 半径随时间线性长，四道的间距就始终相等；参数与 React 的
    // `radio-wave-scale` / `radio-wave-fade` 对齐（16s、linear、12% 到顶、
    // 峰值 0.28）。`ringsFade` 同时充当水波的出现进度：静止环退、水波进。
    final wavePhase = wave?.value;
    if (wavePhase != null) {
      final baseRadius = size.shortestSide * 0.18;
      final peak = 0.28 * (ringsFade?.value ?? 1.0);
      for (var i = 0; i < 4; i++) {
        final t = (wavePhase + i / 4.0) % 1.0;
        final scale = 1 + 1.6 * t;
        final alpha = t < 0.12
            ? peak * (t / 0.12)
            : peak * (1 - (t - 0.12) / 0.88);
        if (alpha <= 0.004) continue;
        canvas.drawCircle(
          ringCenter,
          baseRadius * scale,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = tokens.accent.withValues(alpha: alpha),
        );
      }
    }

    // 底部一根静息波段（五根细柱，高度按 seed 错开 —— 静态，不做循环动画）
    final barWidth = size.width * 0.035;
    final baseY = size.height * 0.86;
    for (var i = 0; i < 5; i++) {
      final phase = station.seed * math.pi + i * 0.9;
      final barHeight =
          size.height * (0.10 + 0.10 * (0.5 + 0.5 * math.sin(phase)));
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            size.width * (0.12 + i * 0.075),
            baseY - barHeight,
            barWidth,
            barHeight,
          ),
          Radius.circular(barWidth / 2),
        ),
        Paint()..color = tokens.accent.withValues(alpha: 0.44),
      );
    }
  }

  /// 画笔自己拿不到 `BuildContext`，token 表由调用方在构造时传进来。
  @override
  bool shouldRepaint(covariant _StationArtPainter oldDelegate) =>
      oldDelegate.station.id != station.id ||
      oldDelegate.station.seed != station.seed ||
      oldDelegate.tokens != tokens ||
      oldDelegate.wave != wave ||
      oldDelegate.ringsFade != ringsFade;
}

/// 在播的三根柱子：从底部各自起伏，相位错开 1/3 圈 —— 看着像真在跳的电平表。
///
/// 只在「正在响」的那一行才挂这个组件（[RadioState.isLive] 已经带 playing 判定），
/// 所以动画只在真的在播时跑。系统开了「减少动效」就停在固定一帧上，不空转。
class _EqualizerBars extends StatefulWidget {
  const _EqualizerBars({required this.color});

  final Color color;

  @override
  State<_EqualizerBars> createState() => _EqualizerBarsState();
}

class _EqualizerBarsState extends State<_EqualizerBars>
    with SingleTickerProviderStateMixin {
  /// 三根柱子的基准高度（等比缩放后就是跳动幅度）。
  static const List<double> _base = <double>[12, 7, 15];

  /// 图标外框的固定高度（与 React `.radio-eq` 的 15px 同档）。
  /// 列表行是居中对齐；外框若跟着最高那根柱子一起长高，整颗图标会被上下
  /// 带着漂。这里把外框钉死，只让柱子从底边往上长 —— 律动留在原地。
  static const double _boxHeight = 15;

  late final AnimationController _beat = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.of(context).disableAnimations) {
      _beat.value = 0.28;
      _beat.stop();
    } else if (!_beat.isAnimating) {
      _beat.repeat();
    }
  }

  @override
  void dispose() {
    _beat.dispose();
    super.dispose();
  }

  /// 余弦起伏压到 0.42~1：柱子不会缩成一条线，也不会顶到框外。
  double _factor(int index) {
    final phase = (_beat.value + index / 3.0) % 1.0;
    return 0.42 + 0.58 * (0.5 - 0.5 * math.cos(2 * math.pi * phase));
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const Key('radio-eq'),
      height: _boxHeight,
      child: AnimatedBuilder(
        animation: _beat,
        builder: (context, _) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < _base.length; i++) ...[
                if (i > 0) const SizedBox(width: 3),
                Container(
                  width: 2,
                  height: _base[i] * _factor(i),
                  decoration: BoxDecoration(
                    color: widget.color.withValues(alpha: i == 1 ? 0.55 : 0.9),
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// 主角播放圆钮：accent 实底 + 深色墨色图标，与音乐页的播放键同款。
class _PlayCircle extends StatelessWidget {
  const _PlayCircle({
    required this.playing,
    required this.loading,
    required this.size,
    required this.onTap,
  });

  final bool playing;
  final bool loading;
  final double size;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Semantics(
      button: true,
      label: playing ? '暂停' : '播放',
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: tokens.accent,
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: size,
            height: size,
            child: Center(
              child: loading
                  ? SizedBox(
                      width: size * 0.42,
                      height: size * 0.42,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.6,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          tokens.accentInk,
                        ),
                      ),
                    )
                  : CustomPaint(
                      size: Size.square(size * 0.46),
                      painter: _PlayGlyphPainter(
                        playing: playing,
                        color: tokens.accentInk,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PlayGlyphPainter extends CustomPainter {
  const _PlayGlyphPainter({required this.playing, required this.color});

  final bool playing;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..isAntiAlias = true;
    if (playing) {
      final barWidth = size.width * 0.16;
      final barHeight = size.height * 0.62;
      final top = (size.height - barHeight) / 2;
      for (final left in [size.width * 0.30, size.width * 0.54]) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(left, top, barWidth, barHeight),
            Radius.circular(barWidth / 2),
          ),
          paint,
        );
      }
      return;
    }
    final path = Path()
      ..moveTo(size.width * 0.36, size.height * 0.20)
      ..lineTo(size.width * 0.36, size.height * 0.80)
      ..lineTo(size.width * 0.78, size.height * 0.50)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _PlayGlyphPainter oldDelegate) =>
      oldDelegate.playing != playing || oldDelegate.color != color;
}

/// 广播图标（页头用）：与顶栏那颗 [RadioIcon] 同一套规格，只是尺寸更大。
class _BroadcastPainter extends CustomPainter {
  const _BroadcastPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    final center = Offset(12 * s, 17.2 * s);
    canvas.drawCircle(center, 1.9 * s, Paint()..color = color);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1.6 * s;
    for (final radius in const [4.6, 7.2, 9.8]) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius * s),
        math.pi,
        math.pi,
        false,
        stroke,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BroadcastPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// 音符图标（「音乐」回退钮）。
class _MusicNotePainter extends CustomPainter {
  const _MusicNotePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8 * s
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path()
      ..moveTo(9 * s, 16.6 * s)
      ..lineTo(9 * s, 5.4 * s)
      ..lineTo(18 * s, 3.8 * s)
      ..lineTo(18 * s, 14.2 * s);
    canvas.drawPath(path, stroke);
    canvas.drawCircle(Offset(6.6 * s, 16.8 * s), 2.6 * s, stroke);
    canvas.drawCircle(Offset(15.6 * s, 14.4 * s), 2.6 * s, stroke);
  }

  @override
  bool shouldRepaint(covariant _MusicNotePainter oldDelegate) =>
      oldDelegate.color != color;
}
