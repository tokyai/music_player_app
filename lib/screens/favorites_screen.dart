import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../providers/player_provider.dart';
import '../services/favorite_file_service.dart';
import '../services/favorite_service.dart';
import '../theme/app_theme.dart';
import '../utils/song_source_matcher.dart';
import '../widgets/mini_player.dart';
import '../widgets/song_tile.dart';

enum _FavoriteMenuAction { importBackup, exportBackup }

class _SourceSwitchResult {
  final SongSearchResult original;
  final SongSearchResult? replacement;
  final bool alreadyOnTarget;

  const _SourceSwitchResult({
    required this.original,
    this.replacement,
    this.alreadyOnTarget = false,
  });
}

/// 本地收藏页：支持备份、批量管理和跨平台换源。
class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({super.key});

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  final Set<String> _selectedKeys = {};
  bool _selecting = false;
  bool _switchingSources = false;
  int _switchCompleted = 0;
  int _switchTotal = 0;

  @override
  void initState() {
    super.initState();
    unawaited(context.read<FavoriteService>().load());
  }

  @override
  Widget build(BuildContext context) {
    final favorites = context.watch<FavoriteService>();
    final songs = favorites.favorites;
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;

    return Scaffold(
      appBar: _buildAppBar(songs),
      body: Stack(
        children: [
          if (songs.isEmpty)
            _buildEmpty()
          else if (isLandscape)
            _buildLandscapeBody(songs)
          else
            _buildPortraitBody(songs),
          if (_switchingSources) _buildSwitchProgress(),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_selecting) _buildSelectionBar(songs),
            const MiniPlayer(),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(List<SongSearchResult> songs) {
    if (_selecting) {
      return AppBar(
        leading: IconButton(
          tooltip: '退出选择',
          onPressed: _exitSelection,
          icon: const Icon(Icons.close),
        ),
        title: Text('已选 ${_selectedKeys.length} 首'),
        actions: [
          IconButton(
            tooltip: _selectedKeys.length == songs.length ? '取消全选' : '全选',
            onPressed: () => _toggleSelectAll(songs),
            icon: Icon(
              _selectedKeys.length == songs.length
                  ? Icons.deselect
                  : Icons.select_all,
            ),
          ),
        ],
      );
    }

    return AppBar(
      title: const Text('我的收藏'),
      actions: [
        if (songs.isNotEmpty)
          IconButton(
            tooltip: '批量选择',
            onPressed: () => setState(() => _selecting = true),
            icon: const Icon(Icons.library_add_check_outlined),
          ),
        PopupMenuButton<_FavoriteMenuAction>(
          tooltip: '收藏管理',
          onSelected: (action) {
            switch (action) {
              case _FavoriteMenuAction.importBackup:
                unawaited(_importFavorites());
              case _FavoriteMenuAction.exportBackup:
                unawaited(_exportFavorites());
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(
              value: _FavoriteMenuAction.importBackup,
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.file_open_outlined),
                title: Text('导入收藏'),
              ),
            ),
            PopupMenuItem(
              value: _FavoriteMenuAction.exportBackup,
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.save_alt_outlined),
                title: Text('导出收藏'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildPortraitBody(List<SongSearchResult> songs) {
    return Column(
      children: [
        _buildOverview(songs),
        Expanded(child: _buildSongList(songs)),
      ],
    );
  }

  Widget _buildLandscapeBody(List<SongSearchResult> songs) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final overviewWidth = (constraints.maxWidth * 0.3).clamp(220.0, 300.0);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: overviewWidth,
              child: SingleChildScrollView(child: _buildOverview(songs)),
            ),
            VerticalDivider(
              width: 1,
              thickness: 1,
              color: AppColors.surfaceSoft,
            ),
            Expanded(child: _buildSongList(songs)),
          ],
        );
      },
    );
  }

  Widget _buildOverview(List<SongSearchResult> songs) {
    final counts = {
      for (final platform in musicPlatformDisplayOrder)
        platform: songs.where((song) => song.platform == platform).length,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.favorite, color: Colors.redAccent, size: 28),
              const SizedBox(width: 10),
              Text(
                '${songs.length} 首歌曲',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: musicPlatformDisplayOrder.map((platform) {
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: PlatformColors.of(platform),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    '${platform.label} ${counts[platform]}',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              );
            }).toList(),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () =>
                  context.read<PlayerProvider>().playFromPlaylist(songs, 0),
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('播放全部'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSongList(List<SongSearchResult> songs) {
    return ListView.builder(
      key: const PageStorageKey('favorite-songs'),
      padding: const EdgeInsets.only(top: 4, bottom: 16),
      itemCount: songs.length,
      itemBuilder: (context, index) {
        final song = songs[index];
        final key = FavoriteService.keyOf(song);
        return SongTile(
          song: song,
          showPlatformTag: true,
          showFavorite: !_selecting,
          selectionMode: _selecting,
          selected: _selectedKeys.contains(key),
          onSelectionChanged: (selected) => _setSelected(key, selected),
          onLongPress: () => _startSelection(key),
          onTap: () =>
              context.read<PlayerProvider>().playFromPlaylist(songs, index),
          onAddToQueue: () {
            context.read<PlayerProvider>().addToQueue(song);
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('已添加: ${song.name}')));
          },
        );
      },
    );
  }

  Widget _buildSelectionBar(List<SongSearchResult> songs) {
    final enabled = _selectedKeys.isNotEmpty && !_switchingSources;
    return Material(
      color: AppColors.surface,
      elevation: 6,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: enabled ? () => _switchSelectedSources(songs) : null,
                icon: const Icon(Icons.swap_horiz),
                label: const Text('换源'),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: '删除所选',
              onPressed: enabled ? _deleteSelected : null,
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSwitchProgress() {
    final progress = _switchTotal == 0 ? null : _switchCompleted / _switchTotal;
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.28),
        child: Center(
          child: Material(
            color: AppColors.surface,
            elevation: 12,
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 260,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LinearProgressIndicator(value: progress),
                    const SizedBox(height: 14),
                    Text('正在匹配 $_switchCompleted / $_switchTotal'),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _startSelection(String key) {
    setState(() {
      _selecting = true;
      _selectedKeys.add(key);
    });
  }

  void _setSelected(String key, bool selected) {
    setState(() {
      if (selected) {
        _selectedKeys.add(key);
      } else {
        _selectedKeys.remove(key);
      }
    });
  }

  void _toggleSelectAll(List<SongSearchResult> songs) {
    setState(() {
      if (_selectedKeys.length == songs.length) {
        _selectedKeys.clear();
      } else {
        _selectedKeys
          ..clear()
          ..addAll(songs.map(FavoriteService.keyOf));
      }
    });
  }

  void _exitSelection() {
    setState(() {
      _selecting = false;
      _selectedKeys.clear();
    });
  }

  Future<void> _deleteSelected() async {
    final count = _selectedKeys.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除收藏'),
        content: Text('确定删除选中的 $count 首歌曲？'),
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
    final removed = await context.read<FavoriteService>().removeMany(
      Set.of(_selectedKeys),
    );
    if (!mounted) return;
    _exitSelection();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已删除 $removed 首收藏')));
  }

  Future<void> _switchSelectedSources(List<SongSearchResult> allSongs) async {
    final target = await _chooseTargetPlatform();
    if (target == null || !mounted) return;

    final selectedSongs = allSongs
        .where((song) => _selectedKeys.contains(FavoriteService.keyOf(song)))
        .toList();
    if (selectedSongs.isEmpty) return;
    final api = context.read<PlayerProvider>().api;
    final results = List<_SourceSwitchResult?>.filled(
      selectedSongs.length,
      null,
    );
    var nextIndex = 0;

    setState(() {
      _switchingSources = true;
      _switchCompleted = 0;
      _switchTotal = selectedSongs.length;
    });

    Future<void> worker() async {
      while (true) {
        final index = nextIndex++;
        if (index >= selectedSongs.length) return;
        final song = selectedSongs[index];
        if (song.platform == target) {
          results[index] = _SourceSwitchResult(
            original: song,
            alreadyOnTarget: true,
          );
        } else {
          try {
            final candidates = await api.search(
              target,
              '${song.name} ${song.artist}',
            );
            results[index] = _SourceSwitchResult(
              original: song,
              replacement: SongSourceMatcher.bestMatch(song, candidates),
            );
          } catch (_) {
            results[index] = _SourceSwitchResult(original: song);
          }
        }
        if (mounted) setState(() => _switchCompleted++);
      }
    }

    try {
      final workerCount = selectedSongs.length.clamp(1, 2);
      await Future.wait(List.generate(workerCount, (_) => worker()));
    } finally {
      if (mounted) setState(() => _switchingSources = false);
    }
    if (!mounted) return;

    final resolved = results.whereType<_SourceSwitchResult>().toList();
    final matches = resolved
        .where((result) => result.replacement != null)
        .toList();
    final already = resolved.where((result) => result.alreadyOnTarget).length;
    final unmatched = resolved
        .where(
          (result) => result.replacement == null && !result.alreadyOnTarget,
        )
        .toList();
    if (matches.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            already == resolved.length ? '所选歌曲已经是目标音源' : '没有找到可信的匹配音源',
          ),
        ),
      );
      return;
    }

    final confirmed = await _confirmSourceSwitch(
      target: target,
      matched: matches.length,
      already: already,
      unmatched: unmatched,
    );
    if (confirmed != true || !mounted) return;

    final replacements = {
      for (final match in matches)
        FavoriteService.keyOf(match.original): match.replacement!,
    };
    final replaced = await context.read<FavoriteService>().replaceMany(
      replacements,
    );
    if (!mounted) return;
    _exitSelection();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已将 $replaced 首歌曲切换为 ${target.label} 音源')),
    );
  }

  Future<MusicPlatform?> _chooseTargetPlatform() {
    return showDialog<MusicPlatform>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('切换到'),
        children: musicPlatformDisplayOrder.map((platform) {
          return SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogContext, platform),
            child: Row(
              children: [
                Icon(Icons.music_note, color: PlatformColors.of(platform)),
                const SizedBox(width: 12),
                Text(platform.label),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  Future<bool?> _confirmSourceSwitch({
    required MusicPlatform target,
    required int matched,
    required int already,
    required List<_SourceSwitchResult> unmatched,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('切换为 ${target.label}'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '匹配成功 $matched 首 · 已是目标源 $already 首 · 未匹配 ${unmatched.length} 首',
              ),
              if (unmatched.isNotEmpty) ...[
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 150),
                  child: ListView(
                    shrinkWrap: true,
                    children: unmatched
                        .map(
                          (result) => ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.info_outline, size: 18),
                            title: Text(
                              result.original.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(result.original.artist),
                          ),
                        )
                        .toList(),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text('替换 $matched 首'),
          ),
        ],
      ),
    );
  }

  Future<void> _exportFavorites() async {
    final favorites = context.read<FavoriteService>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      await favorites.load();
      if (!mounted) return;
      final result = await FavoriteFileService.exportBackup(
        favorites.exportJson(),
      );
      if (!mounted || result == FavoriteExportResult.cancelled) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            result == FavoriteExportResult.saved ? '收藏备份已保存' : '收藏备份已复制到剪贴板',
          ),
        ),
      );
    } on PlatformException catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(error.message ?? '导出失败')));
    }
  }

  Future<void> _importFavorites() async {
    String? raw;
    try {
      raw = await FavoriteFileService.importBackup();
    } on UnsupportedError {
      if (!mounted) return;
      raw = await _showPasteImportDialog();
    } on PlatformException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message ?? '读取备份失败')));
      return;
    }
    if (raw == null || raw.trim().isEmpty || !mounted) return;

    final mode = await _chooseImportMode();
    if (mode == null || !mounted) return;
    try {
      final result = await context.read<FavoriteService>().importJson(
        raw,
        mode: mode,
      );
      if (!mounted) return;
      _exitSelection();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导入 ${result.added} 首，跳过 ${result.skipped} 首')),
      );
    } on FormatException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  Future<String?> _showPasteImportDialog() async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('粘贴收藏备份'),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 5,
          maxLines: 10,
          decoration: const InputDecoration(hintText: 'JSON 内容'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('继续'),
          ),
        ],
      ),
    );
    controller.dispose();
    return value;
  }

  Future<FavoriteImportMode?> _chooseImportMode() {
    return showDialog<FavoriteImportMode>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('导入方式'),
        content: const Text('合并会保留现有收藏；覆盖会先清空当前收藏。'),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.pop(dialogContext, FavoriteImportMode.replace),
            child: const Text('覆盖'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, FavoriteImportMode.merge),
            child: const Text('合并'),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              color: AppColors.primarySoft,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.favorite_border,
              size: 40,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '还没有收藏歌曲',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}
