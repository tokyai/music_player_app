import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../providers/search_session.dart';
import '../services/api_service.dart';
import '../services/favorite_service.dart';
import '../theme/app_layout.dart';
import '../theme/app_motion.dart';
import '../theme/app_theme.dart';
import '../theme/lyric_style.dart';
import '../utils/color_extractor.dart';
import '../utils/system_ui.dart';
import '../widgets/cover_hero_tags.dart';
import '../widgets/smart_cover.dart';
import 'video_player_screen.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  static Route<void> route(BuildContext context) {
    final duration = AppMotion.resolve(context, AppMotion.page);
    return PageRouteBuilder<void>(
      transitionDuration: duration,
      reverseTransitionDuration: duration,
      pageBuilder: (_, _, _) => const PlayerScreen(),
      transitionsBuilder: (_, animation, _, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: AppMotion.enterCurve,
          reverseCurve: AppMotion.exitCurve,
        );
        // The cover Hero already provides continuity. Fading the complete
        // player adds a full-screen opacity layer exactly while its first
        // frame is decoding artwork, which is costly on low-end head units.
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.025),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        );
      },
    );
  }

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _LyricSearchDialog extends StatefulWidget {
  final PlayerProvider player;
  final PlayQueueItem song;

  const _LyricSearchDialog({required this.player, required this.song});

  @override
  State<_LyricSearchDialog> createState() => _LyricSearchDialogState();
}

class _LyricSearchDialogState extends State<_LyricSearchDialog> {
  late final TextEditingController _queryController;
  List<SongSearchResult> _results = const [];
  bool _loading = false;
  String? _applyingId;
  String? _error;
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    _queryController = TextEditingController(text: widget.song.name);
    WidgetsBinding.instance.addPostFrameCallback((_) => _search());
  }

  @override
  void dispose() {
    _requestId++;
    _queryController.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _queryController.text.trim();
    if (query.isEmpty) {
      setState(() {
        _results = const [];
        _error = '请输入歌曲名';
      });
      return;
    }
    final requestId = ++_requestId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await widget.player.searchLyricCandidates(query);
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _results = results;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _loading = false;
        _results = const [];
        _error = error is ApiException ? error.message : '歌词搜索失败，请稍后重试';
      });
    }
  }

  Future<void> _apply(SongSearchResult result) async {
    if (_applyingId != null) return;
    setState(() {
      _applyingId = result.id;
      _error = null;
    });
    try {
      await widget.player.applyLyricCandidate(result);
      if (!mounted) return;
      Navigator.pop(context, result.name);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _applyingId = null;
        _error = error is ApiException ? error.message : '歌词加载失败，请选择其他版本';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final compact = size.height < 480;
    final dialogWidth = (size.width - 24).clamp(296.0, 900.0);
    final dialogHeight = (size.height - 24).clamp(280.0, 620.0);
    return Dialog(
      key: const ValueKey('lyric-search-dialog'),
      insetPadding: const EdgeInsets.all(12),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: dialogWidth,
        height: dialogHeight,
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                compact ? 14 : 20,
                compact ? 8 : 14,
                compact ? 6 : 10,
                compact ? 4 : 8,
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.lyrics_rounded,
                    color: AppColors.primary,
                    size: compact ? 25 : 30,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '查找歌词',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: compact ? 19 : 23,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('lyric-search-close'),
                    tooltip: '关闭',
                    onPressed: _applyingId == null
                        ? () => Navigator.pop(context)
                        : null,
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 14 : 20,
                vertical: compact ? 2 : 6,
              ),
              child: TextField(
                key: const ValueKey('lyric-search-field'),
                controller: _queryController,
                autofocus: false,
                textInputAction: TextInputAction.search,
                enabled: _applyingId == null,
                onSubmitted: (_) => _search(),
                decoration: InputDecoration(
                  hintText: '歌曲名',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: IconButton(
                    key: const ValueKey('lyric-search-submit'),
                    tooltip: '搜索歌词',
                    onPressed: _loading || _applyingId != null ? null : _search,
                    icon: const Icon(Icons.arrow_forward_rounded),
                  ),
                ),
              ),
            ),
            if (_error != null)
              Padding(
                padding: EdgeInsets.fromLTRB(
                  compact ? 14 : 20,
                  compact ? 4 : 6,
                  compact ? 14 : 20,
                  0,
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.info_outline_rounded,
                      color: Colors.redAccent,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _error!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.redAccent),
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: AppMotionSwitcher(
                child: KeyedSubtree(
                  key: ValueKey(
                    _loading
                        ? 'lyric-search-loading'
                        : _results.isEmpty
                        ? 'lyric-search-empty'
                        : 'lyric-search-content',
                  ),
                  child: _buildResults(compact),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResults(bool compact) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_results.isEmpty) {
      return Center(
        child: Text(
          _error == null ? '没有找到匹配歌曲' : '',
          style: TextStyle(color: AppColors.textSecondary),
        ),
      );
    }
    return ListView.separated(
      key: const ValueKey('lyric-search-results'),
      padding: EdgeInsets.fromLTRB(
        compact ? 6 : 12,
        compact ? 4 : 8,
        compact ? 6 : 12,
        compact ? 8 : 14,
      ),
      itemCount: _results.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final result = _results[index];
        final applying = _applyingId == result.id;
        final album = result.album.trim().isEmpty ? '未知专辑' : result.album;
        return ListTile(
          key: ValueKey(
            'lyric-search-result-${result.platform.code}-${result.id}',
          ),
          dense: compact,
          enabled: _applyingId == null,
          leading: CircleAvatar(
            radius: compact ? 19 : 22,
            backgroundColor: PlatformColors.of(
              result.platform,
            ).withValues(alpha: 0.14),
            child: Icon(
              Icons.music_note_rounded,
              color: PlatformColors.of(result.platform),
              size: compact ? 21 : 24,
            ),
          ),
          title: Text(
            result.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w600,
              fontSize: compact ? 16 : 18,
            ),
          ),
          subtitle: Text(
            '${result.artist} · $album',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: compact ? 13 : 15,
            ),
          ),
          trailing: applying
              ? const SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.chevron_right_rounded),
          onTap: () => _apply(result),
        );
      },
    );
  }
}

class _LyricDisplaySettingsDialog extends StatefulWidget {
  final double fontSize;
  final double lineSpacing;
  final List<double> fontSizes;
  final ValueChanged<double> onFontSizeChanged;
  final ValueChanged<double> onLineSpacingChanged;
  final ValueChanged<double> onLineSpacingChangeEnd;

  const _LyricDisplaySettingsDialog({
    required this.fontSize,
    required this.lineSpacing,
    required this.fontSizes,
    required this.onFontSizeChanged,
    required this.onLineSpacingChanged,
    required this.onLineSpacingChangeEnd,
  });

  @override
  State<_LyricDisplaySettingsDialog> createState() =>
      _LyricDisplaySettingsDialogState();
}

class _LyricDisplaySettingsDialogState
    extends State<_LyricDisplaySettingsDialog> {
  late double _fontSize = widget.fontSize;
  late double _lineSpacing = widget.lineSpacing;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final compact = size.height < 480;
    return Dialog(
      key: const ValueKey('lyric-display-settings-dialog'),
      insetPadding: const EdgeInsets.all(12),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 560, maxHeight: size.height - 24),
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            compact ? 16 : 22,
            compact ? 10 : 16,
            compact ? 16 : 22,
            compact ? 10 : 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '歌词显示',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('lyric-display-settings-close'),
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              SizedBox(height: compact ? 2 : 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 8, right: 12),
                    child: Text(
                      '字号',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  Expanded(
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: widget.fontSizes.map((size) {
                        return ChoiceChip(
                          key: ValueKey('lyric-font-size-${size.round()}'),
                          label: Text('${size.round()}'),
                          selected: _fontSize == size,
                          onSelected: (_) {
                            setState(() => _fontSize = size);
                            widget.onFontSizeChanged(size);
                          },
                        );
                      }).toList(),
                    ),
                  ),
                ],
              ),
              SizedBox(height: compact ? 8 : 16),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '上下间距',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  Text('${_lineSpacing.round()} px'),
                ],
              ),
              Slider(
                key: const ValueKey('lyric-line-spacing-slider'),
                value: _lineSpacing,
                min: _PlayerScreenState._minimumLyricLineSpacing,
                max: _PlayerScreenState._maximumLyricLineSpacing,
                divisions: 28,
                label: '${_lineSpacing.round()} px',
                onChanged: (value) {
                  setState(() => _lineSpacing = value);
                  widget.onLineSpacingChanged(value);
                },
                onChangeEnd: widget.onLineSpacingChangeEnd,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AnimatedLyricLineText extends StatelessWidget {
  final int index;
  final String text;
  final bool isCurrent;
  final bool wordTimingReliable;
  final double progress;
  final double currentFontSize;
  final double inactiveFontSize;
  final Color playedColor;
  final Color unplayedColor;
  final Color inactiveColor;
  final LyricFontFamilyPreset fontFamily;
  final LyricFontWeightPreset fontWeight;

  const _AnimatedLyricLineText({
    required this.index,
    required this.text,
    required this.isCurrent,
    required this.wordTimingReliable,
    required this.progress,
    required this.currentFontSize,
    required this.inactiveFontSize,
    required this.playedColor,
    required this.unplayedColor,
    required this.inactiveColor,
    required this.fontFamily,
    required this.fontWeight,
  });

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      color: isCurrent ? unplayedColor : inactiveColor,
      fontSize: isCurrent ? currentFontSize : inactiveFontSize,
      fontWeight: isCurrent ? fontWeight.currentLineWeight : fontWeight.weight,
      fontFamily: fontFamily.fontFamily,
      fontFamilyFallback: fontFamily.fontFamilyFallback,
      height: 1.18,
    );
    return AnimatedDefaultTextStyle(
      duration: AppMotion.resolve(context, AppMotion.state),
      curve: Curves.easeOutCubic,
      style: style,
      textAlign: TextAlign.center,
      child: isCurrent
          ? wordTimingReliable
                // Do not tween toward an already sampled audio position.  The
                // previous 180 ms tween made the karaoke cursor permanently
                // trail the singer even when the source timestamps were exact.
                ? _KaraokeProgressText(
                    index: index,
                    text: text,
                    progress: progress,
                    playedColor: playedColor,
                    unplayedColor: unplayedColor,
                  )
                : _SolidCurrentLyricText(
                    index: index,
                    text: text,
                    color: playedColor,
                  )
          : Builder(
              builder: (context) => Text(
                text,
                key: ValueKey('lyric-text-$index'),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: DefaultTextStyle.of(context).style,
              ),
            ),
    );
  }
}

/// Current-line fallback for plain LRC and coarse word/phrase timestamps.
///
/// There is deliberately no time-based transition here: the entire active
/// line is rendered in the stronger color.  A single-color shader keeps the
/// same glyph rendering path as karaoke lines without pretending that a
/// phrase-level timestamp identifies the currently sung character.
class _SolidCurrentLyricText extends StatelessWidget {
  final int index;
  final String text;
  final Color color;

  const _SolidCurrentLyricText({
    required this.index,
    required this.text,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style;
    return Text(
      text,
      key: ValueKey('lyric-text-$index'),
      textAlign: TextAlign.center,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style.copyWith(color: color),
    );
  }
}

class _KaraokeProgressText extends StatelessWidget {
  final int index;
  final String text;
  final double progress;
  final Color playedColor;
  final Color unplayedColor;

  const _KaraokeProgressText({
    required this.index,
    required this.text,
    required this.progress,
    required this.playedColor,
    required this.unplayedColor,
  });

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style;
    final textDirection = Directionality.of(context);
    final textScaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          maxLines: 1,
          ellipsis: '…',
          textDirection: textDirection,
          textScaler: textScaler,
        )..layout(maxWidth: maxWidth);
        final textWidth = painter.width.clamp(1.0, maxWidth);
        final resolvedProgress = progress.clamp(0.0, 1.0);
        return SizedBox(
          width: textWidth,
          child: Semantics(
            key: ValueKey('lyric-progress-$index'),
            value: '${(resolvedProgress * 100).round()}%',
            child: ShaderMask(
              blendMode: BlendMode.srcIn,
              shaderCallback: (bounds) {
                if (resolvedProgress <= 0) {
                  return LinearGradient(
                    colors: [unplayedColor, unplayedColor],
                  ).createShader(bounds);
                }
                if (resolvedProgress >= 1) {
                  return LinearGradient(
                    colors: [playedColor, playedColor],
                  ).createShader(bounds);
                }
                return LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    playedColor,
                    playedColor,
                    unplayedColor,
                    unplayedColor,
                  ],
                  stops: [0, resolvedProgress, resolvedProgress, 1],
                ).createShader(bounds);
              },
              child: Text(
                text,
                key: ValueKey('lyric-text-$index'),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                // ShaderMask 用字形 alpha 做遮罩；前景设为不透明，才能让
                // 已唱部分真正显示为高亮色，而不是被未唱色的 alpha 再压暗。
                style: style.copyWith(
                  foreground: Paint()..color = Colors.white,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PlayerScreenState extends State<PlayerScreen> {
  static const _landscapeSplitRatioPreferenceKey =
      'player_landscape_split_ratio';
  static const _lyricFontSizes = <double>[32, 36, 42, 48, 54, 60];
  static const _minimumLyricLineSpacing = 20.0;
  static const _maximumLyricLineSpacing = 160.0;
  static const _defaultLandscapeLeftRatio = 0.42;
  static const _minimumLandscapeLeftRatio = 0.32;
  static const _maximumLandscapeLeftRatio = 0.62;

  Color? _dominantColor;
  bool _lyricsAutoScroll = true;
  bool _lyricFontSizeChangedByUser = false;
  bool _lyricLineSpacingChangedByUser = false;
  double _lyricFontSize = 42;
  double _lyricLineSpacing = 44;
  LyricFontFamilyPreset _lyricFontFamily = LyricFontFamilyPreset.system;
  LyricFontWeightPreset _lyricFontWeight = LyricFontWeightPreset.medium;
  double _lyricLineExtent = 86;
  double _landscapeLeftRatio = _defaultLandscapeLeftRatio;
  bool _landscapeSplitChangedByUser = false;
  bool _mvOpening = false;
  bool _lyricSearchDialogOpen = false;
  final ScrollController _lyricScrollController = ScrollController();
  Animation<double>? _routeAnimation;
  bool _routeTransitionComplete = false;
  String? _lastColorSongId;
  String? _lastAutoScrollSongKey;
  int? _lastAutoScrollLyricIndex;
  bool _forceLyricRecenter = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadLyricDisplaySettings());
    unawaited(_loadLandscapeSplitRatio());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateColor(context.read<PlayerProvider>().currentSong);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    final nextAnimation = route?.animation;
    if (identical(_routeAnimation, nextAnimation)) return;
    _routeAnimation?.removeStatusListener(_handleRouteAnimationStatus);
    _routeAnimation = nextAnimation;
    if (nextAnimation == null) {
      _routeTransitionComplete = true;
      return;
    }
    nextAnimation.addStatusListener(_handleRouteAnimationStatus);
    // A newly inserted route can briefly report `completed` before Navigator
    // starts its forward controller.  Only the root route may eagerly build
    // the expensive background; pushed player routes wait for the real
    // completion callback below.
    _routeTransitionComplete =
        route?.isFirst == true &&
        nextAnimation.status == AnimationStatus.completed;
  }

  void _handleRouteAnimationStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || _routeTransitionComplete) {
      return;
    }
    if (!mounted) return;
    setState(() => _routeTransitionComplete = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _updateColor(context.read<PlayerProvider>().currentSong);
      }
    });
  }

  Future<void> _loadLyricDisplaySettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final rawValue = prefs.get(LyricStylePreferences.fontSizeKey);
      final rawSize = rawValue is num ? rawValue.toDouble() : null;
      final rawSpacingValue = prefs.get(LyricStylePreferences.lineSpacingKey);
      final savedSpacing = rawSpacingValue is num
          ? rawSpacingValue.toDouble().clamp(
              _minimumLyricLineSpacing,
              _maximumLyricLineSpacing,
            )
          : null;
      final savedFontFamily = LyricFontFamilyPreset.fromValue(
        prefs.getString(LyricStylePreferences.fontFamilyKey),
      );
      final rawFontWeight = prefs.get(LyricStylePreferences.fontWeightKey);
      final savedFontWeight = LyricFontWeightPreset.fromValue(
        rawFontWeight is num ? rawFontWeight.toInt() : null,
      );
      // 旧版本的 24/28 档在大屏上过小，平滑迁移到新的最小档 32。
      final savedSize = rawSize != null && rawSize < 32 ? 32.0 : rawSize;
      if (!mounted) return;
      setState(() {
        var layoutChanged = false;
        if (!_lyricFontSizeChangedByUser &&
            savedSize != null &&
            _lyricFontSizes.contains(savedSize)) {
          layoutChanged = layoutChanged || _lyricFontSize != savedSize;
          _lyricFontSize = savedSize;
        }
        if (!_lyricLineSpacingChangedByUser && savedSpacing != null) {
          layoutChanged = layoutChanged || _lyricLineSpacing != savedSpacing;
          _lyricLineSpacing = savedSpacing;
        }
        layoutChanged =
            layoutChanged ||
            _lyricFontFamily != savedFontFamily ||
            _lyricFontWeight != savedFontWeight;
        _lyricFontFamily = savedFontFamily;
        _lyricFontWeight = savedFontWeight;
        if (layoutChanged) {
          _lastAutoScrollLyricIndex = null;
          _forceLyricRecenter = true;
        }
      });
    } catch (_) {}
  }

  void _selectLyricFontSize(double size) {
    if (!_lyricFontSizes.contains(size)) return;
    _lyricFontSizeChangedByUser = true;
    if (_lyricFontSize != size) {
      setState(() {
        _lyricFontSize = size;
        _lastAutoScrollLyricIndex = null;
        _forceLyricRecenter = true;
      });
    }
    unawaited(_saveLyricFontSize(size));
  }

  Future<void> _saveLyricFontSize(double size) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(LyricStylePreferences.fontSizeKey, size);
    } catch (_) {}
  }

  void _previewLyricLineSpacing(double spacing) {
    _lyricLineSpacingChangedByUser = true;
    final next = spacing.clamp(
      _minimumLyricLineSpacing,
      _maximumLyricLineSpacing,
    );
    if (_lyricLineSpacing != next) {
      setState(() {
        _lyricLineSpacing = next;
        _lastAutoScrollLyricIndex = null;
        _forceLyricRecenter = true;
      });
    }
  }

  void _commitLyricLineSpacing(double spacing) {
    _previewLyricLineSpacing(spacing);
    unawaited(_saveLyricLineSpacing(_lyricLineSpacing));
  }

  Future<void> _saveLyricLineSpacing(double spacing) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(LyricStylePreferences.lineSpacingKey, spacing);
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
    _routeAnimation?.removeStatusListener(_handleRouteAnimationStatus);
    _lyricScrollController.dispose();
    super.dispose();
  }

  // 仅在歌曲切换时提取一次封面主色（防抖），避免每次重建都跑图像处理
  void _updateColor(PlayQueueItem? song) {
    // Hero 和页面淡入尚未结束时只绘制纯色背景；封面解码、调色板
    // 提取与全屏模糊都错峰到转场完成后。
    if (!_routeTransitionComplete || song == null) return;
    final id = '${song.platform}_${song.id}';
    if (id == _lastColorSongId) return;
    _lastColorSongId = id;
    if (_dominantColor != null && mounted) {
      setState(() => _dominantColor = null);
    }
    final cover = song.coverUrl;
    if (cover == null || cover.isEmpty) {
      if (_dominantColor != null) setState(() => _dominantColor = null);
      return;
    }
    extractDominantColor(
      cover,
      fallbackImageUrl: CoverProxy.toProxy(cover),
    ).then((color) {
      if (mounted && color != null && id == _lastColorSongId) {
        setState(() => _dominantColor = color);
      }
    });
  }

  void _scrollToLyric(PlayerProvider player) {
    if (!_lyricsAutoScroll) return;
    final index = player.currentLyricIndex;
    final song = player.currentSong;
    final songKey = song == null ? null : '${song.platform.code}:${song.id}';
    if (!_forceLyricRecenter &&
        _lastAutoScrollSongKey == songKey &&
        _lastAutoScrollLyricIndex == index) {
      return;
    }
    if (!_lyricScrollController.hasClients) return;
    final position = _lyricScrollController.position;
    final target = (index * _lyricLineExtent).clamp(
      0.0,
      position.maxScrollExtent,
    );
    _lastAutoScrollSongKey = songKey;
    _lastAutoScrollLyricIndex = index;
    final forceRecenter = _forceLyricRecenter;
    _forceLyricRecenter = false;

    final distance = (position.pixels - target).abs();
    if (forceRecenter || distance > _lyricLineExtent * 4) {
      // 初次打开或跨越多行跳转时直接定位，避免从列表顶部长距离飞过。
      position.jumpTo(target);
      return;
    }
    if (distance < 0.5) return;
    // 相邻歌词使用与参考播放器一致的纵向滑行动画；新动画会平滑接管
    // 上一行尚未结束的滚动，快歌下也不会堆积动画队列。
    final duration = AppMotion.resolve(
      context,
      const Duration(milliseconds: 300),
    );
    if (duration == Duration.zero) {
      position.jumpTo(target);
      return;
    }
    unawaited(
      position
          .animateTo(target, duration: duration, curve: Curves.easeOutCubic)
          .catchError((_) {}),
    );
  }

  void _openScopedSearch(
    BuildContext context,
    PlayerProvider player,
    PlayQueueItem song,
    SearchSubject subject,
  ) {
    final keyword = switch (subject) {
      SearchSubject.title => song.name,
      SearchSubject.artist => song.artist,
      SearchSubject.album => song.album,
      SearchSubject.general => song.name,
    }.trim();
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

  Future<void> _openMusicVideo(
    BuildContext context,
    PlayerProvider player,
    PlayQueueItem song,
  ) async {
    if (_mvOpening) return;
    setState(() => _mvOpening = true);
    try {
      final url = song.platform == MusicPlatform.bilibili
          ? await player.currentBilibiliVideoUrl()
          : await player.api.musicVideoUrl(
              platform: song.platform,
              songId: song.id,
              songName: song.name,
              artist: song.artist,
            );
      if (!context.mounted) return;
      if (player.isPlaying) await player.pause();
      if (!context.mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => VideoPlayerScreen(
            url: url,
            title: song.name,
            artist: song.artist,
            platform: song.platform,
            mode: player.videoPlayerMode,
          ),
        ),
      );
    } catch (error) {
      if (!context.mounted) return;
      final message = error is ApiException
          ? error.message
          : song.platform == MusicPlatform.bilibili
          ? error.toString()
          : 'MV 加载失败，请稍后重试';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _mvOpening = false);
    }
  }

  Future<void> _openLyricSearch(
    BuildContext context,
    PlayerProvider player,
    PlayQueueItem song,
  ) async {
    if (_lyricSearchDialogOpen) return;
    _lyricSearchDialogOpen = true;
    try {
      final selected = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _LyricSearchDialog(player: player, song: song),
      );
      if (!context.mounted || selected == null) return;
      setState(() => _lyricsAutoScroll = true);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已使用《$selected》的歌词')));
    } finally {
      _lyricSearchDialogOpen = false;
    }
  }

  bool _isSearchableMetadata(String value) {
    final normalized = value.trim();
    return normalized.isNotEmpty &&
        normalized != '未知歌曲' &&
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
    if (!_isSearchableMetadata(song.name)) return text;
    return Tooltip(
      message: '搜索歌曲 ${song.name}',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: const ValueKey('player-song-search'),
          onTap: () =>
              _openScopedSearch(context, player, song, SearchSubject.title),
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
              ? 52.0
              : (layout.isCompactLandscape ? 28.0 : 42.0))
        : 42.0;
    final hasArtist = _isSearchableMetadata(song.artist);
    final hasAlbum = _isSearchableMetadata(song.album);
    final artistText = Text(
      song.artist,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(color: color, fontSize: fontSize),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: centered
          ? MainAxisAlignment.center
          : MainAxisAlignment.start,
      children: [
        Flexible(
          child: hasArtist
              ? Tooltip(
                  message: '搜索 ${song.artist} 的歌曲',
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      key: const ValueKey('player-artist-search'),
                      onTap: () => _openScopedSearch(
                        context,
                        player,
                        song,
                        SearchSubject.artist,
                      ),
                      borderRadius: BorderRadius.circular(AppRadius.small),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(minHeight: minHitHeight),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Align(
                            alignment: Alignment.center,
                            child: artistText,
                          ),
                        ),
                      ),
                    ),
                  ),
                )
              : artistText,
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
    return RepaintBoundary(
      key: ValueKey(
        _routeTransitionComplete
            ? 'player-background-ready'
            : 'player-background-deferred',
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: baseColor.withValues(alpha: 0.34)),
          if (_routeTransitionComplete && cover != null && cover.isNotEmpty)
            Positioned.fill(
              key: ValueKey(
                'player-background-cover-${song.platform.code}:${song.id}',
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // Blur a small off-screen surface and let the compositor
                  // upscale the finished layer. Applying ImageFiltered to the
                  // full 1920x1080 canvas was the largest player paint spike.
                  const maximumBlurSurfaceSide = 360.0;
                  final longestSide = constraints.biggest.longestSide;
                  final scale = longestSide > maximumBlurSurfaceSide
                      ? longestSide / maximumBlurSurfaceSide
                      : 1.0;
                  final surfaceWidth = constraints.maxWidth / scale;
                  final surfaceHeight = constraints.maxHeight / scale;
                  final localSigma = 34 / scale;
                  return FittedBox(
                    fit: BoxFit.fill,
                    child: SizedBox(
                      width: surfaceWidth,
                      height: surfaceHeight,
                      child: ImageFiltered(
                        imageFilter: ui.ImageFilter.blur(
                          sigmaX: localSigma,
                          sigmaY: localSigma,
                        ),
                        child: Transform.scale(
                          scale: 1.12,
                          child: SmartCover(
                            url: cover,
                            fit: BoxFit.cover,
                            maxDecodeWidth: maximumBlurSurfaceSide.round(),
                            placeholder: () => ColoredBox(
                              color: baseColor.withValues(alpha: 0.28),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
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
      ),
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
        final largeHeightFactor = layout.isHighDensityCarDisplay ? 0.27 : 0.44;
        final heightLimit =
            constraints.maxHeight *
            (largeUi ? largeHeightFactor : (compactHeight ? 0.24 : 0.54));
        final rawCoverSize = widthLimit < heightLimit
            ? widthLimit
            : heightLimit;
        final coverSize = rawCoverSize.clamp(
          layout.isHighDensityCarDisplay
              ? 128.0
              : (compactHeight ? 72.0 : 160.0),
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
    return Hero(
      tag: playerCoverHeroTag(song.platform, song.id),
      transitionOnUserGestures: true,
      child: Container(
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
          child: AnimatedSwitcher(
            duration: _routeTransitionComplete
                ? AppMotion.resolve(context, AppMotion.page)
                : Duration.zero,
            child: SizedBox.expand(
              key: ValueKey('landscape-cover-${song.platform.code}:${song.id}'),
              child: song.coverUrl != null && song.coverUrl!.isNotEmpty
                  ? SmartCover(
                      url: song.coverUrl,
                      fit: BoxFit.cover,
                      placeholder: () =>
                          _buildDefaultCover(song, compact: true),
                    )
                  : _buildDefaultCover(song, compact: true),
            ),
          ),
        ),
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
            2,
            largeUi ? 14 : 16,
            0,
          ),
          child: AppMotionSwitcher(
            beginOffset: const Offset(0, 0.04),
            child: Column(
              key: ValueKey(
                'landscape-song-info-${song.platform.code}:${song.id}',
              ),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: double.infinity,
                      child: _buildSongNameLink(
                        ctx,
                        player,
                        song,
                        textColor,
                        fontSize: largeUi
                            ? 27
                            : (layout.isCompactLandscape ? 18 : 20),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    if (selection.$1)
                      Positioned(
                        right: 0,
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
                const SizedBox(height: 3),
                _buildArtistAlbumLine(
                  ctx,
                  player,
                  song,
                  subColor,
                  fontSize: largeUi
                      ? 20
                      : (layout.isCompactLandscape ? 15 : 17),
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
        );
      },
    );
  }

  Widget _buildLandscapeLyrics(
    BuildContext ctx,
    PlayerProvider player,
    Color textColor,
  ) {
    return Selector<PlayerProvider, (int, int, bool, Duration, String?)>(
      selector: (_, p) {
        final song = p.currentSong;
        return (
          p.lyrics.length,
          p.currentLyricIndex,
          p.lyricsLoading,
          p.position,
          song == null ? null : '${song.platform.code}:${song.id}',
        );
      },
      builder: (ctx, selection, _) {
        if (selection.$1 > 0) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _scrollToLyric(player);
          });
        }
        return _buildLyricPane(
          ctx,
          player,
          textColor,
          landscape: true,
          toggleOnTap: false,
        );
      },
    );
  }

  Widget _buildLyricPane(
    BuildContext ctx,
    PlayerProvider player,
    Color textColor, {
    required bool landscape,
    bool toggleOnTap = true,
  }) {
    final song = player.currentSong;
    if (song?.platform == MusicPlatform.bilibili) {
      return _buildBilibiliInfoPane(
        ctx,
        player,
        song!,
        textColor,
        landscape: landscape,
      );
    }
    final lyricStateKey = player.lyrics.isNotEmpty
        ? 'content'
        : player.lyricsLoading
        ? 'loading'
        : 'empty';
    return RepaintBoundary(
      key: const ValueKey('player-lyric-repaint-boundary'),
      child: Stack(
        children: [
          Positioned.fill(
            child: AppMotionSwitcher(
              child: KeyedSubtree(
                key: ValueKey('player-lyrics-$lyricStateKey'),
                child: _buildLyricView(
                  ctx,
                  player,
                  textColor,
                  landscape: landscape,
                  toggleOnTap: toggleOnTap,
                ),
              ),
            ),
          ),
          if (song != null)
            Positioned(
              top: landscape ? 0 : 6,
              right: landscape ? 0 : 8,
              child: IconButton(
                key: const ValueKey('player-lyric-search-action'),
                tooltip: '查找歌词',
                onPressed: () => _openLyricSearch(ctx, player, song),
                icon: Icon(Icons.manage_search_rounded, color: textColor),
                iconSize: landscape ? 30 : 28,
                style: IconButton.styleFrom(
                  minimumSize: Size.square(landscape ? 48 : 44),
                  backgroundColor: Colors.black.withValues(alpha: 0.12),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBilibiliInfoPane(
    BuildContext ctx,
    PlayerProvider player,
    PlayQueueItem song,
    Color textColor, {
    required bool landscape,
  }) {
    final subColor = textColor.withValues(alpha: 0.7);
    final pages = song.bilibiliPages;
    final currentPageIndex = pages.indexWhere(
      (page) => page.cid == song.bilibiliCid,
    );
    final audioLabel = _bilibiliQualityLabel(
      player.bilibiliAudioQualities,
      player.bilibiliAudioQuality,
      fallback: '自动',
    );
    final videoLabel = _bilibiliQualityLabel(
      player.bilibiliVideoQualities,
      player.bilibiliVideoQuality,
      fallback: '自动',
    );
    return RepaintBoundary(
      key: const ValueKey('bilibili-info-pane'),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          landscape ? 12 : 20,
          landscape ? 4 : 12,
          landscape ? 12 : 20,
          landscape ? 12 : 24,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '视频信息',
                    style: TextStyle(
                      color: textColor,
                      fontSize: landscape ? 22 : 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  key: const ValueKey('bilibili-quality-action'),
                  tooltip: '音频和视频清晰度',
                  onPressed: () => _showBilibiliQualityDialog(ctx, player),
                  icon: Icon(Icons.tune_rounded, color: textColor),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              song.bilibiliVideoTitle ?? song.album,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: textColor,
                fontSize: landscape ? 17 : 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            _buildBilibiliSectionTitle(
              '分P',
              pages.isEmpty ? '加载中' : '${pages.length} P',
              textColor,
              subColor,
            ),
            const SizedBox(height: 6),
            if (pages.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Center(
                  child: SizedBox.square(
                    dimension: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: PlatformColors.bilibili,
                    ),
                  ),
                ),
              )
            else
              ...pages.indexed.map((entry) {
                final index = entry.$1;
                final page = entry.$2;
                final selected = index == currentPageIndex;
                return ListTile(
                  key: ValueKey('bilibili-page-${page.cid}'),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                  dense: landscape,
                  selected: selected,
                  selectedColor: PlatformColors.bilibili,
                  leading: SizedBox(
                    width: 42,
                    child: Text(
                      'P${page.page}',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: selected ? PlatformColors.bilibili : subColor,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  title: Text(
                    page.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: selected ? null : textColor),
                  ),
                  trailing: page.duration == null
                      ? null
                      : Text(
                          _formatDuration(Duration(seconds: page.duration!)),
                          style: TextStyle(color: subColor),
                        ),
                  onTap: selected
                      ? null
                      : () => player.selectBilibiliPage(index),
                );
              }),
            const SizedBox(height: 14),
            _buildBilibiliSectionTitle('清晰度', null, textColor, subColor),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  key: const ValueKey('bilibili-audio-quality-action'),
                  onPressed: () => _showBilibiliQualityDialog(ctx, player),
                  icon: const Icon(Icons.graphic_eq_rounded),
                  label: Text('音频 $audioLabel'),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('bilibili-video-quality-action'),
                  onPressed: () => _showBilibiliQualityDialog(ctx, player),
                  icon: const Icon(Icons.ondemand_video_rounded),
                  label: Text('视频 $videoLabel'),
                ),
              ],
            ),
            const SizedBox(height: 18),
            _buildBilibiliSectionTitle('视频简介', null, textColor, subColor),
            const SizedBox(height: 8),
            SelectableText(
              song.bilibiliDescription?.trim().isNotEmpty == true
                  ? song.bilibiliDescription!.trim()
                  : '暂无简介',
              style: TextStyle(color: subColor, height: 1.55),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBilibiliSectionTitle(
    String title,
    String? trailing,
    Color textColor,
    Color subColor,
  ) {
    return Row(
      children: [
        Container(
          width: 4,
          height: 18,
          decoration: BoxDecoration(
            color: PlatformColors.bilibili,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            style: TextStyle(color: textColor, fontWeight: FontWeight.w700),
          ),
        ),
        if (trailing != null) Text(trailing, style: TextStyle(color: subColor)),
      ],
    );
  }

  String _bilibiliQualityLabel(
    List<BilibiliStream> streams,
    int quality, {
    required String fallback,
  }) {
    for (final stream in streams) {
      if (stream.quality == quality) return stream.label;
    }
    return streams.isEmpty ? fallback : streams.first.label;
  }

  Future<void> _showBilibiliQualityDialog(
    BuildContext context,
    PlayerProvider player,
  ) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => Consumer<PlayerProvider>(
        builder: (context, current, _) {
          return AlertDialog(
            key: const ValueKey('bilibili-quality-dialog'),
            title: const Text('B站播放清晰度'),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460, maxHeight: 480),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildBilibiliQualityGroup(
                      title: '音频',
                      emptyText: '音频流加载后显示可选音质',
                      streams: current.bilibiliAudioQualities,
                      selectedQuality: current.bilibiliAudioQuality,
                      onSelected: current.setBilibiliAudioQuality,
                    ),
                    const Divider(height: 28),
                    _buildBilibiliQualityGroup(
                      title: '视频',
                      emptyText: '视频流加载后显示可选清晰度',
                      streams: current.bilibiliVideoQualities,
                      selectedQuality: current.bilibiliVideoQuality,
                      onSelected: current.setBilibiliVideoQuality,
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('完成'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildBilibiliQualityGroup({
    required String title,
    required String emptyText,
    required List<BilibiliStream> streams,
    required int selectedQuality,
    required Future<void> Function(int quality) onSelected,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        if (streams.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              emptyText,
              style: TextStyle(color: AppColors.textSecondary),
            ),
          )
        else
          ...streams.map((stream) {
            final selected = stream.quality == selectedQuality;
            return ListTile(
              key: ValueKey('$title-quality-${stream.quality}'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(stream.label),
              subtitle: stream.bandwidth <= 0
                  ? null
                  : Text('${(stream.bandwidth / 1000).round()} kbps'),
              trailing: Icon(
                selected ? Icons.check_circle_rounded : Icons.circle_outlined,
                color: selected
                    ? PlatformColors.bilibili
                    : AppColors.textSecondary,
              ),
              onTap: selected
                  ? null
                  : () => unawaited(onSelected(stream.quality)),
            );
          }),
      ],
    );
  }

  Widget _buildLyricFontControlButton(
    Color color, {
    required double width,
    required double height,
    required double iconSize,
  }) {
    return SizedBox(
      key: const ValueKey('player-lyric-font-action'),
      width: width,
      height: height,
      child: IconButton(
        tooltip: '歌词字号和间距',
        padding: EdgeInsets.zero,
        onPressed: () => showDialog<void>(
          context: context,
          builder: (_) => _LyricDisplaySettingsDialog(
            fontSize: _lyricFontSize,
            lineSpacing: _lyricLineSpacing,
            fontSizes: _lyricFontSizes,
            onFontSizeChanged: _selectLyricFontSize,
            onLineSpacingChanged: _previewLyricLineSpacing,
            onLineSpacingChangeEnd: _commitLyricLineSpacing,
          ),
        ),
        icon: Icon(Icons.format_size_rounded, color: color, size: iconSize),
      ),
    );
  }

  Widget _buildPlayerVisual(
    BuildContext ctx,
    PlayerProvider player,
    PlayQueueItem song,
    Color baseColor,
    Color textColor, {
    bool landscape = false,
  }) {
    return Selector<PlayerProvider, (bool, int, int, bool, Duration, String?)>(
      selector: (_, p) {
        final song = p.currentSong;
        return (
          p.showLyric,
          p.currentLyricIndex,
          p.lyrics.length,
          p.lyricsLoading,
          p.showLyric ? p.position : Duration.zero,
          song == null ? null : '${song.platform.code}:${song.id}',
        );
      },
      builder: (ctx, sel, _) {
        if (sel.$1) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _scrollToLyric(player);
          });
          return _buildLyricPane(ctx, player, textColor, landscape: landscape);
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
            child: Hero(
              tag: playerCoverHeroTag(song.platform, song.id),
              transitionOnUserGestures: true,
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
                  child: AnimatedSwitcher(
                    duration: _routeTransitionComplete
                        ? AppMotion.resolve(ctx, AppMotion.page)
                        : Duration.zero,
                    child: SizedBox.expand(
                      key: ValueKey(
                        'player-cover-${song.platform.code}:${song.id}',
                      ),
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
        final lineExtent = (scaledFontSize + _lyricLineSpacing).clamp(
          52.0,
          scaledFontSize + _maximumLyricLineSpacing,
        );
        _lyricLineExtent = lineExtent;
        final centerPadding = availableHeight > lineExtent
            ? (availableHeight - lineExtent) / 2
            : 0.0;
        return GestureDetector(
          onTap: toggleOnTap ? () => player.toggleShowLyric() : null,
          onVerticalDragUpdate: (_) =>
              setState(() => _lyricsAutoScroll = false),
          child: ListView.builder(
            key: const ValueKey('player-lyric-list'),
            controller: _lyricScrollController,
            padding: EdgeInsets.symmetric(
              vertical: centerPadding,
              horizontal: landscape ? (largeUi ? 44 : 28) : 32,
            ),
            itemCount: player.lyrics.length,
            itemBuilder: (ctx, i) {
              final lyric = player.lyrics[i];
              final isCurrent = i == player.currentLyricIndex;
              final fallbackEnd = i + 1 < player.lyrics.length
                  ? player.lyrics[i + 1].time
                  : player.duration > lyric.time
                  ? player.duration
                  : null;
              final progress = isCurrent
                  ? lyric.progressAt(player.position, fallbackEnd: fallbackEnd)
                  : 0.0;
              final inactiveFontSize = (_lyricFontSize * 0.82).clamp(
                20.0,
                52.0,
              );
              return GestureDetector(
                onTap: () {
                  player.seekTo(lyric.time);
                  setState(() {
                    _lyricsAutoScroll = true;
                    _lastAutoScrollLyricIndex = null;
                  });
                },
                child: SizedBox(
                  key: ValueKey('lyric-line-$i'),
                  height: lineExtent,
                  child: Align(
                    alignment: Alignment.center,
                    child: SizedBox(
                      width: double.infinity,
                      child: _AnimatedLyricLineText(
                        index: i,
                        text: lyric.primaryText,
                        isCurrent: isCurrent,
                        wordTimingReliable: lyric.hasReliableWordTiming,
                        progress: progress,
                        currentFontSize: _lyricFontSize,
                        inactiveFontSize: inactiveFontSize,
                        playedColor: textColor,
                        unplayedColor: textColor.withValues(alpha: 0.42),
                        inactiveColor: textColor.withValues(
                          alpha: i < player.currentLyricIndex ? 0.62 : 0.48,
                        ),
                        fontFamily: _lyricFontFamily,
                        fontWeight: _lyricFontWeight,
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
          child: AppMotionSwitcher(
            beginOffset: const Offset(0, 0.04),
            child: Column(
              key: ValueKey(
                'portrait-song-info-${song.platform.code}:${song.id}',
              ),
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
                  fontSize: largeUi ? 20 : (compact ? 17 : 18),
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
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
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
    return RepaintBoundary(
      key: const ValueKey('player-progress-repaint-boundary'),
      child: Selector<PlayerProvider, (Duration, Duration)>(
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
      ),
    );
  }

  Widget _buildControls(
    BuildContext ctx,
    PlayerProvider player,
    Color textColor, {
    bool compact = false,
    bool landscape = false,
  }) {
    // 仅监听播放状态和模式，避免随播放进度重建
    return Selector<PlayerProvider, (bool, PlayMode)>(
      selector: (_, p) => (p.isPlaying, p.playMode),
      builder: (ctx, sel, _) {
        final isPlaying = sel.$1;
        final playMode = sel.$2;
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
                key: const ValueKey('player-next-track'),
                constraints: BoxConstraints.tightFor(
                  width: iconButtonWidth,
                  height: iconButtonHeight,
                ),
                padding: EdgeInsets.zero,
                tooltip: '播放模式',
                icon: AppAnimatedIcon(
                  stateKey: playMode,
                  child: Icon(
                    playMode == PlayMode.sequence
                        ? Icons.repeat_rounded
                        : playMode == PlayMode.repeat
                        ? Icons.repeat_one_rounded
                        : Icons.shuffle_rounded,
                    color: textColor,
                    size: largeUi ? 28 : (compact ? 22 : 28),
                  ),
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
                  icon: AppAnimatedIcon(
                    stateKey: isPlaying,
                    child: Icon(
                      isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: largeUi ? 38 : (compact ? 32 : 42),
                    ),
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
              if (player.currentSong?.platform == MusicPlatform.bilibili)
                SizedBox(
                  key: const ValueKey('player-bilibili-quality-control'),
                  width: iconButtonWidth,
                  height: iconButtonHeight,
                  child: IconButton(
                    tooltip: '音频和视频清晰度',
                    padding: EdgeInsets.zero,
                    onPressed: () => _showBilibiliQualityDialog(ctx, player),
                    icon: Icon(
                      Icons.tune_rounded,
                      color: textColor,
                      size: largeUi ? 30 : (compact ? 24 : 28),
                    ),
                  ),
                )
              else
                // 字号只保留图标，紧跟在下一首右侧。
                _buildLyricFontControlButton(
                  textColor,
                  width: iconButtonWidth,
                  height: iconButtonHeight,
                  iconSize: largeUi ? 30 : (compact ? 24 : 28),
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
    bool landscape = false,
  }) {
    // 收藏状态跟随 FavoriteService（点击收藏/取消收藏实时刷新）
    final fav = ctx.watch<FavoriteService>();
    final song = player.currentSong;
    final isBilibili = song?.platform == MusicPlatform.bilibili;
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
                    icon: isBilibili
                        ? Icons.video_library_outlined
                        : Icons.text_snippet_rounded,
                    label: isBilibili ? '视频信息' : '歌词',
                    color: showLyric ? AppColors.primary : subColor,
                  ),
                ),
              Expanded(
                child: _playerActionButton(
                  key: const ValueKey('player-mv-action'),
                  context: ctx,
                  compact: compact,
                  onPressed: song == null || _mvOpening
                      ? null
                      : () => _openMusicVideo(ctx, player, song),
                  icon: Icons.ondemand_video_rounded,
                  label: 'MV',
                  color: subColor,
                ),
              ),
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
                  animationKey: isFav,
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

  Widget _playerActionButton({
    Key? key,
    required BuildContext context,
    required bool compact,
    required VoidCallback? onPressed,
    required IconData icon,
    required String label,
    required Color color,
    Object? animationKey,
  }) {
    final layout = AppLayout.fromContext(context);
    final largeUi = layout.usesLargeTypography;
    final height = largeUi ? 54.0 : (compact ? 36.0 : 50.0);
    final iconSize = largeUi ? 24.0 : (compact ? 18.0 : 22.0);
    final fontSize = largeUi ? 16.0 : (compact ? 13.0 : 16.0);
    return Tooltip(
      key: key,
      message: label == '队列' ? '播放队列' : label,
      child: TextButton.icon(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          padding: EdgeInsets.symmetric(horizontal: largeUi ? 4 : 2),
          minimumSize: Size(0, height),
          tapTargetSize: MaterialTapTargetSize.padded,
        ),
        icon: animationKey == null
            ? Icon(icon, color: color, size: iconSize)
            : AppAnimatedIcon(
                stateKey: animationKey,
                child: Icon(icon, color: color, size: iconSize),
              ),
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
      showGeneralDialog<void>(
        context: ctx,
        barrierDismissible: true,
        barrierLabel: '关闭播放队列',
        barrierColor: Colors.black54,
        transitionDuration: AppMotion.resolve(ctx, AppMotion.page),
        pageBuilder: (dialogCtx, _, _) {
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
        transitionBuilder: (_, animation, _, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: AppMotion.enterCurve,
            reverseCurve: AppMotion.exitCurve,
          );
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0.08, 0),
                end: Offset.zero,
              ).animate(curved),
              child: child,
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
