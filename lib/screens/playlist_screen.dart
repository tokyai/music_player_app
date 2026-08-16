import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../services/favorite_service.dart';
import '../theme/app_layout.dart';
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
  PlaylistInfo? _playlist;
  bool _loading = false;
  String? _error;

  Future<void> _loadPlaylist(MusicPlatform platform, String id) async {
    final player = context.read<PlayerProvider>();
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final playlist = platform == MusicPlatform.qq
          ? await player.api.qqPlaylist(id)
          : await player.api.neteasePlaylist(id);
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
        Expanded(child: _buildTrackArea()),
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
            Expanded(
              child: _loading
                  ? Center(
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        color: AppColors.primary,
                      ),
                    )
                  : _playlist == null
                  ? Center(
                      child: Text(
                        '导入歌单后在这里查看歌曲',
                        style: TextStyle(
                          color: AppColors.textHint,
                          fontSize: layout.bodySize,
                        ),
                      ),
                    )
                  : _buildTrackList(),
            ),
          ],
        );
      },
    );
  }

  Widget _buildTitleBar({AppLayout? layout}) {
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
                fontSize: layout?.pageTitleSize ?? 24,
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

  Widget _buildTrackArea() {
    if (_loading) {
      return Center(
        child: CircularProgressIndicator(
          strokeWidth: 2.5,
          color: AppColors.primary,
        ),
      );
    }
    if (_playlist == null) return _buildEmpty();
    return _buildTrackList();
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
      borderRadius: BorderRadius.circular(14),
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
    final isLandscape = layout != null;
    final isCompact = layout?.isCompactLandscape ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          p.name,
          maxLines: isLandscape ? (isCompact ? 2 : 3) : 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: isLandscape ? layout.sectionTitleSize : 16,
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
              fontSize: isLandscape ? layout.secondarySize : 12,
              color: AppColors.textSecondary,
            ),
          ),
        ],
        const SizedBox(height: 4),
        Text(
          '${p.trackCount} 首',
          style: TextStyle(
            fontSize: isLandscape ? layout.secondarySize : 12,
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
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: _playlist!.tracks.length,
      itemBuilder: (ctx, i) {
        final track = _playlist!.tracks[i];
        return SongTile(
          song: track,
          showFavorite: true,
          onTap: () {
            context.read<PlayerProvider>().playFromPlaylist(
              _playlist!.tracks,
              i,
            );
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
              shape: BoxShape.circle,
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
              fontSize: isLandscape ? layout.sectionTitleSize : 16,
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
                fontSize: isLandscape ? layout.secondarySize : 12,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
