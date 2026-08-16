import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../services/audio_cache_service.dart';
import '../theme/app_layout.dart';
import '../theme/app_theme.dart';
import '../widgets/mini_player.dart';

class CacheListScreen extends StatefulWidget {
  const CacheListScreen({super.key});

  @override
  State<CacheListScreen> createState() => _CacheListScreenState();
}

class _CacheListScreenState extends State<CacheListScreen> {
  List<CachedSongInfo> _cacheList = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadCacheList();
  }

  Future<void> _loadCacheList() async {
    setState(() => _loading = true);
    try {
      final list = await AudioCacheService.getCacheList();
      if (mounted) setState(() => _cacheList = list);
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _removeCache(CachedSongInfo info) async {
    await AudioCacheService.removeCache(info.platformCode, info.songId);
    _loadCacheList();
  }

  Future<void> _playFromCache(CachedSongInfo info) async {
    final player = context.read<PlayerProvider>();
    // 通过平台和 ID 搜索歌曲后播放
    final platform = MusicPlatform.values.firstWhere(
      (e) => e.code == info.platformCode,
      orElse: () => MusicPlatform.netease,
    );
    player.playSingle(
      SongSearchResult(
        platform: platform,
        id: info.songId,
        name: info.name,
        artist: info.artist,
        album: '',
      ),
    );
  }

  Future<void> _clearAllCache() async {
    final totalSize = await AudioCacheService.getCacheSize();
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除全部缓存'),
        content: Text(
          '将删除 ${_cacheList.length} 首已缓存歌曲'
          '（${AudioCacheService.formatSize(totalSize)}），'
          '下次播放需重新联网。是否继续？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await AudioCacheService.clearCache();
    _loadCacheList();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('缓存已清除'), duration: Duration(seconds: 1)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    AppColors.syncWithTheme(context);
    final totalSize = _cacheList.fold<int>(0, (sum, e) => sum + e.fileSize);
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;

    return Scaffold(
      body: SafeArea(
        child: isLandscape
            ? _buildLandscapeBody(totalSize)
            : _buildPortraitBody(totalSize),
      ),
      // 底部迷你播放器
      bottomNavigationBar: const SafeArea(top: false, child: MiniPlayer()),
    );
  }

  Widget _buildPortraitBody(int totalSize) {
    return Column(
      children: [
        _buildTitleBar(),
        if (_cacheList.isNotEmpty) _buildStats(totalSize),
        Expanded(child: _buildCacheList()),
      ],
    );
  }

  Widget _buildLandscapeBody(int totalSize) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = AppLayout.fromConstraints(context, constraints);
        final overviewWidth = layout.isCompactLandscape
            ? 210.0
            : layout.usesLargeTypography
            ? 320.0
            : (constraints.maxWidth * 0.28).clamp(250.0, 300.0);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: overviewWidth,
              child: SingleChildScrollView(
                key: const PageStorageKey('cache-landscape-overview'),
                child: _buildLandscapeOverview(totalSize, layout),
              ),
            ),
            VerticalDivider(
              width: 1,
              thickness: 1,
              color: AppColors.surfaceSoft,
            ),
            Expanded(child: _buildCacheList(layout: layout)),
          ],
        );
      },
    );
  }

  Widget _buildTitleBar({AppLayout? layout}) {
    final compact = layout?.isCompactLandscape ?? false;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        layout == null ? 20 : (compact ? 10 : 22),
        layout == null ? 16 : (compact ? 8 : 18),
        layout == null ? 12 : (compact ? 10 : 22),
        layout == null ? 8 : (compact ? 6 : 10),
      ),
      child: Row(
        children: [
          IconButton(
            visualDensity: compact ? VisualDensity.compact : null,
            tooltip: '返回',
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.arrow_back_ios_new),
          ),
          Expanded(
            child: Text(
              '已缓存歌曲',
              style: TextStyle(
                fontSize: layout?.pageTitleSize ?? 22,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          if (layout == null && _cacheList.isNotEmpty)
            TextButton.icon(
              onPressed: _clearAllCache,
              icon: const Icon(Icons.delete_sweep_outlined, size: 20),
              label: const Text('清除'),
            ),
        ],
      ),
    );
  }

  Widget _buildStats(int totalSize, {AppLayout? layout}) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        layout == null ? 20 : (layout.isCompactLandscape ? 12 : 24),
        0,
        layout == null ? 20 : (layout.isCompactLandscape ? 12 : 24),
        layout == null ? 8 : 18,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          '${_cacheList.length} 首 · ${AudioCacheService.formatSize(totalSize)}',
          style: TextStyle(
            fontSize: layout?.secondarySize ?? 13,
            color: AppColors.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _buildLandscapeOverview(int totalSize, AppLayout layout) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildTitleBar(layout: layout),
        if (_cacheList.isNotEmpty) _buildStats(totalSize, layout: layout),
        Padding(
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
                Icons.download_done_outlined,
                size: layout.isCompactLandscape ? 34 : 48,
                color: AppColors.primary,
              ),
              const SizedBox(height: 10),
              Text(
                _cacheList.isEmpty ? '暂无缓存' : '本地缓存',
                style: TextStyle(
                  fontSize: layout.sectionTitleSize,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '播放过的歌曲会自动保存，网络不稳定时优先使用本地文件。',
                style: TextStyle(
                  fontSize: layout.secondarySize,
                  height: 1.45,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _cacheList.isEmpty ? null : _clearAllCache,
                  icon: const Icon(Icons.delete_sweep_outlined),
                  label: const Text('清除全部'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCacheList({AppLayout? layout}) {
    if (_loading) {
      return Center(
        child: SizedBox.square(
          dimension: layout?.isLandscape == true ? 38 : 32,
          child: CircularProgressIndicator(
            strokeWidth: layout?.isLandscape == true ? 3 : 2.5,
            color: AppColors.primary,
          ),
        ),
      );
    }
    if (_cacheList.isEmpty) return _buildEmpty(layout: layout);
    final compact = layout?.isCompactLandscape ?? false;
    final coverSize = layout?.usesLargeTypography == true
        ? 68.0
        : compact
        ? 54.0
        : 48.0;
    return ListView.builder(
      padding: EdgeInsets.only(
        top: layout == null ? 0 : (layout.isCompactLandscape ? 8 : 14),
        bottom: 18,
      ),
      itemCount: _cacheList.length,
      itemBuilder: (ctx, i) {
        final info = _cacheList[i];
        final platform = MusicPlatform.values.firstWhere(
          (e) => e.code == info.platformCode,
          orElse: () => MusicPlatform.netease,
        );
        return ListTile(
          minTileHeight: layout?.songRowHeight ?? 64,
          contentPadding: EdgeInsets.symmetric(
            horizontal: layout?.usesLargeTypography == true
                ? 20
                : (layout?.isLandscape == true ? 14 : 16),
            vertical: layout?.isLandscape == true ? 5 : 2,
          ),
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(
              layout?.usesLargeTypography == true ? 12 : 8,
            ),
            child: Container(
              width: coverSize,
              height: coverSize,
              color: PlatformColors.of(platform).withOpacity(0.12),
              child: Icon(
                Icons.music_note,
                size: layout?.isLandscape == true ? 30 : 24,
                color: PlatformColors.of(platform),
              ),
            ),
          ),
          title: Text(
            info.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: layout?.songTitleSize ?? 14,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          subtitle: Text(
            '${platform.label} · ${info.artist}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: layout?.songSubtitleSize ?? 12,
              color: AppColors.textSecondary,
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                AudioCacheService.formatSize(info.fileSize),
                style: TextStyle(
                  fontSize: layout?.secondarySize ?? 12,
                  color: AppColors.textHint,
                ),
              ),
              IconButton(
                tooltip: '删除缓存',
                icon: Icon(
                  Icons.delete_outline,
                  size: layout?.isLandscape == true ? 24 : 20,
                  color: AppColors.textHint,
                ),
                onPressed: () => _removeCache(info),
              ),
            ],
          ),
          onTap: () => _playFromCache(info),
        );
      },
    );
  }

  Widget _buildEmpty({AppLayout? layout}) {
    final isLandscape = layout?.isLandscape == true;
    final isCompact = layout?.isCompactLandscape == true;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: isLandscape ? (isCompact ? 76 : 112) : 80,
            height: isLandscape ? (isCompact ? 76 : 112) : 80,
            decoration: BoxDecoration(
              color: AppColors.primarySoft,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.cached,
              size: isLandscape ? (isCompact ? 34 : 52) : 36,
              color: AppColors.primary,
            ),
          ),
          SizedBox(height: isCompact ? 10 : 16),
          Text(
            '还没有缓存歌曲',
            style: TextStyle(
              fontSize: isLandscape ? layout!.sectionTitleSize : 15,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '播放过的歌曲会自动缓存到本地',
            style: TextStyle(
              fontSize: isLandscape ? layout!.secondarySize : 12,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
