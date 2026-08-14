import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/song_tile.dart';
import '../widgets/smart_cover.dart';
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
    unawaited(_loadAll());
  }

  Future<void> _loadAll() async {
    await Future.wait([
      _loadQQ(),
      _loadNetease(),
      _loadKugouDaily(),
      _loadKugouNew(),
    ]);
  }

  Future<void> _loadNetease() async {
    setState(() {
      _loadingNetease = true;
      _errNetease = null;
    });
    try {
      final list = await context
          .read<PlayerProvider>()
          .api
          .neteaseHotPlaylists();
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
      final list = await context
          .read<PlayerProvider>()
          .api
          .kugouDailyRecommend();
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
      final list = await context.read<PlayerProvider>().api.kugouNewSongs();
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
          _buildSongSection(_kugouDaily, _loadingKugouDaily, _errKugouDaily),
          const SizedBox(height: 12),
          _buildSectionHeader('酷狗新歌速递', PlatformColors.kugou, '最新上架的热门歌曲'),
          _buildSongSection(_kugouNewSongs, _loadingKugouNew, _errKugouNew),
        ],
      ),
    );
  }

  Widget _buildLandscapeContent() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 760;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _buildLandscapeColumn(
                key: const PageStorageKey('discover-landscape-playlists'),
                compact: compact,
                children: [
                  _buildHeader(),
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
        padding: EdgeInsets.only(bottom: compact ? 12 : 24),
        children: children,
      ),
    );
  }

  /// 顶部问候区
  Widget _buildHeader() {
    final hour = DateTime.now().hour;
    final greet = hour < 6
        ? '夜深了'
        : hour < 12
        ? '早上好'
        : hour < 18
        ? '下午好'
        : '晚上好';
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Image.asset(
              'assets/images/app_logo.png',
              width: 44,
              height: 44,
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
                    fontSize: 20,
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
                    fontSize: 12,
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
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 18,
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
                fontSize: compact ? 15 : 17,
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
                style: TextStyle(fontSize: 11, color: AppColors.textHint),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPlaylistSection(
    List<PlaylistInfo> playlists,
    bool loading,
    String? error,
    MusicPlatform platform,
  ) {
    if (loading) {
      return SizedBox(
        height: 170,
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
      height: 185,
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
    String? error,
  ) {
    if (loading) {
      return SizedBox(
        height: 200,
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
          child: Text('加载失败', style: TextStyle(color: AppColors.textHint)),
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
      margin: const EdgeInsets.symmetric(horizontal: 12),
      decoration: CardStyle.softCard(),
      child: Column(
        children: display.map((song) {
          return SongTile(
            song: song,
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
    final platformColor = PlatformColors.of(platform);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 130,
        margin: const EdgeInsets.symmetric(horizontal: 5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: SizedBox(
                    width: 130,
                    height: 130,
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
                fontSize: 12.5,
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
                style: TextStyle(fontSize: 10, color: AppColors.textHint),
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
