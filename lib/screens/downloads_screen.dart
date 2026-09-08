import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/download_entry.dart';
import '../providers/player_provider.dart';
import '../services/download_manager.dart';
import '../theme/app_layout.dart';
import '../widgets/mini_player.dart';

class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});
  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  late final DownloadManager _manager;
  bool _completedOnly = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _manager = context.read<PlayerProvider>().downloads;
    _initialize();
  }

  Future<void> _initialize() async {
    await _manager.ready;
    await _manager.initializeNetwork();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  Future<void> _remove(DownloadEntry entry) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移除下载'),
        content: Text('移除《${entry.song.name}》的下载记录和本应用保存的文件？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    final player = context.read<PlayerProvider>();
    if (player.currentSong?.downloadId == entry.id) await player.stop();
    if (mounted) await _run(() => _manager.remove(entry));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _manager,
    builder: (context, _) {
      final entries = _manager.entries
          .where(
            (entry) =>
                !_completedOnly || entry.status == DownloadStatus.completed,
          )
          .toList();
      final layout = AppLayout.fromContext(context);
      return Scaffold(
        appBar: AppBar(title: const Text('下载管理')),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child:
                      MediaQuery.orientationOf(context) == Orientation.landscape
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(
                              width: layout.isCompactLandscape ? 190 : 280,
                              child: _tools(),
                            ),
                            const VerticalDivider(width: 24),
                            Expanded(child: _list(entries)),
                          ],
                        )
                      : Column(
                          children: [
                            SizedBox(height: 158, child: _tools()),
                            Expanded(child: _list(entries)),
                          ],
                        ),
                ),
              ),
              const MiniPlayer(),
            ],
          ),
        ),
      );
    },
  );

  Widget _tools() => SingleChildScrollView(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          key: const ValueKey('downloads-wifi-only'),
          contentPadding: EdgeInsets.zero,
          title: const Text('仅 Wi-Fi'),
          value: _manager.wifiOnly,
          onChanged: _loading
              ? null
              : (value) => _run(() => _manager.setWifiOnly(value)),
        ),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('全部')),
            ButtonSegment(value: true, label: Text('已完成')),
          ],
          selected: {_completedOnly},
          onSelectionChanged: (value) =>
              setState(() => _completedOnly = value.first),
        ),
        const SizedBox(height: 12),
        Text(
          '${_manager.entries.length} 个任务${_manager.wifiOnly && !_manager.wifiConnected ? ' · 等待 Wi-Fi' : ''}',
        ),
        if (_manager.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _manager.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    ),
  );

  Widget _list(List<DownloadEntry> entries) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (entries.isEmpty) return const Center(child: Text('暂无下载'));
    return ListView.separated(
      key: const ValueKey('downloads-list'),
      itemCount: entries.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final entry = entries[index];
        final busy =
            entry.status == DownloadStatus.downloading ||
            entry.status == DownloadStatus.processing;
        final label = switch (entry.status) {
          DownloadStatus.queued =>
            _manager.wifiOnly && !_manager.wifiConnected ? '等待 Wi-Fi' : '等待下载',
          DownloadStatus.downloading =>
            entry.total > 0
                ? '${(entry.received / entry.total * 100).round()}%'
                : '${(entry.received / 1024).round()} KB',
          DownloadStatus.processing => '正在保存',
          DownloadStatus.paused => '已暂停',
          DownloadStatus.completed => '已完成',
          DownloadStatus.failed => entry.error ?? '下载失败',
        };
        return Padding(
          key: ValueKey('download-${entry.id}'),
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.music_note_rounded),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.song.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          '${entry.song.artist} · ${entry.quality}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  if (entry.status == DownloadStatus.completed)
                    IconButton(
                      key: ValueKey('download-play-${entry.id}'),
                      tooltip: '播放下载',
                      onPressed: () => _run(
                        () => context.read<PlayerProvider>().playSingle(
                          entry.offlineSong,
                        ),
                      ),
                      icon: const Icon(Icons.play_arrow_rounded),
                    )
                  else
                    IconButton(
                      key: ValueKey('download-toggle-${entry.id}'),
                      tooltip: busy || entry.status == DownloadStatus.queued
                          ? '暂停下载'
                          : '重试下载',
                      onPressed: () => _run(
                        () => busy || entry.status == DownloadStatus.queued
                            ? _manager.pause(entry)
                            : _manager.resume(entry),
                      ),
                      icon: Icon(
                        busy || entry.status == DownloadStatus.queued
                            ? Icons.pause_rounded
                            : Icons.refresh_rounded,
                      ),
                    ),
                  IconButton(
                    key: ValueKey('download-remove-${entry.id}'),
                    tooltip: '移除下载',
                    onPressed: () => _remove(entry),
                    icon: const Icon(Icons.delete_outline_rounded),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(left: 32),
                child: Text(
                  '$label${entry.warning == null ? '' : ' · ${entry.warning}'}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              if (busy)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: LinearProgressIndicator(
                    value:
                        entry.total > 0 &&
                            entry.status != DownloadStatus.processing
                        ? (entry.received / entry.total).clamp(0, 1)
                        : null,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
