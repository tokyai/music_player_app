import 'package:flutter/material.dart';

/// 页面级响应式尺寸。
///
/// 横屏页面应在自身根部通过 [fromConstraints] 创建一次，并把需要的尺寸
/// 传给子组件。这样判断的是导航栏/播放器侧栏扣除后的真实内容宽度，而不是
/// 只看设备方向。
class AppLayout {
  static const double compactLandscapeMaxHeight = 420;
  static const double compactContentMaxWidth = 720;
  static const double wideWindowMinWidth = 1180;
  static const double wideWindowMinHeight = 560;
  static const double wideContentMinWidth = 760;

  final Size windowSize;
  final double contentWidth;

  const AppLayout._({required this.windowSize, required this.contentWidth});

  factory AppLayout.fromContext(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return AppLayout._(windowSize: size, contentWidth: size.width);
  }

  factory AppLayout.fromConstraints(
    BuildContext context,
    BoxConstraints constraints,
  ) {
    final size = MediaQuery.sizeOf(context);
    final width = constraints.maxWidth.isFinite
        ? constraints.maxWidth
        : size.width;
    return AppLayout._(windowSize: size, contentWidth: width);
  }

  bool get isLandscape => windowSize.width > windowSize.height;

  bool get isCompactLandscape =>
      isLandscape &&
      (windowSize.height <= compactLandscapeMaxHeight ||
          contentWidth < compactContentMaxWidth);

  bool get isWideLandscape =>
      isLandscape &&
      windowSize.width >= wideWindowMinWidth &&
      windowSize.height >= wideWindowMinHeight &&
      contentWidth >= wideContentMinWidth;

  double get pagePadding => isWideLandscape ? 32 : (isLandscape ? 20 : 20);
  double get pageTitleSize =>
      isWideLandscape ? 30 : (isCompactLandscape ? 24 : 26);
  double get sectionTitleSize =>
      isWideLandscape ? 22 : (isCompactLandscape ? 18 : 20);
  double get bodySize => isWideLandscape ? 16 : (isCompactLandscape ? 14 : 15);
  double get secondarySize =>
      isWideLandscape ? 14 : (isCompactLandscape ? 13 : 13.5);

  double get songRowHeight =>
      isWideLandscape ? 80 : (isCompactLandscape ? 66 : 72);
  double get songCoverSize =>
      isWideLandscape ? 62 : (isCompactLandscape ? 50 : 56);
  double get songTitleSize =>
      isWideLandscape ? 18 : (isCompactLandscape ? 16 : 17);
  double get songSubtitleSize =>
      isWideLandscape ? 14.5 : (isCompactLandscape ? 13 : 14);

  double get mediaCardWidth =>
      isWideLandscape ? 172 : (isCompactLandscape ? 142 : 154);
  double get mediaCardTitleSize =>
      isWideLandscape ? 16.5 : (isCompactLandscape ? 15 : 16);
  double get mediaCardSubtitleSize =>
      isWideLandscape ? 14 : (isCompactLandscape ? 13 : 13.5);
}
