import 'package:flutter/material.dart';

import '../models/song.dart';
import '../theme/app_layout.dart';
import '../theme/app_motion.dart';
import '../theme/app_theme.dart';
import 'cover_hero_tags.dart';
import 'smart_cover.dart';

/// 收藏歌单卡片：封面在上，歌单名和创建者在下。
class FavoritePlaylistCard extends StatelessWidget {
  final FavoritePlaylist favorite;
  final VoidCallback onTap;
  final VoidCallback onFavoritePressed;

  const FavoritePlaylistCard({
    super.key,
    required this.favorite,
    required this.onTap,
    required this.onFavoritePressed,
  });

  @override
  Widget build(BuildContext context) {
    AppColors.syncWithTheme(context);
    final layout = AppLayout.fromContext(context);
    final playlist = favorite.playlist;
    final platformColor = PlatformColors.of(favorite.platform);
    final cardWidth = layout.mediaCardWidth;
    return SizedBox(
      key: ValueKey(
        'favorite-playlist-${favorite.platform.code}-${playlist.id}',
      ),
      width: cardWidth,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.card),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Stack(
                  children: [
                    Hero(
                      tag: playlistCoverHeroTag(favorite.platform, playlist.id),
                      transitionOnUserGestures: true,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(AppRadius.media),
                        child: SizedBox.square(
                          dimension: cardWidth,
                          child:
                              playlist.coverUrl != null &&
                                  playlist.coverUrl!.isNotEmpty
                              ? SmartCover(
                                  url: playlist.coverUrl,
                                  fit: BoxFit.cover,
                                  placeholder: () =>
                                      _placeholder(platformColor),
                                )
                              : _placeholder(platformColor),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Material(
                        color: Colors.black.withValues(alpha: 0.54),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppRadius.small),
                        ),
                        child: IconButton(
                          tooltip: '取消收藏歌单',
                          visualDensity: VisualDensity.compact,
                          onPressed: onFavoritePressed,
                          icon: const AppAnimatedIcon(
                            stateKey: true,
                            child: Icon(
                              Icons.favorite_rounded,
                              color: Colors.redAccent,
                              size: 21,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  playlist.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: layout.mediaCardTitleSize,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  playlist.creator != null && playlist.creator!.isNotEmpty
                      ? '${favorite.platform.label} · ${playlist.creator}'
                      : favorite.platform.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: layout.mediaCardSubtitleSize,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _placeholder(Color platformColor) {
    return ColoredBox(
      color: platformColor.withValues(alpha: 0.14),
      child: Icon(Icons.queue_music_rounded, color: platformColor, size: 48),
    );
  }
}
