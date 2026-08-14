import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/song_tile.dart';
import '../widgets/playlist_import_dialog.dart';
import '../widgets/smart_cover.dart';

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
        final infoWidth = (constraints.maxWidth * 0.36).clamp(220.0, 320.0);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: infoWidth,
              child: ListView(
                key: const PageStorageKey('playlist-landscape-info'),
                padding: const EdgeInsets.only(bottom: 20),
                children: [
                  _buildTitleBar(compact: true),
                  if (_playlist != null)
                    _buildPlaylistHeader(compact: true)
                  else
                    _buildEmpty(),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        _error!,
                        style: const TextStyle(color: Colors.redAccent),
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
                        strokeWidth: 2.5,
                        color: AppColors.primary,
                      ),
                    )
                  : _playlist == null
                  ? Center(
                      child: Text(
                        '导入歌单后在这里查看歌曲',
                        style: TextStyle(color: AppColors.textHint),
                      ),
                    )
                  : _buildTrackList(),
            ),
          ],
        );
      },
    );
  }

  Widget _buildTitleBar({bool compact = false}) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        compact ? 14 : 20,
        compact ? 10 : 16,
        compact ? 14 : 20,
        compact ? 6 : 8,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '我的歌单',
              style: TextStyle(
                fontSize: compact ? 20 : 24,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          FilledButton.icon(
            onPressed: () {
              showDialog(
                context: context,
                builder: (_) => PlaylistImportDialog(
                  onImport: (platform, id) => _loadPlaylist(platform, id),
                ),
              );
            },
            icon: const Icon(Icons.add, size: 18),
            label: const Text('导入'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            ),
          ),
        ],
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

  Widget _buildPlaylistHeader({bool compact = false}) {
    final p = _playlist!;
    return Container(
      margin: EdgeInsets.fromLTRB(
        compact ? 12 : 16,
        compact ? 8 : 8,
        compact ? 12 : 16,
        8,
      ),
      padding: EdgeInsets.all(compact ? 12 : 16),
      decoration: CardStyle.softCard(),
      child: compact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildPlaylistCover(p, size: 132),
                const SizedBox(height: 12),
                _buildPlaylistMetadata(p, compact: true),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: _buildPlayAllButton(),
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

  Widget _buildPlaylistMetadata(PlaylistInfo p, {bool compact = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          p.name,
          maxLines: compact ? 3 : 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: compact ? 16 : 16,
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
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
        ],
        const SizedBox(height: 4),
        Text(
          '${p.trackCount} 首',
          style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
        ),
      ],
    );
  }

  Widget _buildPlayAllButton() {
    return IconButton.filled(
      onPressed: () {
        if (_playlist!.tracks.isNotEmpty) {
          context.read<PlayerProvider>().playFromPlaylist(_playlist!.tracks, 0);
        }
      },
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

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: AppColors.primarySoft,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.playlist_play,
              size: 44,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '导入 QQ音乐 / 网易云歌单',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '支持粘贴歌单链接或输入 ID，一键导入全部歌曲',
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}
