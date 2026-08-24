import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/ai_assistant_controller.dart';
import '../providers/ai_config_controller.dart';
import '../providers/player_provider.dart';
import '../providers/search_session.dart';
import '../services/favorite_service.dart';
import '../services/voice_input_session.dart';
import '../theme/app_layout.dart';
import '../theme/app_motion.dart';
import '../theme/app_theme.dart';
import '../widgets/cover_hero_tags.dart';
import '../widgets/remote_focusable.dart';
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
  static const _suggestionDebounce = Duration(milliseconds: 350);
  static const _suggestionTimeout = Duration(seconds: 3);
  static const List<_SearchSuggestion> _hotSearches = [
    _SearchSuggestion('周杰伦', _SearchSuggestionKind.artist),
    _SearchSuggestion('海阔天空', _SearchSuggestionKind.track, detail: 'Beyond'),
    _SearchSuggestion('晴天', _SearchSuggestionKind.track, detail: '周杰伦'),
    _SearchSuggestion('邓紫棋', _SearchSuggestionKind.artist),
    _SearchSuggestion('Beyond', _SearchSuggestionKind.artist),
    _SearchSuggestion('告白气球', _SearchSuggestionKind.track, detail: '周杰伦'),
  ];

  late final TextEditingController _controller;
  late final FocusNode _searchFocusNode;
  late TabController _tabController;
  late final SearchSession _session;
  late String _observedSessionKeyword;
  VoiceInputSession? _activeVoiceInputSession;
  bool _voiceInputOpen = false;

  @override
  void initState() {
    super.initState();
    _session = context.read<SearchSession>();
    _observedSessionKeyword = _session.keyword;
    _controller = TextEditingController(text: _session.keyword);
    _searchFocusNode = FocusNode();
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
    final activeVoiceInput = _activeVoiceInputSession;
    _activeVoiceInputSession = null;
    if (activeVoiceInput != null) unawaited(activeVoiceInput.close());
    _session.removeListener(_handleSessionChanged);
    _tabController.removeListener(_handleTabChanged);
    _controller.dispose();
    _searchFocusNode.dispose();
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _search(String keyword) async {
    if (!mounted) return;
    final normalized = keyword.trim();
    if (normalized.isEmpty) return;
    _searchFocusNode.unfocus();
    if (_controller.text != normalized) {
      _controller.value = TextEditingValue(
        text: normalized,
        selection: TextSelection.collapsed(offset: normalized.length),
      );
    }
    await _session.search(context.read<PlayerProvider>().api, normalized);
  }

  Future<void> _showVoiceInput() async {
    if (_voiceInputOpen || !mounted) return;
    final assistant = Provider.of<AiAssistantController?>(
      context,
      listen: false,
    );
    final config = Provider.of<AiConfigController?>(context, listen: false);
    if (assistant == null || config == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('当前语音输入服务不可用')));
      return;
    }
    if (assistant.isActive) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先结束当前 AI 助理对话')));
      return;
    }

    setState(() => _voiceInputOpen = true);
    _searchFocusNode.unfocus();
    VoiceInputSession? voiceSession;
    String? candidate;
    try {
      await config.ready;
      if (!mounted) return;
      voiceSession = VoiceInputSession(
        speech: assistant.speech,
        voiceModel: config.voiceModel,
      );
      _activeVoiceInputSession = voiceSession;
      candidate = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) =>
            _SearchVoiceInputDialog(session: voiceSession!),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('语音输入失败：$error')));
      }
    } finally {
      if (identical(_activeVoiceInputSession, voiceSession)) {
        _activeVoiceInputSession = null;
      }
      await voiceSession?.close();
      if (mounted) setState(() => _voiceInputOpen = false);
    }
    if (!mounted || candidate == null || candidate.trim().isEmpty) return;
    await _search(candidate);
  }

  Future<Iterable<_SearchSuggestion>> _buildSearchSuggestions(
    TextEditingValue value,
  ) async {
    final keyword = value.text.trim();
    if (keyword.isEmpty || !_searchFocusNode.hasFocus) {
      return const <_SearchSuggestion>[];
    }
    final api = context.read<PlayerProvider>().api;
    await Future<void>.delayed(_suggestionDebounce);
    if (!mounted ||
        !_searchFocusNode.hasFocus ||
        _controller.text.trim() != keyword) {
      return const <_SearchSuggestion>[];
    }

    final suggestions = <_SearchSuggestion>[];
    final seen = <String>{};
    void addSuggestion(_SearchSuggestion suggestion) {
      if (!_containsKeyword(suggestion.keyword, keyword)) return;
      final key =
          '${suggestion.kind.name}:${_normalizeSuggestionText(suggestion.keyword)}';
      if (seen.add(key)) suggestions.add(suggestion);
    }

    for (final suggestion in _hotSearches) {
      addSuggestion(suggestion);
    }
    try {
      final songs = await api
          .search(MusicPlatform.qq, keyword)
          .timeout(_suggestionTimeout);
      if (!mounted ||
          !_searchFocusNode.hasFocus ||
          _controller.text.trim() != keyword) {
        return const <_SearchSuggestion>[];
      }
      for (final song in songs) {
        for (final artist in _splitArtists(song.artist)) {
          addSuggestion(
            _SearchSuggestion(artist, _SearchSuggestionKind.artist),
          );
        }
        addSuggestion(
          _SearchSuggestion(
            song.name,
            _SearchSuggestionKind.track,
            detail: song.artist,
          ),
        );
        if (suggestions.length >= 8) break;
      }
    } catch (_) {
      // 本地热门匹配仍可作为网络失败时的联想结果。
    }
    return suggestions.take(8).toList(growable: false);
  }

  bool _containsKeyword(String value, String keyword) {
    return _normalizeSuggestionText(
      value,
    ).contains(_normalizeSuggestionText(keyword));
  }

  String _normalizeSuggestionText(String value) {
    return value.toLowerCase().replaceAll(RegExp(r'\s+'), '');
  }

  Iterable<String> _splitArtists(String artists) sync* {
    final seen = <String>{};
    for (final raw in artists.split(RegExp(r'\s+/\s+|、|，|,\s*|\s+&\s+'))) {
      final artist = raw.trim();
      if (artist.isNotEmpty && seen.add(artist.toLowerCase())) yield artist;
    }
  }

  void _handleTabChanged() {
    if (!mounted || _tabController.indexIsChanging) return;
    unawaited(
      _session.selectPlatform(
        context.read<PlayerProvider>().api,
        _tabController.index,
      ),
    );
  }

  void _retryPlatform(MusicPlatform platform) {
    if (!mounted) return;
    unawaited(_session.retry(context.read<PlayerProvider>().api, platform));
  }

  void _clearSearch() {
    if (!mounted) return;
    _controller.clear();
    _session.clear();
  }

  void _handleQueryChanged(String value) {
    if (!mounted) return;
    if (value.trim().isEmpty && _session.keyword.isNotEmpty) {
      _session.clear();
      return;
    }
    setState(() {});
  }

  void _switchMode(bool playlistMode) {
    if (!mounted) return;
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
        final controlWidth = layout.isCompactLandscape ? 160.0 : 280.0;
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
                        SizedBox(height: layout.isCompactLandscape ? 16 : 24),
                        _buildSearchHistory(compact: layout.isCompactLandscape),
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
              fontSize: layout.pageTitleSize,
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
              fontSize: AppLayout.fromContext(context).pageTitleSize,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchField({EdgeInsetsGeometry? padding}) {
    final layout = AppLayout.fromContext(context);
    return Padding(
      padding: padding ?? const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Row(
        children: [
          Expanded(
            child: RawAutocomplete<_SearchSuggestion>(
              textEditingController: _controller,
              focusNode: _searchFocusNode,
              displayStringForOption: (option) => option.keyword,
              optionsBuilder: _buildSearchSuggestions,
              onSelected: (option) => unawaited(_search(option.keyword)),
              optionsViewOpenDirection: OptionsViewOpenDirection.mostSpace,
              optionsViewBuilder: _buildSuggestionOptions,
              fieldViewBuilder: (context, textController, focusNode, _) {
                return RemoteTextFieldTraversal(
                  controller: textController,
                  child: TextField(
                    key: const ValueKey('search-field'),
                    controller: textController,
                    focusNode: focusNode,
                    decoration: InputDecoration(
                      hintText: '搜索歌曲、歌手...',
                      prefixIcon: Icon(
                        Icons.search,
                        color: AppColors.textSecondary,
                      ),
                      suffixIcon: textController.text.isNotEmpty
                          ? IconButton(
                              tooltip: '清空输入',
                              icon: Icon(
                                Icons.clear,
                                size: layout.isCompactLandscape ? 24 : 28,
                                color: AppColors.textSecondary,
                              ),
                              onPressed: _clearSearch,
                            )
                          : null,
                      hintStyle: TextStyle(
                        color: AppColors.textHint,
                        fontSize: layout.bodySize,
                      ),
                    ),
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: layout.bodySize,
                      height: 1.2,
                    ),
                    textInputAction: TextInputAction.search,
                    onSubmitted: (value) => unawaited(_search(value)),
                    onChanged: _handleQueryChanged,
                    onTapOutside: (_) => focusNode.unfocus(),
                  ),
                );
              },
            ),
          ),
          SizedBox(width: layout.isCompactLandscape ? 6 : 10),
          SizedBox.square(
            dimension: layout.isCompactLandscape ? 48 : 56,
            child: IconButton.filledTonal(
              key: const ValueKey('search-voice-input'),
              tooltip: '语音输入',
              onPressed: _voiceInputOpen
                  ? null
                  : () => unawaited(_showVoiceInput()),
              icon: Icon(
                _voiceInputOpen
                    ? Icons.hourglass_top_rounded
                    : Icons.mic_rounded,
                size: layout.isCompactLandscape ? 24 : 28,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSuggestionOptions(
    BuildContext context,
    AutocompleteOnSelected<_SearchSuggestion> onSelected,
    Iterable<_SearchSuggestion> options,
  ) {
    final layout = AppLayout.fromContext(context);
    final optionList = options.toList(growable: false);
    final highlightedIndex = AutocompleteHighlightedOption.of(context);
    // Suggestions are rebuilt for every completed query. Replaying an opacity
    // layer for the whole list on each keystroke makes typing feel delayed on
    // low-end devices, so the already-debounced results appear immediately.
    return Material(
      key: const ValueKey('search-suggestions'),
      color: AppColors.surface,
      elevation: 8,
      shadowColor: AppColors.cardShadow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.control),
        side: BorderSide(color: AppColors.outline),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: layout.isCompactLandscape ? 220 : 320,
        ),
        child: ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 4),
          shrinkWrap: true,
          itemCount: optionList.length,
          separatorBuilder: (_, _) =>
              Divider(height: 1, thickness: 1, color: AppColors.outline),
          itemBuilder: (context, index) {
            final option = optionList[index];
            final isHighlighted = index == highlightedIndex;
            final isArtist = option.kind == _SearchSuggestionKind.artist;
            final subtitle = isArtist
                ? '歌手'
                : option.detail == null || option.detail!.isEmpty
                ? '曲目'
                : '曲目 · ${option.detail}';
            return Material(
              color: isHighlighted ? AppColors.primarySoft : Colors.transparent,
              child: ListTile(
                key: ValueKey(
                  'search-suggestion-${option.kind.name}-${option.keyword}',
                ),
                dense: layout.isCompactLandscape,
                minTileHeight: layout.isCompactLandscape ? 48 : 58,
                leading: Icon(
                  isArtist ? Icons.person_rounded : Icons.music_note_rounded,
                  size: layout.isCompactLandscape ? 24 : 28,
                  color: isArtist ? PlatformColors.qq : AppColors.primary,
                ),
                title: Text(
                  option.keyword,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: layout.bodySize,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                subtitle: Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: layout.secondarySize,
                    color: AppColors.textSecondary,
                  ),
                ),
                onTap: () => onSelected(option),
              ),
            );
          },
        ),
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
    return AppMotionSwitcher(
      child: KeyedSubtree(
        key: ValueKey(hasSearched ? 'search-results' : 'search-welcome'),
        child: !hasSearched
            ? (landscape ? _buildWelcomeBody() : _buildWelcome())
            : TabBarView(
                controller: _tabController,
                children: musicPlatformDisplayOrder
                    .map(
                      (platform) => _buildPlatformPage(
                        platform,
                        showModeToggle: !landscape,
                      ),
                    )
                    .toList(),
              ),
      ),
    );
  }

  Widget _buildModeToggle() {
    final layout = AppLayout.fromContext(context);
    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<bool>(
        segments: const [
          ButtonSegment(value: false, label: Text('歌曲')),
          ButtonSegment(value: true, label: Text('歌单')),
        ],
        selected: {_session.playlistMode},
        showSelectedIcon: false,
        onSelectionChanged: (s) {
          if (s.isNotEmpty) _switchMode(s.first);
        },
        style: SegmentedButton.styleFrom(
          visualDensity: VisualDensity.compact,
          textStyle: TextStyle(
            fontSize: layout.isCompactLandscape ? 16 : layout.bodySize,
            fontWeight: FontWeight.w700,
          ),
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
                  borderRadius: BorderRadius.circular(AppRadius.card),
                ),
                child: Icon(Icons.search, size: 40, color: AppColors.primary),
              ),
              const SizedBox(height: 16),
              Text(
                '搜索全网音乐',
                style: TextStyle(
                  fontSize: AppLayout.fromContext(context).bodySize,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'QQ音乐 · 网易云 · 酷狗',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: AppLayout.fromContext(context).secondarySize,
                  color: AppColors.textSecondary,
                ),
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
          child: AppMotionSwitcher(
            child: KeyedSubtree(
              key: ValueKey(
                'search-${platform.code}-${_session.playlistMode ? 'playlists' : 'songs'}-${_platformStateKey(platform)}',
              ),
              child: _session.playlistMode
                  ? _buildPlaylistResults(platform)
                  : _buildSongResults(platform),
            ),
          ),
        ),
      ],
    );
  }

  String _platformStateKey(MusicPlatform platform) {
    final songs = _session.songsFor(platform);
    final playlists = _session.playlistsFor(platform);
    final targetEmpty = _session.playlistMode
        ? playlists.isEmpty
        : songs.isEmpty && playlists.isEmpty;
    if (targetEmpty && _session.isLoading(platform)) return 'loading';
    if (targetEmpty && _session.errorFor(platform) != null) return 'error';
    if (targetEmpty) return 'empty';
    return 'content';
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
        final songIndex = i - (hasPlaylists ? 1 : 0);
        final song = list[songIndex];
        return SongTile(
          song: song,
          showFavorite: true,
          onTap: () {
            context.read<PlayerProvider>().playFromSearchResults(
              list,
              songIndex,
            );
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
        : 112.0;
    final cardWidth = coverSize;
    final cardHeight = coverSize + (isLandscape ? 58 : 52);
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
                  fontSize: layout.sectionTitleSize,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${playlists.length} 个',
                style: TextStyle(
                  fontSize: layout.secondarySize,
                  color: AppColors.textSecondary,
                ),
              ),
              const Spacer(),
              TextButton(
                key: const ValueKey('search-related-playlists-action'),
                onPressed: () => _switchMode(true),
                style: TextButton.styleFrom(
                  foregroundColor: platformColor,
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  textStyle: TextStyle(fontSize: layout.secondarySize),
                ),
                child: const Text('点击查看 >'),
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
              return RemoteFocusable(
                semanticLabel: '打开歌单 ${p.name}',
                borderRadius: BorderRadius.circular(AppRadius.card),
                onPressed: () {
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
                          Hero(
                            tag: playlistCoverHeroTag(platform, p.id),
                            transitionOnUserGestures: true,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(
                                AppRadius.media,
                              ),
                              child: SizedBox(
                                width: coverSize,
                                height: coverSize,
                                child:
                                    p.coverUrl != null && p.coverUrl!.isNotEmpty
                                    ? SmartCover(
                                        url: p.coverUrl,
                                        fit: BoxFit.cover,
                                        placeholder: () => Container(
                                          color: platformColor.withOpacity(
                                            0.12,
                                          ),
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
                          fontSize: layout.mediaCardTitleSize,
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
        : layout.songCoverSize;
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
          minTileHeight: layout.songRowHeight,
          contentPadding: EdgeInsets.symmetric(
            horizontal: isLandscape ? layout.pagePadding : 16,
            vertical: isLandscape ? 6 : 2,
          ),
          leading: Hero(
            tag: playlistCoverHeroTag(platform, p.id),
            transitionOnUserGestures: true,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.media),
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
          ),
          title: Text(
            p.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: layout.songTitleSize,
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
              fontSize: layout.songSubtitleSize,
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
          borderRadius: BorderRadius.circular(AppRadius.small),
          child: IconButton(
            tooltip: isFavorite ? '取消收藏歌单' : '收藏歌单',
            visualDensity: VisualDensity.compact,
            onPressed: () async {
              try {
                final added = await favorites.togglePlaylist(
                  platform,
                  playlist,
                );
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      added ? '已收藏歌单: ${playlist.name}' : '已取消收藏歌单',
                    ),
                    duration: const Duration(seconds: 1),
                  ),
                );
              } catch (error) {
                if (!context.mounted) return;
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text('收藏歌单失败：$error')));
              }
            },
            icon: AppAnimatedIcon(
              stateKey: isFavorite,
              child: Icon(
                isFavorite
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                size: overlay ? 24 : 28,
                color: isFavorite
                    ? Colors.redAccent
                    : (overlay ? Colors.white : AppColors.textHint),
              ),
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
              fontSize: layout.bodySize,
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
    final layout = AppLayout.fromContext(context);
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
                  fontSize: compact ? 17 : layout.sectionTitleSize,
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
            children: _hotSearches.map((suggestion) {
              return RemoteFocusable(
                semanticLabel: '搜索 ${suggestion.keyword}',
                borderRadius: BorderRadius.circular(AppRadius.control),
                onPressed: () => unawaited(_search(suggestion.keyword)),
                child: Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: compact ? 9 : 13,
                    vertical: compact ? 7 : 9,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(AppRadius.control),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.cardShadow,
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Text(
                    suggestion.keyword,
                    style: TextStyle(
                      fontSize: compact ? 15 : layout.bodySize,
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

  Widget _buildSearchHistory({bool compact = false}) {
    final layout = AppLayout.fromContext(context);
    final history = _session.searchHistory;
    return Padding(
      key: const ValueKey('search-history-section'),
      padding: compact
          ? EdgeInsets.zero
          : const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '搜索历史',
                style: TextStyle(
                  fontSize: compact ? 17 : layout.sectionTitleSize,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.history_rounded,
                size: compact ? 18 : 22,
                color: AppColors.textSecondary,
              ),
            ],
          ),
          SizedBox(height: compact ? 8 : 12),
          if (history.isEmpty)
            Text(
              '暂无搜索记录',
              style: TextStyle(
                fontSize: compact ? 14 : layout.secondarySize,
                color: AppColors.textHint,
              ),
            )
          else
            ...history.map(
              (keyword) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Material(
                  key: ValueKey('search-history-item-$keyword'),
                  color: AppColors.surface,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.control),
                    side: BorderSide(color: AppColors.outline),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Row(
                    children: [
                      Expanded(
                        child: InkWell(
                          onTap: () => unawaited(_search(keyword)),
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                              compact ? 10 : 14,
                              compact ? 10 : 12,
                              6,
                              compact ? 10 : 12,
                            ),
                            child: Text(
                              keyword,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: compact ? 15 : layout.bodySize,
                                color: AppColors.textPrimary,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      ),
                      IconButton(
                        key: ValueKey('delete-search-history-$keyword'),
                        tooltip: '删除 $keyword',
                        visualDensity: compact
                            ? VisualDensity.compact
                            : VisualDensity.standard,
                        onPressed: () =>
                            unawaited(_session.removeSearchHistory(keyword)),
                        icon: Icon(
                          Icons.close_rounded,
                          size: compact ? 20 : 24,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
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
        const SizedBox(height: 20),
        _buildSearchHistory(),
        const SizedBox(height: 40),
        Center(
          child: Column(
            children: [
              Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  color: AppColors.primarySoft,
                  borderRadius: BorderRadius.circular(AppRadius.card),
                ),
                child: Icon(Icons.search, size: 40, color: AppColors.primary),
              ),
              const SizedBox(height: 16),
              Text(
                '搜索全网音乐',
                style: TextStyle(
                  fontSize: AppLayout.fromContext(context).bodySize,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'QQ音乐 · 网易云 · 酷狗',
                style: TextStyle(
                  fontSize: AppLayout.fromContext(context).secondarySize,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SearchVoiceInputDialog extends StatefulWidget {
  final VoiceInputSession session;

  const _SearchVoiceInputDialog({required this.session});

  @override
  State<_SearchVoiceInputDialog> createState() =>
      _SearchVoiceInputDialogState();
}

class _SearchVoiceInputDialogState extends State<_SearchVoiceInputDialog> {
  late final TextEditingController _candidateController;
  bool _preparing = true;
  bool _listening = false;
  bool _manuallyEdited = false;
  bool _closing = false;
  bool _startPending = false;
  int _operationGeneration = 0;
  String _status = '正在准备语音服务…';
  String? _error;

  @override
  void initState() {
    super.initState();
    _candidateController = TextEditingController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_startListening(clearCandidate: false));
    });
  }

  @override
  void dispose() {
    _candidateController.dispose();
    super.dispose();
  }

  Future<void> _startListening({bool clearCandidate = true}) async {
    if (_closing || _startPending) return;
    final operation = ++_operationGeneration;
    _startPending = true;
    FocusManager.instance.primaryFocus?.unfocus();
    if (clearCandidate) _candidateController.clear();
    _manuallyEdited = false;
    setState(() {
      _preparing = true;
      _listening = false;
      _error = null;
      _status = '正在准备语音服务…';
    });

    try {
      final started = await widget.session.start(
        onResult: _handleResult,
        onError: _handleError,
        onStatus: _handleStatus,
      );
      if (!mounted || _closing || operation != _operationGeneration) return;
      setState(() {
        _preparing = false;
        _listening = started && widget.session.isListening;
        if (!started && _error == null && !_manuallyEdited) {
          _error = '语音输入未能启动，请重试';
          _status = '语音输入不可用';
        }
      });
    } finally {
      _startPending = false;
    }
  }

  void _handleResult(String text, bool isFinal) {
    if (!mounted || _closing || _manuallyEdited) return;
    final candidate = text.trim();
    if (candidate.isEmpty) return;
    _candidateController.value = TextEditingValue(
      text: candidate,
      selection: TextSelection.collapsed(offset: candidate.length),
    );
    setState(() {
      _status = isFinal ? '已识别' : '正在识别…';
      if (isFinal) _listening = false;
    });
    if (isFinal) unawaited(_stopListening());
  }

  void _handleError(String message) {
    if (!mounted || _closing) return;
    setState(() {
      _preparing = false;
      _listening = false;
      _error = _cleanSpeechMessage(message);
      _status = '语音输入失败';
    });
  }

  void _handleStatus(String status) {
    if (!mounted || _closing) return;
    if (status == 'listening') {
      setState(() {
        _preparing = false;
        _listening = true;
        _status = '正在听…';
      });
    } else if (status == 'done' || status == 'notListening') {
      setState(() {
        _preparing = false;
        _listening = false;
        if (_error == null) {
          _status = _candidateController.text.trim().isEmpty ? '未识别到内容' : '已识别';
        }
      });
    }
  }

  Future<void> _stopListening() async {
    if (_closing) return;
    _operationGeneration++;
    await widget.session.stop();
    if (!mounted || _closing) return;
    setState(() {
      _preparing = false;
      _listening = false;
      if (_error == null) {
        _status = _candidateController.text.trim().isEmpty ? '未识别到内容' : '已识别';
      }
    });
  }

  Future<void> _beginManualEditing() async {
    if (_closing || _manuallyEdited) return;
    _operationGeneration++;
    _manuallyEdited = true;
    if (_preparing || _listening) await widget.session.cancel();
    if (!mounted || _closing) return;
    setState(() {
      _preparing = false;
      _listening = false;
      _error = null;
      _status = '可编辑';
    });
  }

  void _handleCandidateChanged(String _) {
    if (_closing) return;
    _manuallyEdited = true;
    setState(() {});
  }

  Future<void> _confirm() async {
    if (_closing || _candidateController.text.trim().isEmpty) return;
    final candidate = _candidateController.text.trim();
    _operationGeneration++;
    setState(() {
      _closing = true;
      _preparing = true;
      _listening = false;
      _status = '正在结束语音输入…';
    });
    await widget.session.close();
    if (!mounted) return;
    Navigator.pop(context, candidate.isEmpty ? null : candidate);
  }

  Future<void> _cancelDialog() async {
    if (_closing) return;
    _operationGeneration++;
    setState(() {
      _closing = true;
      _preparing = true;
      _listening = false;
      _status = '正在结束语音输入…';
    });
    await widget.session.close();
    if (mounted) Navigator.pop(context);
  }

  String _cleanSpeechMessage(String message) {
    return message
        .replaceFirst(RegExp(r'^(speech_not_supported|error_audio):\s*'), '')
        .trim();
  }

  @override
  Widget build(BuildContext context) {
    final layout = AppLayout.fromContext(context);
    final compact = layout.isCompactLandscape;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_cancelDialog());
      },
      child: AlertDialog(
        key: const ValueKey('search-voice-dialog'),
        insetPadding: EdgeInsets.symmetric(
          horizontal: compact ? 12 : 24,
          vertical: compact ? 8 : 24,
        ),
        titlePadding: EdgeInsets.fromLTRB(
          compact ? 16 : 24,
          compact ? 12 : 20,
          compact ? 16 : 24,
          compact ? 4 : 8,
        ),
        contentPadding: EdgeInsets.fromLTRB(
          compact ? 16 : 24,
          compact ? 4 : 8,
          compact ? 16 : 24,
          compact ? 4 : 8,
        ),
        actionsPadding: EdgeInsets.fromLTRB(
          compact ? 12 : 16,
          compact ? 2 : 8,
          compact ? 12 : 16,
          compact ? 8 : 12,
        ),
        title: const Row(
          children: [
            Icon(Icons.mic_rounded),
            SizedBox(width: 10),
            Expanded(child: Text('语音搜索')),
          ],
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 500),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  key: const ValueKey('search-voice-candidate'),
                  controller: _candidateController,
                  minLines: 1,
                  maxLines: compact ? 2 : 3,
                  maxLength: 120,
                  enabled: !_closing,
                  decoration: const InputDecoration(labelText: '搜索内容'),
                  textInputAction: TextInputAction.search,
                  onTap: () => unawaited(_beginManualEditing()),
                  onChanged: _handleCandidateChanged,
                  onSubmitted: (_) => unawaited(_confirm()),
                ),
                SizedBox(height: compact ? 2 : 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _error ?? _status,
                        key: const ValueKey('search-voice-status'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _error == null
                              ? AppColors.textSecondary
                              : Theme.of(context).colorScheme.error,
                          fontSize: layout.secondarySize,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox.square(
                      dimension: compact ? 42 : 48,
                      child: _preparing
                          ? const Padding(
                              padding: EdgeInsets.all(10),
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                              ),
                            )
                          : IconButton.filledTonal(
                              key: const ValueKey('search-voice-retry'),
                              tooltip: _listening ? '停止识别' : '重新识别',
                              onPressed: _closing
                                  ? null
                                  : _listening
                                  ? () => unawaited(_stopListening())
                                  : () => unawaited(_startListening()),
                              icon: Icon(
                                _listening
                                    ? Icons.stop_rounded
                                    : Icons.mic_rounded,
                              ),
                            ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('search-voice-cancel'),
            onPressed: _closing ? null : () => unawaited(_cancelDialog()),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            key: const ValueKey('search-voice-confirm'),
            onPressed: _closing || _candidateController.text.trim().isEmpty
                ? null
                : () => unawaited(_confirm()),
            icon: const Icon(Icons.search_rounded),
            label: const Text('搜索'),
          ),
        ],
      ),
    );
  }
}

enum _SearchSuggestionKind { artist, track }

class _SearchSuggestion {
  final String keyword;
  final _SearchSuggestionKind kind;
  final String? detail;

  const _SearchSuggestion(this.keyword, this.kind, {this.detail});
}
