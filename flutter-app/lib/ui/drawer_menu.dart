// lib/ui/drawer_menu.dart
//
// 一级抽屉菜单：添加音乐 / 清空播放列表 / 换肤 三个入口。
// 「添加音乐」再进一层二级抽屉，选「选择音频文件」或「选择整个文件夹」——
// 系统选择器没法一次同时选文件和目录，两个动作保留、一级只占一行。
// 外观逐条对译 Web 端 `src/components/LibraryMenu.tsx` + `app.css:3488-3560`：
//
//   ┌────────────────────────┐
//   │ ● 更多            (×)  │  ← `.drawer__head`：点题圆点 + 16px 标题 + 正圆关闭钮
//   │ [＋] 添加音乐      ›    │  ← `.menu-row--sub`：进二级选文件 / 文件夹
//   │ [▤] 清空播放列表   (红) │  ← `.menu-row--danger`
//   │ [◐] 换肤           ›    │  ← `.menu-row--sub`
//   └────────────────────────┘
//
// 面板宽度是 `min(288px, 82vw)`（`.drawer__panel--narrow`），比换肤那档窄一档。
// 只画内容与二级抽屉的打开时序；遮罩、滑入动画在 `more_menu.dart` 的宿主里。
// 三个回调都由调用方注入，测试不碰 file_picker。
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/breakpoints.dart';
import '../theme/app_tokens.dart';
import 'drawer_shell.dart';
import 'theme_drawer.dart' show showThemeDrawer;

/// 抽屉里的一个入口动作。
typedef MenuAction = Future<void> Function();

/// 遮罩色：直接取 `--scrim`（[AppTokens.scrim]）—— 与 React
/// `.drawer__scrim { background: var(--scrim) }`（app.css:3190-3199）同源。
///
/// 深色三套 `rgba(4, 8, 12, 0.66)`（粉/蓝是 0.68）、浅色三套
/// `rgba(28, 42, 56, 0.3)`（app.css:82/:190/:294/:336），都是**压暗**背景。
///
/// 不要再用 `tokens.bg.withValues(alpha: .66)` 派生：浅色主题的 `--bg` 是近白色，
/// 派生出来是一层 66% 的「白纱」—— 背景被提亮、正文几乎糊掉，和原版把页面
/// 推远的观感正好相反（弹层一开，整页像被漂白过）。
Color scrimColor(AppTokens tokens) => tokens.scrim;

/// 菜单卡描边（`.menu-row { border: 1px solid var(--border) }`）。
///
/// 深色主题的 `--border` 是 7% 白，落在深底上 1px 线会被抗锯齿摊成一条
/// 半透明的软边 —— 截图上几乎看不出来，和 Web 端 1px 实线一眼就能看出
/// 「这是一张卡」的观感对不上。这里取 `--border` 与 `--border-strong`
/// 的中间档（深色薄荷 ≈ 11.5% 白），线条才立得住，又不到 hover 那么亮。
///
/// 浅色主题本来就是深色描边（12% 深蓝），压在近白底上很清楚，不加浓。
Color menuCardBorder(AppTokens tokens) => tokens.brightness == Brightness.light
    ? tokens.border
    : Color.lerp(tokens.border, tokens.borderStrong, 0.5)!;

/// 右侧一级抽屉。宽度固定 [width]，屏幕更窄时按 `82vw` 收。
class DrawerMenu extends StatelessWidget {
  const DrawerMenu({
    required this.onAddFiles,
    required this.onAddFolder,
    required this.onClear,
    this.showLibraryActions = true,
    super.key,
  });

  final MenuAction onAddFiles;
  final MenuAction onAddFolder;
  final MenuAction onClear;

  /// 是否展示「添加音乐 / 清空播放列表」两条曲库操作。
  /// 电台页传 false：那页只留「换肤」，不掺音乐曲库的动作。
  final bool showLibraryActions;

  /// 一级菜单档位宽度：Web `.drawer__panel--narrow` 是 `min(288px, 82vw)`。
  static const double width = 288;

  @override
  Widget build(BuildContext context) {
    return DrawerPanel(
      baseWidth: width,
      viewportFraction: 0.82,
      title: '更多',
      closeLabel: '关闭菜单',
      // `.menu-list { display: flex; flex-direction: column; gap: 8px }`
      gap: 8,
      onClose: () => Navigator.of(context).maybePop(),
      children: [
        // 曲库操作只在音乐页出现：电台页是另一条音频链路，那页的「更多」
        // 只负责换肤，避免收听中被「清空播放列表」误导。
        if (showLibraryActions) ...[
          MenuRow(
            icon: Icons.add,
            label: '添加音乐',
            sub: true,
            // 「添加音乐」是二级抽屉：里面再选音频文件 / 整个文件夹。
            // 浏览器与移动端的系统选择器都没法一次同时选文件和目录，所以
            // 两个动作保留，但一级菜单只占一行。
            onTap: () => _closeAnd(context, () => _openAdd(context)),
          ),
          MenuRow(
            icon: Icons.delete_outline,
            label: '清空播放列表',
            danger: true,
            onTap: () => _confirmClear(context),
          ),
        ],
        MenuRow(
          icon: Icons.palette_outlined,
          label: '换肤',
          sub: true,
          // 换肤是二级抽屉：先收一级再弹二级（与 LibraryMenu 的二级入口同序）——
          // 两层叠着会让 Esc/遮罩语义变糊。
          onTap: () => _closeAnd(context, () => _openTheme(context)),
        ),
      ],
    );
  }

  /// 先收抽屉再执行：选择器弹在抽屉之上、回来时抽屉已经不在，避免叠两层。
  Future<void> _closeAnd(BuildContext context, MenuAction action) {
    _close(context);
    return action();
  }

  /// 打开二级抽屉：先等一级抽屉**真的收完**再弹，两级遮罩叠着会互相吞
  /// Esc / 遮罩点击。
  ///
  /// 这里不能用固定延时去猜。抽屉收起动画 240ms，`pop` 一结束它的 Element 就
  /// 被拆掉；以前写的是「等 260ms 再用一级抽屉的 context 弹」，只要路由先拆完
  /// （真机稳定帧率下就是这样），计时器回来时 `context.mounted == false`，直接
  /// return —— 用户看到的就是「抽屉收起来了，二级抽屉没出来」。
  ///
  /// 现在改成两件确定性的事：
  /// 1. 等 `ModalRoute.completed`，也就是这条抽屉路由自己播完收起动画；
  /// 2. 用 `NavigatorState` 的 context 去弹（路由层，抽屉收起后依然在树上，
  ///    且仍在 MultiProvider / Theme 之下，`context.tokens` 与
  ///    `context.watch<ThemeState>()` 都照常可用）。
  Future<void> _openSubDrawer(
    BuildContext context,
    void Function(BuildContext host) show,
  ) async {
    final navigator = Navigator.of(context);
    final route = ModalRoute.of(context);
    if (route != null) {
      await route.completed;
    }
    final host = navigator.context;
    if (!host.mounted) return;
    show(host);
  }

  Future<void> _openTheme(BuildContext context) =>
      _openSubDrawer(context, showThemeDrawer);

  Future<void> _openAdd(BuildContext context) => _openSubDrawer(
        context,
        (host) => showAddDrawer(
          host,
          onAddFiles: onAddFiles,
          onAddFolder: onAddFolder,
        ),
      );

  void _close(BuildContext context) {
    Navigator.of(context).maybePop();
  }

  /// 清空是破坏性操作：先问一句，确认了才交给状态层。
  Future<void> _confirmClear(BuildContext context) async {
    final tokens = context.tokens;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: scrimColor(tokens),
      builder: (dialogContext) => AlertDialog(
        backgroundColor: tokens.sheetA,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRadiusLg),
          side: BorderSide(color: tokens.borderStrong),
        ),
        title: Text(
          '确定清空播放列表吗？',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: tokens.text,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            style: TextButton.styleFrom(
              foregroundColor: tokens.textDim,
              minimumSize: const Size(0, 36),
            ),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: tokens.danger,
              foregroundColor: tokens.dangerInk,
              minimumSize: const Size(0, 36),
            ),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    _close(context);
    await onClear();
  }
}

/// 「添加音乐」二级抽屉：只保留一个一级入口，进去再选文件或文件夹。
///
/// 为什么不直接合并成一次点击：系统选择器没有能同时选择文件和目录的对话框，
/// 文件多选与目录选择是两个互斥的入口；拆成二级既能只占一行菜单，也不会把
/// 任一导入方式藏掉。宽度、行高、图标托与一级抽屉完全相同，保持像素级一致。
class AddDrawer extends StatelessWidget {
  const AddDrawer({
    required this.onAddFiles,
    required this.onAddFolder,
    super.key,
  });

  final MenuAction onAddFiles;
  final MenuAction onAddFolder;

  /// 与一级抽屉同宽：Web 两个抽屉都走 `.drawer__panel--narrow`。
  static const double width = DrawerMenu.width;

  @override
  Widget build(BuildContext context) {
    return DrawerPanel(
      baseWidth: width,
      viewportFraction: 0.82,
      title: '添加音乐',
      hint: '选择音频文件，或导入整个文件夹',
      closeLabel: '关闭添加音乐',
      gap: 8,
      onClose: () => Navigator.of(context).maybePop(),
      children: [
        MenuRow(
          icon: Icons.add,
          label: '选择音频文件',
          onTap: () => _closeAnd(context, onAddFiles),
        ),
        MenuRow(
          icon: Icons.folder_open,
          label: '选择整个文件夹',
          onTap: () => _closeAnd(context, onAddFolder),
        ),
      ],
    );
  }

  /// 先收抽屉再执行：选择器弹在抽屉之上、回来时抽屉已经不在，避免叠两层。
  Future<void> _closeAnd(BuildContext context, MenuAction action) {
    Navigator.of(context).maybePop();
    return action();
  }
}

/// 打开「添加音乐」二级抽屉。时序与 [DrawerMenu] 的换肤入口同一套：
/// 一级抽屉收起完成后再弹，避免两层遮罩互相吞 Esc / 点击。
void showAddDrawer(
  BuildContext context, {
  required MenuAction onAddFiles,
  required MenuAction onAddFolder,
}) {
  final tokens = context.tokens;
  showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭添加音乐',
    barrierColor: scrimColor(tokens),
    transitionDuration: const Duration(milliseconds: 240),
    pageBuilder: (context, animation, secondaryAnimation) => SafeArea(
      minimum: const EdgeInsets.all(kDrawerMargin),
      child: Align(
        alignment: Alignment.topRight,
        child: AddDrawer(
          onAddFiles: onAddFiles,
          onAddFolder: onAddFolder,
        ),
      ),
    ),
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      );
    },
  );
}

/// 菜单行（`.menu-row`）：54px 小卡，34px 图标托 + 14px 文案。一级和二级抽屉共用。
///
/// 三档变体与 CSS 一一对应：
///   · 默认：`--tint-1` 底 + 1px 描边（[menuCardBorder]），图标托 `--accent-soft`
///     / 图标 `--accent-light`；
///   · [danger]：整行字色 `--danger`，图标托换 `--danger-soft`（清空播放列表）；
///   · [sub]：右侧补一个 6px 小箭头（`.menu-row--sub::after`），提示还能再点进去。
class MenuRow extends StatelessWidget {
  const MenuRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
    this.sub = false,
    super.key,
  });

  final IconData icon;
  final String label;
  final MenuAction onTap;
  final bool danger;

  /// 二级入口：行尾画一颗指向右侧的小箭头。
  final bool sub;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final color = danger ? tokens.danger : tokens.text;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        overlayColor: WidgetStatePropertyAll<Color>(
          danger ? tokens.dangerSoft : tokens.accentSoft,
        ),
        child: Container(
          constraints: const BoxConstraints(minHeight: 54),
          // `.menu-row { padding: 9px 12px }`；二级入口额外 `padding-right: 34px`
          //（15 右边距 + 6 箭头 + 13 间隙），箭头位置才和 Web 一致。
          padding: EdgeInsets.fromLTRB(12, 9, sub ? 15 : 12, 9),
          decoration: BoxDecoration(
            color: tokens.tint1,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: menuCardBorder(tokens)),
          ),
          child: Row(
            children: [
              // `.menu-row__icon`：34×34、11 圆角、`--accent-soft` 托、17px 图标
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(11),
                  color: danger ? tokens.dangerSoft : tokens.accentSoft,
                ),
                child: Icon(
                  icon,
                  size: 17,
                  color: danger ? tokens.danger : tokens.accentLight,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    // CSS `font-weight: 550`：Flutter 的字重只有整百档，取 600。
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
              ),
              if (sub) ...[const SizedBox(width: 13), const _SubChevron()],
            ],
          ),
        ),
      ),
    );
  }
}

/// `.menu-row--sub::after`：6×6 的「上 + 右」两条边，转 45° 成一颗右向箭头。
class _SubChevron extends StatelessWidget {
  const _SubChevron();

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Transform.rotate(
      angle: math.pi / 4,
      child: Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: tokens.textFaint, width: 1.6),
            right: BorderSide(color: tokens.textFaint, width: 1.6),
          ),
        ),
      ),
    );
  }
}
