import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../services/favorite_service.dart';
import '../theme/app_layout.dart';
import '../theme/app_motion.dart';
import '../theme/app_theme.dart';
import 'smart_cover.dart';

/// 歌曲列表项 Widget（清新风格：圆形封面 + 平台胶囊）
class SongTile extends StatelessWidget {
  final SongSearchResult song;
  final VoidCallback onTap;
  final VoidCallback? onAddToQueue;
  final bool isPlaying;
  final bool showPlatformTag;
  final bool showFavorite;
  final bool selectionMode;
  final bool selected;
  final ValueChanged<bool>? onSelectionChanged;
  final VoidCallback? onLongPress;

  /// Uses the bordered, padded collection card treatment used by favorite
  /// playlist rows. The default keeps the existing compact song-row style.
  final bool collectionCard;

  const SongTile({
    super.key,
    required this.song,
    required this.onTap,
    this.onAddToQueue,
    this.isPlaying = false,
    this.showPlatformTag = true,
    this.showFavorite = false,
    this.selectionMode = false,
    this.selected = false,
    this.onSelectionChanged,
    this.onLongPress,
    this.collectionCard = false,
  }) : assert(!selectionMode || onSelectionChanged != null);

  @override
  Widget build(BuildContext context) {
    AppColors.syncWithTheme(context);
    final playerState = context.select<PlayerProvider, (bool, bool)>((player) {
      final current = player.currentSong;
      final isCurrent =
          current?.id == song.id && current?.platform == song.platform;
      return (isCurrent, isCurrent && player.isPlaying);
    });
    final isCurrent = playerState.$1;
    final platformColor = PlatformColors.of(song.platform);
    final layout = AppLayout.fromContext(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final veryCompact = constraints.maxWidth < 180;
        final narrowPane = constraints.maxWidth < 380;
        final coverSize = collectionCard
            ? (layout.usesLargeTypography
                  ? 88.0
                  : (layout.isCompactLandscape ? 58.0 : 72.0))
            : layout.songCoverSize;
        final actionIconSize = layout.usesLargeTypography ? 26.0 : 22.0;
        final cardPadding = collectionCard
            ? EdgeInsets.all(layout.isCompactLandscape ? 8 : 10)
            : EdgeInsets.zero;
        return Container(
          decoration: BoxDecoration(
            color: selectionMode && selected
                ? AppColors.primarySoft
                : isCurrent
                ? AppColors.primarySoft.withValues(alpha: 0.72)
                : collectionCard
                ? AppColors.surface
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: collectionCard
                ? Border.all(color: AppColors.outline)
                : null,
          ),
          padding: cardPadding,
          child: ListTile(
            minTileHeight: collectionCard ? coverSize : layout.songRowHeight,
            minVerticalPadding: collectionCard ? 0 : null,
            tileColor: Colors.transparent,
            selectedTileColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.card),
            ),
            horizontalTitleGap: collectionCard ? 12 : null,
            contentPadding: collectionCard
                ? EdgeInsets.zero
                : EdgeInsets.symmetric(
                    horizontal: veryCompact
                        ? 8
                        : (layout.usesLargeTypography ? 20 : 14),
                    vertical: layout.usesLargeTypography ? 8 : 4,
                  ),
            leading: veryCompact
                ? null
                : ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.media),
                    child: SizedBox(
                      width: coverSize,
                      height: coverSize,
                      child: song.coverUrl != null && song.coverUrl!.isNotEmpty
                          ? SmartCover(
                              url: song.coverUrl,
                              fit: BoxFit.cover,
                              placeholder: () => _placeholder(platformColor),
                            )
                          : _placeholder(platformColor),
                    ),
                  ),
            title: Row(
              children: [
                Expanded(
                  child: Text(
                    song.name,
                    maxLines: collectionCard ? 2 : 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isCurrent
                          ? AppColors.primary
                          : AppColors.textPrimary,
                      fontWeight: isCurrent
                          ? FontWeight.w700
                          : (collectionCard
                                ? FontWeight.w600
                                : FontWeight.w500),
                      fontSize: layout.songTitleSize,
                      height: collectionCard ? null : 1.25,
                    ),
                  ),
                ),
                if (playerState.$2) ...[
                  const SizedBox(width: 8),
                  _PlayingIndicator(color: AppColors.primary),
                ],
              ],
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '${song.artist} · ${song.album}',
                maxLines: collectionCard ? 2 : 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: layout.songSubtitleSize,
                  height: collectionCard ? null : 1.25,
                  color: isCurrent
                      ? AppColors.primary.withOpacity(0.7)
                      : AppColors.textSecondary,
                ),
              ),
            ),
            trailing: veryCompact
                ? null
                : selectionMode
                ? Checkbox(
                    value: selected,
                    onChanged: (value) =>
                        onSelectionChanged?.call(value ?? false),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (showFavorite)
                        Selector<FavoriteService, bool>(
                          selector: (_, favorites) =>
                              favorites.isFavorite(song.platform, song.id),
                          builder: (ctx, isFav, _) {
                            final favorites = ctx.read<FavoriteService>();
                            return IconButton(
                              tooltip: isFav ? '取消收藏' : '收藏',
                              icon: AppAnimatedIcon(
                                stateKey: isFav,
                                child: Icon(
                                  isFav
                                      ? Icons.favorite
                                      : Icons.favorite_border,
                                  size: actionIconSize,
                                  color: isFav
                                      ? Colors.redAccent
                                      : AppColors.textHint,
                                ),
                              ),
                              onPressed: () {
                                favorites.toggle(song);
                                ScaffoldMessenger.of(ctx).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      isFav
                                          ? '已取消收藏: ${song.name}'
                                          : '已收藏: ${song.name}',
                                    ),
                                    duration: const Duration(seconds: 1),
                                  ),
                                );
                              },
                            );
                          },
                        ),
                      if (showPlatformTag && !narrowPane)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: platformColor.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(
                              AppRadius.control,
                            ),
                          ),
                          child: Text(
                            song.platform.label,
                            style: TextStyle(
                              fontSize: layout.secondarySize,
                              color: platformColor,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      if (onAddToQueue != null) ...[
                        const SizedBox(width: 2),
                        PopupMenuButton<String>(
                          iconSize: actionIconSize,
                          color: AppColors.surface,
                          onSelected: (value) {
                            if (value == 'add_queue') onAddToQueue!();
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                              value: 'add_queue',
                              child: Text('添加到队列'),
                            ),
                          ],
                        ),
                      ] else
                        Icon(
                          Icons.chevron_right,
                          size: actionIconSize,
                          color: AppColors.textHint,
                        ),
                    ],
                  ),
            selected: selectionMode && selected,
            onTap: selectionMode
                ? () => onSelectionChanged?.call(!selected)
                : onTap,
            onLongPress: onLongPress,
          ),
        );
      },
    );
  }

  Widget _placeholder(Color platformColor) {
    return Container(
      color: platformColor.withOpacity(0.12),
      child: Icon(Icons.music_note, color: platformColor, size: 22),
    );
  }
}

/// 播放中的轻量静态指示器。
///
/// 列表中可能同时存在多个当前歌曲卡片，常驻逐帧音波会为每个卡片
/// 保留一个 ticker。静态图标仍能清晰表达播放状态，但不会持续占用 CPU。
class _PlayingIndicator extends StatelessWidget {
  final Color color;

  const _PlayingIndicator({required this.color});

  @override
  Widget build(BuildContext context) {
    return Icon(
      Icons.graphic_eq_rounded,
      key: const ValueKey('song-playing-indicator'),
      size: 20,
      color: color,
    );
  }
}
