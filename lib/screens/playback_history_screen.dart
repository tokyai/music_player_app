import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/player_provider.dart';
import '../services/playback_history_service.dart';
import '../theme/app_layout.dart';
import '../theme/app_theme.dart';
import '../widgets/mini_player.dart';
import '../widgets/smart_cover.dart';
import 'player_screen.dart';

class PlaybackHistoryScreen extends StatelessWidget {
  const PlaybackHistoryScreen({super.key});

  Future<void> _play(
    BuildContext context,
    List<PlaybackHistoryEntry> entries,
    int index,
  ) async {
    final player = context.read<PlayerProvider>();
    unawaited(player.playFromHistoryEntries(entries, index));
    await Navigator.push(context, PlayerScreen.route(context));
  }

  Future<void> _clear(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空播放历史'),
        content: const Text('将删除所有歌曲的播放记录和断点，是否继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      await context.read<PlayerProvider>().clearPlaybackHistory();
    }
  }

  @override
  Widget build(BuildContext context) {
    AppColors.syncWithTheme(context);
    context.select<PlayerProvider, int>(
      (player) => player.playbackHistoryRevision,
    );
    final player = context.read<PlayerProvider>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('播放历史'),
        actions: [
          if (player.playbackHistory.isNotEmpty)
            IconButton(
              key: const ValueKey('playback-history-clear'),
              tooltip: '清空播放历史',
              onPressed: () => _clear(context),
              icon: const Icon(Icons.delete_sweep_outlined),
            ),
        ],
      ),
      body: SafeArea(
        child: FutureBuilder<void>(
          future: player.historyReady,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final history = player.playbackHistory;
            if (history.isEmpty) return _buildEmpty(context);
            return LayoutBuilder(
              builder: (context, constraints) {
                final layout = AppLayout.fromConstraints(context, constraints);
                return ListView.separated(
                  key: const ValueKey('playback-history-list'),
                  padding: EdgeInsets.fromLTRB(
                    layout.isCompactLandscape ? 8 : 12,
                    8,
                    layout.isCompactLandscape ? 8 : 12,
                    24,
                  ),
                  itemCount: history.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final entry = history[index];
                    return _HistoryTile(
                      key: ValueKey('playback-history-${entry.key}'),
                      entry: entry,
                      layout: layout,
                      onTap: () => _play(context, history, index),
                    );
                  },
                );
              },
            );
          },
        ),
      ),
      bottomNavigationBar: const SafeArea(top: false, child: MiniPlayer()),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    final layout = AppLayout.fromContext(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.history_rounded,
            size: layout.usesLargeTypography ? 76 : 64,
            color: AppColors.textHint,
          ),
          const SizedBox(height: 12),
          Text(
            '还没有播放历史',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: layout.bodySize,
            ),
          ),
          const SizedBox(height: 4),
          Text('播放过的歌曲会在这里保留断点', style: TextStyle(color: AppColors.textHint)),
        ],
      ),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  final PlaybackHistoryEntry entry;
  final AppLayout layout;
  final VoidCallback onTap;

  const _HistoryTile({
    super.key,
    required this.entry,
    required this.layout,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final song = entry.song;
    final platformColor = PlatformColors.of(song.platform);
    final coverSize = layout.usesLargeTypography
        ? 78.0
        : (layout.isCompactLandscape ? 54.0 : 66.0);
    final subtitle = [
      if (song.artist.trim().isNotEmpty) song.artist,
      if (song.album.trim().isNotEmpty) song.album,
    ].join(' · ');
    return ListTile(
      minTileHeight: layout.usesLargeTypography
          ? 104
          : (layout.isCompactLandscape ? 70 : 86),
      contentPadding: EdgeInsets.symmetric(
        horizontal: layout.isCompactLandscape ? 8 : 14,
        vertical: layout.usesLargeTypography ? 8 : 4,
      ),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.media),
        child: SizedBox(
          width: coverSize,
          height: coverSize,
          child: song.coverUrl != null && song.coverUrl!.isNotEmpty
              ? SmartCover(
                  url: song.coverUrl,
                  fit: BoxFit.cover,
                  placeholder: () => _placeholder(platformColor),
                )
              : _placeholder(platformColor),
        ),
      ),
      title: Text(
        song.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: layout.songTitleSize,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (subtitle.isNotEmpty)
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: layout.songSubtitleSize),
            ),
          Text(
            '${song.platform.label} · ${_resumeLabel(entry)} · ${_formatDate(entry.playedAt)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: layout.secondarySize,
            ),
          ),
        ],
      ),
      trailing: Icon(
        Icons.play_circle_outline_rounded,
        color: AppColors.primary,
        size: layout.usesLargeTypography ? 34 : 28,
      ),
      onTap: onTap,
    );
  }

  Widget _placeholder(Color color) {
    return ColoredBox(
      color: color.withValues(alpha: 0.12),
      child: Icon(Icons.music_note_rounded, color: color, size: 24),
    );
  }

  String _resumeLabel(PlaybackHistoryEntry entry) {
    final durationSeconds = entry.song.duration;
    final position = _formatDuration(entry.position);
    if (durationSeconds == null || durationSeconds <= 0) {
      return entry.position > Duration.zero ? '继续 $position' : '从头播放';
    }
    final duration = Duration(seconds: durationSeconds);
    return entry.position > Duration.zero
        ? '继续 $position / ${_formatDuration(duration)}'
        : '从头播放 / ${_formatDuration(duration)}';
  }

  String _formatDate(DateTime value) {
    final local = value.toLocal();
    return '${local.month}/${local.day} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  String _formatDuration(Duration value) {
    final seconds = value.inSeconds.clamp(0, 1 << 31).toInt();
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }
}
