import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
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
  final TextEditingController _controller = TextEditingController();
  late TabController _tabController;
  bool _searching = false;
  String _lastKeyword = '';
  bool _playlistMode = false; // true=歌单模式, false=歌曲模式
  int _searchRequestId = 0;
  final List<String> _hotKeywords = [
    '周杰伦',
    '海阔天空',
    '晴天',
    '邓紫棋',
    'Beyond',
    '告白气球',
  ];

  final Map<MusicPlatform, List<SongSearchResult>> _results = {
    MusicPlatform.qq: [],
    MusicPlatform.netease: [],
    MusicPlatform.kugou: [],
  };

  final Map<MusicPlatform, List<PlaylistInfo>> _playlistResults = {
    MusicPlatform.qq: [],
    MusicPlatform.netease: [],
    MusicPlatform.kugou: [],
  };

  final Map<MusicPlatform, String?> _searchErrors = {
    MusicPlatform.qq: null,
    MusicPlatform.netease: null,
    MusicPlatform.kugou: null,
  };

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _controller.dispose();
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _search(String keyword) async {
    final normalizedKeyword = keyword.trim();
    if (normalizedKeyword.isEmpty) return;
    final provider = context.read<PlayerProvider>();
    final requestId = ++_searchRequestId;
    final playlistMode = _playlistMode;

    setState(() {
      _searching = true;
      _lastKeyword = normalizedKeyword;
      for (final platform in musicPlatformDisplayOrder) {
        _results[platform] = [];
        _playlistResults[platform] = [];
        _searchErrors[platform] = null;
      }
    });

    bool isCurrent() =>
        mounted &&
        requestId == _searchRequestId &&
        playlistMode == _playlistMode;

    Future<void> loadSongs(MusicPlatform platform) async {
      try {
        final list = await provider.api.search(platform, normalizedKeyword);
        if (isCurrent()) setState(() => _results[platform] = list);
      } catch (e) {
        debugPrint('搜索 ${platform.label} 歌曲失败: $e');
        if (isCurrent()) {
          setState(() => _searchErrors[platform] = '搜索失败，请稍后重试');
        }
      }
    }

    Future<void> loadPlaylists(MusicPlatform platform) async {
      try {
        final List<PlaylistInfo> list;
        switch (platform) {
          case MusicPlatform.netease:
            list = await provider.api.neteaseSearchPlaylists(normalizedKeyword);
            break;
          case MusicPlatform.qq:
            list = await provider.api.qqSearchPlaylists(normalizedKeyword);
            break;
          case MusicPlatform.kugou:
            list = await provider.api.kugouSearchPlaylists(normalizedKeyword);
            break;
        }
        if (isCurrent()) setState(() => _playlistResults[platform] = list);
      } catch (e) {
        debugPrint('搜索 ${platform.label} 歌单失败: $e');
        if (isCurrent()) {
          setState(() => _searchErrors[platform] = '搜索失败，请稍后重试');
        }
      }
    }

    final futures = <Future<void>>[];
    if (playlistMode) {
      // 歌单模式：三平台并行搜索歌单
      futures.addAll(musicPlatformDisplayOrder.map(loadPlaylists));
    } else {
      // 歌曲模式：并行搜索三平台歌曲 + 相关歌单（混合展示，歌单默认可见）
      for (final platform in musicPlatformDisplayOrder) {
        futures.add(loadSongs(platform));
        futures.add(loadPlaylists(platform));
      }
    }
    await Future.wait(futures);
    if (isCurrent()) setState(() => _searching = false);
  }

  void _clearSearch() {
    _searchRequestId++;
    _controller.clear();
    setState(() {
      _lastKeyword = '';
      _searching = false;
      for (final platform in musicPlatformDisplayOrder) {
        _results[platform] = [];
        _playlistResults[platform] = [];
        _searchErrors[platform] = null;
      }
    });
  }

  void _switchMode(bool playlistMode) {
    if (_playlistMode == playlistMode) return;
    setState(() => _playlistMode = playlistMode);
    // 已有关键词时立即按新模式搜索
    if (_lastKeyword.isNotEmpty) {
      _search(_lastKeyword);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasSearched = _lastKeyword.isNotEmpty;
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
        final controlWidth = (constraints.maxWidth * 0.38).clamp(220.0, 320.0);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: controlWidth, child: _buildLandscapeControls()),
            VerticalDivider(
              width: 1,
              thickness: 1,
              color: AppColors.surfaceSoft,
            ),
            Expanded(
              child: Column(
                children: [
                  _buildPlatformTabs(),
                  const SizedBox(height: 4),
                  Expanded(
                    child: _buildResultsBody(hasSearched, landscape: true),
                  ),
                ],
              ),
            ),
          ],
        );
      },
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

  Widget _buildSearchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
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
          hintStyle: TextStyle(color: AppColors.textHint),
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
        : _searching && _allResultsEmpty()
        ? Center(
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: AppColors.primary,
            ),
          )
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

  Widget _buildLandscapeControls() {
    return ListView(
      key: const PageStorageKey('search-landscape-controls'),
      padding: const EdgeInsets.only(bottom: 20),
      children: [
        _buildTitle(),
        _buildSearchField(),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: _buildModeToggle(),
        ),
        _buildHotKeywords(),
      ],
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
        selected: {_playlistMode},
        showSelectedIcon: false,
        onSelectionChanged: (s) => _switchMode(s.first),
        style: SegmentedButton.styleFrom(
          visualDensity: VisualDensity.compact,
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
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
                'QQ音乐 · 网易云 · 酷狗 三大平台同步搜索',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      ],
    );
  }

  bool _allResultsEmpty() {
    if (_playlistMode) {
      return _playlistResults.values.every((l) => l.isEmpty);
    }
    return _results.values.every((l) => l.isEmpty);
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
          child: _playlistMode
              ? _buildPlaylistResults(platform)
              : _buildSongResults(platform),
        ),
      ],
    );
  }

  Widget _buildSongResults(MusicPlatform platform) {
    final list = _results[platform] ?? [];
    final playlists = _playlistResults[platform] ?? [];
    final error = _searchErrors[platform];
    if (list.isEmpty && playlists.isEmpty && error != null && !_searching) {
      return _buildEmptyHint(Icons.error_outline, error);
    }
    if (list.isEmpty &&
        playlists.isEmpty &&
        _lastKeyword.isNotEmpty &&
        !_searching) {
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
    final platformColor = PlatformColors.of(platform);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              Text(
                '相关歌单',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${playlists.length} 个',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
              const Spacer(),
              Text(
                '点击查看 >',
                style: TextStyle(fontSize: 12, color: platformColor),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 124,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
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
                  width: 96,
                  margin: const EdgeInsets.only(right: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: SizedBox(
                          width: 96,
                          height: 96,
                          child: p.coverUrl != null && p.coverUrl!.isNotEmpty
                              ? SmartCover(
                                  url: p.coverUrl,
                                  fit: BoxFit.cover,
                                  placeholder: () => Container(
                                    color: platformColor.withOpacity(0.12),
                                    child: Icon(
                                      Icons.queue_music,
                                      size: 30,
                                      color: platformColor,
                                    ),
                                  ),
                                )
                              : Container(
                                  color: platformColor.withOpacity(0.12),
                                  child: Icon(
                                    Icons.queue_music,
                                    size: 30,
                                    color: platformColor,
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        p.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
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
    final list = _playlistResults[platform] ?? [];
    final error = _searchErrors[platform];
    if (list.isEmpty && error != null && !_searching) {
      return _buildEmptyHint(Icons.error_outline, error);
    }
    if (list.isEmpty && _lastKeyword.isNotEmpty && !_searching) {
      return _buildEmptyHint(Icons.playlist_remove, '没有找到相关歌单');
    }
    final platformColor = PlatformColors.of(platform);
    return ListView.builder(
      padding: const EdgeInsets.only(top: 4, bottom: 16),
      itemCount: list.length,
      itemBuilder: (ctx, i) {
        final p = list[i];
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 2,
          ),
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: 52,
              height: 52,
              child: p.coverUrl != null && p.coverUrl!.isNotEmpty
                  ? SmartCover(
                      url: p.coverUrl,
                      fit: BoxFit.cover,
                      placeholder: () => Container(
                        color: platformColor.withOpacity(0.12),
                        child: Icon(
                          Icons.queue_music,
                          size: 24,
                          color: platformColor,
                        ),
                      ),
                    )
                  : Container(
                      color: platformColor.withOpacity(0.12),
                      child: Icon(
                        Icons.queue_music,
                        size: 24,
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
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: AppColors.textPrimary,
            ),
          ),
          subtitle: Text(
            p.creator != null && p.creator!.isNotEmpty
                ? '${p.creator} · ${p.trackCount} 首'
                : '${p.trackCount} 首',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
          trailing: Icon(
            Icons.chevron_right,
            size: 20,
            color: AppColors.textHint,
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

  Widget _buildEmptyHint(IconData icon, String text) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 64, color: AppColors.textHint),
          const SizedBox(height: 16),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _buildHotKeywords() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '热门搜索',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.local_fire_department,
                size: 18,
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
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
                      fontSize: 13,
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
                'QQ音乐 · 网易云 · 酷狗 三大平台同步搜索',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
