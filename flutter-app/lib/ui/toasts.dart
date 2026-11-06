// lib/ui/toasts.dart
//
// 提示条宿主：对译 `.toast-host` + `.toast`（src/styles/app.css:3794）。
// 顶部居中、压在安全区下面 12px、宽 min(420, 屏宽 - 24)；
// 一条一个卡片，点一下关掉。颜色只取 token 表，不引入表外的颜色。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/toast_state.dart';
import '../theme/app_tokens.dart';

/// 挂在页面最上层（`Stack` / `Overlay` 均可）。
///
/// 只负责「把 [ToastState.items] 画出来 + 点击关闭」；去重、排队、计时都在
/// [ToastState] 里。宿主用 `context.watch` 订阅，提示变化时自动重建。
class ToastsHost extends StatelessWidget {
  const ToastsHost({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ToastState>();
    final width = MediaQuery.sizeOf(context).width;
    return Semantics(
      liveRegion: true,
      label: '提示',
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          // `.toast-host { top: calc(12px + env(safe-area-inset-top)) }`
          padding: EdgeInsets.only(
            top: 12 + MediaQuery.viewPaddingOf(context).top,
          ),
          child: SizedBox(
            width: math.min(420, width - 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final item in state.items)
                  _ToastCard(
                    key: ValueKey<int>(item.id),
                    item: item,
                    onTap: () => state.dismiss(item.id),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 一条提示。error 用错误底色，其余用普通底色；点整张卡片关闭。
class _ToastCard extends StatelessWidget {
  const _ToastCard({super.key, required this.item, required this.onTap});

  final ToastItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final radius = BorderRadius.circular(12);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: item.kind == ToastKind.error
            ? tokens.toastErrorBg
            : tokens.toastBg,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 11, 10, 11),
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(color: tokens.borderStrong),
            ),
            child: Text(
              item.message,
              style: TextStyle(
                fontSize: 12.8,
                height: 1.45,
                color: tokens.text,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
