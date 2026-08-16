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
  final double devicePixelRatio;

  const AppLayout._({
    required this.windowSize,
    required this.contentWidth,
    required this.devicePixelRatio,
  });

  factory AppLayout.fromContext(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return AppLayout._(
      windowSize: size,
      contentWidth: size.width,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
    );
  }

  factory AppLayout.fromConstraints(
    BuildContext context,
    BoxConstraints constraints,
  ) {
    final size = MediaQuery.sizeOf(context);
    final width = constraints.maxWidth.isFinite
        ? constraints.maxWidth
        : size.width;
    return AppLayout._(
      windowSize: size,
      contentWidth: width,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
    );
  }

  /// 在应用根部合并系统字号、大屏阅读补偿和用户设置的字号比例。
  static MediaQueryData adaptiveMediaQueryOf(
    BuildContext context, {
    double fontScale = 1,
  }) {
    final mediaQuery = MediaQuery.of(context);
    final layout = AppLayout.fromContext(context);
    final systemTextScale = mediaQuery.textScaler.scale(16) / 16;
    final userTextScale = fontScale.isFinite ? fontScale : 1.0;
    return mediaQuery.copyWith(
      textScaler: TextScaler.linear(
        systemTextScale * layout.interfaceTextScale * userTextScale,
      ),
    );
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

  Size get physicalWindowSize => Size(
    windowSize.width * devicePixelRatio,
    windowSize.height * devicePixelRatio,
  );

  /// 车机经常把 1920×1080 以 2× 密度上报为 960×540 逻辑尺寸。
  /// 仅看逻辑宽度会误用普通横屏字号，因此同时校验逻辑可用空间和物理分辨率。
  bool get isHighDensityCarDisplay =>
      isLandscape &&
      devicePixelRatio >= 1.25 &&
      windowSize.width >= 900 &&
      windowSize.height >= 500 &&
      physicalWindowSize.width >= 1600 &&
      physicalWindowSize.height >= 900;

  bool get usesLargeTypography => isWideLandscape || isHighDensityCarDisplay;

  /// 对未使用页面尺寸令牌的文字做温和补偿；窄横屏不放大，避免挤压操作入口。
  double get interfaceTextScale {
    if (usesLargeTypography) return 1.18;
    if (isLandscape && !isCompactLandscape) return 1.12;
    if (!isLandscape) return 1.1;
    return 1;
  }

  double get pagePadding =>
      usesLargeTypography ? 36 : (isCompactLandscape ? 12 : 24);
  double get pageTitleSize =>
      usesLargeTypography ? 36 : (isCompactLandscape ? 27 : 31);
  double get sectionTitleSize =>
      usesLargeTypography ? 28 : (isCompactLandscape ? 21 : 25);
  double get bodySize =>
      usesLargeTypography ? 21 : (isCompactLandscape ? 16 : 19);
  double get secondarySize =>
      usesLargeTypography ? 18 : (isCompactLandscape ? 14 : 16.5);

  double get songRowHeight =>
      usesLargeTypography ? 100 : (isCompactLandscape ? 70 : 86);
  double get songCoverSize =>
      usesLargeTypography ? 78 : (isCompactLandscape ? 54 : 66);
  double get songTitleSize =>
      usesLargeTypography ? 23 : (isCompactLandscape ? 18 : 21);
  double get songSubtitleSize =>
      usesLargeTypography ? 18 : (isCompactLandscape ? 14 : 17);

  double get mediaCardWidth =>
      usesLargeTypography ? 210 : (isCompactLandscape ? 150 : 180);
  double get mediaCardTitleSize =>
      usesLargeTypography ? 21 : (isCompactLandscape ? 16 : 19);
  double get mediaCardSubtitleSize =>
      usesLargeTypography ? 18 : (isCompactLandscape ? 14 : 16);
}
