import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../services/favorite_service.dart';
import '../theme/app_layout.dart';
import '../theme/app_motion.dart';
import '../theme/app_theme.dart';
import '../widgets/song_tile.dart';
import '../widgets/playlist_import_dialog.dart';
import '../widgets/smart_cover.dart';
import 'favorites_screen.dart';

class PlaylistScreen extends StatefulWidget {
  const PlaylistScreen({super.key});

  @override
  State<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends State<PlaylistScreen> {
  static const _pageSize = 20;
  PlaylistInfo? _playlist;
  MusicPlatform? _platform;
  final ScrollController _trackScrollController = ScrollController();
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _trackScrollController.addListener(_handleTrackScroll);
  }

  @override
  void dispose() {
    _trackScrollController.dispose();
    super.dispose();
  }

  void _handleTrackScroll() {
    if (!_trackScrollController.hasClients || _loadingMore || !_hasMore) {
      return;
    }
    if (_trackScrollController.position.extentAfter < 520) {
      _loadMoreTracks();
    }
  }

  Future<void> _loadPlaylist(MusicPlatform platform, String id) async {
    final player = context.read<PlayerProvider>();
    setState(() {
      _loading = true;
      _error = null;
      _platform = platform;
      _playlist = null;
      _hasMore = false;
    });

    try {
      PlaylistInfo playlist;
      if (platform == MusicPlatform.qq) {
        playlist = await player.api.qqPlaylist(id);
        _hasMore = playlist.tracks.length < playlist.trackCount;
      } else {
        final page = await player.api.neteasePlaylistTracks(
          id,
          limit: _pageSize,
        );
        playlist = PlaylistInfo(
          id: id,
          name: '网易云歌单',
          trackCount: page.total ?? page.tracks.length,
          tracks: page.tracks,
        );
        _hasMore = page.hasMore(0, _pageSize);
      }
      if (!mounted) return;
      setState(() {
        _playlist = playlist;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  PlaylistInfo _copyPlaylist(
    PlaylistInfo source,
    List<SongSearchResult> tracks,
  ) {
    return PlaylistInfo(
      id: source.id,
      name: source.name,
      coverUrl: source.coverUrl,
      creator: source.creator,
      trackCount: source.trackCount,
      description: source.description,
      tracks: tracks,
    );
  }

  Future<void> _loadMoreTracks() async {
    final playlist = _playlist;
    final platform = _platform;
    if (playlist == null || platform == null || _loadingMore || !_hasMore) {
      return;
    }
    setState(() => _loadingMore = true);
    try {
      final offset = playlist.tracks.length;
      final api = context.read<PlayerProvider>().api;
      final page = platform == MusicPlatform.qq
          ? await api.qqPlaylistTracks(
              playlist.id,
              limit: _pageSize,
              offset: offset,
            )
          : await api.neteasePlaylistTracks(
              playlist.id,
              limit: _pageSize,
              offset: offset,
            );
      final nextTracks = page.tracks;
      final total = page.total;
      if (!mounted) return;
      final combined = [...playlist.tracks, ...nextTracks];
      setState(() {
        _playlist = _copyPlaylist(playlist, combined);
        _hasMore =
            nextTracks.isNotEmpty &&
            (total != null
                ? combined.length < total
                : nextTracks.length >= _pageSize);
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('加载更多失败，请稍后重试')));
      }
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    AppColors.syncWithTheme(context);
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    return Scaffold(
      body: SafeArea(
        child: isLandscape ? _buildLandscapeBody() : _buildPortraitBody(),
      ),
    );
  }

  Widget _buildPortraitBody() {
    return Column(
      children: [
        _buildTitleBar(),
        if (_playlist != null) _buildPlaylistHeader(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              _error!,
              style: const TextStyle(color: Colors.redAccent),
            ),
          ),
        Expanded(child: _buildAnimatedTrackArea()),
      ],
    );
  }

  Widget _buildLandscapeBody() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = AppLayout.fromConstraints(context, constraints);
        final infoWidth = layout.isCompactLandscape
            ? 210.0
            : layout.usesLargeTypography
            ? 340.0
            : (constraints.maxWidth * 0.35).clamp(280.0, 320.0);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: infoWidth,
              child: ListView(
                key: const PageStorageKey('playlist-landscape-info'),
                padding: EdgeInsets.only(
                  bottom: layout.isCompactLandscape ? 12 : 28,
                ),
                children: [
                  _buildTitleBar(layout: layout),
                  if (_playlist != null)
                    _buildPlaylistHeader(layout: layout)
                  else
                    _buildEmpty(layout: layout),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Colors.redAccent,
                          fontSize: layout.bodySize,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            VerticalDivider(
              width: 1,
              thickness: 1,
              color: AppColors.surfaceSoft,
            ),
            Expanded(child: _buildAnimatedTrackArea(layout: layout)),
          ],
        );
      },
    );
  }

  Widget _buildTitleBar({AppLayout? layout}) {
    final metrics = layout ?? AppLayout.fromContext(context);
    final isLandscape = layout != null;
    final isCompact = layout?.isCompactLandscape ?? false;
    final favoriteButton = Consumer<FavoriteService>(
      builder: (context, favorites, _) => IconButton(
        tooltip: '我的收藏',
        visualDensity: isCompact ? VisualDensity.compact : null,
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const FavoritesScreen()),
        ),
        icon: Icon(
          favorites.favorites.isEmpty ? Icons.favorite_border : Icons.favorite,
          size: isLandscape ? (isCompact ? 22 : 26) : 24,
          color: favorites.favorites.isEmpty
              ? AppColors.textSecondary
              : Colors.redAccent,
        ),
      ),
    );
    final importButton = isCompact
        ? IconButton.filledTonal(
            tooltip: '导入歌单',
            visualDensity: VisualDensity.compact,
            onPressed: _showImportDialog,
            icon: const Icon(Icons.add, size: 22),
          )
        : FilledButton.icon(
            onPressed: _showImportDialog,
            icon: const Icon(Icons.add, size: 20),
            label: Text(isLandscape ? '导入歌单' : '导入'),
            style: FilledButton.styleFrom(
              padding: EdgeInsets.symmetric(
                horizontal: isLandscape ? 14 : 10,
                vertical: isLandscape ? 10 : 7,
              ),
            ),
          );
    return Padding(
      padding: EdgeInsets.fromLTRB(
        isLandscape ? (isCompact ? 12 : 20) : 20,
        isLandscape ? (isCompact ? 8 : 18) : 16,
        isLandscape ? (isCompact ? 10 : 20) : 20,
        isLandscape ? (isCompact ? 6 : 10) : 8,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '我的歌单',
              style: TextStyle(
                fontSize: metrics.pageTitleSize,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          favoriteButton,
          if (!isCompact) const SizedBox(width: 4),
          importButton,
        ],
      ),
    );
  }

  void _showImportDialog() {
    showDialog(
      context: context,
      builder: (_) => PlaylistImportDialog(
        onImport: (platform, id) => _loadPlaylist(platform, id),
      ),
    );
  }

  Widget _buildAnimatedTrackArea({AppLayout? layout}) {
    final stateKey = _loading
        ? 'loading'
        : _playlist == null
        ? 'empty'
        : 'content';
    final Widget content;
    if (_loading) {
      content = Center(
        child: CircularProgressIndicator(
          strokeWidth: layout == null ? 2.5 : 3,
          color: AppColors.primary,
        ),
      );
    } else if (_playlist == null) {
      content = layout == null
          ? _buildEmpty()
          : Center(
              child: Text(
                '导入歌单后在这里查看歌曲',
                style: TextStyle(
                  color: AppColors.textHint,
                  fontSize: layout.bodySize,
                ),
              ),
            );
    } else {
      content = _buildTrackList();
    }
    return AppMotionSwitcher(
      child: KeyedSubtree(
        key: ValueKey('imported-playlist-$stateKey'),
        child: content,
      ),
    );
  }

  Widget _buildPlaylistHeader({AppLayout? layout}) {
    final p = _playlist!;
    final isLandscape = layout != null;
    final isCompact = layout?.isCompactLandscape ?? false;
    final coverSize = isCompact
        ? 112.0
        : layout?.usesLargeTypography == true
        ? 210.0
        : 176.0;
    return Container(
      margin: EdgeInsets.fromLTRB(
        isLandscape ? (isCompact ? 10 : 18) : 16,
        isLandscape ? (isCompact ? 6 : 10) : 8,
        isLandscape ? (isCompact ? 10 : 18) : 16,
        8,
      ),
      padding: EdgeInsets.all(isLandscape ? (isCompact ? 10 : 18) : 16),
      decoration: CardStyle.softCard(),
      child: isLandscape
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(child: _buildPlaylistCover(p, size: coverSize)),
                SizedBox(height: isCompact ? 10 : 16),
                _buildPlaylistMetadata(p, layout: layout),
                SizedBox(height: isCompact ? 10 : 16),
                SizedBox(
                  width: double.infinity,
                  child: _buildPlayAllButton(showLabel: true),
                ),
              ],
            )
          : Row(
              children: [
                _buildPlaylistCover(p),
                const SizedBox(width: 16),
                Expanded(child: _buildPlaylistMetadata(p)),
                const SizedBox(width: 8),
                _buildPlayAllButton(),
              ],
            ),
    );
  }

  Widget _buildPlaylistCover(PlaylistInfo p, {double size = 92}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.media),
      child: SizedBox(
        width: size,
        height: size,
        child: p.coverUrl != null && p.coverUrl!.isNotEmpty
            ? SmartCover(
                url: p.coverUrl,
                fit: BoxFit.cover,
                placeholder: () => _coverPlaceholder(),
              )
            : _coverPlaceholder(),
      ),
    );
  }

  Widget _buildPlaylistMetadata(PlaylistInfo p, {AppLayout? layout}) {
    final metrics = layout ?? AppLayout.fromContext(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          p.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: metrics.sectionTitleSize,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        if (p.creator != null) ...[
          const SizedBox(height: 6),
          Text(
            'by ${p.creator}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: metrics.secondarySize,
              color: AppColors.textSecondary,
            ),
          ),
        ],
        const SizedBox(height: 4),
        Text(
          '${p.trackCount} 首',
          style: TextStyle(
            fontSize: metrics.secondarySize,
            color: AppColors.textSecondary,
          ),
        ),
      ],
    );
  }

  Widget _buildPlayAllButton({bool showLabel = false}) {
    final onPressed = () {
      if (_playlist!.tracks.isNotEmpty) {
        context.read<PlayerProvider>().playFromPlaylist(_playlist!.tracks, 0);
      }
    };
    if (showLabel) {
      return FilledButton.icon(
        onPressed: onPressed,
        icon: const Icon(Icons.play_arrow_rounded, size: 24),
        label: const Text('播放全部'),
      );
    }
    return IconButton.filled(
      onPressed: onPressed,
      style: IconButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      icon: const Icon(Icons.play_arrow_rounded, size: 26),
      tooltip: '播放全部',
    );
  }

  Widget _coverPlaceholder() {
    return Container(
      color: AppColors.primarySoft,
      child: Icon(Icons.playlist_play, size: 40, color: AppColors.primary),
    );
  }

  Widget _buildTrackList() {
    final tracks = _playlist!.tracks;
    return ListView.builder(
      controller: _trackScrollController,
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: tracks.length + (_hasMore || _loadingMore ? 1 : 0),
      itemBuilder: (ctx, i) {
        if (i >= tracks.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Center(
              child: AppMotionSwitcher(
                beginOffset: Offset.zero,
                child: _loadingMore
                    ? const SizedBox.square(
                        key: ValueKey('imported-playlist-loading-more'),
                        dimension: 26,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      )
                    : TextButton(
                        key: const ValueKey('playlist-load-more'),
                        onPressed: _loadMoreTracks,
                        child: const Text('加载更多'),
                      ),
              ),
            ),
          );
        }
        final track = tracks[i];
        return SongTile(
          song: track,
          showFavorite: true,
          onTap: () {
            context.read<PlayerProvider>().playFromPlaylist(tracks, i);
          },
          onAddToQueue: () {
            context.read<PlayerProvider>().addToQueue(track);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('已添加: ${track.name}'),
                duration: const Duration(seconds: 1),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildEmpty({AppLayout? layout}) {
    final metrics = layout ?? AppLayout.fromContext(context);
    final isLandscape = layout != null;
    final isCompact = layout?.isCompactLandscape ?? false;
    final iconSize = isLandscape ? (isCompact ? 70.0 : 112.0) : 96.0;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: iconSize,
            height: iconSize,
            decoration: BoxDecoration(
              color: AppColors.primarySoft,
              borderRadius: BorderRadius.circular(AppRadius.panel),
            ),
            child: Icon(
              Icons.playlist_play,
              size: isLandscape ? (isCompact ? 34 : 50) : 44,
              color: AppColors.primary,
            ),
          ),
          SizedBox(height: isCompact ? 10 : 16),
          Text(
            '导入 QQ音乐 / 网易云歌单',
            style: TextStyle(
              fontSize: metrics.sectionTitleSize,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          if (!isCompact) ...[
            const SizedBox(height: 6),
            Text(
              '支持粘贴歌单链接或输入 ID，一键导入全部歌曲',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: metrics.secondarySize,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
