import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../screens/player_screen.dart';
import '../services/favorite_service.dart';
import '../theme/app_layout.dart';
import '../theme/app_motion.dart';
import '../theme/app_theme.dart';
import 'cover_hero_tags.dart';
import 'smart_cover.dart';

/// 迷你播放器（底部悬浮圆角卡片）
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    AppColors.syncWithTheme(context);
    return Selector<PlayerProvider, PlayQueueItem?>(
      selector: (_, player) => player.currentSong,
      builder: (ctx, song, _) => AppMotionSwitcher(
        alignment: Alignment.bottomCenter,
        child: song == null
            ? const SizedBox.shrink(key: ValueKey('mini-player-empty'))
            : _buildPlayerCard(ctx, song),
      ),
    );
  }

  Widget _buildPlayerCard(BuildContext context, PlayQueueItem song) {
    final platformColor = PlatformColors.of(song.platform);
    final layout = AppLayout.fromContext(context);
    final compact = layout.isCompactLandscape;
    final coverSize = layout.songCoverSize;
    final songKey = '${song.platform.code}:${song.id}';

    return GestureDetector(
      key: ValueKey('mini-player-$songKey'),
      onTap: () => Navigator.push(context, PlayerScreen.route(context)),
      child: Container(
        margin: EdgeInsets.fromLTRB(
          compact ? 8 : 12,
          compact ? 2 : 4,
          compact ? 8 : 12,
          compact ? 3 : 6,
        ),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: AppColors.outline),
          boxShadow: [
            BoxShadow(
              color: AppColors.cardShadow,
              blurRadius: 14,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _MiniProgressBar(platformColor: platformColor),
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 10 : 12,
                vertical: compact ? 5 : 8,
              ),
              child: Row(
                children: [
                  Hero(
                    tag: playerCoverHeroTag(song.platform, song.id),
                    transitionOnUserGestures: true,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadius.media),
                      child: SizedBox(
                        width: coverSize,
                        height: coverSize,
                        child:
                            song.coverUrl != null && song.coverUrl!.isNotEmpty
                            ? SmartCover(
                                url: song.coverUrl,
                                fit: BoxFit.cover,
                                placeholder: () =>
                                    _defaultCover(song, platformColor),
                              )
                            : _defaultCover(song, platformColor),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          song.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: layout.songTitleSize,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${song.platform.label} · ${song.artist}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: layout.songSubtitleSize,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _MiniPlaybackControls(
                    loading: song.loading,
                    compact: compact,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _defaultCover(PlayQueueItem song, Color platformColor) {
    return Container(
      color: platformColor.withOpacity(0.12),
      child: Icon(Icons.music_note, size: 20, color: platformColor),
    );
  }
}

class _MiniProgressBar extends StatelessWidget {
  final Color platformColor;

  const _MiniProgressBar({required this.platformColor});

  @override
  Widget build(BuildContext context) {
    return Selector<PlayerProvider, (Duration, Duration)>(
      selector: (_, player) => (player.position, player.duration),
      builder: (context, value, _) {
        final durationMs = value.$2.inMilliseconds;
        final progress = durationMs > 0
            ? value.$1.inMilliseconds / durationMs
            : 0.0;
        return RepaintBoundary(
          key: const ValueKey('mini-player-progress-repaint-boundary'),
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(AppRadius.card),
            ),
            child: LinearProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              minHeight: 3,
              backgroundColor: AppColors.primarySoft,
              valueColor: AlwaysStoppedAnimation<Color>(platformColor),
            ),
          ),
        );
      },
    );
  }
}

class _MiniPlaybackControls extends StatelessWidget {
  final bool loading;
  final bool compact;

  const _MiniPlaybackControls({required this.loading, required this.compact});

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerProvider>();
    return Selector<PlayerProvider, bool>(
      selector: (_, player) => player.isPlaying,
      builder: (context, isPlaying, _) => AppMotionSwitcher(
        beginOffset: Offset.zero,
        child: loading
            ? SizedBox(
                key: const ValueKey('mini-player-loading'),
                width: 40,
                height: 40,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: AppColors.primary,
                  ),
                ),
              )
            : Row(
                key: const ValueKey('mini-player-controls'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: isPlaying ? '暂停' : '播放',
                    icon: AppAnimatedIcon(
                      stateKey: isPlaying,
                      child: Icon(
                        isPlaying
                            ? Icons.pause_circle_filled
                            : Icons.play_circle_fill,
                        size: compact ? 36 : 40,
                        color: AppColors.primary,
                      ),
                    ),
                    onPressed: player.playPause,
                  ),
                  IconButton(
                    tooltip: '下一首',
                    icon: Icon(
                      Icons.skip_next_rounded,
                      size: compact ? 26 : 30,
                      color: AppColors.textPrimary,
                    ),
                    onPressed: player.playNext,
                  ),
                ],
              ),
      ),
    );
  }
}

/// 横屏宽布局中的常驻播放侧栏。
class LandscapeMiniPlayer extends StatelessWidget {
  const LandscapeMiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    AppColors.syncWithTheme(context);
    return Selector<PlayerProvider, PlayQueueItem?>(
      selector: (_, player) => player.currentSong,
      builder: (ctx, song, _) {
        if (song == null) return const SizedBox.shrink();

        final platformColor = PlatformColors.of(song.platform);
        final player = ctx.read<PlayerProvider>();

        return AppMotionSwitcher(
          child: LayoutBuilder(
            key: ValueKey(
              'landscape-mini-player-${song.platform.code}:${song.id}',
            ),
            builder: (context, constraints) {
              final compactHeight = constraints.maxHeight < 480;
              final coverSize = compactHeight
                  ? 92.0
                  : (constraints.maxWidth >= 280 ? 164.0 : 148.0);
              return Material(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(AppRadius.panel),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => Navigator.push(ctx, PlayerScreen.route(ctx)),
                  child: SafeArea(
                    left: false,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        compactHeight ? 14 : 20,
                        compactHeight ? 10 : 20,
                        compactHeight ? 14 : 20,
                        compactHeight ? 8 : 16,
                      ),
                      child: Column(
                        children: [
                          const Spacer(),
                          Hero(
                            tag: playerCoverHeroTag(song.platform, song.id),
                            transitionOnUserGestures: true,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(
                                AppRadius.media,
                              ),
                              child: SizedBox(
                                width: coverSize,
                                height: coverSize,
                                child:
                                    song.coverUrl != null &&
                                        song.coverUrl!.isNotEmpty
                                    ? SmartCover(
                                        url: song.coverUrl,
                                        fit: BoxFit.cover,
                                        placeholder: () =>
                                            _landscapeDefaultCover(
                                              song,
                                              platformColor,
                                            ),
                                      )
                                    : _landscapeDefaultCover(
                                        song,
                                        platformColor,
                                      ),
                              ),
                            ),
                          ),
                          SizedBox(height: compactHeight ? 8 : 18),
                          Text(
                            song.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: compactHeight ? 18 : 23,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '${song.platform.label} · ${song.artist}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: compactHeight ? 14 : 18,
                            ),
                          ),
                          SizedBox(height: compactHeight ? 8 : 16),
                          _LandscapeMiniProgressBar(
                            platformColor: platformColor,
                          ),
                          SizedBox(height: compactHeight ? 5 : 10),
                          _LandscapeMiniControls(
                            loading: song.loading,
                            compactHeight: compactHeight,
                          ),
                          if (!compactHeight) ...[
                            const SizedBox(height: 4),
                            _LandscapePlayerActions(song: song, player: player),
                          ],
                          const _LandscapeQueuePosition(),
                          const Spacer(),
                        ],
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

  Widget _landscapeDefaultCover(PlayQueueItem song, Color platformColor) {
    return Container(
      color: platformColor.withOpacity(0.12),
      child: Icon(Icons.music_note, size: 32, color: platformColor),
    );
  }
}

class _LandscapeMiniProgressBar extends StatelessWidget {
  final Color platformColor;

  const _LandscapeMiniProgressBar({required this.platformColor});

  @override
  Widget build(BuildContext context) {
    return Selector<PlayerProvider, (Duration, Duration)>(
      selector: (_, player) => (player.position, player.duration),
      builder: (context, value, _) {
        final durationMs = value.$2.inMilliseconds;
        final progress = durationMs > 0
            ? value.$1.inMilliseconds / durationMs
            : 0.0;
        return RepaintBoundary(
          key: const ValueKey('landscape-mini-progress-repaint-boundary'),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              minHeight: 3,
              backgroundColor: AppColors.primarySoft,
              valueColor: AlwaysStoppedAnimation<Color>(platformColor),
            ),
          ),
        );
      },
    );
  }
}

class _LandscapeMiniControls extends StatelessWidget {
  final bool loading;
  final bool compactHeight;

  const _LandscapeMiniControls({
    required this.loading,
    required this.compactHeight,
  });

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerProvider>();
    return Selector<PlayerProvider, bool>(
      selector: (_, player) => player.isPlaying,
      builder: (context, isPlaying, _) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            tooltip: '上一首',
            onPressed: player.playPrevious,
            icon: Icon(
              Icons.skip_previous_rounded,
              size: compactHeight ? 24 : 30,
            ),
          ),
          AppMotionSwitcher(
            beginOffset: Offset.zero,
            child: loading
                ? SizedBox(
                    key: const ValueKey('landscape-mini-loading'),
                    width: compactHeight ? 44 : 52,
                    height: compactHeight ? 44 : 52,
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: AppColors.primary,
                      ),
                    ),
                  )
                : IconButton.filled(
                    key: const ValueKey('landscape-mini-play-control'),
                    tooltip: isPlaying ? '暂停' : '播放',
                    onPressed: player.playPause,
                    icon: AppAnimatedIcon(
                      stateKey: isPlaying,
                      child: Icon(
                        isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        size: compactHeight ? 24 : 30,
                      ),
                    ),
                  ),
          ),
          IconButton(
            tooltip: '下一首',
            onPressed: player.playNext,
            icon: Icon(Icons.skip_next_rounded, size: compactHeight ? 24 : 30),
          ),
        ],
      ),
    );
  }
}

class _LandscapeQueuePosition extends StatelessWidget {
  const _LandscapeQueuePosition();

  @override
  Widget build(BuildContext context) {
    return Selector<PlayerProvider, (int, int)>(
      selector: (_, player) => (player.currentIndex, player.queue.length),
      builder: (context, value, _) => value.$2 > 1
          ? Text(
              '${value.$1 + 1} / ${value.$2}',
              style: TextStyle(color: AppColors.textHint, fontSize: 17),
            )
          : const SizedBox.shrink(),
    );
  }
}

class _LandscapePlayerActions extends StatelessWidget {
  final PlayQueueItem song;
  final PlayerProvider player;

  const _LandscapePlayerActions({required this.song, required this.player});

  @override
  Widget build(BuildContext context) {
    AppColors.syncWithTheme(context);
    final favorites = context.watch<FavoriteService>();
    final isFavorite = favorites.isFavorite(song.platform, song.id);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          tooltip: isFavorite ? '取消收藏' : '收藏',
          onPressed: () =>
              favorites.toggle(SongSearchResult.fromQueueItem(song)),
          icon: AppAnimatedIcon(
            stateKey: isFavorite,
            child: Icon(
              isFavorite ? Icons.favorite : Icons.favorite_border,
              color: isFavorite ? Colors.redAccent : AppColors.textSecondary,
            ),
          ),
        ),
        const SizedBox(width: 10),
        IconButton(
          tooltip: '播放队列',
          onPressed: () => _showMiniQueue(context, player),
          icon: Icon(Icons.queue_music_rounded, color: AppColors.textSecondary),
        ),
      ],
    );
  }
}

void _showMiniQueue(BuildContext context, PlayerProvider player) {
  final size = MediaQuery.sizeOf(context);
  final layout = AppLayout.fromContext(context);
  showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭播放队列',
    barrierColor: Colors.black54,
    transitionDuration: AppMotion.resolve(context, AppMotion.page),
    pageBuilder: (dialogContext, _, _) => Align(
      alignment: Alignment.centerRight,
      child: SafeArea(
        left: false,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Material(
            color: AppColors.surface,
            elevation: 12,
            borderRadius: BorderRadius.circular(AppRadius.panel),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              width: (size.width * 0.36).clamp(340.0, 430.0),
              height: size.height * 0.86,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 18, 8, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '播放队列 (${player.queue.length})',
                            style: TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: layout.sectionTitleSize,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '关闭',
                          onPressed: () => Navigator.pop(dialogContext),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView.builder(
                      itemCount: player.queue.length,
                      itemBuilder: (context, index) {
                        final item = player.queue[index];
                        final current = index == player.currentIndex;
                        return ListTile(
                          minTileHeight: 64,
                          selected: current,
                          selectedTileColor: AppColors.primarySoft,
                          leading: Icon(
                            current ? Icons.graphic_eq : Icons.music_note,
                            color: current
                                ? AppColors.primary
                                : AppColors.textHint,
                          ),
                          title: Text(
                            item.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            item.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () {
                            player.playQueueItem(index);
                            Navigator.pop(dialogContext);
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
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
}
