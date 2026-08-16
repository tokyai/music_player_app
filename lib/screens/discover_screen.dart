import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../services/favorite_service.dart';
import '../theme/app_layout.dart';
import '../theme/app_theme.dart';
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
  List<PlaylistInfo> _neteasePlaylists = [];
  List<PlaylistInfo> _qqPlaylists = [];
  List<SongSearchResult> _kugouDaily = [];
  List<SongSearchResult> _kugouNewSongs = [];

  bool _loadingNetease = false;
  bool _loadingQQ = false;
  bool _loadingKugouDaily = false;
  bool _loadingKugouNew = false;

  String? _errNetease;
  String? _errQQ;
  String? _errKugouDaily;
  String? _errKugouNew;

  @override
  void initState() {
    super.initState();
    unawaited(context.read<FavoriteService>().load());
    unawaited(_loadAll());
  }

  Future<void> _loadAll() async {
    if (!mounted) return;
    setState(() {
      _loadingQQ = true;
      _loadingNetease = true;
      _loadingKugouDaily = true;
      _loadingKugouNew = true;
      _errQQ = null;
      _errNetease = null;
      _errKugouDaily = null;
      _errKugouNew = null;
    });

    // 每列自上而下加载，同时最多保留两个请求，避免启动瞬间压满中转服务。
    await Future.wait([
      () async {
        await _loadQQ();
        if (mounted) await _loadNetease();
      }(),
      () async {
        await _loadKugouDaily();
        if (mounted) await _loadKugouNew();
      }(),
    ]);
  }

  Future<void> _loadNetease() async {
    setState(() {
      _loadingNetease = true;
      _errNetease = null;
    });
    try {
      final list = await context.read<PlayerProvider>().api.neteaseHotPlaylists(
        limit: 12,
      );
      if (mounted) setState(() => _neteasePlaylists = list);
    } catch (e) {
      if (mounted) setState(() => _errNetease = e.toString());
    } finally {
      if (mounted) setState(() => _loadingNetease = false);
    }
  }

  Future<void> _loadQQ() async {
    setState(() {
      _loadingQQ = true;
      _errQQ = null;
    });
    try {
      final list = await context
          .read<PlayerProvider>()
          .api
          .qqRecommendPlaylists();
      if (mounted) setState(() => _qqPlaylists = list);
    } catch (e) {
      if (mounted) setState(() => _errQQ = e.toString());
    } finally {
      if (mounted) setState(() => _loadingQQ = false);
    }
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

  Future<void> _loadKugouNew() async {
    setState(() {
      _loadingKugouNew = true;
      _errKugouNew = null;
    });
    try {
      final list = await context.read<PlayerProvider>().api.kugouNewSongs(
        pagesize: 12,
      );
      if (mounted) setState(() => _kugouNewSongs = list);
    } catch (e) {
      if (mounted) setState(() => _errKugouNew = e.toString());
    } finally {
      if (mounted) setState(() => _loadingKugouNew = false);
    }
  }

  @override
  Widget build(BuildContext context) {
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
          _buildSectionHeader('QQ音乐推荐歌单', PlatformColors.qq, 'QQ 音乐编辑推荐'),
          _buildPlaylistSection(
            _qqPlaylists,
            _loadingQQ,
            _errQQ,
            MusicPlatform.qq,
          ),
          const SizedBox(height: 12),
          _buildSectionHeader('网易云热门歌单', PlatformColors.netease, '为你精选全网好听的歌单'),
          _buildPlaylistSection(
            _neteasePlaylists,
            _loadingNetease,
            _errNetease,
            MusicPlatform.netease,
          ),
          const SizedBox(height: 12),
          _buildSectionHeader('酷狗每日推荐', PlatformColors.kugou, '每天为你精选 20 首'),
          _buildSongSection(
            _kugouDaily,
            _loadingKugouDaily,
            _errKugouDaily,
            onRetry: _loadKugouDaily,
          ),
          const SizedBox(height: 12),
          _buildSectionHeader('酷狗新歌速递', PlatformColors.kugou, '最新上架的热门歌曲'),
          _buildSongSection(
            _kugouNewSongs,
            _loadingKugouNew,
            _errKugouNew,
            onRetry: _loadKugouNew,
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
                key: const PageStorageKey('discover-landscape-playlists'),
                compact: compact,
                children: [
                  _buildHeader(),
                  _buildFavoritesBlock(compact: compact),
                  const SizedBox(height: 12),
                  _buildSectionHeader(
                    'QQ音乐推荐歌单',
                    PlatformColors.qq,
                    'QQ 音乐编辑推荐',
                    compact: compact,
                  ),
                  _buildPlaylistSection(
                    _qqPlaylists,
                    _loadingQQ,
                    _errQQ,
                    MusicPlatform.qq,
                  ),
                  const SizedBox(height: 12),
                  _buildSectionHeader(
                    '网易云热门歌单',
                    PlatformColors.netease,
                    '为你精选全网好听的歌单',
                    compact: compact,
                  ),
                  _buildPlaylistSection(
                    _neteasePlaylists,
                    _loadingNetease,
                    _errNetease,
                    MusicPlatform.netease,
                  ),
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
                    '酷狗每日推荐',
                    PlatformColors.kugou,
                    '每天为你精选 20 首',
                    compact: compact,
                  ),
                  _buildSongSection(
                    _kugouDaily,
                    _loadingKugouDaily,
                    _errKugouDaily,
                    onRetry: _loadKugouDaily,
                  ),
                  const SizedBox(height: 12),
                  _buildSectionHeader(
                    '酷狗新歌速递',
                    PlatformColors.kugou,
                    '最新上架的热门歌曲',
                    compact: compact,
                  ),
                  _buildSongSection(
                    _kugouNewSongs,
                    _loadingKugouNew,
                    _errKugouNew,
                    onRetry: _loadKugouNew,
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
              : (AppLayout.fromContext(context).isWideLandscape ? 32 : 24),
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
        layout.isWideLandscape ? 28 : 20,
        layout.isCompactLandscape ? 10 : 18,
        layout.isWideLandscape ? 28 : 20,
        10,
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Image.asset(
              'assets/images/app_logo.png',
              width: layout.isWideLandscape ? 56 : 48,
              height: layout.isWideLandscape ? 56 : 48,
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
                    fontSize: layout.isWideLandscape
                        ? 28
                        : (layout.isCompactLandscape ? 22 : 24),
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
                    fontSize: layout.isWideLandscape ? 15 : 13,
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
        layout.isWideLandscape ? 28 : (layout.isCompactLandscape ? 14 : 20),
        layout.isWideLandscape ? 18 : 12,
        layout.isWideLandscape ? 28 : (layout.isCompactLandscape ? 14 : 20),
        10,
      ),
      child: Row(
        children: [
          Container(
            width: 4,
            height: layout.isWideLandscape ? 24 : 20,
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
                fontSize: layout.isWideLandscape
                    ? 22
                    : (layout.isCompactLandscape ? 18 : 20),
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
                  fontSize: layout.isWideLandscape ? 14 : 13,
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
              '我的收藏',
              Colors.redAccent,
              '${songs.length} 首',
              compact: compact,
              key: const ValueKey('home-favorites-header'),
              onTap: _openFavorites,
            ),
            _buildFavoriteSection(favorites, compact: compact),
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
    if (!favorites.loaded) {
      return SizedBox(
        height: layout.isWideLandscape ? 150 : (compact ? 108 : 128),
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
        height: layout.isWideLandscape ? 126 : (compact ? 92 : 112),
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
      height: layout.isWideLandscape ? 238 : (compact ? 196 : 218),
      child: ListView.builder(
        key: const ValueKey('home-favorites-carousel'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: songs.length,
        itemBuilder: (context, index) {
          final song = songs[index];
          return _FavoriteSongCard(
            song: song,
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

  Widget _buildPlaylistSection(
    List<PlaylistInfo> playlists,
    bool loading,
    String? error,
    MusicPlatform platform,
  ) {
    final layout = AppLayout.fromContext(context);
    final cardHeight = layout.isWideLandscape
        ? 246.0
        : (layout.isCompactLandscape ? 208.0 : 224.0);
    if (loading) {
      return SizedBox(
        height: cardHeight,
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
        height: 90,
        child: Center(
          child: TextButton.icon(
            onPressed: () {
              if (platform == MusicPlatform.netease) {
                _loadNetease();
              } else {
                _loadQQ();
              }
            },
            icon: Icon(Icons.refresh, size: 18, color: AppColors.primary),
            label: Text(
              '加载失败，点击重试',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
        ),
      );
    }
    if (playlists.isEmpty) {
      return SizedBox(
        height: 90,
        child: Center(
          child: Text('暂无数据', style: TextStyle(color: AppColors.textHint)),
        ),
      );
    }
    return SizedBox(
      height: cardHeight,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: playlists.length,
        itemBuilder: (ctx, i) {
          final p = playlists[i];
          return _PlaylistCard(
            playlist: p,
            platform: platform,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      PlaylistDetailScreen(playlist: p, platform: platform),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildSongSection(
    List<SongSearchResult> songs,
    bool loading,
    String? error, {
    Future<void> Function()? onRetry,
  }) {
    final layout = AppLayout.fromContext(context);
    final listHeight = layout.isWideLandscape
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
        horizontal: AppLayout.fromContext(context).isWideLandscape ? 20 : 12,
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
}

class _FavoriteSongCard extends StatelessWidget {
  final SongSearchResult song;
  final VoidCallback onTap;

  const _FavoriteSongCard({required this.song, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final layout = AppLayout.fromContext(context);
    final cardSize = layout.mediaCardWidth;
    final platformColor = PlatformColors.of(song.platform);
    return InkWell(
      key: ValueKey('home-favorite-${song.platform.code}-${song.id}'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: cardSize,
        margin: const EdgeInsets.symmetric(horizontal: 7),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
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
                fontSize: layout.mediaCardTitleSize,
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
                fontSize: layout.mediaCardSubtitleSize,
                color: AppColors.textHint,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 歌单卡片
class _PlaylistCard extends StatelessWidget {
  final PlaylistInfo playlist;
  final MusicPlatform platform;
  final VoidCallback onTap;

  const _PlaylistCard({
    required this.playlist,
    required this.platform,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final layout = AppLayout.fromContext(context);
    final cardSize = layout.mediaCardWidth;
    final platformColor = PlatformColors.of(platform);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: cardSize,
        margin: const EdgeInsets.symmetric(horizontal: 7),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: SizedBox(
                    width: cardSize,
                    height: cardSize,
                    child:
                        playlist.coverUrl != null &&
                            playlist.coverUrl!.isNotEmpty
                        ? SmartCover(
                            url: playlist.coverUrl,
                            fit: BoxFit.cover,
                            placeholder: () => _coverPlaceholder(platformColor),
                          )
                        : _coverPlaceholder(platformColor),
                  ),
                ),
                // 播放数/角标
                Positioned(
                  right: 6,
                  bottom: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.45),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.play_arrow_rounded,
                          size: 12,
                          color: Colors.white,
                        ),
                        Text(
                          '${playlist.trackCount}',
                          style: const TextStyle(
                            fontSize: 10,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              playlist.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: layout.mediaCardTitleSize,
                fontWeight: FontWeight.w500,
                color: AppColors.textPrimary,
                height: 1.3,
              ),
            ),
            if (playlist.creator != null) ...[
              const SizedBox(height: 2),
              Text(
                playlist.creator!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: layout.mediaCardSubtitleSize,
                  color: AppColors.textHint,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _coverPlaceholder(Color platformColor) {
    return Container(
      color: platformColor.withOpacity(0.12),
      child: Icon(Icons.playlist_play, size: 40, color: platformColor),
    );
  }
}
