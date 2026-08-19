import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../services/favorite_service.dart';
import '../theme/app_layout.dart';
import '../theme/app_motion.dart';
import '../theme/app_theme.dart';
import '../widgets/favorite_playlist_card.dart';
import '../widgets/remote_focusable.dart';
import '../widgets/song_tile.dart';
import '../widgets/smart_cover.dart';
import 'favorites_screen.dart';
import 'playlist_detail_screen.dart';

class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  List<SongSearchResult> _kugouDaily = [];

  bool _loadingKugouDaily = false;

  String? _errKugouDaily;

  @override
  void initState() {
    super.initState();
    unawaited(context.read<FavoriteService>().load());
    unawaited(_loadAll());
  }

  Future<void> _loadAll() async {
    await _loadKugouDaily();
  }

  Future<void> _loadKugouDaily() async {
    setState(() {
      _loadingKugouDaily = true;
      _errKugouDaily = null;
    });
    try {
      final list = await context.read<PlayerProvider>().api.kugouDailyRecommend(
        pagesize: 12,
      );
      if (mounted) setState(() => _kugouDaily = list);
    } catch (e) {
      if (mounted) setState(() => _errKugouDaily = e.toString());
    } finally {
      if (mounted) setState(() => _loadingKugouDaily = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    AppColors.syncWithTheme(context);
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    return Scaffold(
      body: SafeArea(
        child: isLandscape ? _buildLandscapeContent() : _buildPortraitContent(),
      ),
    );
  }

  Widget _buildPortraitContent() {
    return RefreshIndicator(
      onRefresh: _loadAll,
      color: AppColors.primary,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          _buildHeader(),
          _buildFavoritesBlock(),
          const SizedBox(height: 12),
          _buildFavoritePlaylistsBlock(),
          const SizedBox(height: 12),
          _buildBilibiliFavoritesBlock(),
          const SizedBox(height: 12),
          _buildSectionHeader('每日推荐', PlatformColors.kugou, '每天为你精选好音乐'),
          _buildAnimatedSongSection(
            _kugouDaily,
            _loadingKugouDaily,
            _errKugouDaily,
            onRetry: _loadKugouDaily,
          ),
        ],
      ),
    );
  }

  Widget _buildLandscapeContent() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final pageLayout = AppLayout.fromConstraints(context, constraints);
        final compact = pageLayout.isCompactLandscape;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _buildLandscapeColumn(
                key: const PageStorageKey('discover-landscape-library'),
                compact: compact,
                children: [
                  _buildHeader(),
                  _buildFavoritesBlock(compact: compact),
                  const SizedBox.shrink(),
                  _buildFavoritePlaylistsBlock(compact: compact),
                  const SizedBox.shrink(),
                  _buildBilibiliFavoritesBlock(compact: compact),
                  const SizedBox(height: 24),
                ],
              ),
            ),
            VerticalDivider(
              width: 1,
              thickness: 1,
              color: AppColors.surfaceSoft,
            ),
            Expanded(
              child: _buildLandscapeColumn(
                key: const PageStorageKey('discover-landscape-songs'),
                compact: compact,
                children: [
                  const SizedBox(height: 16),
                  _buildSectionHeader(
                    '每日推荐',
                    PlatformColors.kugou,
                    '每天为你精选好音乐',
                    compact: compact,
                  ),
                  _buildAnimatedSongSection(
                    _kugouDaily,
                    _loadingKugouDaily,
                    _errKugouDaily,
                    onRetry: _loadKugouDaily,
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildLandscapeColumn({
    required Key key,
    required bool compact,
    required List<Widget> children,
  }) {
    return RefreshIndicator(
      key: key,
      onRefresh: _loadAll,
      color: AppColors.primary,
      child: ListView(
        key: PageStorageKey('${key.toString()}-scroll'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.only(
          bottom: compact
              ? 16
              : (AppLayout.fromContext(context).usesLargeTypography ? 32 : 24),
        ),
        children: children,
      ),
    );
  }

  /// 顶部问候区
  Widget _buildHeader() {
    final layout = AppLayout.fromContext(context);
    final hour = DateTime.now().hour;
    final greet = hour < 6
        ? '夜深了'
        : hour < 12
        ? '早上好'
        : hour < 18
        ? '下午好'
        : '晚上好';
    return Container(
      margin: EdgeInsets.fromLTRB(
        layout.usesLargeTypography ? 28 : 20,
        layout.isCompactLandscape ? 10 : 18,
        layout.usesLargeTypography ? 28 : 20,
        10,
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.media),
            child: Image.asset(
              'assets/images/app_logo.png',
              width: layout.usesLargeTypography ? 60 : 48,
              height: layout.usesLargeTypography ? 60 : 48,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$greet 👋',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: layout.pageTitleSize,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '发现好音乐，开启一天好心情',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: layout.secondarySize,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(
    String title,
    Color color,
    String subtitle, {
    bool compact = false,
    VoidCallback? onTap,
    Key? key,
  }) {
    final layout = AppLayout.fromContext(context);
    final content = Container(
      padding: EdgeInsets.fromLTRB(
        layout.usesLargeTypography ? 28 : (layout.isCompactLandscape ? 14 : 20),
        layout.usesLargeTypography ? 18 : 12,
        layout.usesLargeTypography ? 28 : (layout.isCompactLandscape ? 14 : 20),
        10,
      ),
      child: Row(
        children: [
          Container(
            width: 4,
            height: layout.usesLargeTypography ? 26 : 20,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: layout.sectionTitleSize,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          if (!compact)
            Flexible(
              child: Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
                style: TextStyle(
                  fontSize: layout.secondarySize,
                  color: AppColors.textHint,
                ),
              ),
            ),
          if (onTap != null) ...[
            const SizedBox(width: 4),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: AppColors.textHint,
            ),
          ],
        ],
      ),
    );
    if (onTap == null) return content;
    return Material(
      key: key,
      color: Colors.transparent,
      child: InkWell(onTap: onTap, child: content),
    );
  }

  Widget _buildFavoritesBlock({bool compact = false}) {
    return Consumer<FavoriteService>(
      builder: (context, favorites, _) {
        final songs = favorites.favorites;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildSectionHeader(
              '收藏歌曲',
              Colors.redAccent,
              '${songs.length} 首',
              compact: compact,
              key: const ValueKey('home-favorites-header'),
              onTap: _openFavorites,
            ),
            AppMotionSwitcher(
              child: KeyedSubtree(
                key: ValueKey(
                  !favorites.loaded
                      ? 'home-favorites-loading'
                      : songs.isEmpty
                      ? 'home-favorites-empty'
                      : 'home-favorites-content',
                ),
                child: _buildFavoriteSection(favorites, compact: compact),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildFavoriteSection(
    FavoriteService favorites, {
    bool compact = false,
  }) {
    final layout = AppLayout.fromContext(context);
    final cardSize = _favoritePreviewSize(layout);
    if (!favorites.loaded) {
      return SizedBox(
        height: cardSize + (layout.usesLargeTypography ? 62 : 52),
        child: Center(
          child: SizedBox.square(
            dimension: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: AppColors.primary,
            ),
          ),
        ),
      );
    }

    final songs = favorites.favorites;
    if (songs.isEmpty) {
      return SizedBox(
        height: layout.usesLargeTypography ? 88 : (compact ? 76 : 96),
        child: Center(
          child: TextButton.icon(
            onPressed: _openFavorites,
            icon: const Icon(Icons.favorite_border_rounded, size: 20),
            label: const Text('还没有收藏歌曲'),
          ),
        ),
      );
    }

    return SizedBox(
      height:
          cardSize + (layout.usesLargeTypography ? 62 : (compact ? 54 : 60)),
      child: ListView.builder(
        key: const ValueKey('home-favorites-carousel'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: songs.length,
        itemBuilder: (context, index) {
          final song = songs[index];
          return _FavoriteSongCard(
            song: song,
            cardSize: cardSize,
            onTap: () => context.read<PlayerProvider>().playSingle(song),
          );
        },
      ),
    );
  }

  void _openFavorites() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const FavoritesScreen()),
    );
  }

  Widget _buildFavoritePlaylistsBlock({bool compact = false}) {
    return Consumer<FavoriteService>(
      builder: (context, favorites, _) {
        final playlists = favorites.favoritePlaylists;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildSectionHeader(
              '收藏歌单',
              AppColors.primary,
              '${playlists.length} 个',
              compact: compact,
              key: const ValueKey('home-favorite-playlists-header'),
              onTap: _openFavorites,
            ),
            AppMotionSwitcher(
              child: KeyedSubtree(
                key: ValueKey(
                  !favorites.loaded
                      ? 'home-playlists-loading'
                      : playlists.isEmpty
                      ? 'home-playlists-empty'
                      : 'home-playlists-content',
                ),
                child: _buildFavoritePlaylistSection(
                  favorites,
                  compact: compact,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildFavoritePlaylistSection(
    FavoriteService favorites, {
    bool compact = false,
  }) {
    final layout = AppLayout.fromContext(context);
    final cardSize = _favoritePreviewSize(layout);
    final sectionHeight =
        cardSize + (layout.usesLargeTypography ? 62 : (compact ? 56 : 60));
    if (!favorites.loaded) {
      return SizedBox(
        height: sectionHeight,
        child: Center(
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            color: AppColors.primary,
          ),
        ),
      );
    }
    final playlists = favorites.favoritePlaylists;
    if (playlists.isEmpty) {
      return SizedBox(
        height: layout.usesLargeTypography ? 88 : (compact ? 76 : 96),
        child: Center(
          child: TextButton.icon(
            onPressed: _openFavorites,
            icon: const Icon(Icons.playlist_add_rounded, size: 22),
            label: const Text('还没有收藏歌单'),
          ),
        ),
      );
    }
    return SizedBox(
      height: sectionHeight,
      child: ListView.builder(
        key: const ValueKey('home-favorite-playlists-carousel'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: playlists.length,
        itemBuilder: (ctx, i) {
          final favorite = playlists[i];
          return Padding(
            padding: const EdgeInsets.only(right: 14),
            child: FavoritePlaylistCard(
              favorite: favorite,
              cardWidth: cardSize,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => PlaylistDetailScreen(
                    playlist: favorite.playlist,
                    platform: favorite.platform,
                  ),
                ),
              ),
              onFavoritePressed: () =>
                  favorites.removePlaylist(favorite.platform, favorite.id),
            ),
          );
        },
      ),
    );
  }

  Widget _buildBilibiliFavoritesBlock({bool compact = false}) {
    return Consumer<FavoriteService>(
      builder: (context, favorites, _) {
        final videos = favorites.bilibiliFavorites;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildSectionHeader(
              'B站收藏',
              PlatformColors.bilibili,
              '${videos.length} 个',
              compact: compact,
              key: const ValueKey('home-bilibili-favorites-header'),
              onTap: _openFavorites,
            ),
            AppMotionSwitcher(
              child: KeyedSubtree(
                key: ValueKey(
                  !favorites.loaded
                      ? 'home-bilibili-loading'
                      : videos.isEmpty
                      ? 'home-bilibili-empty'
                      : 'home-bilibili-content',
                ),
                child: _buildBilibiliFavoriteSection(
                  favorites,
                  compact: compact,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildBilibiliFavoriteSection(
    FavoriteService favorites, {
    bool compact = false,
  }) {
    final layout = AppLayout.fromContext(context);
    final cardSize = _favoritePreviewSize(layout);
    final sectionHeight =
        cardSize + (layout.usesLargeTypography ? 62 : (compact ? 54 : 60));
    if (!favorites.loaded) {
      return SizedBox(
        height: sectionHeight,
        child: Center(
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            color: PlatformColors.bilibili,
          ),
        ),
      );
    }
    final videos = favorites.bilibiliFavorites;
    if (videos.isEmpty) {
      return SizedBox(
        height: layout.usesLargeTypography ? 88 : (compact ? 76 : 96),
        child: Center(
          child: TextButton.icon(
            onPressed: _openFavorites,
            icon: const Icon(Icons.video_library_outlined, size: 21),
            label: const Text('还没有B站收藏'),
          ),
        ),
      );
    }
    return SizedBox(
      height: sectionHeight,
      child: ListView.builder(
        key: const ValueKey('home-bilibili-favorites-carousel'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: videos.length,
        itemBuilder: (context, index) {
          final video = videos[index];
          return _FavoriteSongCard(
            song: video,
            cardSize: cardSize,
            onTap: () => context.read<PlayerProvider>().playSingle(video),
          );
        },
      ),
    );
  }

  double _favoritePreviewSize(AppLayout layout) {
    if (!layout.isLandscape) return layout.mediaCardWidth.clamp(110.0, 144.0);
    if (layout.usesLargeTypography) return 92;
    return layout.isCompactLandscape ? 86 : 104;
  }

  Widget _buildSongSection(
    List<SongSearchResult> songs,
    bool loading,
    String? error, {
    Future<void> Function()? onRetry,
  }) {
    final layout = AppLayout.fromContext(context);
    final listHeight = layout.usesLargeTypography
        ? 520.0
        : (layout.isCompactLandscape ? 360.0 : 420.0);
    if (loading) {
      return SizedBox(
        height: listHeight,
        child: Center(
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            color: AppColors.primary,
          ),
        ),
      );
    }
    if (error != null) {
      return SizedBox(
        height: 80,
        child: Center(
          child: TextButton.icon(
            onPressed: onRetry,
            icon: Icon(Icons.refresh, size: 18, color: AppColors.primary),
            label: Text(
              '加载失败，点击重试',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
        ),
      );
    }
    if (songs.isEmpty) {
      return SizedBox(
        height: 80,
        child: Center(
          child: Text('暂无数据', style: TextStyle(color: AppColors.textHint)),
        ),
      );
    }
    // 最多显示 10 首
    final display = songs.length > 10 ? songs.sublist(0, 10) : songs;
    return Container(
      margin: EdgeInsets.symmetric(
        horizontal: AppLayout.fromContext(context).usesLargeTypography
            ? 20
            : 12,
      ),
      decoration: CardStyle.softCard(),
      child: Column(
        children: display.map((song) {
          return SongTile(
            song: song,
            showFavorite: true,
            showPlatformTag: false,
            onTap: () {
              context.read<PlayerProvider>().playSingle(song);
            },
            onAddToQueue: () {
              context.read<PlayerProvider>().addToQueue(song);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('已添加到队列: ${song.name}'),
                  duration: const Duration(seconds: 1),
                ),
              );
            },
          );
        }).toList(),
      ),
    );
  }

  Widget _buildAnimatedSongSection(
    List<SongSearchResult> songs,
    bool loading,
    String? error, {
    Future<void> Function()? onRetry,
  }) {
    final stateKey = loading
        ? 'loading'
        : error != null
        ? 'error'
        : songs.isEmpty
        ? 'empty'
        : 'content';
    return AppMotionSwitcher(
      child: KeyedSubtree(
        key: ValueKey('home-daily-$stateKey'),
        child: _buildSongSection(songs, loading, error, onRetry: onRetry),
      ),
    );
  }
}

class _FavoriteSongCard extends StatelessWidget {
  final SongSearchResult song;
  final VoidCallback onTap;
  final double? cardSize;

  const _FavoriteSongCard({
    required this.song,
    required this.onTap,
    this.cardSize,
  });

  @override
  Widget build(BuildContext context) {
    AppColors.syncWithTheme(context);
    final layout = AppLayout.fromContext(context);
    final cardSize = this.cardSize ?? layout.mediaCardWidth;
    final compactPreview = cardSize < layout.mediaCardWidth;
    final platformColor = PlatformColors.of(song.platform);
    return RemoteFocusable(
      key: ValueKey('home-favorite-${song.platform.code}-${song.id}'),
      onPressed: onTap,
      semanticLabel: '播放 ${song.name}',
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: Container(
        width: cardSize,
        margin: const EdgeInsets.symmetric(horizontal: 7),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.media),
              child: SizedBox.square(
                dimension: cardSize,
                child: SmartCover(
                  url: song.coverUrl,
                  fit: BoxFit.cover,
                  placeholder: () => Container(
                    color: platformColor.withValues(alpha: 0.12),
                    child: Icon(
                      Icons.music_note_rounded,
                      size: 38,
                      color: platformColor,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 7),
            Text(
              song.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: compactPreview ? 15 : layout.mediaCardTitleSize,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              song.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: compactPreview ? 13 : layout.mediaCardSubtitleSize,
                color: AppColors.textHint,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
