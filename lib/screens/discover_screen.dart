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
                  const SizedBox.shrink(),
                  _buildPlaybackHistoryBlock(compact: compact),
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
      margin: EdgeInsets.fromLTRB(
        layout.usesLargeTypography ? 28 : 20,
        layout.isCompactLandscape ? 10 : 18,
        layout.usesLargeTypography ? 28 : 20,
        10,
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
                  size: layout.usesLargeTypography ? 60 : 48,
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
      builder: (dialogContext) => SimpleDialog(
        key: const ValueKey('user-switch-dialog'),
        title: const Text('切换用户'),
        children: [
          for (final user in users.users)
            SimpleDialogOption(
              key: ValueKey('user-switch-${user.id}'),
              onPressed: () => Navigator.pop(dialogContext, user.id),
              child: Row(
                children: [
                  AppUserAvatar(user: user, size: 44),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      user.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (user.id == users.activeUserId)
                    Icon(Icons.check_rounded, color: AppColors.primary),
                ],
              ),
            ),
        ],
      ),
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
              onTap: _openFavoriteSongs,
              arrowOnly: true,
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
            onPressed: _openFavoriteSongs,
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
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildSectionHeader(
              '收藏歌单',
              AppColors.primary,
              '${playlists.length} 个',
              compact: compact,
              key: const ValueKey('home-favorite-playlists-header'),
              onTap: _openFavoritePlaylists,
              arrowOnly: true,
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
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildSectionHeader(
              'B站收藏',
              PlatformColors.bilibili,
              '${videos.length} 个',
              compact: compact,
              key: const ValueKey('home-bilibili-favorites-header'),
              onTap: _openBilibiliFavorites,
              arrowOnly: true,
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
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildSectionHeader(
              '播放历史',
              AppColors.primary,
              '${history.length} 条',
              compact: compact,
              key: const ValueKey('home-playback-history-header'),
              onTap: _openPlaybackHistory,
            ),
            FutureBuilder<void>(
              future: player.historyReady,
              builder: (context, snapshot) {
                final loading =
                    snapshot.connectionState != ConnectionState.done;
                return AppMotionSwitcher(
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
                );
              },
            ),
          ],
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
    final sectionHeight =
        cardSize + (layout.usesLargeTypography ? 62 : (compact ? 54 : 60));
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
