import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../providers/search_session.dart';
import '../services/favorite_service.dart';
import '../theme/app_layout.dart';
import '../theme/app_theme.dart';
import '../utils/color_extractor.dart';
import '../utils/system_ui.dart';
import '../widgets/smart_cover.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  static const _lyricFontSizePreferenceKey = 'lyric_font_size';
  static const _landscapeSplitRatioPreferenceKey =
      'player_landscape_split_ratio';
  static const _lyricFontSizes = <double>[32, 36, 42, 48, 54, 60];
  static const _defaultLandscapeLeftRatio = 0.42;
  static const _minimumLandscapeLeftRatio = 0.32;
  static const _maximumLandscapeLeftRatio = 0.62;

  Color? _dominantColor;
  bool _lyricsAutoScroll = true;
  bool _lyricFontSizeChangedByUser = false;
  double _lyricFontSize = 42;
  double _lyricLineExtent = 92;
  double _landscapeLeftRatio = _defaultLandscapeLeftRatio;
  bool _landscapeSplitChangedByUser = false;
  final ScrollController _lyricScrollController = ScrollController();
  String? _lastColorSongId;

  @override
  void initState() {
    super.initState();
    unawaited(_loadLyricFontSize());
    unawaited(_loadLandscapeSplitRatio());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateColor(context.read<PlayerProvider>().currentSong);
    });
  }

  Future<void> _loadLyricFontSize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final rawValue = prefs.get(_lyricFontSizePreferenceKey);
      final rawSize = rawValue is num ? rawValue.toDouble() : null;
      // 旧版本的 24/28 档在大屏上过小，平滑迁移到新的最小档 32。
      final savedSize = rawSize != null && rawSize < 32 ? 32.0 : rawSize;
      if (!mounted ||
          _lyricFontSizeChangedByUser ||
          savedSize == null ||
          !_lyricFontSizes.contains(savedSize)) {
        return;
      }
      setState(() {
        _lyricFontSize = savedSize;
        _lyricLineExtent = savedSize + 46;
      });
    } catch (_) {}
  }

  void _selectLyricFontSize(double size) {
    if (!_lyricFontSizes.contains(size)) return;
    _lyricFontSizeChangedByUser = true;
    if (_lyricFontSize != size) {
      setState(() => _lyricFontSize = size);
    }
    unawaited(_saveLyricFontSize(size));
  }

  Future<void> _saveLyricFontSize(double size) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_lyricFontSizePreferenceKey, size);
    } catch (_) {}
  }

  Future<void> _loadLandscapeSplitRatio() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getDouble(_landscapeSplitRatioPreferenceKey);
      if (!mounted ||
          _landscapeSplitChangedByUser ||
          saved == null ||
          !saved.isFinite) {
        return;
      }
      setState(() {
        _landscapeLeftRatio = saved.clamp(
          _minimumLandscapeLeftRatio,
          _maximumLandscapeLeftRatio,
        );
      });
    } catch (_) {}
  }

  Future<void> _saveLandscapeSplitRatio() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(
        _landscapeSplitRatioPreferenceKey,
        _landscapeLeftRatio,
      );
    } catch (_) {}
  }

  @override
  void dispose() {
    // 离开播放页后恢复全局状态栏样式（跟随主题）
    applySystemUi(dark: AppColors.isDark);
    _lyricScrollController.dispose();
    super.dispose();
  }

  // 仅在歌曲切换时提取一次封面主色（防抖），避免每次重建都跑图像处理
  void _updateColor(PlayQueueItem? song) {
    if (song == null) return;
    final id = '${song.platform}_${song.id}';
    if (id == _lastColorSongId) return;
    _lastColorSongId = id;
    final cover = song.coverUrl;
    if (cover == null || cover.isEmpty) {
      if (_dominantColor != null) setState(() => _dominantColor = null);
      return;
    }
    // SmartCover 会优先使用中转地址；主色提取复用相同的缓存键，避免进入
    // 播放页后又从原始封面地址下载一次图片。
    final cachedCover = CoverProxy.toProxy(cover) ?? cover;
    extractDominantColor(cachedCover).then((color) {
      if (mounted && color != null && id == _lastColorSongId) {
        setState(() => _dominantColor = color);
      }
    });
  }

  void _scrollToLyric(int index) {
    if (!_lyricsAutoScroll) return;
    if (!_lyricScrollController.hasClients) return;
    final position = _lyricScrollController.position;
    // 第 index 行顶部在内容坐标 = topPadding + index*行高；
    // 让它滚到与首行初始位置（topPadding 处）重合，offset = index*行高。
    // 用 jumpTo 瞬时定位，避免 animateTo 300ms 动画在快歌下“追不上”当前行。
    final target = (index * _lyricLineExtent).clamp(
      0.0,
      position.maxScrollExtent,
    );
    position.jumpTo(target);
  }

  void _openScopedSearch(
    BuildContext context,
    PlayerProvider player,
    PlayQueueItem song,
    SearchSubject subject,
  ) {
    final keyword = (subject == SearchSubject.artist ? song.artist : song.album)
        .trim();
    if (!_isSearchableMetadata(keyword)) return;
    unawaited(
      context.read<SearchSession>().openScopedSearch(
        player.api,
        keyword: keyword,
        subject: subject,
        preferredPlatform: song.platform,
      ),
    );
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  bool _isSearchableMetadata(String value) {
    final normalized = value.trim();
    return normalized.isNotEmpty &&
        normalized != '未知歌手' &&
        normalized != '未知专辑';
  }

  Widget _buildSongNameLink(
    BuildContext context,
    PlayerProvider player,
    PlayQueueItem song,
    Color color, {
    required double fontSize,
    TextAlign textAlign = TextAlign.start,
  }) {
    final layout = AppLayout.fromContext(context);
    final minHitHeight = layout.isLandscape
        ? (layout.usesLargeTypography
              ? 52.0
              : (layout.isCompactLandscape ? 30.0 : 44.0))
        : 44.0;
    final text = Text(
      song.name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: textAlign,
      style: TextStyle(
        color: color,
        fontSize: fontSize,
        fontWeight: FontWeight.bold,
      ),
    );
    if (!_isSearchableMetadata(song.artist)) return text;
    return Tooltip(
      message: '搜索 ${song.artist} 的歌曲',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: const ValueKey('player-artist-search'),
          onTap: () =>
              _openScopedSearch(context, player, song, SearchSubject.artist),
          borderRadius: BorderRadius.circular(AppRadius.small),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: minHitHeight),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              child: Align(
                alignment: textAlign == TextAlign.center
                    ? Alignment.center
                    : Alignment.centerLeft,
                child: text,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildArtistAlbumLine(
    BuildContext context,
    PlayerProvider player,
    PlayQueueItem song,
    Color color, {
    required double fontSize,
    bool centered = false,
  }) {
    final layout = AppLayout.fromContext(context);
    final minHitHeight = layout.isLandscape
        ? (layout.usesLargeTypography
              ? 48.0
              : (layout.isCompactLandscape ? 28.0 : 42.0))
        : 42.0;
    final hasAlbum = _isSearchableMetadata(song.album);
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: centered
          ? MainAxisAlignment.center
          : MainAxisAlignment.start,
      children: [
        Flexible(
          child: Text(
            song.artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: color, fontSize: fontSize),
          ),
        ),
        if (hasAlbum) ...[
          Text(
            ' · ',
            style: TextStyle(color: color, fontSize: fontSize),
          ),
          Flexible(
            child: Tooltip(
              message: '搜索专辑 ${song.album}',
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  key: const ValueKey('player-album-search'),
                  onTap: () => _openScopedSearch(
                    context,
                    player,
                    song,
                    SearchSubject.album,
                  ),
                  borderRadius: BorderRadius.circular(AppRadius.small),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: minHitHeight),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Align(
                        alignment: Alignment.center,
                        child: Text(
                          song.album,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: color,
                            fontSize: fontSize,
                            decoration: TextDecoration.underline,
                            decorationColor: color.withValues(alpha: 0.55),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    AppColors.syncWithTheme(context);
    // 外层只监听 currentSong：切歌/空态才整体重建；
    // position 每 200ms 的更新不会触发这里，避免整页卡顿。
    return Selector<PlayerProvider, PlayQueueItem?>(
      selector: (_, p) => p.currentSong,
      builder: (ctx, song, _) {
        if (song == null) {
          return _buildEmptyPlayer(ctx);
        }

        final player = context.read<PlayerProvider>();

        // 歌曲切换时更新背景主色（内部已防抖，只处理一次）
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _updateColor(song);
        });

        final baseColor = _dominantColor ?? AppColors.primary;
        final darkTheme = Theme.of(ctx).brightness == Brightness.dark;
        // 背景明暗由当前主题决定，不再直接跟随封面主色。这样浅色封面在
        // 深色模式下也会先压暗，避免出现浅背景配白字的低对比度组合。
        applySystemUi(dark: darkTheme);
        final textColor = darkTheme ? Colors.white : const Color(0xFF171A1F);
        final subTextColor = darkTheme
            ? Colors.white.withValues(alpha: 0.74)
            : const Color(0xFF414750);
        final isLandscape =
            MediaQuery.orientationOf(ctx) == Orientation.landscape;

        return Scaffold(
          body: Stack(
            fit: StackFit.expand,
            children: [
              _buildPlayerBackground(song, baseColor, darkTheme),
              SafeArea(
                child: isLandscape
                    ? _buildLandscapePlayer(
                        ctx,
                        player,
                        song,
                        baseColor,
                        textColor,
                        subTextColor,
                      )
                    : Column(
                        children: [
                          _buildTopBar(ctx, player, textColor, subTextColor),
                          Expanded(
                            child: _buildPlayerVisual(
                              ctx,
                              player,
                              song,
                              baseColor,
                              textColor,
                            ),
                          ),
                          _buildSongInfo(
                            ctx,
                            player,
                            song,
                            textColor,
                            subTextColor,
                          ),
                          _buildProgressBar(
                            ctx,
                            player,
                            textColor,
                            subTextColor,
                          ),
                          _buildControls(ctx, player, textColor),
                          _buildBottomActions(ctx, player, subTextColor),
                        ],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPlayerBackground(
    PlayQueueItem song,
    Color baseColor,
    bool darkTheme,
  ) {
    final cover = song.coverUrl;
    final scrim = darkTheme
        ? Colors.black.withValues(alpha: 0.7)
        : Colors.white.withValues(alpha: 0.82);
    final lowerScrim = darkTheme
        ? const Color(0xF2131519)
        : const Color(0xFAF7F8FA);
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: baseColor.withValues(alpha: 0.34)),
        if (cover != null && cover.isNotEmpty)
          Positioned.fill(
            child: ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: 34, sigmaY: 34),
              child: Transform.scale(
                scale: 1.12,
                child: SmartCover(
                  url: cover,
                  fit: BoxFit.cover,
                  placeholder: () =>
                      ColoredBox(color: baseColor.withValues(alpha: 0.28)),
                ),
              ),
            ),
          ),
        Positioned.fill(
          child: DecoratedBox(
            key: const ValueKey('player-background-scrim'),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [scrim, scrim.withValues(alpha: 0.82), lowerScrim],
                stops: const [0, 0.56, 1],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyPlayer(BuildContext ctx) {
    final isLandscape = MediaQuery.orientationOf(ctx) == Orientation.landscape;
    final illustration = Container(
      width: 96,
      height: 96,
      decoration: BoxDecoration(
        color: AppColors.primarySoft,
        shape: BoxShape.circle,
      ),
      child: Icon(Icons.music_note, size: 44, color: AppColors.primary),
    );
    final message = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '还没有播放任何歌曲',
          style: TextStyle(color: AppColors.textSecondary, fontSize: 16),
        ),
        const SizedBox(height: 8),
        Text(
          '去搜索你喜欢的音乐吧',
          style: TextStyle(color: AppColors.textHint, fontSize: 14),
        ),
      ],
    );
    return Scaffold(
      body: Center(
        child: isLandscape
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [illustration, const SizedBox(width: 24), message],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [illustration, const SizedBox(height: 16), message],
              ),
      ),
    );
  }

  Widget _buildLandscapePlayer(
    BuildContext ctx,
    PlayerProvider player,
    PlayQueueItem song,
    Color baseColor,
    Color textColor,
    Color subTextColor,
  ) {
    final layout = AppLayout.fromContext(ctx);
    final largeUi = layout.usesLargeTypography;
    return Column(
      children: [
        _buildTopBar(ctx, player, textColor, subTextColor, showQueue: false),
        Expanded(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              largeUi ? 28 : 8,
              0,
              largeUi ? 28 : 8,
              largeUi ? 18 : 4,
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final compact = layout.isCompactLandscape;
                final dividerWidth = largeUi ? 30.0 : (compact ? 20.0 : 24.0);
                final panesWidth = (constraints.maxWidth - dividerWidth).clamp(
                  1.0,
                  double.infinity,
                );
                final minimumLeftWidth = largeUi
                    ? 360.0
                    : (compact ? 220.0 : 300.0);
                final minimumRightWidth = largeUi
                    ? 390.0
                    : (compact ? 250.0 : 320.0);
                final minimumRatio = (minimumLeftWidth / panesWidth).clamp(
                  _minimumLandscapeLeftRatio,
                  _maximumLandscapeLeftRatio,
                );
                final maximumRatio =
                    ((panesWidth - minimumRightWidth) / panesWidth).clamp(
                      _minimumLandscapeLeftRatio,
                      _maximumLandscapeLeftRatio,
                    );
                final lower = minimumRatio <= maximumRatio ? minimumRatio : 0.5;
                final upper = minimumRatio <= maximumRatio ? maximumRatio : 0.5;
                final effectiveRatio = _landscapeLeftRatio.clamp(lower, upper);
                final leftWidth = panesWidth * effectiveRatio;

                void updateRatio(double delta) {
                  final next = (effectiveRatio + delta / panesWidth).clamp(
                    lower,
                    upper,
                  );
                  _landscapeSplitChangedByUser = true;
                  if (next != _landscapeLeftRatio) {
                    setState(() => _landscapeLeftRatio = next);
                  }
                }

                return Row(
                  children: [
                    SizedBox(
                      width: leftWidth,
                      child: KeyedSubtree(
                        key: const ValueKey('landscape-player-controls'),
                        child: _buildLandscapeControlPane(
                          ctx,
                          player,
                          song,
                          baseColor,
                          textColor,
                          subTextColor,
                        ),
                      ),
                    ),
                    _buildLandscapeDivider(
                      width: dividerWidth,
                      color: subTextColor,
                      ratio: effectiveRatio,
                      onDragUpdate: updateRatio,
                      onDragEnd: () {
                        unawaited(_saveLandscapeSplitRatio());
                      },
                    ),
                    Expanded(
                      child: KeyedSubtree(
                        key: const ValueKey('landscape-player-lyrics'),
                        child: _buildLandscapeLyrics(ctx, player, textColor),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLandscapeDivider({
    required double width,
    required Color color,
    required double ratio,
    required ValueChanged<double> onDragUpdate,
    required VoidCallback onDragEnd,
  }) {
    return Semantics(
      label: '播放页左右分栏比例',
      value: '左侧 ${(ratio * 100).round()}%',
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeColumn,
        child: GestureDetector(
          key: const ValueKey('landscape-player-divider'),
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (details) => onDragUpdate(details.delta.dx),
          onHorizontalDragEnd: (_) => onDragEnd(),
          onHorizontalDragCancel: onDragEnd,
          child: SizedBox(
            width: width,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 1,
                  margin: const EdgeInsets.symmetric(vertical: 8),
                  color: color.withValues(alpha: 0.16),
                ),
                Container(
                  width: 5,
                  height: 58,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.32),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLandscapeControlPane(
    BuildContext ctx,
    PlayerProvider player,
    PlayQueueItem song,
    Color baseColor,
    Color textColor,
    Color subTextColor,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = AppLayout.fromContext(context);
        final largeUi = layout.usesLargeTypography;
        final compactHeight = constraints.maxHeight < 420 && !largeUi;
        final widthLimit = constraints.maxWidth - (compactHeight ? 28 : 40);
        final largeHeightFactor = layout.isHighDensityCarDisplay ? 0.34 : 0.44;
        final heightLimit =
            constraints.maxHeight *
            (largeUi ? largeHeightFactor : (compactHeight ? 0.24 : 0.54));
        final rawCoverSize = widthLimit < heightLimit
            ? widthLimit
            : heightLimit;
        final coverSize = rawCoverSize.clamp(
          compactHeight ? 72.0 : 160.0,
          largeUi ? 400.0 : 320.0,
        );
        final verticalPadding = largeUi ? 6.0 : (compactHeight ? 4.0 : 10.0);

        return SingleChildScrollView(
          padding: EdgeInsets.symmetric(vertical: verticalPadding),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: constraints.maxHeight - verticalPadding * 2,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildLandscapeCoverArt(song, baseColor, coverSize),
                SizedBox(height: largeUi ? 8 : (compactHeight ? 5 : 14)),
                _buildLandscapeSongInfo(
                  ctx,
                  player,
                  song,
                  textColor,
                  subTextColor,
                ),
                _buildProgressBar(
                  ctx,
                  player,
                  textColor,
                  subTextColor,
                  compact: true,
                ),
                _buildControls(
                  ctx,
                  player,
                  textColor,
                  compact: true,
                  landscape: true,
                ),
                _buildBottomActions(
                  ctx,
                  player,
                  subTextColor,
                  compact: true,
                  showLyricFontControl: largeUi,
                  landscape: true,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildLandscapeCoverArt(
    PlayQueueItem song,
    Color baseColor,
    double size,
  ) {
    return Container(
      key: const ValueKey('landscape-player-cover'),
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: baseColor.withOpacity(0.3),
            blurRadius: 22,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: song.coverUrl != null && song.coverUrl!.isNotEmpty
            ? SmartCover(
                url: song.coverUrl,
                fit: BoxFit.cover,
                placeholder: () => _buildDefaultCover(song, compact: true),
              )
            : _buildDefaultCover(song, compact: true),
      ),
    );
  }

  Widget _buildLandscapeSongInfo(
    BuildContext ctx,
    PlayerProvider player,
    PlayQueueItem song,
    Color textColor,
    Color subColor,
  ) {
    final layout = AppLayout.fromContext(ctx);
    final largeUi = layout.usesLargeTypography;
    return Selector<PlayerProvider, (bool, String?)>(
      selector: (_, p) => (p.isLoading, p.errorMessage),
      builder: (ctx, selection, _) {
        return Padding(
          padding: EdgeInsets.fromLTRB(
            largeUi ? 14 : 16,
            largeUi ? 2 : 2,
            8,
            0,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildSongNameLink(
                      ctx,
                      player,
                      song,
                      textColor,
                      fontSize: largeUi
                          ? 27
                          : (layout.isCompactLandscape ? 18 : 20),
                    ),
                    const SizedBox(height: 3),
                    _buildArtistAlbumLine(
                      ctx,
                      player,
                      song,
                      subColor,
                      fontSize: largeUi
                          ? 17
                          : (layout.isCompactLandscape ? 13 : 14),
                    ),
                    if (selection.$2 != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        selection.$2!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.redAccent,
                          fontSize: largeUi
                              ? 14
                              : (layout.isCompactLandscape ? 11 : 12),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (selection.$1)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: SizedBox(
                    width: largeUi ? 22 : 18,
                    height: largeUi ? 22 : 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.primary,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildLandscapeLyrics(
    BuildContext ctx,
    PlayerProvider player,
    Color textColor,
  ) {
    return Selector<PlayerProvider, (int, int, bool)>(
      selector: (_, p) =>
          (p.lyrics.length, p.currentLyricIndex, p.lyricsLoading),
      builder: (ctx, selection, _) {
        if (selection.$1 > 0) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _scrollToLyric(selection.$2);
          });
        }
        if (selection.$1 == 0 && selection.$3) {
          return Center(
            child: SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: AppColors.primary,
              ),
            ),
          );
        }
        return _buildLyricView(
          ctx,
          player,
          textColor,
          landscape: true,
          toggleOnTap: false,
        );
      },
    );
  }

  Widget _buildLyricFontMenu(Color color) {
    return PopupMenuButton<double>(
      tooltip: '歌词字号',
      initialValue: _lyricFontSize,
      position: PopupMenuPosition.under,
      icon: Icon(Icons.format_size_rounded, color: color, size: 30),
      onSelected: _selectLyricFontSize,
      itemBuilder: (_) => _lyricFontMenuItems(),
    );
  }

  List<PopupMenuEntry<double>> _lyricFontMenuItems() => const [
    PopupMenuItem(value: 32, child: Text('小 · 32')),
    PopupMenuItem(value: 36, child: Text('中 · 36')),
    PopupMenuItem(value: 42, child: Text('标准 · 42')),
    PopupMenuItem(value: 48, child: Text('大 · 48')),
    PopupMenuItem(value: 54, child: Text('特大 · 54')),
    PopupMenuItem(value: 60, child: Text('最大 · 60')),
  ];

  Widget _buildPlayerVisual(
    BuildContext ctx,
    PlayerProvider player,
    PlayQueueItem song,
    Color baseColor,
    Color textColor, {
    bool landscape = false,
  }) {
    return Selector<PlayerProvider, (bool, int, int)>(
      selector: (_, p) => (p.showLyric, p.currentLyricIndex, p.lyrics.length),
      builder: (ctx, sel, _) {
        if (sel.$1) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _scrollToLyric(sel.$2);
          });
          return _buildLyricView(ctx, player, textColor, landscape: landscape);
        }
        return _buildCoverArt(
          ctx,
          player,
          song,
          baseColor,
          landscape: landscape,
        );
      },
    );
  }

  Widget _buildTopBar(
    BuildContext ctx,
    PlayerProvider player,
    Color textColor,
    Color subColor, {
    bool showQueue = true,
  }) {
    final layout = AppLayout.fromContext(ctx);
    final largeUi = layout.usesLargeTypography;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: largeUi ? 20 : 8,
        vertical: largeUi ? 8 : 4,
      ),
      child: Row(
        children: [
          IconButton(
            key: const ValueKey('player-back'),
            tooltip: '返回',
            icon: Icon(Icons.keyboard_arrow_down, color: textColor),
            onPressed: () => Navigator.pop(ctx),
          ),
          Expanded(
            child: Column(
              children: [
                Text(
                  '正在播放',
                  style: TextStyle(
                    color: subColor,
                    fontSize: largeUi ? 16 : 13,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  player.queue.length > 1
                      ? '播放列表 (${player.currentIndex + 1}/${player.queue.length})'
                      : '单曲播放',
                  style: TextStyle(
                    color: textColor,
                    fontSize: largeUi ? 20 : 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          if (showQueue)
            IconButton(
              icon: Icon(Icons.queue_music, color: textColor),
              onPressed: () => _showQueueSheet(ctx, player),
            )
          else
            const SizedBox(width: 48),
        ],
      ),
    );
  }

  Widget _buildCoverArt(
    BuildContext ctx,
    PlayerProvider player,
    PlayQueueItem song,
    Color baseColor, {
    bool landscape = false,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final coverSize = landscape
            ? (constraints.biggest.shortestSide - 32).clamp(96.0, 300.0)
            : 300.0;
        return GestureDetector(
          onTap: () => player.toggleShowLyric(),
          child: Center(
            child: Container(
              width: coverSize,
              height: coverSize,
              margin: EdgeInsets.all(landscape ? 16 : 24),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(28),
                boxShadow: [
                  BoxShadow(
                    color: baseColor.withOpacity(0.35),
                    blurRadius: landscape ? 24 : 40,
                    offset: Offset(0, landscape ? 8 : 16),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(28),
                child: song.coverUrl != null && song.coverUrl!.isNotEmpty
                    ? SmartCover(
                        url: song.coverUrl,
                        fit: BoxFit.cover,
                        placeholder: () => _buildDefaultCover(song),
                      )
                    : _buildDefaultCover(song),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDefaultCover(PlayQueueItem song, {bool compact = false}) {
    final color = PlatformColors.of(song.platform);
    return Container(
      color: color.withOpacity(0.15),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.music_note, size: compact ? 34 : 80, color: color),
            SizedBox(height: compact ? 4 : 12),
            Text(
              song.platform.label,
              style: TextStyle(color: color, fontSize: compact ? 11 : 16),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLyricView(
    BuildContext ctx,
    PlayerProvider player,
    Color textColor, {
    bool landscape = false,
    bool toggleOnTap = true,
  }) {
    if (player.lyrics.isEmpty && player.lyricsLoading) {
      return Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            color: AppColors.primary,
          ),
        ),
      );
    }
    if (player.lyrics.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.lyrics_outlined,
              size: 64,
              color: textColor.withOpacity(0.3),
            ),
            const SizedBox(height: 16),
            Text(
              '暂无歌词',
              style: TextStyle(
                color: textColor.withOpacity(0.5),
                fontSize: AppLayout.fromContext(ctx).bodySize,
              ),
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final availableHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : _lyricLineExtent * 2;
        final layout = AppLayout.fromContext(ctx);
        final largeUi = landscape && layout.usesLargeTypography;
        final scaledFontSize = MediaQuery.textScalerOf(
          ctx,
        ).scale(_lyricFontSize);
        final lineExtent = landscape
            ? (scaledFontSize + (largeUi ? 34 : 28)).clamp(
                largeUi ? 64.0 : 58.0,
                largeUi ? 92.0 : 82.0,
              )
            : (scaledFontSize + 30).clamp(60.0, 86.0);
        _lyricLineExtent = lineExtent;
        final landscapePadding = availableHeight <= 20
            ? 0.0
            : ((availableHeight - lineExtent) / 2).clamp(20.0, availableHeight);
        return GestureDetector(
          onTap: toggleOnTap ? () => player.toggleShowLyric() : null,
          onVerticalDragUpdate: (_) =>
              setState(() => _lyricsAutoScroll = false),
          child: ListView.builder(
            controller: _lyricScrollController,
            padding: EdgeInsets.symmetric(
              vertical: landscape
                  ? landscapePadding
                  : MediaQuery.sizeOf(ctx).height * 0.28,
              horizontal: landscape ? (largeUi ? 44 : 28) : 32,
            ),
            itemCount: player.lyrics.length,
            itemBuilder: (ctx, i) {
              final lyric = player.lyrics[i];
              final isCurrent = i == player.currentLyricIndex;
              return GestureDetector(
                onTap: () {
                  player.seekTo(lyric.time);
                  setState(() => _lyricsAutoScroll = true);
                },
                child: SizedBox(
                  height: lineExtent,
                  child: Align(
                    alignment: Alignment.center,
                    child: SizedBox(
                      width: double.infinity,
                      child: Text(
                        lyric.text,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isCurrent
                              ? textColor
                              : textColor.withOpacity(0.68),
                          fontSize: isCurrent
                              ? _lyricFontSize
                              : (_lyricFontSize - 3).clamp(20.0, 40.0),
                          fontWeight: isCurrent
                              ? FontWeight.w700
                              : FontWeight.w500,
                          height: 1.25,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildSongInfo(
    BuildContext ctx,
    PlayerProvider player,
    PlayQueueItem song,
    Color textColor,
    Color subColor, {
    bool compact = false,
  }) {
    // 仅监听加载状态与错误信息，避免随播放进度频繁重建
    return Selector<PlayerProvider, (bool, String?)>(
      selector: (_, p) => (p.isLoading, p.errorMessage),
      builder: (ctx, sel, _) {
        final isLoading = sel.$1;
        final errorMessage = sel.$2;
        final layout = AppLayout.fromContext(ctx);
        final largeUi = layout.usesLargeTypography;
        return Padding(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 20 : 32,
            vertical: compact ? 2 : 8,
          ),
          child: Column(
            children: [
              _buildSongNameLink(
                ctx,
                player,
                song,
                textColor,
                fontSize: largeUi ? 27 : (compact ? 21 : 24),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              _buildArtistAlbumLine(
                ctx,
                player,
                song,
                subColor,
                fontSize: largeUi ? 17 : (compact ? 15 : 16),
                centered: true,
              ),
              if (isLoading) ...[
                const SizedBox(height: 6),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox.square(
                      dimension: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: textColor.withOpacity(0.7),
                      ),
                    ),
                    const SizedBox(width: 7),
                    Text(
                      '正在准备音频',
                      style: TextStyle(
                        color: subColor,
                        fontSize: compact ? 12 : 13,
                      ),
                    ),
                  ],
                ),
              ],
              if (errorMessage != null) ...[
                const SizedBox(height: 4),
                Text(
                  errorMessage,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildProgressBar(
    BuildContext ctx,
    PlayerProvider player,
    Color textColor,
    Color subColor, {
    bool compact = false,
  }) {
    // 进度条独立监听 position/duration，只有时间变化才重建这一小块
    return Selector<PlayerProvider, (Duration, Duration)>(
      selector: (_, p) => (p.position, p.duration),
      builder: (ctx, sel, _) {
        final position = sel.$1;
        final duration = sel.$2;
        final layout = AppLayout.fromContext(ctx);
        final largeUi = compact && layout.usesLargeTypography;
        final total = duration.inMilliseconds.toDouble();
        final pos = position.inMilliseconds.toDouble().clamp(
          0,
          total > 0 ? total : 1,
        );
        return Padding(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 16 : 24,
            vertical: compact ? 0 : 4,
          ),
          child: Column(
            children: [
              SliderTheme(
                data: SliderTheme.of(ctx).copyWith(
                  trackHeight: largeUi ? 4 : 3,
                  thumbShape: RoundSliderThumbShape(
                    enabledThumbRadius: largeUi ? 8 : 6,
                  ),
                  overlayShape: RoundSliderOverlayShape(
                    overlayRadius: largeUi ? 16 : 12,
                  ),
                  activeTrackColor: AppColors.primary,
                  inactiveTrackColor: subColor.withOpacity(0.25),
                  thumbColor: AppColors.primary,
                ),
                child: SizedBox(
                  height: largeUi ? 44 : (compact ? 34 : 50),
                  child: Slider(
                    value: total > 0 ? pos / total : 0,
                    onChanged: total > 0
                        ? (v) {
                            player.seekTo(
                              Duration(milliseconds: (v * total).toInt()),
                            );
                          }
                        : null,
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _formatDuration(position),
                      style: TextStyle(
                        color: subColor,
                        fontSize: largeUi ? 14 : (compact ? 11 : 13),
                      ),
                    ),
                    Text(
                      _formatDuration(duration),
                      style: TextStyle(
                        color: subColor,
                        fontSize: largeUi ? 14 : (compact ? 12 : 13),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildControls(
    BuildContext ctx,
    PlayerProvider player,
    Color textColor, {
    bool compact = false,
    bool landscape = false,
  }) {
    // 仅监听播放状态/模式/歌词开关，避免随播放进度重建
    return Selector<PlayerProvider, (bool, PlayMode, bool)>(
      selector: (_, p) => (p.isPlaying, p.playMode, p.showLyric),
      builder: (ctx, sel, _) {
        final isPlaying = sel.$1;
        final playMode = sel.$2;
        final showLyric = sel.$3;
        final layout = AppLayout.fromContext(ctx);
        final largeUi = landscape && layout.usesLargeTypography;
        final iconButtonWidth = largeUi ? 58.0 : (compact ? 46.0 : 54.0);
        final iconButtonHeight = largeUi ? 58.0 : (compact ? 48.0 : 56.0);
        final playButtonSize = largeUi ? 68.0 : (compact ? 56.0 : 76.0);
        return Padding(
          key: landscape ? const ValueKey('landscape-player-buttons') : null,
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 0 : 24,
            vertical: compact ? 0 : 4,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // 播放模式
              IconButton(
                constraints: BoxConstraints.tightFor(
                  width: iconButtonWidth,
                  height: iconButtonHeight,
                ),
                padding: EdgeInsets.zero,
                tooltip: '播放模式',
                icon: Icon(
                  playMode == PlayMode.sequence
                      ? Icons.repeat_rounded
                      : playMode == PlayMode.repeat
                      ? Icons.repeat_one_rounded
                      : Icons.shuffle_rounded,
                  color: textColor,
                  size: largeUi ? 28 : (compact ? 22 : 28),
                ),
                onPressed: player.togglePlayMode,
              ),
              // 上一首
              IconButton(
                constraints: BoxConstraints.tightFor(
                  width: iconButtonWidth,
                  height: iconButtonHeight,
                ),
                padding: EdgeInsets.zero,
                tooltip: '上一首',
                icon: Icon(
                  Icons.skip_previous_rounded,
                  color: textColor,
                  size: largeUi ? 42 : (compact ? 32 : 46),
                ),
                onPressed: player.playPrevious,
              ),
              // 播放/暂停
              Container(
                width: playButtonSize,
                height: playButtonSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.primary,
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.primary.withOpacity(0.4),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: IconButton(
                  tooltip: isPlaying ? '暂停' : '播放',
                  icon: Icon(
                    isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: largeUi ? 38 : (compact ? 32 : 42),
                  ),
                  onPressed: player.playPause,
                ),
              ),
              // 下一首
              IconButton(
                constraints: BoxConstraints.tightFor(
                  width: iconButtonWidth,
                  height: iconButtonHeight,
                ),
                padding: EdgeInsets.zero,
                tooltip: '下一首',
                icon: Icon(
                  Icons.skip_next_rounded,
                  color: textColor,
                  size: largeUi ? 42 : (compact ? 32 : 46),
                ),
                onPressed: player.playNext,
              ),
              if (!landscape)
                IconButton(
                  constraints: BoxConstraints.tightFor(
                    width: iconButtonWidth,
                    height: iconButtonHeight,
                  ),
                  padding: EdgeInsets.zero,
                  tooltip: '歌词',
                  icon: Icon(
                    Icons.lyrics_rounded,
                    color: showLyric
                        ? AppColors.primary
                        : textColor.withOpacity(0.5),
                    size: 24,
                  ),
                  onPressed: player.toggleShowLyric,
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBottomActions(
    BuildContext ctx,
    PlayerProvider player,
    Color subColor, {
    bool compact = false,
    bool showLyricFontControl = false,
    bool landscape = false,
  }) {
    // 收藏状态跟随 FavoriteService（点击收藏/取消收藏实时刷新）
    final fav = ctx.watch<FavoriteService>();
    final song = player.currentSong;
    final isFav = song != null && fav.isFavorite(song.platform, song.id);
    return Selector<PlayerProvider, bool>(
      selector: (_, p) => p.showLyric,
      builder: (ctx, showLyric, _) {
        return Padding(
          padding: EdgeInsets.only(bottom: compact ? 0 : 12),
          child: Row(
            children: [
              if (!landscape)
                Expanded(
                  child: _playerActionButton(
                    context: ctx,
                    compact: compact,
                    onPressed: player.toggleShowLyric,
                    icon: Icons.text_snippet_rounded,
                    label: '歌词',
                    color: showLyric ? AppColors.primary : subColor,
                  ),
                ),
              if (showLyricFontControl || landscape)
                Expanded(child: _buildLyricFontAction(ctx, subColor))
              else if (!compact)
                _buildLyricFontMenu(subColor),
              Expanded(
                child: _playerActionButton(
                  context: ctx,
                  compact: compact,
                  onPressed: () async {
                    if (song == null) return;
                    final added = await fav.toggle(
                      SongSearchResult.fromQueueItem(song),
                    );
                    if (ctx.mounted) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        SnackBar(
                          content: Text(added ? '已收藏 ♥' : '已取消收藏'),
                          duration: const Duration(seconds: 1),
                        ),
                      );
                    }
                  },
                  icon: isFav ? Icons.favorite : Icons.favorite_border,
                  label: isFav ? '已收藏' : '收藏',
                  color: isFav ? Colors.redAccent : subColor,
                ),
              ),
              Expanded(
                child: _playerActionButton(
                  context: ctx,
                  compact: compact,
                  onPressed: () => _showQueueSheet(ctx, player),
                  icon: Icons.queue_music_rounded,
                  label: '队列',
                  color: subColor,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildLyricFontAction(BuildContext context, Color color) {
    final layout = AppLayout.fromContext(context);
    final largeUi = layout.usesLargeTypography;
    final iconSize = largeUi ? 24.0 : 20.0;
    final fontSize = largeUi ? 16.0 : 14.0;
    return PopupMenuButton<double>(
      key: const ValueKey('player-lyric-font-action'),
      tooltip: '歌词字号',
      initialValue: _lyricFontSize,
      position: PopupMenuPosition.under,
      onSelected: _selectLyricFontSize,
      itemBuilder: (_) => _lyricFontMenuItems(),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: largeUi ? 54 : 46),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.format_size_rounded, color: color, size: iconSize),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                '字号',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: color, fontSize: fontSize),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _playerActionButton({
    required BuildContext context,
    required bool compact,
    required VoidCallback onPressed,
    required IconData icon,
    required String label,
    required Color color,
  }) {
    final layout = AppLayout.fromContext(context);
    final largeUi = layout.usesLargeTypography;
    final height = largeUi ? 54.0 : (compact ? 36.0 : 50.0);
    final iconSize = largeUi ? 24.0 : (compact ? 18.0 : 22.0);
    final fontSize = largeUi ? 16.0 : (compact ? 13.0 : 16.0);
    return Tooltip(
      message: label == '队列' ? '播放队列' : label,
      child: TextButton.icon(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          padding: EdgeInsets.symmetric(horizontal: largeUi ? 4 : 2),
          minimumSize: Size(0, height),
          tapTargetSize: MaterialTapTargetSize.padded,
        ),
        icon: Icon(icon, color: color, size: iconSize),
        label: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: color, fontSize: fontSize),
        ),
      ),
    );
  }

  void _showQueueSheet(BuildContext ctx, PlayerProvider player) {
    final isLandscape = MediaQuery.orientationOf(ctx) == Orientation.landscape;
    if (isLandscape) {
      showDialog<void>(
        context: ctx,
        barrierColor: Colors.black54,
        builder: (dialogCtx) {
          final size = MediaQuery.sizeOf(dialogCtx);
          final panelWidth = (size.width * 0.42).clamp(300.0, 420.0);
          return Align(
            alignment: Alignment.centerRight,
            child: SafeArea(
              left: false,
              child: Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Material(
                  color: AppColors.surface,
                  elevation: 12,
                  borderRadius: BorderRadius.circular(AppRadius.panel),
                  clipBehavior: Clip.antiAlias,
                  child: SizedBox(
                    width: panelWidth,
                    height: size.height * 0.86,
                    child: _buildQueueContent(
                      dialogCtx,
                      player,
                      null,
                      showHandle: false,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
      return;
    }

    showModalBottomSheet(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.panel),
        ),
      ),
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.3,
          maxChildSize: 0.9,
          expand: false,
          builder: (ctx, scrollController) {
            return _buildQueueContent(ctx, player, scrollController);
          },
        );
      },
    );
  }

  Widget _buildQueueContent(
    BuildContext ctx,
    PlayerProvider player,
    ScrollController? scrollController, {
    bool showHandle = true,
  }) {
    return Column(
      children: [
        if (showHandle)
          Container(
            margin: const EdgeInsets.only(top: 10),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.textHint.withOpacity(0.4),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '播放队列 (${player.queue.length})',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              if (player.queue.isNotEmpty)
                TextButton(
                  onPressed: () {
                    player.clearQueue();
                    Navigator.pop(ctx);
                  },
                  child: Text('清空', style: TextStyle(color: AppColors.primary)),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            controller: scrollController,
            itemCount: player.queue.length,
            itemBuilder: (ctx, i) {
              final item = player.queue[i];
              final isCurrent = i == player.currentIndex;
              return ListTile(
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.media),
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: item.coverUrl != null && item.coverUrl!.isNotEmpty
                        ? SmartCover(
                            url: item.coverUrl,
                            fit: BoxFit.cover,
                            placeholder: () => _queueCoverPlaceholder(),
                          )
                        : _queueCoverPlaceholder(),
                  ),
                ),
                title: Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isCurrent
                        ? AppColors.primary
                        : AppColors.textPrimary,
                    fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
                    fontSize: 14,
                  ),
                ),
                subtitle: Text(
                  '${item.platform.label} · ${item.artist}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondary,
                  ),
                ),
                trailing: isCurrent
                    ? Icon(Icons.equalizer_rounded, color: AppColors.primary)
                    : item.loading
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.primary,
                        ),
                      )
                    : IconButton(
                        icon: Icon(
                          Icons.close_rounded,
                          size: 20,
                          color: AppColors.textSecondary,
                        ),
                        onPressed: () => player.removeFromQueue(i),
                      ),
                onTap: () => player.playQueueItem(i),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _queueCoverPlaceholder() {
    return Container(
      color: AppColors.primarySoft,
      child: Icon(Icons.music_note, size: 20, color: AppColors.primary),
    );
  }

  String _formatDuration(Duration d) {
    final min = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final sec = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$min:$sec';
  }
}
