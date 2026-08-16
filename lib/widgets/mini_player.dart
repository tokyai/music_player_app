import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../screens/player_screen.dart';
import '../services/favorite_service.dart';
import '../theme/app_layout.dart';
import '../theme/app_theme.dart';
import 'smart_cover.dart';

/// 迷你播放器（底部悬浮圆角卡片）
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    AppColors.syncWithTheme(context);
    return Consumer<PlayerProvider>(
      builder: (ctx, player, _) {
        final song = player.currentSong;
        if (song == null) return const SizedBox.shrink();

        final progress = player.duration.inMilliseconds > 0
            ? player.position.inMilliseconds / player.duration.inMilliseconds
            : 0.0;
        final platformColor = PlatformColors.of(song.platform);
        final layout = AppLayout.fromContext(context);
        final compact = layout.isCompactLandscape;
        final coverSize = compact
            ? 44.0
            : (layout.usesLargeTypography ? 64.0 : 52.0);

        return GestureDetector(
          onTap: () {
            Navigator.push(
              ctx,
              MaterialPageRoute(builder: (_) => const PlayerScreen()),
            );
          },
          child: Container(
            margin: EdgeInsets.fromLTRB(
              compact ? 8 : 12,
              compact ? 2 : 4,
              compact ? 8 : 12,
              compact ? 3 : 6,
            ),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(compact ? 14 : 18),
              border: Border.all(color: AppColors.outline),
              boxShadow: [
                BoxShadow(
                  color: AppColors.cardShadow,
                  blurRadius: 14,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 进度条
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(18),
                  ),
                  child: LinearProgressIndicator(
                    value: progress.clamp(0.0, 1.0),
                    minHeight: 3,
                    backgroundColor: AppColors.primarySoft,
                    valueColor: AlwaysStoppedAnimation<Color>(platformColor),
                  ),
                ),
                // 内容区
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: compact ? 10 : 12,
                    vertical: compact ? 5 : 8,
                  ),
                  child: Row(
                    children: [
                      // 封面
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
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
                      const SizedBox(width: 12),
                      // 歌曲信息
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
                                fontSize: compact ? 15 : 16,
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
                                fontSize: compact ? 12 : 13,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // 播放控制
                      if (song.loading)
                        SizedBox(
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
                      else ...[
                        IconButton(
                          icon: Icon(
                            player.isPlaying
                                ? Icons.pause_circle_filled
                                : Icons.play_circle_fill,
                            size: compact ? 36 : 40,
                            color: AppColors.primary,
                          ),
                          onPressed: player.playPause,
                        ),
                        IconButton(
                          icon: Icon(
                            Icons.skip_next_rounded,
                            size: compact ? 26 : 30,
                            color: AppColors.textPrimary,
                          ),
                          onPressed: player.playNext,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _defaultCover(PlayQueueItem song, Color platformColor) {
    return Container(
      color: platformColor.withOpacity(0.12),
      child: Icon(Icons.music_note, size: 20, color: platformColor),
    );
  }
}

/// 横屏宽布局中的常驻播放侧栏。
class LandscapeMiniPlayer extends StatelessWidget {
  const LandscapeMiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    AppColors.syncWithTheme(context);
    return Consumer<PlayerProvider>(
      builder: (ctx, player, _) {
        final song = player.currentSong;
        if (song == null) return const SizedBox.shrink();

        final progress = player.duration.inMilliseconds > 0
            ? player.position.inMilliseconds / player.duration.inMilliseconds
            : 0.0;
        final platformColor = PlatformColors.of(song.platform);

        return LayoutBuilder(
          builder: (context, constraints) {
            final compactHeight = constraints.maxHeight < 480;
            final coverSize = compactHeight
                ? 92.0
                : (constraints.maxWidth >= 280 ? 164.0 : 148.0);
            return Material(
              color: AppColors.surface,
              child: InkWell(
                onTap: () => Navigator.push(
                  ctx,
                  MaterialPageRoute(builder: (_) => const PlayerScreen()),
                ),
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
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: SizedBox(
                            width: coverSize,
                            height: coverSize,
                            child:
                                song.coverUrl != null &&
                                    song.coverUrl!.isNotEmpty
                                ? SmartCover(
                                    url: song.coverUrl,
                                    fit: BoxFit.cover,
                                    placeholder: () => _landscapeDefaultCover(
                                      song,
                                      platformColor,
                                    ),
                                  )
                                : _landscapeDefaultCover(song, platformColor),
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
                            fontSize: compactHeight ? 16 : 18,
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
                            fontSize: compactHeight ? 13 : 14,
                          ),
                        ),
                        SizedBox(height: compactHeight ? 8 : 16),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: progress.clamp(0.0, 1.0),
                            minHeight: 3,
                            backgroundColor: AppColors.primarySoft,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              platformColor,
                            ),
                          ),
                        ),
                        SizedBox(height: compactHeight ? 5 : 10),
                        Row(
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
                            if (song.loading)
                              SizedBox(
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
                            else
                              IconButton.filled(
                                tooltip: player.isPlaying ? '暂停' : '播放',
                                onPressed: player.playPause,
                                icon: Icon(
                                  player.isPlaying
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded,
                                  size: compactHeight ? 24 : 30,
                                ),
                              ),
                            IconButton(
                              tooltip: '下一首',
                              onPressed: player.playNext,
                              icon: Icon(
                                Icons.skip_next_rounded,
                                size: compactHeight ? 24 : 30,
                              ),
                            ),
                          ],
                        ),
                        if (!compactHeight) ...[
                          const SizedBox(height: 4),
                          _LandscapePlayerActions(song: song, player: player),
                        ],
                        if (player.queue.length > 1)
                          Text(
                            '${player.currentIndex + 1} / ${player.queue.length}',
                            style: TextStyle(
                              color: AppColors.textHint,
                              fontSize: 13,
                            ),
                          ),
                        const Spacer(),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
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
          icon: Icon(
            isFavorite ? Icons.favorite : Icons.favorite_border,
            color: isFavorite ? Colors.redAccent : AppColors.textSecondary,
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
  showDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    builder: (dialogContext) => Align(
      alignment: Alignment.centerRight,
      child: SafeArea(
        left: false,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Material(
            color: AppColors.surface,
            elevation: 12,
            borderRadius: BorderRadius.circular(22),
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
                              fontSize: 20,
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
  );
}
