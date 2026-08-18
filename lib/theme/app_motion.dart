import 'package:flutter/material.dart';

/// 全局轻量动效规范。
///
/// 只使用 Flutter 内置的透明度、位移和缩放动画；动画结束后不会保留活跃
/// ticker。系统要求减少动态效果时，所有非必要动画自动缩短为零。
abstract final class AppMotion {
  static const quick = Duration(milliseconds: 140);
  static const state = Duration(milliseconds: 180);
  static const page = Duration(milliseconds: 220);
  static const background = Duration(milliseconds: 300);

  static const Curve enterCurve = Curves.easeOutCubic;
  static const Curve exitCurve = Curves.easeInCubic;

  static Duration resolve(BuildContext context, Duration duration) {
    final mediaQuery = MediaQuery.maybeOf(context);
    return mediaQuery?.disableAnimations == true ? Duration.zero : duration;
  }
}

/// 状态内容间的淡入和极短位移，适合加载/空态/内容、选择模式等低频切换。
class AppMotionSwitcher extends StatelessWidget {
  final Widget child;
  final Duration duration;
  final Offset beginOffset;
  final AlignmentGeometry alignment;

  const AppMotionSwitcher({
    super.key,
    required this.child,
    this.duration = AppMotion.state,
    this.beginOffset = const Offset(0, 0.018),
    this.alignment = Alignment.center,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: AppMotion.resolve(context, duration),
      reverseDuration: AppMotion.resolve(context, AppMotion.quick),
      switchInCurve: AppMotion.enterCurve,
      switchOutCurve: AppMotion.exitCurve,
      // Large loading/content switches used to retain and paint both the old
      // and new list during the cross-fade.  Keeping only the incoming child
      // halves the peak paint/layout work on low-end head units.
      layoutBuilder: (currentChild, _) => currentChild == null
          ? const SizedBox.shrink()
          : Stack(alignment: alignment, children: [currentChild]),
      transitionBuilder: (child, animation) {
        // Default state changes use only a compositor translation. A fade is
        // reserved for centered overlays that explicitly request no movement;
        // this avoids full-list opacity layers at high resolutions.
        if (beginOffset == Offset.zero) {
          return FadeTransition(opacity: animation, child: child);
        }
        return SlideTransition(
          position: Tween<Offset>(
            begin: beginOffset,
            end: Offset.zero,
          ).animate(animation),
          child: child,
        );
      },
      child: child,
    );
  }
}

/// 播放、收藏和模式图标的短时交叉缩放。静止时没有动画开销。
class AppAnimatedIcon extends StatelessWidget {
  final Object stateKey;
  final Widget child;
  final Duration duration;

  const AppAnimatedIcon({
    super.key,
    required this.stateKey,
    required this.child,
    this.duration = AppMotion.quick,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: AppMotion.resolve(context, duration),
      switchInCurve: AppMotion.enterCurve,
      switchOutCurve: AppMotion.exitCurve,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.9, end: 1).animate(animation),
          child: child,
        ),
      ),
      child: KeyedSubtree(key: ValueKey(stateKey), child: child),
    );
  }
}
