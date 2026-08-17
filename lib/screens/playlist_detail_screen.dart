import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../services/favorite_service.dart';
import '../theme/app_layout.dart';
import '../theme/app_theme.dart';
import '../widgets/mini_player.dart';
import '../widgets/song_tile.dart';
import '../widgets/smart_cover.dart';

/// 歌单详情页（支持网易云 / QQ音乐）
class PlaylistDetailScreen extends StatefulWidget {
  final PlaylistInfo playlist;
  final MusicPlatform platform;

  const PlaylistDetailScreen({
    super.key,
    required this.playlist,
    required this.platform,
  });

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen> {
  static const _pageSize = 20;
  PlaylistInfo? _detail;
  final List<SongSearchResult> _tracks = <SongSearchResult>[];
  final ScrollController _trackScrollController = ScrollController();
  Future<List<SongSearchResult>>? _loadMoreFuture;
  bool _loading = false;
  bool _loadingMore = false;
  bool _loadingAll = false;
  bool _hasMore = true;
  int _nextOffset = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _trackScrollController.addListener(_handleTrackScroll);
    _loadDetail();
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
    final position = _trackScrollController.position;
    if (position.extentAfter < 520) {
      unawaited(_loadMore(context.read<PlayerProvider>()));
    }
  }

  Future<void> _loadDetail() async {
    final player = context.read<PlayerProvider>();
    setState(() {
      _loading = true;
      _error = null;
      _tracks.clear();
      _nextOffset = 0;
      _hasMore = true;
    });
    try {
      final page = await _fetchPage(player, 0);
      final source = widget.playlist;
      final total = page.total != null && page.total! > 0
          ? page.total!
          : source.trackCount > 0
          ? source.trackCount
          : page.tracks.length;
      final result = PlaylistInfo(
        id: source.id,
        name: source.name,
        coverUrl: source.coverUrl,
        creator: source.creator,
        trackCount: total,
        description: source.description,
        tracks: page.tracks,
      );
      if (mounted) {
        setState(() {
          _detail = result;
          _tracks
            ..clear()
            ..addAll(page.tracks);
          _nextOffset = _tracks.length;
          _hasMore = _pageHasMore(page, _nextOffset);
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = _friendlyError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<PlaylistTrackPage> _fetchPage(PlayerProvider player, int offset) {
    final api = player.api;
    switch (widget.platform) {
      case MusicPlatform.netease:
        return api.neteasePlaylistTracks(
          widget.playlist.id,
          limit: _pageSize,
          offset: offset,
        );
      case MusicPlatform.qq:
        return api.qqPlaylistTracks(
          widget.playlist.id,
          limit: _pageSize,
          offset: offset,
        );
      case MusicPlatform.kugou:
        return api.kugouPlaylistTracks(
          widget.playlist.id,
          page: offset ~/ _pageSize + 1,
          limit: _pageSize,
        );
    }
  }

  bool _pageHasMore(PlaylistTrackPage page, int offset) {
    if (page.total != null && page.total! > 0) return offset < page.total!;
    return page.tracks.length >= _pageSize;
  }

  String _friendlyError(Object error) {
    final message = error.toString();
    if (message.contains('TimeoutException')) return '网络响应较慢，请稍后重试';
    if (message.contains('SocketException')) return '网络连接失败，请检查网络后重试';
    return message;
  }

  Future<List<SongSearchResult>> _loadMore(PlayerProvider player) {
    final pending = _loadMoreFuture;
    if (pending != null) return pending;
    if (_loading || !_hasMore) {
      return Future.value(const <SongSearchResult>[]);
    }

    late final Future<List<SongSearchResult>> operation;
    operation = _loadMorePage(player).whenComplete(() {
      if (identical(_loadMoreFuture, operation)) {
        _loadMoreFuture = null;
      }
    });
    _loadMoreFuture = operation;
    return operation;
  }

  Future<List<SongSearchResult>> _loadMorePage(PlayerProvider player) async {
    final offset = _nextOffset;
    _loadingMore = true;
    if (mounted) setState(() {});
    try {
      final page = await _fetchPage(player, offset);
      final nextTracks = List<SongSearchResult>.of(page.tracks);
      void appendPage() {
        _tracks.addAll(nextTracks);
        _nextOffset = offset + nextTracks.length;
        _hasMore = nextTracks.isNotEmpty && _pageHasMore(page, _nextOffset);
        if (_detail != null) {
          _detail = PlaylistInfo(
            id: _detail!.id,
            name: _detail!.name,
            coverUrl: _detail!.coverUrl,
            creator: _detail!.creator,
            trackCount: _detail!.trackCount,
            description: _detail!.description,
            tracks: List.unmodifiable(_tracks),
          );
        }
      }

      if (mounted) {
        setState(appendPage);
      } else {
        appendPage();
      }
      return nextTracks;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('加载更多失败：${_friendlyError(e)}')));
      }
      return const <SongSearchResult>[];
    } finally {
      _loadingMore = false;
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    AppColors.syncWithTheme(context);
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    return Scaffold(
      body: SafeArea(
        child: isLandscape
            ? _buildLandscapeBody()
            : Column(
                children: [
                  _buildDetailHeader(),
                  Expanded(child: _buildTrackArea()),
                ],
              ),
      ),
      bottomNavigationBar: const SafeArea(top: false, child: MiniPlayer()),
    );
  }

  Widget _buildLandscapeBody() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = AppLayout.fromConstraints(context, constraints);
        final infoWidth = layout.isCompactLandscape
            ? 210.0
            : layout.usesLargeTypography
            ? 370.0
            : (constraints.maxWidth * 0.36).clamp(290.0, 340.0);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: infoWidth,
              child: _buildDetailHeader(layout: layout),
            ),
            VerticalDivider(
              width: 1,
              thickness: 1,
              color: AppColors.surfaceSoft,
            ),
            Expanded(child: _buildTrackArea()),
          ],
        );
      },
    );
  }

  Widget _buildDetailHeader({AppLayout? layout}) {
    final metrics = layout ?? AppLayout.fromContext(context);
    final isLandscape = layout != null;
    final isCompact = layout?.isCompactLandscape ?? false;
    final p = _detail ?? widget.playlist;
    final platformColor = PlatformColors.of(widget.platform);
    final coverSize = isLandscape
        ? isCompact
              ? 104.0
              : layout.usesLargeTypography
              ? 230.0
              : 184.0
        : 108.0;
    final cover = ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.media),
      child: SizedBox(
        width: coverSize,
        height: coverSize,
        child: p.coverUrl != null && p.coverUrl!.isNotEmpty
            ? SmartCover(
                url: p.coverUrl,
                fit: BoxFit.cover,
                placeholder: () => _coverPlaceholder(platformColor),
              )
            : _coverPlaceholder(platformColor),
      ),
    );
    final metadata = Column(
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
    final canPlay = _detail != null && _detail!.tracks.isNotEmpty;
    Future<void> playAll() async {
      if (!canPlay || _loadingAll) return;
      final player = context.read<PlayerProvider>();
      final initialTracks = List<SongSearchResult>.of(_tracks);
      setState(() => _loadingAll = true);
      final playback = player.playFromPlaylist(initialTracks, 0);
      final queueSessionId = player.queueSessionId;
      unawaited(playback);
      try {
        while (_hasMore && player.queueSessionId == queueSessionId) {
          final nextTracks = await _loadMore(player);
          if (nextTracks.isEmpty ||
              !player.addTracksToQueue(
                nextTracks,
                expectedQueueSessionId: queueSessionId,
              )) {
            break;
          }
        }
      } finally {
        if (mounted) setState(() => _loadingAll = false);
      }
    }

    final loadingIcon = SizedBox.square(
      dimension: 22,
      child: CircularProgressIndicator(
        strokeWidth: 2.4,
        color: isLandscape ? null : Colors.white,
      ),
    );
    final loadingLabel = p.trackCount > 0
        ? '加载中 ${_tracks.length}/${p.trackCount}'
        : '加载中';
    final playButton = canPlay
        ? isLandscape
              ? FilledButton.icon(
                  onPressed: _loadingAll ? null : playAll,
                  icon: _loadingAll
                      ? loadingIcon
                      : const Icon(Icons.play_arrow_rounded, size: 24),
                  label: Text(_loadingAll ? loadingLabel : '播放全部'),
                )
              : IconButton.filled(
                  onPressed: _loadingAll ? null : playAll,
                  style: IconButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                  ),
                  icon: _loadingAll
                      ? loadingIcon
                      : const Icon(Icons.play_arrow_rounded, size: 28),
                  tooltip: _loadingAll ? loadingLabel : '播放全部',
                )
        : const SizedBox.shrink();
    final favoriteButton = Consumer<FavoriteService>(
      builder: (context, favorites, _) {
        final isFavorite = favorites.isPlaylistFavorite(widget.platform, p.id);
        return IconButton(
          key: const ValueKey('playlist-favorite-button'),
          tooltip: isFavorite ? '取消收藏歌单' : '收藏歌单',
          style: IconButton.styleFrom(
            backgroundColor: isFavorite
                ? Colors.redAccent.withValues(alpha: 0.14)
                : AppColors.surfaceSoft,
          ),
          onPressed: () async {
            final added = await favorites.togglePlaylist(widget.platform, p);
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(added ? '已收藏歌单: ${p.name}' : '已取消收藏歌单')),
            );
          },
          icon: Icon(
            isFavorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
            color: isFavorite ? Colors.redAccent : AppColors.textSecondary,
          ),
        );
      },
    );

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.panel),
        border: Border.all(color: AppColors.outline),
      ),
      child: isLandscape
          ? ListView(
              key: const PageStorageKey('playlist-detail-landscape-info'),
              padding: EdgeInsets.fromLTRB(
                isCompact ? 10 : 24,
                isCompact ? 6 : 16,
                isCompact ? 10 : 24,
                isCompact ? 14 : 30,
              ),
              children: [
                Row(
                  children: [
                    IconButton(
                      visualDensity: isCompact
                          ? VisualDensity.compact
                          : VisualDensity.standard,
                      tooltip: '返回',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.arrow_back_ios_new),
                    ),
                    SizedBox(width: isCompact ? 2 : 8),
                    Expanded(
                      child: Text(
                        '歌单详情',
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: layout.pageTitleSize,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    favoriteButton,
                  ],
                ),
                SizedBox(height: isCompact ? 4 : 18),
                Center(child: cover),
                SizedBox(height: isCompact ? 10 : 18),
                metadata,
                SizedBox(height: isCompact ? 10 : 18),
                if (canPlay)
                  SizedBox(width: double.infinity, child: playButton),
              ],
            )
          : Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 16, 16),
              child: Row(
                children: [
                  IconButton(
                    tooltip: '返回',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back_ios_new),
                  ),
                  cover,
                  const SizedBox(width: 16),
                  Expanded(child: metadata),
                  playButton,
                  const SizedBox(width: 6),
                  favoriteButton,
                ],
              ),
            ),
    );
  }

  Widget _buildTrackArea() {
    final layout = AppLayout.fromContext(context);
    if (_loading) {
      return Center(
        child: CircularProgressIndicator(
          strokeWidth: layout.isLandscape ? 3 : 2.5,
          color: AppColors.primary,
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '加载失败: $_error',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.redAccent,
                  fontSize: layout.bodySize,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: _loadDetail, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    if (_detail == null || _tracks.isEmpty) {
      return Center(
        child: Text(
          '暂无歌曲',
          style: TextStyle(
            color: AppColors.textHint,
            fontSize: layout.bodySize,
          ),
        ),
      );
    }
    final itemCount = _tracks.length + (_hasMore || _loadingMore ? 1 : 0);
    return ListView.builder(
      key: const PageStorageKey('playlist-detail-tracks'),
      controller: _trackScrollController,
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: itemCount,
      itemBuilder: (ctx, i) {
        if (i >= _tracks.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Center(
              child: _loadingMore
                  ? const SizedBox.square(
                      dimension: 26,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    )
                  : TextButton(
                      key: const ValueKey('playlist-load-more'),
                      onPressed: () =>
                          unawaited(_loadMore(context.read<PlayerProvider>())),
                      child: const Text('加载更多'),
                    ),
            ),
          );
        }
        final track = _tracks[i];
        return SongTile(
          song: track,
          showFavorite: true,
          onTap: () {
            context.read<PlayerProvider>().playFromPlaylist(_tracks, i);
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

  Widget _coverPlaceholder(Color platformColor) {
    return Container(
      color: AppColors.primarySoft,
      child: Icon(Icons.playlist_play, size: 40, color: platformColor),
    );
  }
}
