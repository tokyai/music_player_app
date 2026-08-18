import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../providers/player_provider.dart';
import '../services/backup_service.dart';
import '../services/favorite_file_service.dart';
import '../services/favorite_service.dart';
import '../theme/app_layout.dart';
import '../theme/app_motion.dart';
import '../theme/app_theme.dart';
import '../utils/song_source_matcher.dart';
import '../widgets/favorite_playlist_card.dart';
import '../widgets/mini_player.dart';
import '../widgets/song_tile.dart';
import 'backup_restore_screen.dart';
import 'playlist_detail_screen.dart';

enum _FavoriteMenuAction { importBackup, exportBackup, openNetworkBackup }

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
    AppColors.syncWithTheme(context);
    final favorites = context.watch<FavoriteService>();
    final songs = favorites.favorites;
    final playlists = favorites.favoritePlaylists;
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;

    return Scaffold(
      appBar: _buildAppBar(songs),
      body: Stack(
        children: [
          if (isLandscape)
            _buildLandscapeBody(songs, playlists)
          else
            _buildPortraitBody(songs, playlists),
          Positioned.fill(
            child: AppMotionSwitcher(
              beginOffset: Offset.zero,
              child: _switchingSources
                  ? KeyedSubtree(
                      key: const ValueKey('favorites-source-progress'),
                      child: _buildSwitchProgress(),
                    )
                  : const SizedBox.shrink(
                      key: ValueKey('favorites-source-progress-hidden'),
                    ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!isLandscape)
              AnimatedSize(
                duration: AppMotion.resolve(context, AppMotion.state),
                curve: AppMotion.enterCurve,
                child: AppMotionSwitcher(
                  alignment: Alignment.bottomCenter,
                  child: _selecting
                      ? KeyedSubtree(
                          key: const ValueKey('favorites-selection-bar'),
                          child: _buildSelectionBar(songs),
                        )
                      : const SizedBox.shrink(
                          key: ValueKey('favorites-selection-bar-hidden'),
                        ),
                ),
              ),
            const MiniPlayer(),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(List<SongSearchResult> songs) {
    final AppBar appBar;
    if (_selecting) {
      appBar = AppBar(
        key: const ValueKey('favorites-selection-app-bar'),
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
    } else {
      appBar = AppBar(
        key: const ValueKey('favorites-normal-app-bar'),
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
                case _FavoriteMenuAction.openNetworkBackup:
                  _openBackupScreen();
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
              PopupMenuItem(
                value: _FavoriteMenuAction.openNetworkBackup,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.cloud_sync_outlined),
                  title: Text('备份与还原'),
                ),
              ),
            ],
          ),
        ],
      );
    }
    return PreferredSize(
      preferredSize: appBar.preferredSize,
      child: AppMotionSwitcher(
        beginOffset: const Offset(0, -0.08),
        child: appBar,
      ),
    );
  }

  Widget _buildPortraitBody(
    List<SongSearchResult> songs,
    List<FavoritePlaylist> playlists,
  ) {
    return Column(
      children: [
        _buildOverview(songs),
        Expanded(child: _buildAnimatedCollectionList(songs, playlists)),
      ],
    );
  }

  Widget _buildLandscapeBody(
    List<SongSearchResult> songs,
    List<FavoritePlaylist> playlists,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = AppLayout.fromConstraints(context, constraints);
        final overviewWidth = layout.isCompactLandscape
            ? 210.0
            : layout.usesLargeTypography
            ? 340.0
            : (constraints.maxWidth * 0.3).clamp(260.0, 320.0);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: overviewWidth,
              child: SingleChildScrollView(
                key: const PageStorageKey('favorites-landscape-overview'),
                child: AppMotionSwitcher(
                  child: _selecting
                      ? KeyedSubtree(
                          key: const ValueKey(
                            'favorites-landscape-selection-overview',
                          ),
                          child: _buildSelectionOverview(songs, layout),
                        )
                      : KeyedSubtree(
                          key: const ValueKey(
                            'favorites-landscape-normal-overview',
                          ),
                          child: _buildOverview(songs, layout: layout),
                        ),
                ),
              ),
            ),
            VerticalDivider(
              width: 1,
              thickness: 1,
              color: AppColors.surfaceSoft,
            ),
            Expanded(child: _buildAnimatedCollectionList(songs, playlists)),
          ],
        );
      },
    );
  }

  Widget _buildOverview(List<SongSearchResult> songs, {AppLayout? layout}) {
    final metrics = layout ?? AppLayout.fromContext(context);
    final isLandscape = layout != null;
    final isCompact = layout?.isCompactLandscape ?? false;
    final counts = {
      for (final platform in musicPlatformDisplayOrder)
        platform: songs.where((song) => song.platform == platform).length,
    };
    return Padding(
      padding: EdgeInsets.fromLTRB(
        isLandscape ? (isCompact ? 12 : 24) : 20,
        isLandscape ? (isCompact ? 12 : 22) : 16,
        isLandscape ? (isCompact ? 12 : 24) : 20,
        isLandscape ? (isCompact ? 14 : 24) : 14,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.favorite,
                color: Colors.redAccent,
                size: isLandscape ? (isCompact ? 24 : 32) : 28,
              ),
              SizedBox(width: isLandscape ? 10 : 10),
              Text(
                '${songs.length} 首歌曲',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: metrics.sectionTitleSize,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          SizedBox(height: isLandscape ? (isCompact ? 12 : 18) : 12),
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
                      fontSize: metrics.secondarySize,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              );
            }).toList(),
          ),
          SizedBox(height: isLandscape ? (isCompact ? 14 : 22) : 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: songs.isEmpty
                  ? null
                  : () => context.read<PlayerProvider>().playFromPlaylist(
                      songs,
                      0,
                    ),
              icon: Icon(Icons.play_arrow_rounded, size: isLandscape ? 24 : 20),
              label: const Text('播放全部'),
            ),
          ),
          if (isLandscape) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => unawaited(_importFavorites()),
                    icon: const Icon(Icons.file_open_outlined, size: 18),
                    label: const Text('导入'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => unawaited(_exportFavorites()),
                    icon: const Icon(Icons.save_alt_outlined, size: 18),
                    label: const Text('导出'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: TextButton.icon(
                onPressed: () => setState(() => _selecting = true),
                icon: const Icon(Icons.library_add_check_outlined, size: 19),
                label: const Text('批量管理'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _openBackupScreen,
                icon: const Icon(Icons.cloud_sync_outlined, size: 19),
                label: const Text('备份与还原'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSelectionOverview(
    List<SongSearchResult> songs,
    AppLayout layout,
  ) {
    final enabled = _selectedKeys.isNotEmpty && !_switchingSources;
    final allSelected = _selectedKeys.length == songs.length;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        layout.isCompactLandscape ? 12 : 24,
        layout.isCompactLandscape ? 14 : 24,
        layout.isCompactLandscape ? 12 : 24,
        20,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.library_add_check,
            color: AppColors.primary,
            size: layout.isCompactLandscape ? 30 : 40,
          ),
          const SizedBox(height: 10),
          Text(
            '批量管理',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: layout.sectionTitleSize,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '已选 ${_selectedKeys.length} / ${songs.length} 首',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: layout.bodySize,
            ),
          ),
          SizedBox(height: layout.isCompactLandscape ? 16 : 24),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _toggleSelectAll(songs),
              icon: Icon(allSelected ? Icons.deselect : Icons.select_all),
              label: Text(allSelected ? '取消全选' : '全选歌曲'),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: enabled ? () => _switchSelectedSources(songs) : null,
              icon: const Icon(Icons.swap_horiz),
              label: const Text('换源'),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: enabled ? _deleteSelected : null,
              icon: const Icon(Icons.delete_outline),
              label: const Text('删除所选'),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: TextButton.icon(
              onPressed: _exitSelection,
              icon: const Icon(Icons.close),
              label: const Text('退出选择'),
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
      itemBuilder: (context, index) => _buildSongTile(songs, index),
    );
  }

  Widget _buildCollectionList(
    List<SongSearchResult> songs,
    List<FavoritePlaylist> playlists,
  ) {
    if (_selecting) return _buildSongList(songs);
    return CustomScrollView(
      key: const PageStorageKey('favorite-library'),
      slivers: [
        if (songs.isEmpty)
          SliverToBoxAdapter(child: _buildEmptySongs())
        else
          SliverList.builder(
            itemCount: songs.length,
            itemBuilder: (context, index) => _buildSongTile(songs, index),
          ),
        SliverToBoxAdapter(child: _buildFavoritePlaylistsSection(playlists)),
      ],
    );
  }

  Widget _buildAnimatedCollectionList(
    List<SongSearchResult> songs,
    List<FavoritePlaylist> playlists,
  ) {
    return AppMotionSwitcher(
      child: KeyedSubtree(
        key: ValueKey(
          _selecting ? 'favorites-selecting-list' : 'favorites-library-list',
        ),
        child: _buildCollectionList(songs, playlists),
      ),
    );
  }

  Widget _buildSongTile(List<SongSearchResult> songs, int index) {
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
  }

  Widget _buildEmptySongs() {
    final layout = AppLayout.fromContext(context);
    return SizedBox(
      height: layout.isLandscape ? 156 : 132,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.favorite_border_rounded,
              color: AppColors.textHint,
              size: layout.isLandscape ? 42 : 36,
            ),
            const SizedBox(height: 8),
            Text(
              '还没有收藏歌曲',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: layout.bodySize,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFavoritePlaylistsSection(List<FavoritePlaylist> playlists) {
    final layout = AppLayout.fromContext(context);
    final cardHeight = layout.mediaCardWidth + 82;
    return Container(
      key: const ValueKey('favorites-playlists-section'),
      padding: EdgeInsets.only(
        top: layout.isLandscape ? 18 : 14,
        bottom: layout.isLandscape ? 24 : 18,
      ),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.surfaceSoft)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: layout.isLandscape ? layout.pagePadding : 20,
            ),
            child: Row(
              children: [
                Icon(
                  Icons.queue_music_rounded,
                  color: AppColors.primary,
                  size: layout.isLandscape ? 26 : 22,
                ),
                const SizedBox(width: 8),
                Text(
                  '收藏歌单',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: layout.sectionTitleSize,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                Text(
                  '${playlists.length} 个',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: layout.secondarySize,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (playlists.isEmpty)
            SizedBox(
              height: layout.isLandscape ? 94 : 82,
              child: Center(
                child: Text(
                  '在歌单详情或搜索结果中点击收藏按钮',
                  style: TextStyle(
                    color: AppColors.textHint,
                    fontSize: layout.bodySize,
                  ),
                ),
              ),
            )
          else
            SizedBox(
              key: const ValueKey('favorites-playlists-carousel'),
              height: cardHeight,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.symmetric(
                  horizontal: layout.isLandscape ? layout.pagePadding : 20,
                ),
                itemCount: playlists.length,
                separatorBuilder: (_, _) => const SizedBox(width: 14),
                itemBuilder: (context, index) {
                  final favorite = playlists[index];
                  return FavoritePlaylistCard(
                    favorite: favorite,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => PlaylistDetailScreen(
                          playlist: favorite.playlist,
                          platform: favorite.platform,
                        ),
                      ),
                    ),
                    onFavoritePressed: () => context
                        .read<FavoriteService>()
                        .removePlaylist(favorite.platform, favorite.id),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSelectionBar(List<SongSearchResult> songs) {
    final enabled = _selectedKeys.isNotEmpty && !_switchingSources;
    return Material(
      color: AppColors.surface,
      elevation: 6,
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(AppRadius.panel),
      ),
      clipBehavior: Clip.antiAlias,
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
    final layout = AppLayout.fromContext(context);
    final progress = _switchTotal == 0 ? null : _switchCompleted / _switchTotal;
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.28),
      child: Center(
        child: Material(
          color: AppColors.surface,
          elevation: 12,
          borderRadius: BorderRadius.circular(AppRadius.panel),
          child: SizedBox(
            width: layout.isLandscape
                ? (layout.isCompactLandscape ? 260 : 360)
                : 260,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (progress == null)
                    const LinearProgressIndicator()
                  else
                    TweenAnimationBuilder<double>(
                      duration: AppMotion.resolve(context, AppMotion.quick),
                      curve: AppMotion.enterCurve,
                      tween: Tween(end: progress),
                      builder: (context, value, _) =>
                          LinearProgressIndicator(value: value),
                    ),
                  const SizedBox(height: 14),
                  Text(
                    '正在匹配 $_switchCompleted / $_switchTotal',
                    style: TextStyle(fontSize: layout.bodySize),
                  ),
                ],
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
    final player = context.read<PlayerProvider>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      await Future.wait([favorites.load(), player.settingsReady]);
      if (!mounted) return;
      final result = await FavoriteFileService.exportBackup(
        BackupService.exportJson(favorites: favorites, player: player),
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
      final result = await BackupService.importJson(
        raw: raw,
        favorites: context.read<FavoriteService>(),
        player: context.read<PlayerProvider>(),
        mode: mode,
      );
      if (!mounted) return;
      _exitSelection();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '已导入 ${result.songsAdded} 首歌曲、${result.playlistsAdded} 个歌单',
          ),
        ),
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

  void _openBackupScreen() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const BackupRestoreScreen()),
    );
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
}
