import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../services/favorite_service.dart';
import '../theme/app_layout.dart';
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
  }) : assert(!selectionMode || onSelectionChanged != null);

  @override
  Widget build(BuildContext context) {
    AppColors.syncWithTheme(context);
    final playerState = context
        .select<PlayerProvider, (String?, MusicPlatform?, bool)>(
          (player) => (
            player.currentSong?.id,
            player.currentSong?.platform,
            player.isPlaying,
          ),
        );
    final isCurrent =
        playerState.$1 == song.id && playerState.$2 == song.platform;
    final platformColor = PlatformColors.of(song.platform);
    final layout = AppLayout.fromContext(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final veryCompact = constraints.maxWidth < 180;
        final narrowPane = constraints.maxWidth < 380;
        final coverSize = layout.songCoverSize;
        final actionIconSize = layout.usesLargeTypography ? 26.0 : 22.0;
        return ListTile(
          minTileHeight: layout.songRowHeight,
          tileColor: isCurrent
              ? AppColors.primarySoft.withValues(alpha: 0.72)
              : Colors.transparent,
          selectedTileColor: AppColors.primarySoft,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.card),
          ),
          contentPadding: EdgeInsets.symmetric(
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
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isCurrent
                        ? AppColors.primary
                        : AppColors.textPrimary,
                    fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
                    fontSize: layout.songTitleSize,
                    height: 1.25,
                  ),
                ),
              ),
              if (isCurrent && playerState.$3) ...[
                const SizedBox(width: 8),
                _PlayingIndicator(color: AppColors.primary),
              ],
            ],
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              '${song.artist} · ${song.album}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: layout.songSubtitleSize,
                height: 1.25,
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
                      Consumer<FavoriteService>(
                        builder: (ctx, fav, _) {
                          final isFav = fav.isFavorite(song.platform, song.id);
                          return IconButton(
                            tooltip: isFav ? '取消收藏' : '收藏',
                            icon: Icon(
                              isFav ? Icons.favorite : Icons.favorite_border,
                              size: actionIconSize,
                              color: isFav
                                  ? Colors.redAccent
                                  : AppColors.textHint,
                            ),
                            onPressed: () {
                              fav.toggle(song);
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

/// 播放中的音波动画指示器
class _PlayingIndicator extends StatefulWidget {
  final Color color;
  const _PlayingIndicator({required this.color});

  @override
  State<_PlayingIndicator> createState() => _PlayingIndicatorState();
}

class _PlayingIndicatorState extends State<_PlayingIndicator>
    with TickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (_, child) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final delay = i * 0.2;
            final value = ((_controller.value + delay) % 1.0);
            final height = 3.0 + (value * 9);
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 1),
              width: 3,
              height: height,
              decoration: BoxDecoration(
                color: widget.color,
                borderRadius: BorderRadius.circular(1.5),
              ),
            );
          }),
        );
      },
    );
  }
}
