import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../models/app_user.dart';
import '../providers/player_provider.dart';
import '../providers/user_controller.dart';
import '../services/favorite_service.dart';
import '../services/playback_history_service.dart';
import '../theme/app_layout.dart';
import '../theme/app_motion.dart';
import '../theme/app_theme.dart';
import '../widgets/favorite_playlist_card.dart';
import '../widgets/remote_focusable.dart';
import '../widgets/song_tile.dart';
import '../widgets/smart_cover.dart';
import '../widgets/app_user_avatar.dart';
import 'favorites_screen.dart';
import 'playback_history_screen.dart';
import 'player_screen.dart';
import 'playlist_detail_screen.dart';

class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  late final ScrollController _portraitScrollController;
  List<SongSearchResult> _kugouDaily = [];

  bool _loadingKugouDaily = false;

  String? _errKugouDaily;

  @override
  void initState() {
    super.initState();
    _portraitScrollController = ScrollController();
    unawaited(context.read<FavoriteService>().load());
    unawaited(_loadAll());
  }

  @override
  void dispose() {
    _portraitScrollController.dispose();
    super.dispose();
  }

  Future<void> _loadAll() async {
    await _loadKugouDaily();
  }

  Future<void> _loadKugouDaily() async {
    if (!mounted) return;
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
        // The shell keeps several pages alive in an IndexedStack. Do not let
        // their vertical lists compete for the route's primary controller.
        key: const PageStorageKey('discover-portrait-scroll'),
        controller: _portraitScrollController,
        primary: false,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _buildHeader(),
          _buildFavoritesBlock(),
          const SizedBox(height: 12),
          _buildFavoritePlaylistsBlock(),
          const SizedBox(height: 12),
          _buildBilibiliFavoritesBlock(),
          const SizedBox(height: 12),
          _buildPlaybackHistoryBlock(),
          const SizedBox(height: 12),
          _buildSectionHeader(
            '每日推荐',
            PlatformColors.kugou,
            '每天为你精选好音乐',
            icon: Icons.auto_awesome_rounded,
          ),
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
              flex: 6,
              child: _buildLandscapeColumn(
                key: const PageStorageKey('discover-landscape-library'),
                scrollKey: const ValueKey('discover-landscape-library-scroll'),
                compact: compact,
                children: [
                  _buildHeader(),
                  _buildLandscapeCollectionGrid(compact: compact),
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
              flex: 5,
              child: _buildLandscapeColumn(
                key: const PageStorageKey('discover-landscape-songs'),
                scrollKey: const ValueKey('discover-landscape-songs-scroll'),
                compact: compact,
                children: [
                  const SizedBox(height: 16),
                  _buildSectionHeader(
                    '每日推荐',
                    PlatformColors.kugou,
                    '每天为你精选好音乐',
                    compact: compact,
                    icon: Icons.auto_awesome_rounded,
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
    required Key scrollKey,
    required bool compact,
    required List<Widget> children,
  }) {
    return RefreshIndicator(
      key: key,
      onRefresh: _loadAll,
      color: AppColors.primary,
      child: ListView(
        key: scrollKey,
        primary: false,
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

  Widget _buildLandscapeCollectionGrid({required bool compact}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final gap = compact ? 4.0 : 8.0;
        final columns = constraints.maxWidth + 0.1 >= 560 ? 2 : 1;
        final itemWidth = columns == 1
            ? constraints.maxWidth
            : (constraints.maxWidth - gap) / 2;
        return Wrap(
          key: const ValueKey('home-collection-grid'),
          spacing: gap,
          runSpacing: compact ? 2 : 6,
          children: [
            SizedBox(
              width: itemWidth,
              child: _buildFavoritesBlock(compact: compact),
            ),
            SizedBox(
              width: itemWidth,
              child: _buildFavoritePlaylistsBlock(compact: compact),
            ),
            SizedBox(
              width: itemWidth,
              child: _buildBilibiliFavoritesBlock(compact: compact),
            ),
            SizedBox(
              width: itemWidth,
              child: _buildPlaybackHistoryBlock(compact: compact),
            ),
          ],
        );
      },
    );
  }

  /// 顶部问候区
  Widget _buildHeader() {
    final layout = AppLayout.fromContext(context);
    final users = Provider.of<UserController?>(context);
    final user = users?.activeUser ?? AppUserProfile.defaultUser;
    final hour = DateTime.now().hour;
    final greet = hour < 6
        ? '夜深了'
        : hour < 12
        ? '早上好'
        : hour < 18
        ? '下午好'
        : '晚上好';
    return Container(
      key: const ValueKey('home-header-card'),
      margin: EdgeInsets.fromLTRB(
        layout.usesLargeTypography ? 24 : (layout.isCompactLandscape ? 10 : 16),
        layout.isCompactLandscape ? 10 : 18,
        layout.usesLargeTypography ? 24 : (layout.isCompactLandscape ? 10 : 16),
        layout.isCompactLandscape ? 8 : 12,
      ),
      padding: EdgeInsets.symmetric(
        horizontal: layout.usesLargeTypography ? 18 : 14,
        vertical: layout.isCompactLandscape ? 12 : 16,
      ),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.outline),
      ),
      child: Row(
        children: [
          RemoteFocusable(
            key: const ValueKey('home-user-avatar'),
            borderRadius: BorderRadius.circular(AppRadius.media),
            onPressed: users == null || users.switching
                ? null
                : () => _showUserSwitcher(users),
            child: Tooltip(
              message: '切换用户',
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: AppUserAvatar(
                  user: user,
                  size: layout.usesLargeTypography
                      ? 68
                      : (layout.isCompactLandscape ? 52 : 58),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$greet，${user.name}',
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

  Future<void> _showUserSwitcher(UserController users) async {
    final selected = await showDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => _UserSwitcherDialog(users: users),
    );
    if (selected == null || selected == users.activeUserId || !mounted) return;
    try {
      await users.switchUser(selected);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('切换用户失败：$error')));
    }
  }

  Widget _buildSectionHeader(
    String title,
    Color color,
    String subtitle, {
    bool compact = false,
    IconData? icon,
    VoidCallback? onTap,
    Key? key,
    bool arrowOnly = false,
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
          if (icon == null)
            Container(
              width: 4,
              height: layout.usesLargeTypography ? 26 : 20,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(2),
              ),
            )
          else
            Container(
              width: layout.usesLargeTypography
                  ? 48
                  : (layout.isCompactLandscape ? 38 : 44),
              height: layout.usesLargeTypography
                  ? 48
                  : (layout.isCompactLandscape ? 38 : 44),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(AppRadius.control),
              ),
              alignment: Alignment.center,
              child: Icon(
                icon,
                color: color,
                size: layout.usesLargeTypography
                    ? 29
                    : (layout.isCompactLandscape ? 24 : 27),
              ),
            ),
          SizedBox(width: icon == null ? 8 : 12),
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
            if (arrowOnly)
              IconButton(
                key: key,
                tooltip: '打开$title',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(
                  minWidth: 24,
                  minHeight: 24,
                  maxWidth: 24,
                  maxHeight: 24,
                ),
                padding: EdgeInsets.zero,
                iconSize: 20,
                onPressed: onTap,
                icon: Icon(
                  Icons.chevron_right_rounded,
                  color: AppColors.textHint,
                ),
              )
            else
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
    if (arrowOnly) {
      return Material(color: Colors.transparent, child: content);
    }
    return Material(
      key: key,
      color: Colors.transparent,
      child: InkWell(onTap: onTap, child: content),
    );
  }

  Widget _buildCollectionPanel({
    required Key panelKey,
    required Key headerKey,
    required String title,
    required String countText,
    required IconData icon,
    required Color accentColor,
    required VoidCallback onTap,
    required Widget child,
  }) {
    final layout = AppLayout.fromContext(context);
    final compact = layout.isCompactLandscape;
    final horizontalMargin = layout.usesLargeTypography
        ? 20.0
        : (compact ? 8.0 : 14.0);
    final iconBoxSize = layout.usesLargeTypography
        ? 58.0
        : (compact ? 48.0 : 52.0);
    final titleSize = layout.usesLargeTypography
        ? 26.0
        : (compact ? 20.0 : 23.0);

    return Container(
      key: panelKey,
      margin: EdgeInsets.fromLTRB(horizontalMargin, 6, horizontalMargin, 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              compact ? 12 : 16,
              compact ? 11 : 14,
              compact ? 10 : 14,
              compact ? 11 : 14,
            ),
            child: Row(
              children: [
                Container(
                  width: iconBoxSize,
                  height: iconBoxSize,
                  decoration: BoxDecoration(
                    color: accentColor.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(AppRadius.control),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    icon,
                    color: accentColor,
                    size: layout.usesLargeTypography ? 34 : (compact ? 28 : 31),
                  ),
                ),
                SizedBox(width: compact ? 12 : 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: titleSize,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        countText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: layout.usesLargeTypography
                              ? 18
                              : (compact ? 14 : 16),
                        ),
                      ),
                    ],
                  ),
                ),
                RemoteFocusable(
                  key: headerKey,
                  onPressed: onTap,
                  semanticLabel: '打开$title',
                  borderRadius: BorderRadius.circular(AppRadius.control),
                  child: Container(
                    width: compact ? 52 : 58,
                    height: compact ? 52 : 58,
                    decoration: BoxDecoration(
                      color: AppColors.surfaceSoft,
                      borderRadius: BorderRadius.circular(AppRadius.control),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.chevron_right_rounded,
                      color: AppColors.textSecondary,
                      size: compact ? 32 : 36,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Divider(
            height: 1,
            thickness: 1,
            indent: compact ? 12 : 16,
            endIndent: compact ? 12 : 16,
            color: AppColors.outline,
          ),
          child,
        ],
      ),
    );
  }

  Widget _buildFavoritesBlock({bool compact = false}) {
    return Consumer<FavoriteService>(
      builder: (context, favorites, _) {
        final songs = favorites.favorites;
        return _buildCollectionPanel(
          panelKey: const ValueKey('home-favorites-panel'),
          headerKey: const ValueKey('home-favorites-header'),
          title: '收藏歌曲',
          countText: '${songs.length} 首歌曲',
          icon: Icons.favorite_rounded,
          accentColor: Colors.redAccent,
          onTap: _openFavoriteSongs,
          child: AppMotionSwitcher(
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
    final sectionHeight = cardSize + _favoritePreviewExtraHeight(layout);
    if (!favorites.loaded) {
      return SizedBox(
        height: sectionHeight,
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
            onPressed: _openFavoriteSongs,
            icon: const Icon(Icons.favorite_border_rounded, size: 20),
            label: const Text('还没有收藏歌曲'),
          ),
        ),
      );
    }

    return SizedBox(
      height: sectionHeight,
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
            onTap: () =>
                context.read<PlayerProvider>().playFromPlaylist(songs, index),
          );
        },
      ),
    );
  }

  void _openFavoriteSongs() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const FavoriteSongsScreen()),
    );
  }

  void _openFavoritePlaylists() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const FavoritePlaylistsScreen()),
    );
  }

  void _openBilibiliFavorites() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const BilibiliFavoritesScreen()),
    );
  }

  Widget _buildFavoritePlaylistsBlock({bool compact = false}) {
    return Consumer<FavoriteService>(
      builder: (context, favorites, _) {
        final playlists = favorites.favoritePlaylists;
        return _buildCollectionPanel(
          panelKey: const ValueKey('home-favorite-playlists-panel'),
          headerKey: const ValueKey('home-favorite-playlists-header'),
          title: '收藏歌单',
          countText: '${playlists.length} 个歌单',
          icon: Icons.queue_music_rounded,
          accentColor: AppColors.primary,
          onTap: _openFavoritePlaylists,
          child: AppMotionSwitcher(
            child: KeyedSubtree(
              key: ValueKey(
                !favorites.loaded
                    ? 'home-playlists-loading'
                    : playlists.isEmpty
                    ? 'home-playlists-empty'
                    : 'home-playlists-content',
              ),
              child: _buildFavoritePlaylistSection(favorites, compact: compact),
            ),
          ),
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
    final sectionHeight = cardSize + _favoritePreviewExtraHeight(layout);
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
            onPressed: _openFavoritePlaylists,
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
        return _buildCollectionPanel(
          panelKey: const ValueKey('home-bilibili-favorites-panel'),
          headerKey: const ValueKey('home-bilibili-favorites-header'),
          title: 'B站收藏',
          countText: '${videos.length} 个视频',
          icon: Icons.ondemand_video_rounded,
          accentColor: PlatformColors.bilibili,
          onTap: _openBilibiliFavorites,
          child: AppMotionSwitcher(
            child: KeyedSubtree(
              key: ValueKey(
                !favorites.loaded
                    ? 'home-bilibili-loading'
                    : videos.isEmpty
                    ? 'home-bilibili-empty'
                    : 'home-bilibili-content',
              ),
              child: _buildBilibiliFavoriteSection(favorites, compact: compact),
            ),
          ),
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
    final sectionHeight = cardSize + _favoritePreviewExtraHeight(layout);
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
            onPressed: _openBilibiliFavorites,
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
            onTap: () =>
                context.read<PlayerProvider>().playFromPlaylist(videos, index),
          );
        },
      ),
    );
  }

  Widget _buildPlaybackHistoryBlock({bool compact = false}) {
    return Selector<PlayerProvider, int>(
      selector: (_, player) => player.playbackHistoryRevision,
      builder: (context, _, __) {
        final player = context.read<PlayerProvider>();
        final history = player.playbackHistory;
        return FutureBuilder<void>(
          future: player.historyReady,
          builder: (context, snapshot) {
            final loading = snapshot.connectionState != ConnectionState.done;
            return _buildCollectionPanel(
              panelKey: const ValueKey('home-playback-history-panel'),
              headerKey: const ValueKey('home-playback-history-header'),
              title: '播放历史',
              countText: '${history.length} 条记录',
              icon: Icons.history_rounded,
              accentColor: const Color(0xFF7A5AF8),
              onTap: _openPlaybackHistory,
              child: AppMotionSwitcher(
                child: KeyedSubtree(
                  key: ValueKey(
                    loading
                        ? 'home-playback-history-loading'
                        : history.isEmpty
                        ? 'home-playback-history-empty'
                        : 'home-playback-history-content',
                  ),
                  child: _buildPlaybackHistorySection(
                    player,
                    loading: loading,
                    compact: compact,
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildPlaybackHistorySection(
    PlayerProvider player, {
    required bool loading,
    bool compact = false,
  }) {
    final layout = AppLayout.fromContext(context);
    final cardSize = _favoritePreviewSize(layout);
    final sectionHeight = cardSize + _favoritePreviewExtraHeight(layout);
    if (loading) {
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
    final history = player.playbackHistory;
    if (history.isEmpty) {
      return SizedBox(
        height: layout.usesLargeTypography ? 88 : (compact ? 76 : 96),
        child: Center(
          child: TextButton.icon(
            onPressed: _openPlaybackHistory,
            icon: const Icon(Icons.history_rounded, size: 21),
            label: const Text('查看播放历史'),
          ),
        ),
      );
    }
    final display = history.length > 8 ? history.sublist(0, 8) : history;
    return SizedBox(
      height: sectionHeight,
      child: ListView.builder(
        key: const ValueKey('home-playback-history-carousel'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: display.length,
        itemBuilder: (context, index) {
          final entry = display[index];
          return _PlaybackHistoryCard(
            entry: entry,
            cardSize: cardSize,
            onTap: () => _playPlaybackHistory(display, index),
          );
        },
      ),
    );
  }

  void _openPlaybackHistory() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const PlaybackHistoryScreen()),
    );
  }

  void _playPlaybackHistory(List<PlaybackHistoryEntry> entries, int index) {
    final player = context.read<PlayerProvider>();
    unawaited(player.playFromHistoryEntries(entries, index));
    Navigator.push(context, PlayerScreen.route(context));
  }

  double _favoritePreviewSize(AppLayout layout) {
    if (!layout.isLandscape) return layout.mediaCardWidth.clamp(128.0, 156.0);
    if (layout.usesLargeTypography) return 148;
    return layout.isCompactLandscape ? 112 : 132;
  }

  double _favoritePreviewExtraHeight(AppLayout layout) {
    if (layout.usesLargeTypography) return 84;
    return layout.isCompactLandscape ? 64 : 72;
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
    final titleSize = layout.usesLargeTypography
        ? 20.0
        : (layout.isCompactLandscape ? 17.0 : 18.0);
    final subtitleSize = layout.usesLargeTypography
        ? 17.0
        : (layout.isCompactLandscape ? 14.0 : 15.0);
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
                      size: (cardSize * 0.38).clamp(38.0, 58.0),
                      color: platformColor,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              song.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: titleSize,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 1),
            Text(
              song.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: subtitleSize,
                color: AppColors.textHint,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A car-friendly user switcher.  The grid keeps every profile as a large,
/// independently tappable target while the scroll view prevents a long user
/// list from exceeding the short head-unit viewport.
class _UserSwitcherDialog extends StatelessWidget {
  final UserController users;

  const _UserSwitcherDialog({required this.users});

  @override
  Widget build(BuildContext context) {
    final layout = AppLayout.fromContext(context);
    final compact = layout.isCompactLandscape;
    final media = MediaQuery.sizeOf(context);
    final horizontalInset = compact ? 12.0 : 24.0;
    final verticalInset = compact ? 10.0 : 24.0;
    final availableWidth = (media.width - horizontalInset * 2)
        .clamp(1.0, double.infinity)
        .toDouble();
    final maxWidth = (compact ? 760.0 : 620.0)
        .clamp(1.0, availableWidth)
        .toDouble();
    final maxHeight = (media.height - verticalInset * 2).clamp(220.0, 620.0);
    final columns = compact || layout.isWideLandscape ? 2 : 1;

    return Dialog(
      key: const ValueKey('user-switch-dialog'),
      insetPadding: EdgeInsets.symmetric(
        horizontal: horizontalInset,
        vertical: verticalInset,
      ),
      child: SizedBox(
        width: maxWidth,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              compact ? 18 : 24,
              compact ? 14 : 22,
              compact ? 18 : 24,
              compact ? 14 : 22,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      width: compact ? 42 : 50,
                      height: compact ? 42 : 50,
                      decoration: BoxDecoration(
                        color: AppColors.primarySoft,
                        borderRadius: BorderRadius.circular(AppRadius.control),
                      ),
                      child: Icon(
                        Icons.switch_account_rounded,
                        color: AppColors.primary,
                        size: compact ? 25 : 30,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '切换用户 · 当前：${users.activeUser.name}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: compact ? 21 : 25,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('user-switch-close'),
                      tooltip: '关闭',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                      iconSize: compact ? 26 : 30,
                      constraints: BoxConstraints.tightFor(
                        width: compact ? 50 : 56,
                        height: compact ? 50 : 56,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: compact ? 14 : 20),
                Flexible(
                  child: GridView.builder(
                    key: const ValueKey('user-switch-list'),
                    shrinkWrap: true,
                    padding: const EdgeInsets.all(2),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      crossAxisSpacing: compact ? 10 : 12,
                      mainAxisSpacing: compact ? 10 : 12,
                      mainAxisExtent: compact ? 76 : 86,
                    ),
                    itemCount: users.users.length,
                    itemBuilder: (context, index) {
                      final user = users.users[index];
                      final selected = user.id == users.activeUserId;
                      return _UserSwitcherOption(
                        key: ValueKey('user-switch-${user.id}'),
                        user: user,
                        selected: selected,
                        compact: compact,
                        onPressed: () => Navigator.pop(context, user.id),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _UserSwitcherOption extends StatelessWidget {
  final AppUserProfile user;
  final bool selected;
  final bool compact;
  final VoidCallback onPressed;

  const _UserSwitcherOption({
    super.key,
    required this.user,
    required this.selected,
    required this.compact,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final borderColor = selected ? AppColors.primary : AppColors.outline;
    return RemoteFocusable(
      onPressed: onPressed,
      semanticLabel: '切换到 ${user.name}',
      borderRadius: BorderRadius.circular(AppRadius.control),
      child: AnimatedContainer(
        duration: AppMotion.resolve(context, AppMotion.quick),
        padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 14),
        decoration: BoxDecoration(
          color: selected ? AppColors.primarySoft : AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.control),
          border: Border.all(color: borderColor, width: selected ? 2 : 1),
        ),
        child: Row(
          children: [
            AppUserAvatar(user: user, size: compact ? 48 : 54),
            SizedBox(width: compact ? 10 : 12),
            Expanded(
              child: Text(
                user.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: compact ? 17 : 19,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                ),
              ),
            ),
            if (selected)
              Icon(
                Icons.check_circle_rounded,
                color: AppColors.primary,
                size: compact ? 24 : 28,
              ),
          ],
        ),
      ),
    );
  }
}

class _PlaybackHistoryCard extends StatelessWidget {
  final PlaybackHistoryEntry entry;
  final double cardSize;
  final VoidCallback onTap;

  const _PlaybackHistoryCard({
    required this.entry,
    required this.cardSize,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return _FavoriteSongCard(
      song: entry.song,
      cardSize: cardSize,
      onTap: onTap,
    );
  }
}
