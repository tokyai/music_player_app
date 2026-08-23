import 'dart:async';
import 'dart:ui';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'providers/ai_assistant_controller.dart';
import 'providers/ai_config_controller.dart';
import 'providers/player_provider.dart';
import 'providers/search_session.dart';
import 'providers/theme_controller.dart';
import 'providers/user_controller.dart';
import 'screens/discover_screen.dart';
import 'screens/player_screen.dart';
import 'screens/search_screen.dart';
import 'screens/playlist_screen.dart';
import 'screens/settings_screen.dart';
import 'services/favorite_service.dart';
import 'services/app_exit_service.dart';
import 'services/floating_capsule_service.dart';
import 'services/player_media_handler.dart';
import 'services/user_data_scope.dart';
import 'theme/app_layout.dart';
import 'theme/app_motion.dart';
import 'theme/app_theme.dart';
import 'utils/system_ui.dart';
import 'widgets/mini_player.dart';
import 'widgets/ai_assistant_overlay.dart';
import 'widgets/remote_focusable.dart';

final _navigatorKey = GlobalKey<NavigatorState>();
const _foregroundMediaKeyChannel = MethodChannel(
  'music_player/foreground_media_keys',
);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Music lists can contain hundreds of covers. Flutter's default image
  // cache is item-count based and may retain a large decoded-image working
  // set on a car display. Bound only the in-memory decoded cache; the disk
  // cache and user audio cache remain untouched.
  final imageCache = PaintingBinding.instance.imageCache;
  imageCache.maximumSize = 300;
  imageCache.maximumSizeBytes = 64 << 20;
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('未捕获的后台异常: $error');
    debugPrintStack(stackTrace: stack);
    return true;
  };
  // 全面屏适配：内容延伸到状态栏/导航栏区域（各页面已用 SafeArea 保护内容）
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  // Restore the mini-window preference before constructing the player. The
  // player can restore a paused queue immediately, and that song should still
  // be available in the always-on-top window.
  FloatingCapsuleService.init();
  final users = UserController();
  await users.ready;
  await FloatingCapsuleService.restoreEnabled(scope: users.activeScope);
  final player = PlayerProvider(dataScope: users.activeScope);
  try {
    final audioSession = await AudioSession.instance;
    await audioSession.configure(const AudioSessionConfiguration.music());
  } catch (error, stack) {
    debugPrint('音频会话初始化失败，使用系统默认配置: $error');
    debugPrintStack(stackTrace: stack);
  }
  // 系统媒体会话：通知栏、锁屏和车机方向盘共用应用内播放队列。
  PlayerMediaHandler? mediaHandler;
  try {
    mediaHandler = await AudioService.init<PlayerMediaHandler>(
      builder: () => PlayerMediaHandler(player),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.example.music_player_app.audio',
        androidNotificationChannelName: '库仔音乐播放',
        androidNotificationOngoing: true,
        // 车机通知只需要小尺寸缩略图，避免音频服务完整解码高分辨率封面。
        artDownscaleWidth: 256,
        artDownscaleHeight: 256,
      ),
    );
  } catch (error, stack) {
    debugPrint('系统媒体会话初始化失败，继续使用应用内播放器: $error');
    debugPrintStack(stackTrace: stack);
  }
  // Some car launchers deliver next/previous to the foreground Activity
  // instead of the active MediaSession. Keep a narrow fallback for that path.
  var activePlayer = player;
  _foregroundMediaKeyChannel.setMethodCallHandler((call) async {
    try {
      switch (call.method) {
        case 'next':
          await activePlayer.playNext();
          break;
        case 'previous':
          await activePlayer.playPrevious();
          break;
      }
    } catch (error) {
      debugPrint('前台车机媒体键处理失败: $error');
    }
    return null;
  });
  bool? foregroundMediaKeysEnabled;
  void syncForegroundMediaKeys() {
    final enabled = activePlayer.currentSong != null && activePlayer.isPlaying;
    if (foregroundMediaKeysEnabled == enabled) return;
    foregroundMediaKeysEnabled = enabled;
    unawaited(
      _foregroundMediaKeyChannel
          .invokeMethod<void>('setEnabled', {'enabled': enabled})
          .catchError((_) {}),
    );
  }

  void bindSystemPlayer(PlayerProvider next) {
    if (identical(activePlayer, next)) return;
    activePlayer.removeListener(syncForegroundMediaKeys);
    activePlayer = next;
    mediaHandler?.bindPlayer(next);
    foregroundMediaKeysEnabled = null;
    activePlayer.addListener(syncForegroundMediaKeys);
    syncForegroundMediaKeys();
  }

  activePlayer.addListener(syncForegroundMediaKeys);
  syncForegroundMediaKeys();
  // Android 13+ 请求通知权限（否则系统媒体通知不显示）
  try {
    await Permission.notification.request();
  } catch (_) {}
  runApp(
    MusicPlayerApp(
      player: player,
      users: users,
      bindSystemPlayer: bindSystemPlayer,
    ),
  );
}

class MusicPlayerApp extends StatefulWidget {
  const MusicPlayerApp({
    super.key,
    required this.player,
    required this.users,
    required this.bindSystemPlayer,
  });

  final PlayerProvider player;
  final UserController users;
  final void Function(PlayerProvider player) bindSystemPlayer;

  @override
  State<MusicPlayerApp> createState() => _MusicPlayerAppState();
}

class _MusicPlayerAppState extends State<MusicPlayerApp>
    with WidgetsBindingObserver {
  late _UserSession _session;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _session = _UserSession(
      scope: widget.users.activeScope,
      player: widget.player,
    );
    widget.users.attachSessionSwitcher(_switchUserSession);
    FloatingCapsuleService.onPlayPauseTap = () => _session.player.playPause();
    FloatingCapsuleService.onCapsuleTap = () {
      final context = _navigatorKey.currentContext;
      if (context != null) {
        _navigatorKey.currentState?.push(PlayerScreen.route(context));
      }
    };
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_syncFloatingCapsuleOnResume());
    }
  }

  Future<void> _syncFloatingCapsuleOnResume() async {
    if (!mounted || !FloatingCapsuleService.enabled) return;
    final player = _session.player;
    final song = player.currentSong;
    if (song == null) return;
    await FloatingCapsuleService.show(
      title: song.name,
      artist: song.artist,
      coverUrl: song.coverUrl,
      isPlaying: player.isPlaying,
    );
  }

  Future<void> _switchUserSession(String userId) async {
    if (userId == _session.scope.userId) return;
    final target = _UserSession(
      scope: UserDataScope(userId),
      activateRestoredSession: false,
    );
    var previousPrepared = false;
    try {
      await target.ready;
      await _session.aiAssistant.stopSession(restoreMusic: false);
      await _session.player.prepareForUserSwitch();
      previousPrepared = true;
      if (!mounted) throw StateError('应用正在关闭，无法切换用户');
      await widget.users.activatePreparedUser(userId);
      if (!mounted) {
        target.dispose();
        return;
      }
      final previous = _session;
      setState(() => _session = target);
      WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
      try {
        _navigatorKey.currentState?.popUntil((route) => route.isFirst);
        widget.bindSystemPlayer(target.player);
        await FloatingCapsuleService.hide();
        await FloatingCapsuleService.restoreEnabled(scope: target.scope);
        await target.player.activateRestoredSession();
      } catch (error, stackTrace) {
        // The user/session commit is already complete. Optional platform
        // integrations must not roll the UI back to providers being disposed.
        debugPrint('切换用户后同步系统播放状态失败: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
    } catch (error) {
      if (previousPrepared && _session.scope.userId != userId) {
        await _session.player.cancelPreparedUserSwitch();
      }
      if (!identical(_session, target)) target.dispose();
      rethrow;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.users.detachSessionSwitcher();
    FloatingCapsuleService.onPlayPauseTap = null;
    FloatingCapsuleService.onCapsuleTap = null;
    _session.dispose();
    widget.users.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      key: ValueKey('user-session-${_session.scope.userId}'),
      providers: [
        ChangeNotifierProvider<UserController>.value(value: widget.users),
        ChangeNotifierProvider<PlayerProvider>.value(value: _session.player),
        ChangeNotifierProvider<AiConfigController>.value(
          value: _session.aiConfig,
        ),
        ChangeNotifierProvider<AiAssistantController>.value(
          value: _session.aiAssistant,
        ),
        ChangeNotifierProvider<SearchSession>.value(value: _session.search),
        ChangeNotifierProvider<ThemeController>.value(value: _session.theme),
        ChangeNotifierProvider<FavoriteService>.value(
          value: _session.favorites,
        ),
      ],
      child: Consumer<ThemeController>(
        builder: (context, themeCtrl, _) {
          return MaterialApp(
            navigatorKey: _navigatorKey,
            title: '库仔音乐',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light(),
            darkTheme: AppTheme.dark(),
            themeMode: themeCtrl.mode,
            // AnimatedTheme interpolates the complete application theme and
            // rebuilds every visible page for several frames.  An immediate
            // switch is much more reliable on low-end car hardware and also
            // prevents custom surfaces from lagging one frame behind.
            themeAnimationDuration: Duration.zero,
            // 按实际生效的主题同步全局亮暗标志 + 系统栏样式（状态栏不黑条、图标跟随主题）
            builder: (context, child) {
              AppColors.syncWithTheme(context);
              applySystemUi(dark: AppColors.isDark);
              // 在车机大屏上统一放大未显式使用 AppLayout 尺寸令牌的文字，
              // 同时合并系统无障碍字号和用户设置的整体字号比例。
              return TvRemoteScope(
                navigatorKey: _navigatorKey,
                child: MediaQuery(
                  data: AppLayout.adaptiveMediaQueryOf(
                    context,
                    fontScale: themeCtrl.fontScale,
                  ),
                  child: child!,
                ),
              );
            },
            home: MainScreen(key: ValueKey(_session.scope.userId)),
          );
        },
      ),
    );
  }
}

class _UserSession {
  final UserDataScope scope;
  final PlayerProvider player;
  late final AiConfigController aiConfig;
  late final AiAssistantController aiAssistant;
  late final SearchSession search;
  late final ThemeController theme;
  late final FavoriteService favorites;
  bool _disposed = false;

  _UserSession({
    required this.scope,
    PlayerProvider? player,
    bool activateRestoredSession = true,
  }) : player =
           player ??
           PlayerProvider(
             dataScope: scope,
             activateRestoredSession: activateRestoredSession,
           ) {
    aiConfig = AiConfigController(dataScope: scope);
    aiAssistant = AiAssistantController(
      player: this.player,
      configController: aiConfig,
    );
    search = SearchSession(dataScope: scope);
    theme = ThemeController(dataScope: scope);
    favorites = FavoriteService(dataScope: scope);
    ready = Future.wait<void>([
      this.player.settingsReady,
      this.player.historyReady,
      this.player.playbackStateReady,
      aiConfig.ready,
      search.historyReady,
      theme.ready,
      favorites.load(),
    ]);
  }

  late final Future<void> ready;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    aiAssistant.dispose();
    aiConfig.dispose();
    search.dispose();
    theme.dispose();
    favorites.dispose();
    player.dispose();
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen>
    with SingleTickerProviderStateMixin {
  int _currentIndex = 0;
  SearchSession? _searchSession;
  int _handledSearchNavigationId = 0;
  late final AnimationController _pageTransitionController;
  late final Animation<Offset> _pageOffset;

  final List<Widget?> _screens = [const DiscoverScreen(), null, null, null];

  @override
  void initState() {
    super.initState();
    _pageTransitionController = AnimationController(
      vsync: this,
      duration: AppMotion.state,
      value: 1,
    );
    final curved = CurvedAnimation(
      parent: _pageTransitionController,
      curve: AppMotion.enterCurve,
    );
    _pageOffset = Tween<Offset>(
      begin: const Offset(0.012, 0),
      end: Offset.zero,
    ).animate(curved);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final session = context.read<SearchSession>();
    if (identical(_searchSession, session)) return;
    _searchSession?.removeListener(_handleSearchNavigation);
    _searchSession = session..addListener(_handleSearchNavigation);
    _handleSearchNavigation();
  }

  @override
  void dispose() {
    _searchSession?.removeListener(_handleSearchNavigation);
    _pageTransitionController.dispose();
    super.dispose();
  }

  void _runPageTransition() {
    if (AppMotion.resolve(context, AppMotion.state) == Duration.zero) {
      _pageTransitionController.value = 1;
      return;
    }
    _pageTransitionController.forward(from: 0);
  }

  void _handleSearchNavigation() {
    final navigationId = _searchSession?.navigationId ?? 0;
    if (!mounted || navigationId <= _handledSearchNavigationId) return;
    _handledSearchNavigationId = navigationId;
    setState(() {
      _screens[1] ??= _createScreen(1);
      _currentIndex = 1;
    });
    _runPageTransition();
  }

  Widget _createScreen(int index) {
    return switch (index) {
      0 => const DiscoverScreen(),
      1 => const SearchScreen(),
      2 => const PlaylistScreen(),
      3 => const SettingsScreen(),
      _ => throw RangeError.index(index, _screens),
    };
  }

  void _selectScreen(int index) {
    if (index == _currentIndex) return;
    setState(() {
      _screens[index] ??= _createScreen(index);
      _currentIndex = index;
    });
    _runPageTransition();
  }

  @override
  Widget build(BuildContext context) {
    AppColors.syncWithTheme(context);
    return Selector<PlayerProvider, ({bool hasSong, String? error})>(
      selector: (_, player) =>
          (hasSong: player.currentSong != null, error: player.lastError),
      builder: (context, playerState, _) {
        if (playerState.error != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!context.mounted) return;
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(
                SnackBar(
                  content: Text(playerState.error!),
                  duration: const Duration(seconds: 3),
                  action: SnackBarAction(label: '知道了', onPressed: () {}),
                ),
              );
            context.read<PlayerProvider>().consumeError();
          });
        }

        final isLandscape =
            MediaQuery.orientationOf(context) == Orientation.landscape;
        final hasCurrentSong = playerState.hasSong;
        // A compositor-only offset preserves a clear navigation response
        // without applying animated opacity to the entire image-heavy page.
        final content = SlideTransition(
          position: _pageOffset,
          child: IndexedStack(
            index: _currentIndex,
            children: List.generate(
              _screens.length,
              (index) => TickerMode(
                enabled: index == _currentIndex,
                child: _screens[index] ?? const SizedBox.shrink(),
              ),
            ),
          ),
        );

        if (isLandscape) {
          return LayoutBuilder(
            builder: (context, constraints) {
              final layout = AppLayout.fromConstraints(context, constraints);
              final largeUi = layout.usesLargeTypography;
              final compactRail = constraints.maxHeight < 480;
              final showPlayerPane =
                  hasCurrentSong &&
                  constraints.maxWidth >= AppLayout.wideWindowMinWidth &&
                  constraints.maxHeight >= AppLayout.wideWindowMinHeight;
              return Scaffold(
                body: Stack(
                  fit: StackFit.expand,
                  children: [
                    Row(
                      children: [
                        SafeArea(
                          right: false,
                          child: NavigationRail(
                            key: const ValueKey('landscape-navigation'),
                            minWidth: compactRail
                                ? 96
                                : (largeUi
                                      ? (layout.isHighDensityCarDisplay
                                            ? 136
                                            : 132)
                                      : 118),
                            selectedIndex: _currentIndex,
                            onDestinationSelected: (index) {
                              if (index == 4) {
                                AppExitService.confirmAndExit(context);
                                return;
                              }
                              _selectScreen(index);
                            },
                            labelType: NavigationRailLabelType.all,
                            groupAlignment: compactRail ? 0 : -0.28,
                            useIndicator: true,
                            indicatorColor: AppColors.primarySoft,
                            indicatorShape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(
                                AppRadius.control,
                              ),
                            ),
                            selectedIconTheme: IconThemeData(
                              color: AppColors.primary,
                              size: compactRail ? 31 : (largeUi ? 38 : 34),
                            ),
                            unselectedIconTheme: IconThemeData(
                              color: AppColors.textSecondary,
                              size: compactRail ? 29 : (largeUi ? 35 : 32),
                            ),
                            selectedLabelTextStyle: TextStyle(
                              color: AppColors.primary,
                              fontSize: compactRail ? 15 : (largeUi ? 21 : 18),
                              fontWeight: FontWeight.w700,
                            ),
                            unselectedLabelTextStyle: TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: compactRail ? 15 : (largeUi ? 20 : 18),
                              fontWeight: FontWeight.w600,
                            ),
                            leading: _buildLandscapeBrand(
                              compact: compactRail,
                              wide: largeUi,
                            ),
                            scrollable: compactRail,
                            destinations: const [
                              NavigationRailDestination(
                                icon: Icon(Icons.explore_outlined),
                                selectedIcon: Icon(Icons.explore),
                                label: RemoteFocusable(
                                  key: ValueKey(
                                    'landscape-navigation-initial-focus',
                                  ),
                                  autofocus: true,
                                  borderRadius: BorderRadius.all(
                                    Radius.circular(6),
                                  ),
                                  child: Padding(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: 4,
                                    ),
                                    child: Text('发现'),
                                  ),
                                ),
                              ),
                              NavigationRailDestination(
                                icon: Icon(Icons.search_outlined),
                                selectedIcon: Icon(Icons.search),
                                label: Text('搜索'),
                              ),
                              NavigationRailDestination(
                                icon: Icon(Icons.playlist_play_outlined),
                                selectedIcon: Icon(Icons.playlist_play),
                                label: Text('歌单'),
                              ),
                              NavigationRailDestination(
                                icon: Icon(Icons.settings_outlined),
                                selectedIcon: Icon(Icons.settings),
                                label: Text('设置'),
                              ),
                              NavigationRailDestination(
                                icon: Icon(
                                  Icons.power_settings_new_rounded,
                                  key: ValueKey('landscape-complete-exit'),
                                ),
                                label: Text('退出'),
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
                          child: Column(
                            children: [
                              Expanded(child: content),
                              if (hasCurrentSong && !showPlayerPane)
                                const MiniPlayer(),
                            ],
                          ),
                        ),
                        if (showPlayerPane)
                          SizedBox(
                            width: 297,
                            child: Row(
                              children: [
                                VerticalDivider(
                                  width: 1,
                                  thickness: 1,
                                  color: AppColors.surfaceSoft,
                                ),
                                const SizedBox(
                                  width: 296,
                                  child: LandscapeMiniPlayer(),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                    Selector<AiConfigController?, bool>(
                      selector: (_, config) =>
                          config?.showAssistantOnAllPages ?? true,
                      builder: (context, visible, _) => visible
                          ? AiAssistantPetOverlay(
                              reservedInsets: EdgeInsets.only(
                                right: showPlayerPane ? 297 : 0,
                                bottom: hasCurrentSong && !showPlayerPane
                                    ? 76
                                    : 0,
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ],
                ),
              );
            },
          );
        }

        return Scaffold(
          body: Stack(
            fit: StackFit.expand,
            children: [
              content,
              Selector<AiConfigController?, bool>(
                selector: (_, config) =>
                    config?.showAssistantOnAllPages ?? true,
                builder: (context, visible, _) => visible
                    ? const AiAssistantPetOverlay()
                    : const SizedBox.shrink(),
              ),
            ],
          ),
          bottomNavigationBar: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const MiniPlayer(),
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(AppRadius.panel),
                  ),
                  child: NavigationBar(
                    selectedIndex: _currentIndex,
                    onDestinationSelected: _selectScreen,
                    destinations: const [
                      NavigationDestination(
                        icon: Icon(Icons.explore_outlined),
                        selectedIcon: Icon(Icons.explore),
                        label: '发现',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.search_outlined),
                        selectedIcon: Icon(Icons.search),
                        label: '搜索',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.playlist_play_outlined),
                        selectedIcon: Icon(Icons.playlist_play),
                        label: '歌单',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.settings_outlined),
                        selectedIcon: Icon(Icons.settings),
                        label: '设置',
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildLandscapeBrand({required bool compact, required bool wide}) {
    return Padding(
      padding: EdgeInsets.fromLTRB(8, compact ? 8 : 16, 8, compact ? 8 : 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.media),
            child: Image.asset(
              'assets/images/app_logo.png',
              width: compact ? 44 : (wide ? 62 : 56),
              height: compact ? 44 : (wide ? 62 : 56),
              fit: BoxFit.cover,
            ),
          ),
          if (!compact) ...[
            const SizedBox(height: 10),
            Text(
              '库仔音乐',
              maxLines: 1,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: wide ? 20 : 17,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
