import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../providers/search_session.dart';
import '../services/favorite_service.dart';
import '../theme/app_layout.dart';
import '../theme/app_theme.dart';
import '../widgets/smart_cover.dart';
import '../widgets/song_tile.dart';
import 'playlist_detail_screen.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen>
    with SingleTickerProviderStateMixin {
  late final TextEditingController _controller;
  late TabController _tabController;
  late final SearchSession _session;
  late String _observedSessionKeyword;
  final List<String> _hotKeywords = [
    '周杰伦',
    '海阔天空',
    '晴天',
    '邓紫棋',
    'Beyond',
    '告白气球',
  ];

  @override
  void initState() {
    super.initState();
    _session = context.read<SearchSession>();
    _observedSessionKeyword = _session.keyword;
    _controller = TextEditingController(text: _session.keyword);
    _tabController = TabController(
      length: musicPlatformDisplayOrder.length,
      initialIndex: _session.selectedPlatformIndex,
      vsync: this,
    );
    _tabController.addListener(_handleTabChanged);
    _session.addListener(_handleSessionChanged);
  }

  @override
  void dispose() {
    _session.removeListener(_handleSessionChanged);
    _tabController.removeListener(_handleTabChanged);
    _controller.dispose();
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _search(String keyword) async {
    await _session.search(context.read<PlayerProvider>().api, keyword);
  }

  void _handleTabChanged() {
    if (_tabController.indexIsChanging) return;
    unawaited(
      _session.selectPlatform(
        context.read<PlayerProvider>().api,
        _tabController.index,
      ),
    );
  }

  void _retryPlatform(MusicPlatform platform) {
    unawaited(_session.retry(context.read<PlayerProvider>().api, platform));
  }

  void _clearSearch() {
    // 清空仅用于重新输入，已有搜索会话和结果必须继续保留。
    _controller.clear();
    setState(() {});
  }

  void _switchMode(bool playlistMode) {
    unawaited(
      _session.setPlaylistMode(
        context.read<PlayerProvider>().api,
        playlistMode,
      ),
    );
  }

  void _handleSessionChanged() {
    if (!mounted) return;
    if (_observedSessionKeyword != _session.keyword) {
      _observedSessionKeyword = _session.keyword;
      _controller.value = TextEditingValue(
        text: _session.keyword,
        selection: TextSelection.collapsed(offset: _session.keyword.length),
      );
    }
    if (!_tabController.indexIsChanging &&
        _tabController.index != _session.selectedPlatformIndex) {
      _tabController.index = _session.selectedPlatformIndex;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    AppColors.syncWithTheme(context);
    final hasSearched = _session.keyword.isNotEmpty;
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    return Scaffold(
      body: SafeArea(
        child: isLandscape
            ? _buildLandscapeLayout(hasSearched)
            : _buildPortraitLayout(hasSearched),
      ),
    );
  }

  Widget _buildPortraitLayout(bool hasSearched) {
    return Column(
      children: [
        _buildTitle(),
        _buildSearchField(),
        _buildPlatformTabs(),
        const SizedBox(height: 4),
        Expanded(child: _buildResultsBody(hasSearched)),
      ],
    );
  }

  Widget _buildLandscapeLayout(bool hasSearched) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = AppLayout.fromConstraints(context, constraints);
        final controlWidth = layout.isCompactLandscape ? 136.0 : 244.0;
        return Column(
          children: [
            _buildLandscapeHeader(layout),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: controlWidth,
                    child: ListView(
                      key: const PageStorageKey('search-landscape-controls'),
                      padding: EdgeInsets.fromLTRB(
                        layout.isCompactLandscape ? 8 : 18,
                        8,
                        layout.isCompactLandscape ? 8 : 18,
                        20,
                      ),
                      children: [
                        _buildModeToggle(),
                        SizedBox(height: layout.isCompactLandscape ? 10 : 18),
                        _buildHotKeywords(compact: layout.isCompactLandscape),
                      ],
                    ),
                  ),
                  VerticalDivider(
                    width: 1,
                    thickness: 1,
                    color: AppColors.surfaceSoft,
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        _buildPlatformTabs(),
                        const SizedBox(height: 6),
                        Expanded(
                          child: _buildResultsBody(
                            hasSearched,
                            landscape: true,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildLandscapeHeader(AppLayout layout) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        layout.isCompactLandscape ? 12 : 24,
        layout.isCompactLandscape ? 6 : 12,
        layout.isCompactLandscape ? 12 : 24,
        layout.isCompactLandscape ? 4 : 8,
      ),
      child: Row(
        children: [
          Text(
            '搜索',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: layout.usesLargeTypography ? 32 : 24,
              fontWeight: FontWeight.w700,
            ),
          ),
          SizedBox(width: layout.isCompactLandscape ? 12 : 20),
          Expanded(child: _buildSearchField(padding: EdgeInsets.zero)),
        ],
      ),
    );
  }

  Widget _buildTitle() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
      child: Row(
        children: [
          Text(
            '搜索',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          const Spacer(),
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: AppColors.primary,
              shape: BoxShape.circle,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchField({EdgeInsetsGeometry? padding}) {
    return Padding(
      padding: padding ?? const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: TextField(
        controller: _controller,
        decoration: InputDecoration(
          hintText: '搜索歌曲、歌手...',
          prefixIcon: Icon(Icons.search, color: AppColors.textSecondary),
          suffixIcon: _controller.text.isNotEmpty
              ? IconButton(
                  icon: Icon(
                    Icons.clear,
                    size: 20,
                    color: AppColors.textSecondary,
                  ),
                  onPressed: _clearSearch,
                )
              : null,
          hintStyle: TextStyle(color: AppColors.textHint, fontSize: 16),
        ),
        textInputAction: TextInputAction.search,
        onSubmitted: _search,
        onChanged: (_) => setState(() {}),
      ),
    );
  }

  Widget _buildPlatformTabs() {
    return TabBar(
      controller: _tabController,
      tabs: musicPlatformDisplayOrder
          .map((platform) => Tab(text: platform.label))
          .toList(),
    );
  }

  Widget _buildResultsBody(bool hasSearched, {bool landscape = false}) {
    return !hasSearched
        ? (landscape ? _buildWelcomeBody() : _buildWelcome())
        : TabBarView(
            controller: _tabController,
            children: musicPlatformDisplayOrder
                .map(
                  (platform) =>
                      _buildPlatformPage(platform, showModeToggle: !landscape),
                )
                .toList(),
          );
  }

  Widget _buildModeToggle() {
    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<bool>(
        segments: const [
          ButtonSegment(value: false, label: Text('歌曲')),
          ButtonSegment(value: true, label: Text('歌单')),
        ],
        selected: {_session.playlistMode},
        showSelectedIcon: false,
        onSelectionChanged: (s) => _switchMode(s.first),
        style: SegmentedButton.styleFrom(
          visualDensity: VisualDensity.compact,
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  Widget _buildWelcomeBody() {
    return ListView(
      key: const PageStorageKey('search-welcome-results'),
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
      children: [
        Center(
          child: Column(
            children: [
              Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  color: AppColors.primarySoft,
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.search, size: 40, color: AppColors.primary),
              ),
              const SizedBox(height: 16),
              Text(
                '搜索全网音乐',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'QQ音乐 · 网易云 · 酷狗',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 单个平台的结果页：歌曲/歌单切换 + 结果列表
  Widget _buildPlatformPage(
    MusicPlatform platform, {
    bool showModeToggle = true,
  }) {
    return Column(
      children: [
        // 歌曲 / 歌单 切换
        if (showModeToggle) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 6, 20, 2),
            child: _buildModeToggle(),
          ),
          const SizedBox(height: 4),
        ],
        Expanded(
          child: _session.playlistMode
              ? _buildPlaylistResults(platform)
              : _buildSongResults(platform),
        ),
      ],
    );
  }

  Widget _buildSongResults(MusicPlatform platform) {
    final list = _session.songsFor(platform);
    final playlists = _session.playlistsFor(platform);
    final error = _session.errorFor(platform);
    final loading = _session.isLoading(platform);
    if (list.isEmpty && playlists.isEmpty && loading) {
      return _buildLoadingHint();
    }
    if (list.isEmpty && playlists.isEmpty && error != null) {
      return _buildEmptyHint(
        Icons.error_outline,
        error,
        onRetry: () => _retryPlatform(platform),
      );
    }
    if (list.isEmpty && playlists.isEmpty && _session.keyword.isNotEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.music_off, size: 64, color: AppColors.textHint),
            const SizedBox(height: 16),
            Text('没有找到结果', style: TextStyle(color: AppColors.textSecondary)),
          ],
        ),
      );
    }
    final hasPlaylists = playlists.isNotEmpty;
    return ListView.builder(
      padding: const EdgeInsets.only(top: 4, bottom: 16),
      itemCount: list.length + (hasPlaylists ? 1 : 0),
      itemBuilder: (ctx, i) {
        if (hasPlaylists && i == 0) {
          return _buildRelatedPlaylists(platform, playlists);
        }
        final song = list[i - (hasPlaylists ? 1 : 0)];
        return SongTile(
          song: song,
          showFavorite: true,
          onTap: () {
            context.read<PlayerProvider>().playSingle(song);
          },
          onAddToQueue: () {
            context.read<PlayerProvider>().addToQueue(song);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('已添加到队列: ${song.name}'),
                duration: const Duration(seconds: 1),
              ),
            );
          },
        );
      },
    );
  }

  /// 搜索结果顶部的「相关歌单」横滑卡片
  Widget _buildRelatedPlaylists(
    MusicPlatform platform,
    List<PlaylistInfo> playlists,
  ) {
    final layout = AppLayout.fromContext(context);
    final isLandscape = layout.isLandscape;
    final coverSize = isLandscape
        ? (layout.isCompactLandscape ? 108.0 : 140.0)
        : 96.0;
    final cardWidth = coverSize;
    final cardHeight = coverSize + (isLandscape ? 48 : 28);
    final horizontalPadding = isLandscape ? layout.pagePadding : 16.0;
    final platformColor = PlatformColors.of(platform);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            isLandscape ? 16 : 12,
            horizontalPadding,
            isLandscape ? 12 : 8,
          ),
          child: Row(
            children: [
              Text(
                '相关歌单',
                style: TextStyle(
                  fontSize: isLandscape ? layout.sectionTitleSize : 15,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${playlists.length} 个',
                style: TextStyle(
                  fontSize: isLandscape ? layout.secondarySize : 12,
                  color: AppColors.textSecondary,
                ),
              ),
              const Spacer(),
              Text(
                '点击查看 >',
                style: TextStyle(
                  fontSize: isLandscape ? layout.secondarySize : 12,
                  color: platformColor,
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: cardHeight,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
            itemCount: playlists.length,
            itemBuilder: (ctx, i) {
              final p = playlists[i];
              return GestureDetector(
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          PlaylistDetailScreen(playlist: p, platform: platform),
                    ),
                  );
                },
                child: Container(
                  width: cardWidth,
                  margin: EdgeInsets.only(right: isLandscape ? 16 : 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Stack(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: SizedBox(
                              width: coverSize,
                              height: coverSize,
                              child:
                                  p.coverUrl != null && p.coverUrl!.isNotEmpty
                                  ? SmartCover(
                                      url: p.coverUrl,
                                      fit: BoxFit.cover,
                                      placeholder: () => Container(
                                        color: platformColor.withOpacity(0.12),
                                        child: Icon(
                                          Icons.queue_music,
                                          size: isLandscape ? 36 : 30,
                                          color: platformColor,
                                        ),
                                      ),
                                    )
                                  : Container(
                                      color: platformColor.withOpacity(0.12),
                                      child: Icon(
                                        Icons.queue_music,
                                        size: isLandscape ? 36 : 30,
                                        color: platformColor,
                                      ),
                                    ),
                            ),
                          ),
                          Positioned(
                            top: 4,
                            right: 4,
                            child: _buildPlaylistFavoriteButton(
                              platform,
                              p,
                              overlay: true,
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: isLandscape ? 8 : 4),
                      Text(
                        p.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: isLandscape
                              ? layout.mediaCardTitleSize
                              : 12,
                          fontWeight: isLandscape
                              ? FontWeight.w600
                              : FontWeight.w400,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildPlaylistResults(MusicPlatform platform) {
    final list = _session.playlistsFor(platform);
    final error = _session.errorFor(platform);
    final loading = _session.isLoading(platform);
    if (list.isEmpty && loading) {
      return _buildLoadingHint();
    }
    if (list.isEmpty && error != null) {
      return _buildEmptyHint(
        Icons.error_outline,
        error,
        onRetry: () => _retryPlatform(platform),
      );
    }
    if (list.isEmpty && _session.keyword.isNotEmpty) {
      return _buildEmptyHint(Icons.playlist_remove, '没有找到相关歌单');
    }
    final layout = AppLayout.fromContext(context);
    final isLandscape = layout.isLandscape;
    final coverSize = isLandscape
        ? (layout.isCompactLandscape ? 56.0 : 68.0)
        : 52.0;
    final platformColor = PlatformColors.of(platform);
    return ListView.builder(
      padding: EdgeInsets.only(
        top: isLandscape ? 8 : 4,
        bottom: isLandscape ? 24 : 16,
      ),
      itemCount: list.length,
      itemBuilder: (ctx, i) {
        final p = list[i];
        return ListTile(
          minTileHeight: isLandscape
              ? (layout.isCompactLandscape ? 68 : 84)
              : null,
          contentPadding: EdgeInsets.symmetric(
            horizontal: isLandscape ? layout.pagePadding : 16,
            vertical: isLandscape ? 6 : 2,
          ),
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: coverSize,
              height: coverSize,
              child: p.coverUrl != null && p.coverUrl!.isNotEmpty
                  ? SmartCover(
                      url: p.coverUrl,
                      fit: BoxFit.cover,
                      placeholder: () => Container(
                        color: platformColor.withOpacity(0.12),
                        child: Icon(
                          Icons.queue_music,
                          size: isLandscape ? 30 : 24,
                          color: platformColor,
                        ),
                      ),
                    )
                  : Container(
                      color: platformColor.withOpacity(0.12),
                      child: Icon(
                        Icons.queue_music,
                        size: isLandscape ? 30 : 24,
                        color: platformColor,
                      ),
                    ),
            ),
          ),
          title: Text(
            p.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: isLandscape ? layout.songTitleSize : 15,
              fontWeight: isLandscape ? FontWeight.w600 : FontWeight.w500,
              color: AppColors.textPrimary,
            ),
          ),
          subtitle: Text(
            p.creator != null && p.creator!.isNotEmpty
                ? '${p.creator} · ${p.trackCount} 首'
                : '${p.trackCount} 首',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: isLandscape ? layout.songSubtitleSize : 12,
              color: AppColors.textSecondary,
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildPlaylistFavoriteButton(platform, p),
              Icon(
                Icons.chevron_right,
                size: isLandscape ? 26 : 20,
                color: AppColors.textHint,
              ),
            ],
          ),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    PlaylistDetailScreen(playlist: p, platform: platform),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildPlaylistFavoriteButton(
    MusicPlatform platform,
    PlaylistInfo playlist, {
    bool overlay = false,
  }) {
    return Consumer<FavoriteService>(
      builder: (context, favorites, _) {
        final isFavorite = favorites.isPlaylistFavorite(platform, playlist.id);
        return Material(
          color: overlay
              ? Colors.black.withValues(alpha: 0.5)
              : Colors.transparent,
          shape: const CircleBorder(),
          child: IconButton(
            tooltip: isFavorite ? '取消收藏歌单' : '收藏歌单',
            visualDensity: VisualDensity.compact,
            onPressed: () async {
              final added = await favorites.togglePlaylist(platform, playlist);
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(added ? '已收藏歌单: ${playlist.name}' : '已取消收藏歌单'),
                  duration: const Duration(seconds: 1),
                ),
              );
            },
            icon: Icon(
              isFavorite
                  ? Icons.favorite_rounded
                  : Icons.favorite_border_rounded,
              size: overlay ? 19 : 22,
              color: isFavorite
                  ? Colors.redAccent
                  : (overlay ? Colors.white : AppColors.textHint),
            ),
          ),
        );
      },
    );
  }

  Widget _buildLoadingHint() {
    final layout = AppLayout.fromContext(context);
    return Center(
      child: SizedBox.square(
        dimension: layout.isLandscape ? 38 : 32,
        child: CircularProgressIndicator(
          strokeWidth: layout.isLandscape ? 3 : 2.5,
          color: AppColors.primary,
        ),
      ),
    );
  }

  Widget _buildEmptyHint(IconData icon, String text, {VoidCallback? onRetry}) {
    final layout = AppLayout.fromContext(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            icon,
            size: layout.isLandscape ? 72 : 64,
            color: AppColors.textHint,
          ),
          SizedBox(height: layout.isLandscape ? 18 : 16),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: layout.isLandscape ? layout.bodySize : 14,
            ),
          ),
          if (onRetry != null) ...[
            const SizedBox(height: 10),
            TextButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重试'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildHotKeywords({bool compact = false}) {
    return Padding(
      padding: compact
          ? EdgeInsets.zero
          : const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '热门搜索',
                style: TextStyle(
                  fontSize: compact ? 15 : 18,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.local_fire_department,
                size: compact ? 17 : 20,
                color: PlatformColors.qq,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _hotKeywords.map((kw) {
              return GestureDetector(
                onTap: () {
                  _controller.text = kw;
                  _search(kw);
                },
                child: Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: compact ? 9 : 13,
                    vertical: compact ? 7 : 9,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(22),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.cardShadow,
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Text(
                    kw,
                    style: TextStyle(
                      fontSize: compact ? 13 : 15,
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  /// 未搜索时的欢迎页 + 热门关键词
  Widget _buildWelcome() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      children: [
        _buildHotKeywords(),
        const SizedBox(height: 40),
        Center(
          child: Column(
            children: [
              Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  color: AppColors.primarySoft,
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.search, size: 40, color: AppColors.primary),
              ),
              const SizedBox(height: 16),
              Text(
                '搜索全网音乐',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'QQ音乐 · 网易云 · 酷狗',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
