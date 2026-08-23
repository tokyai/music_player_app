import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../services/api_service.dart';
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
  int _loadRequestId = 0;

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
    if (!mounted ||
        !_trackScrollController.hasClients ||
        _loading ||
        _loadingMore ||
        !_hasMore) {
      return;
    }
    if (_trackScrollController.position.extentAfter < 520) {
      _loadMoreTracks();
    }
  }

  Future<void> _loadPlaylist(
    MusicPlatform platform,
    String id, {
    bool saveOnSuccess = false,
    PlaylistInfo? savedMetadata,
  }) async {
    if (!mounted) return;
    final player = context.read<PlayerProvider>();
    final favorites = context.read<FavoriteService>();
    final requestId = ++_loadRequestId;
    setState(() {
      _loading = true;
      _loadingMore = false;
      _error = null;
    });

    try {
      final (playlist, hasMore) = await _fetchPlaylist(
        player,
        platform,
        id,
        savedMetadata: savedMetadata,
      );
      if (!mounted || requestId != _loadRequestId) return;
      final added = saveOnSuccess
          ? await favorites.savePlaylist(platform, playlist)
          : false;
      if (!mounted || requestId != _loadRequestId) return;
      setState(() {
        _platform = platform;
        _playlist = playlist;
        _hasMore = hasMore;
        _loading = false;
      });
      if (saveOnSuccess) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(added ? '已导入：${playlist.name}' : '歌单已存在，已打开')),
        );
      }
    } catch (e) {
      if (!mounted || requestId != _loadRequestId) return;
      setState(() {
        _error = e is ApiException ? e.message : e.toString();
        _loading = false;
      });
    }
  }

  Future<(PlaylistInfo, bool)> _fetchPlaylist(
    PlayerProvider player,
    MusicPlatform platform,
    String id, {
    PlaylistInfo? savedMetadata,
  }) async {
    switch (platform) {
      case MusicPlatform.qq:
        if (savedMetadata == null) {
          final playlist = await player.api.qqPlaylist(id);
          return (playlist, playlist.tracks.length < playlist.trackCount);
        }
        final page = await player.api.qqPlaylistTracks(id, limit: _pageSize);
        final playlist = _copyPlaylist(
          savedMetadata,
          page.tracks,
          trackCount: page.total,
        );
        return (playlist, page.hasMore(0, _pageSize));
      case MusicPlatform.netease:
        final metadata =
            savedMetadata ?? await player.api.neteasePlaylistSummary(id);
        final page = await player.api.neteasePlaylistTracks(
          id,
          limit: _pageSize,
        );
        final playlist = _copyPlaylist(
          metadata,
          page.tracks,
          trackCount: page.total,
        );
        return (playlist, page.hasMore(0, _pageSize));
      case MusicPlatform.kugou:
        if (savedMetadata == null) {
          throw const ApiException('PLAYLIST_IMPORT_UNSUPPORTED', '导入暂不支持酷狗歌单');
        }
        final page = await player.api.kugouPlaylistTracks(id, limit: _pageSize);
        final playlist = _copyPlaylist(
          savedMetadata,
          page.tracks,
          trackCount: page.total,
        );
        return (playlist, page.hasMore(0, _pageSize));
      case MusicPlatform.bilibili:
        throw const ApiException('PLAYLIST_UNSUPPORTED', 'B站歌单暂不支持在此页打开');
    }
  }

  PlaylistInfo _copyPlaylist(
    PlaylistInfo source,
    List<SongSearchResult> tracks, {
    int? trackCount,
  }) {
    return PlaylistInfo(
      id: source.id,
      name: source.name,
      coverUrl: source.coverUrl,
      creator: source.creator,
      trackCount: trackCount ?? source.trackCount,
      description: source.description,
      tracks: tracks,
    );
  }

  Future<void> _loadMoreTracks() async {
    if (!mounted) return;
    final playlist = _playlist;
    final platform = _platform;
    final requestId = _loadRequestId;
    if (playlist == null ||
        platform == null ||
        _loading ||
        _loadingMore ||
        !_hasMore) {
      return;
    }
    setState(() => _loadingMore = true);
    try {
      final offset = playlist.tracks.length;
      final api = context.read<PlayerProvider>().api;
      final page = switch (platform) {
        MusicPlatform.qq => await api.qqPlaylistTracks(
          playlist.id,
          limit: _pageSize,
          offset: offset,
        ),
        MusicPlatform.netease => await api.neteasePlaylistTracks(
          playlist.id,
          limit: _pageSize,
          offset: offset,
        ),
        MusicPlatform.kugou => await api.kugouPlaylistTracks(
          playlist.id,
          page: offset ~/ _pageSize + 1,
          limit: _pageSize,
        ),
        MusicPlatform.bilibili => throw const ApiException(
          'PLAYLIST_UNSUPPORTED',
          'B站歌单暂不支持在此页打开',
        ),
      };
      final nextTracks = page.tracks;
      final total = page.total;
      if (!mounted || requestId != _loadRequestId) return;
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
      if (mounted && requestId == _loadRequestId) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('加载更多失败，请稍后重试')));
      }
    } finally {
      if (mounted && requestId == _loadRequestId) {
        setState(() => _loadingMore = false);
      }
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
        _buildPlaylistSelector(),
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
        final libraryWidth = layout.isCompactLandscape
            ? (constraints.maxWidth * 0.31).clamp(168.0, 196.0)
            : layout.usesLargeTypography
            ? 310.0
            : (constraints.maxWidth * 0.27).clamp(240.0, 290.0);
        final pageGap = layout.isCompactLandscape ? 10.0 : 18.0;
        return Column(
          children: [
            _buildTitleBar(layout: layout),
            Expanded(
              child: Padding(
                key: const ValueKey('playlist-landscape-workspace'),
                padding: EdgeInsets.fromLTRB(
                  layout.isCompactLandscape ? 10 : layout.pagePadding,
                  0,
                  layout.isCompactLandscape ? 10 : layout.pagePadding,
                  layout.isCompactLandscape ? 10 : 20,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: libraryWidth,
                      child: _buildPlaylistLibrary(layout),
                    ),
                    VerticalDivider(
                      width: pageGap,
                      thickness: 1,
                      indent: layout.isCompactLandscape ? 5 : 9,
                      endIndent: layout.isCompactLandscape ? 5 : 9,
                      color: AppColors.outline.withValues(alpha: 0.72),
                    ),
                    Expanded(
                      key: const ValueKey('playlist-landscape-content'),
                      child: Column(
                        children: [
                          if (_error != null)
                            Padding(
                              padding: EdgeInsets.only(
                                bottom: layout.isCompactLandscape ? 6 : 12,
                              ),
                              child: Material(
                                color: Colors.redAccent.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(
                                  AppRadius.small,
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 8,
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(
                                        Icons.error_outline_rounded,
                                        color: Colors.redAccent,
                                        size: 20,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          _error!,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: Colors.redAccent,
                                            fontSize: layout.secondarySize,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          Expanded(
                            child: _buildAnimatedTrackArea(layout: layout),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
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
      builder: (context, favorites, _) {
        final icon = Icon(
          favorites.favorites.isEmpty ? Icons.favorite_border : Icons.favorite,
          size: isLandscape ? (isCompact ? 21 : 24) : 24,
          color: favorites.favorites.isEmpty
              ? AppColors.textSecondary
              : Colors.redAccent,
        );
        void openFavorites() => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const FavoriteSongsScreen()),
        );
        if (isLandscape && !isCompact) {
          return OutlinedButton.icon(
            onPressed: openFavorites,
            icon: icon,
            label: const Text('我的收藏'),
          );
        }
        return IconButton.filledTonal(
          tooltip: '我的收藏',
          visualDensity: isCompact ? VisualDensity.compact : null,
          onPressed: openFavorites,
          icon: icon,
        );
      },
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '我的歌单',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: metrics.pageTitleSize,
                    height: 1.12,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                if (isLandscape) ...[
                  const SizedBox(height: 2),
                  Consumer<FavoriteService>(
                    builder: (context, favorites, _) {
                      final playlistCount = favorites.favoritePlaylists.length;
                      return Text(
                        playlistCount == 0
                            ? '整理你的私人音乐库'
                            : '$playlistCount 个已导入歌单',
                        style: TextStyle(
                          fontSize: metrics.secondarySize,
                          color: AppColors.textSecondary,
                        ),
                      );
                    },
                  ),
                ],
              ],
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
        onImport: (platform, id) =>
            _loadPlaylist(platform, id, saveOnSuccess: true),
      ),
    );
  }

  Widget _buildPlaylistSelector() {
    return Consumer<FavoriteService>(
      builder: (context, favorites, _) {
        final playlists = favorites.favoritePlaylists;
        if (playlists.isEmpty) return const SizedBox.shrink();
        return SizedBox(
          height: 68,
          child: ListView.separated(
            key: const ValueKey('imported-playlist-selector'),
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
            itemCount: playlists.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (_, index) => SizedBox(
              width: 220,
              child: _buildPlaylistLibraryItem(playlists[index], compact: true),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPlaylistLibrary(AppLayout layout) {
    final compact = layout.isCompactLandscape;
    return Container(
      key: const ValueKey('playlist-landscape-library'),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.outline),
      ),
      clipBehavior: Clip.antiAlias,
      child: Consumer<FavoriteService>(
        builder: (context, favorites, _) {
          final playlists = favorites.favoritePlaylists;
          return Column(
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  compact ? 10 : 16,
                  compact ? 8 : 14,
                  compact ? 8 : 12,
                  compact ? 7 : 12,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.library_music_rounded,
                      size: compact ? 20 : 24,
                      color: AppColors.primary,
                    ),
                    SizedBox(width: compact ? 6 : 9),
                    Expanded(
                      child: Text(
                        '歌单库',
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: compact ? 16 : layout.bodySize,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: compact ? 7 : 9,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceSoft,
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                      child: Text(
                        '${playlists.length}',
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: compact ? 12 : layout.secondarySize,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Divider(color: AppColors.surfaceSoft),
              Expanded(
                child: playlists.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Text(
                            '还没有歌单\n点击右上角导入',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: AppColors.textHint,
                              fontSize: compact ? 14 : layout.secondarySize,
                              height: 1.45,
                            ),
                          ),
                        ),
                      )
                    : ListView.separated(
                        key: const PageStorageKey(
                          'playlist-landscape-library-list',
                        ),
                        padding: EdgeInsets.all(compact ? 6 : 9),
                        itemCount: playlists.length,
                        separatorBuilder: (_, _) =>
                            SizedBox(height: compact ? 4 : 7),
                        itemBuilder: (_, index) => _buildPlaylistLibraryItem(
                          playlists[index],
                          compact: compact,
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildPlaylistLibraryItem(
    FavoritePlaylist favorite, {
    required bool compact,
  }) {
    final selected =
        _platform == favorite.platform && _playlist?.id == favorite.id;
    final platformColor = PlatformColors.of(favorite.platform);
    final coverSize = compact ? 42.0 : 56.0;
    return Material(
      key: ValueKey(
        'imported-playlist-${favorite.platform.code}-${favorite.id}',
      ),
      color: selected
          ? AppColors.primarySoft.withValues(alpha: 0.86)
          : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.small),
        side: BorderSide(
          color: selected
              ? AppColors.primary.withValues(alpha: 0.42)
              : Colors.transparent,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _loadPlaylist(
          favorite.platform,
          favorite.id,
          savedMetadata: favorite.playlist,
        ),
        onLongPress: () => _confirmDeletePlaylist(favorite),
        child: Padding(
          padding: EdgeInsets.all(compact ? 6 : 8),
          child: Row(
            children: [
              _buildSavedPlaylistCover(
                favorite,
                size: coverSize,
                platformColor: platformColor,
              ),
              SizedBox(width: compact ? 8 : 11),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      favorite.playlist.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: selected
                            ? AppColors.primary
                            : AppColors.textPrimary,
                        fontSize: compact ? 15 : 18,
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${favorite.platform.label} · ${favorite.playlist.trackCount} 首',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: compact ? 12.5 : 15,
                      ),
                    ),
                  ],
                ),
              ),
              if (selected) ...[
                const SizedBox(width: 2),
                IconButton(
                  tooltip: '删除歌单 ${favorite.playlist.name}',
                  visualDensity: VisualDensity.compact,
                  style: IconButton.styleFrom(
                    minimumSize: Size.square(compact ? 32 : 38),
                    maximumSize: Size.square(compact ? 32 : 38),
                    padding: EdgeInsets.zero,
                  ),
                  onPressed: () => _confirmDeletePlaylist(favorite),
                  icon: Icon(
                    Icons.close_rounded,
                    size: compact ? 18 : 20,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSavedPlaylistCover(
    FavoritePlaylist favorite, {
    required double size,
    required Color platformColor,
  }) {
    final coverUrl = favorite.playlist.coverUrl;
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.small),
      child: SizedBox.square(
        dimension: size,
        child: coverUrl != null && coverUrl.isNotEmpty
            ? SmartCover(
                url: coverUrl,
                fit: BoxFit.cover,
                placeholder: () => _savedPlaylistPlaceholder(platformColor),
              )
            : _savedPlaylistPlaceholder(platformColor),
      ),
    );
  }

  Widget _savedPlaylistPlaceholder(Color platformColor) {
    return ColoredBox(
      color: platformColor.withValues(alpha: 0.14),
      child: Icon(Icons.queue_music_rounded, color: platformColor, size: 26),
    );
  }

  Future<void> _confirmDeletePlaylist(FavoritePlaylist favorite) async {
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除歌单'),
        content: Text('确定从我的歌单中删除「${favorite.playlist.name}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final deletingSelected =
        _platform == favorite.platform && _playlist?.id == favorite.id;
    if (deletingSelected) {
      _loadRequestId++;
      setState(() {
        _playlist = null;
        _platform = null;
        _loading = false;
        _loadingMore = false;
        _hasMore = false;
        _error = null;
      });
    }
    try {
      await context.read<FavoriteService>().removePlaylist(
        favorite.platform,
        favorite.id,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已删除：${favorite.playlist.name}')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('删除歌单失败：$error')));
    }
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
      content = layout == null ? _buildEmpty() : _buildLandscapeEmpty(layout);
    } else {
      content = layout == null
          ? _buildTrackList()
          : _buildLandscapePlaylistContent(layout);
    }
    return AppMotionSwitcher(
      child: KeyedSubtree(
        key: ValueKey('imported-playlist-$stateKey'),
        child: content,
      ),
    );
  }

  Widget _buildLandscapePlaylistContent(AppLayout layout) {
    return Column(
      children: [
        _buildPlaylistHeader(layout: layout),
        SizedBox(height: layout.isCompactLandscape ? 7 : 14),
        Expanded(child: _buildLandscapeTrackPanel(layout)),
      ],
    );
  }

  Widget _buildPlaylistHeader({AppLayout? layout}) {
    final p = _playlist!;
    if (layout != null) return _buildLandscapePlaylistHeader(p, layout);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      padding: const EdgeInsets.all(16),
      decoration: CardStyle.softCard(),
      child: Row(
        children: [
          _buildPlaylistCover(p),
          const SizedBox(width: 16),
          Expanded(child: _buildPlaylistMetadata(p)),
          const SizedBox(width: 8),
          _buildDeletePlaylistButton(p),
          const SizedBox(width: 4),
          _buildPlayAllButton(),
        ],
      ),
    );
  }

  Widget _buildLandscapePlaylistHeader(
    PlaylistInfo playlist,
    AppLayout layout,
  ) {
    final compact = layout.isCompactLandscape;
    final platform = _platform;
    final accent = platform == null
        ? AppColors.primary
        : PlatformColors.of(platform);
    final coverSize = compact
        ? 76.0
        : layout.usesLargeTypography
        ? 164.0
        : 138.0;
    final platformBadge = Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 7 : 10,
        vertical: compact ? 2 : 4,
      ),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        platform?.label ?? '歌单',
        style: TextStyle(
          color: accent,
          fontSize: compact ? 11.5 : layout.secondarySize,
          fontWeight: FontWeight.w700,
        ),
      ),
    );

    return Container(
      key: const ValueKey('playlist-current-header'),
      padding: EdgeInsets.all(compact ? 8 : 20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            accent.withValues(alpha: AppColors.isDark ? 0.18 : 0.12),
            AppColors.surface,
          ],
        ),
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: accent.withValues(alpha: 0.24)),
      ),
      child: Row(
        children: [
          _buildPlaylistCover(playlist, size: coverSize),
          SizedBox(width: compact ? 10 : 20),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    platformBadge,
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${playlist.trackCount} 首歌曲',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: compact ? 12.5 : layout.secondarySize,
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: compact ? 3 : 8),
                Text(
                  playlist.name,
                  maxLines: compact ? 1 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: layout.sectionTitleSize,
                    height: 1.16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (playlist.creator != null &&
                    playlist.creator!.isNotEmpty) ...[
                  SizedBox(height: compact ? 2 : 5),
                  Text(
                    '创建者 · ${playlist.creator}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: layout.secondarySize,
                    ),
                  ),
                ],
                if (!compact &&
                    playlist.description != null &&
                    playlist.description!.isNotEmpty) ...[
                  const SizedBox(height: 7),
                  Text(
                    playlist.description!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.textHint,
                      fontSize: layout.secondarySize,
                      height: 1.35,
                    ),
                  ),
                ],
                if (!compact) ...[
                  const SizedBox(height: 14),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildPlayAllButton(showLabel: true),
                      const SizedBox(width: 8),
                      _buildDeletePlaylistButton(playlist),
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (compact) ...[
            const SizedBox(width: 6),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildPlayAllButton(compact: true),
                const SizedBox(height: 4),
                _buildDeletePlaylistButton(playlist, compact: true),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLandscapeTrackPanel(AppLayout layout) {
    final tracks = _playlist!.tracks;
    final loadedLabel = _hasMore
        ? '${tracks.length} / ${_playlist!.trackCount}'
        : '${tracks.length}';
    return Container(
      key: const ValueKey('playlist-track-panel'),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.outline),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: layout.isCompactLandscape ? 11 : 18,
              vertical: layout.isCompactLandscape ? 5 : 11,
            ),
            child: Row(
              children: [
                Icon(
                  Icons.graphic_eq_rounded,
                  color: AppColors.primary,
                  size: layout.isCompactLandscape ? 20 : 24,
                ),
                const SizedBox(width: 8),
                Text(
                  '歌曲',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: layout.isCompactLandscape ? 17 : layout.bodySize,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                Text(
                  '$loadedLabel 首',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: layout.secondarySize,
                  ),
                ),
              ],
            ),
          ),
          Divider(color: AppColors.surfaceSoft),
          Expanded(
            child: tracks.isEmpty
                ? Center(
                    child: Text(
                      '这个歌单暂时没有可播放歌曲',
                      style: TextStyle(
                        color: AppColors.textHint,
                        fontSize: layout.bodySize,
                      ),
                    ),
                  )
                : _buildTrackList(
                    padding: EdgeInsets.fromLTRB(
                      layout.isCompactLandscape ? 3 : 7,
                      layout.isCompactLandscape ? 2 : 5,
                      layout.isCompactLandscape ? 3 : 7,
                      10,
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildLandscapeEmpty(AppLayout layout) {
    final compact = layout.isCompactLandscape;
    return Consumer<FavoriteService>(
      builder: (context, favorites, _) {
        final hasSavedPlaylists = favorites.favoritePlaylists.isNotEmpty;
        return Container(
          key: const ValueKey('playlist-landscape-empty'),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppColors.primarySoft, AppColors.surface],
            ),
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: AppColors.outline),
          ),
          child: Center(
            child: SingleChildScrollView(
              padding: EdgeInsets.all(compact ? 12 : 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: compact ? 52 : 78,
                    height: compact ? 52 : 78,
                    decoration: BoxDecoration(
                      color: AppColors.surface.withValues(alpha: 0.86),
                      borderRadius: BorderRadius.circular(AppRadius.card),
                    ),
                    child: Icon(
                      hasSavedPlaylists
                          ? Icons.touch_app_rounded
                          : Icons.library_add_rounded,
                      color: AppColors.primary,
                      size: compact ? 28 : 40,
                    ),
                  ),
                  SizedBox(height: compact ? 9 : 16),
                  Text(
                    hasSavedPlaylists ? '选择一个歌单开始播放' : '建立你的歌单库',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: layout.sectionTitleSize,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (!compact) ...[
                    const SizedBox(height: 7),
                    Text(
                      hasSavedPlaylists
                          ? '从左侧歌单库选择内容，歌曲与播放操作会显示在这里'
                          : '支持 QQ音乐和网易云，粘贴链接或输入歌单 ID 即可导入',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: layout.secondarySize,
                      ),
                    ),
                  ],
                  SizedBox(height: compact ? 10 : 18),
                  FilledButton.icon(
                    onPressed: _showImportDialog,
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('立即导入'),
                    style: compact
                        ? FilledButton.styleFrom(
                            minimumSize: const Size(44, 42),
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                          )
                        : null,
                  ),
                ],
              ),
            ),
          ),
        );
      },
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

  Widget _buildPlayAllButton({bool showLabel = false, bool compact = false}) {
    final VoidCallback? onPressed = _playlist!.tracks.isEmpty
        ? null
        : () {
            context.read<PlayerProvider>().playFromPlaylist(
              _playlist!.tracks,
              0,
            );
          };
    if (showLabel) {
      return FilledButton.icon(
        key: const ValueKey('playlist-play-all-button'),
        onPressed: onPressed,
        icon: const Icon(Icons.play_arrow_rounded, size: 24),
        label: const Text('播放全部'),
      );
    }
    return IconButton.filled(
      key: const ValueKey('playlist-play-all-button'),
      onPressed: onPressed,
      style: IconButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        minimumSize: compact ? const Size.square(38) : null,
        maximumSize: compact ? const Size.square(38) : null,
        padding: compact ? EdgeInsets.zero : null,
      ),
      icon: Icon(Icons.play_arrow_rounded, size: compact ? 23 : 26),
      tooltip: '播放全部',
    );
  }

  Widget _buildDeletePlaylistButton(
    PlaylistInfo playlist, {
    bool compact = false,
  }) {
    final platform = _platform;
    if (platform == null) return const SizedBox.shrink();
    return IconButton(
      key: const ValueKey('delete-current-playlist'),
      tooltip: '删除当前歌单',
      visualDensity: compact ? VisualDensity.compact : null,
      style: compact
          ? IconButton.styleFrom(
              minimumSize: const Size.square(38),
              maximumSize: const Size.square(38),
              padding: EdgeInsets.zero,
            )
          : null,
      onPressed: () => _confirmDeletePlaylist(
        FavoritePlaylist(platform: platform, playlist: playlist),
      ),
      icon: Icon(Icons.delete_outline_rounded, size: compact ? 21 : null),
    );
  }

  Widget _coverPlaceholder() {
    return Container(
      color: AppColors.primarySoft,
      child: const Icon(
        Icons.playlist_play,
        size: 40,
        color: AppColors.primary,
      ),
    );
  }

  Widget _buildTrackList({EdgeInsetsGeometry? padding}) {
    final tracks = _playlist!.tracks;
    return ListView.builder(
      key: const ValueKey('playlist-track-list'),
      controller: _trackScrollController,
      padding: padding ?? const EdgeInsets.only(bottom: 16),
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
