import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'providers/player_provider.dart';
import 'providers/search_session.dart';
import 'providers/sync_controller.dart';
import 'providers/theme_controller.dart';
import 'screens/login_screen.dart';
import 'screens/discover_screen.dart';
import 'screens/player_screen.dart';
import 'screens/search_screen.dart';
import 'screens/playlist_screen.dart';
import 'screens/settings_screen.dart';
import 'services/favorite_service.dart';
import 'services/account_service.dart';
import 'services/account_sync_service.dart';
import 'services/floating_capsule_service.dart';
import 'services/player_media_handler.dart';
import 'services/user_profile_store.dart';
import 'theme/app_layout.dart';
import 'theme/app_motion.dart';
import 'theme/app_theme.dart';
import 'utils/system_ui.dart';
import 'widgets/mini_player.dart';
import 'widgets/remote_focusable.dart';

final _navigatorKey = GlobalKey<NavigatorState>();
const _foregroundMediaKeyChannel = MethodChannel(
  'music_player/foreground_media_keys',
);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 全面屏适配：内容延伸到状态栏/导航栏区域（各页面已用 SafeArea 保护内容）
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  final account = AccountService();
  await account.initialize();
  if (account.isAuthenticated && account.user != null) {
    await UserProfileStore.activate(account.user!.id);
    try {
      await AccountSyncService(account).bootstrap();
    } catch (error) {
      debugPrint('启动账号同步失败: $error');
    }
  }
  final player = PlayerProvider();
  final audioSession = await AudioSession.instance;
  await audioSession.configure(const AudioSessionConfiguration.music());
  // 系统媒体会话：通知栏、锁屏和车机方向盘共用应用内播放队列。
  await AudioService.init(
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
  // Some car launchers deliver next/previous to the foreground Activity
  // instead of the active MediaSession. Keep a narrow fallback for that path.
  _foregroundMediaKeyChannel.setMethodCallHandler((call) async {
    try {
      switch (call.method) {
        case 'next':
          await player.playNext();
          break;
        case 'previous':
          await player.playPrevious();
          break;
      }
    } catch (error) {
      debugPrint('前台车机媒体键处理失败: $error');
    }
    return null;
  });
  bool? foregroundMediaKeysEnabled;
  void syncForegroundMediaKeys() {
    final enabled = player.currentSong != null && player.isPlaying;
    if (foregroundMediaKeysEnabled == enabled) return;
    foregroundMediaKeysEnabled = enabled;
    unawaited(
      _foregroundMediaKeyChannel
          .invokeMethod<void>('setEnabled', {'enabled': enabled})
          .catchError((_) {}),
    );
  }

  player.addListener(syncForegroundMediaKeys);
  syncForegroundMediaKeys();
  // Android 13+ 请求通知权限（否则系统媒体通知不显示）
  try {
    await Permission.notification.request();
  } catch (_) {}
  // 系统悬浮窗胶囊：初始化通道 + 恢复开关状态
  FloatingCapsuleService.init();
  try {
    final prefs = await SharedPreferences.getInstance();
    FloatingCapsuleService.setEnabled(
      prefs.getBool('floating_capsule_enabled') ?? false,
    );
  } catch (_) {}
  runApp(MusicPlayerApp(player: player, account: account));
}

class MusicPlayerApp extends StatelessWidget {
  const MusicPlayerApp({super.key, required this.player, this.account});

  final PlayerProvider player;
  final AccountService? account;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        if (account != null)
          ChangeNotifierProvider<AccountService>.value(value: account!),
        ChangeNotifierProvider<PlayerProvider>.value(value: player),
        ChangeNotifierProvider(create: (_) => SearchSession()),
        ChangeNotifierProvider(create: (_) => ThemeController()),
        ChangeNotifierProvider(create: (_) => FavoriteService()..load()),
        if (account != null)
          ChangeNotifierProvider(
            lazy: false,
            create: (context) => SyncController(
              service: AccountSyncService(account!),
              favorites: context.read<FavoriteService>(),
              player: player,
              search: context.read<SearchSession>(),
              theme: context.read<ThemeController>(),
            ),
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
              // 注入系统悬浮窗胶囊回调（仅一次）
              if (FloatingCapsuleService.onPlayPauseTap == null) {
                FloatingCapsuleService.onPlayPauseTap = () {
                  context.read<PlayerProvider>().playPause();
                };
                FloatingCapsuleService.onCapsuleTap = () {
                  _navigatorKey.currentState?.push(PlayerScreen.route(context));
                };
              }
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
            home: account == null
                ? const MainScreen()
                : AccountGate(
                    initiallyReady: account!.isAuthenticated,
                    child: const MainScreen(),
                  ),
          );
        },
      ),
    );
  }
}

class AccountGate extends StatefulWidget {
  final bool initiallyReady;
  final Widget child;

  const AccountGate({
    super.key,
    required this.initiallyReady,
    required this.child,
  });

  @override
  State<AccountGate> createState() => _AccountGateState();
}

class _AccountGateState extends State<AccountGate> {
  late bool _ready;
  bool _preparing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _ready = widget.initiallyReady;
  }

  Future<void> _login(String server, String username, String password) async {
    final account = context.read<AccountService>();
    final player = context.read<PlayerProvider>();
    final favorites = context.read<FavoriteService>();
    final search = context.read<SearchSession>();
    final theme = context.read<ThemeController>();
    setState(() {
      _preparing = true;
      _ready = false;
      _error = null;
    });
    try {
      await player.prepareForAccountSwitch();
      await account.login(
        serverUrl: server,
        username: username,
        password: password,
      );
      final user = account.user!;
      await UserProfileStore.activate(user.id);
      try {
        await AccountSyncService(account).bootstrap();
      } catch (error) {
        debugPrint('登录后同步失败，将使用本地账号数据: $error');
      }
      await Future.wait([
        favorites.reloadForAccount(),
        search.reloadForAccount(),
        theme.reloadForAccount(),
        player.reloadForAccount(),
      ]);
      if (!mounted) return;
      setState(() => _ready = true);
    } on AccountException {
      rethrow;
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '账号数据初始化失败：$error');
      rethrow;
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = context.watch<AccountService>();
    if (account.status == AccountStatus.disabled) {
      return _AccountUnavailableScreen(message: account.message ?? '当前账号不可用');
    }
    if (!account.isAuthenticated) {
      return LoginScreen(onLogin: _login);
    }
    if (_preparing || !_ready) {
      return Scaffold(
        body: SafeArea(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(_error ?? '正在同步账号数据...'),
              ],
            ),
          ),
        ),
      );
    }
    return widget.child;
  }
}

class _AccountUnavailableScreen extends StatelessWidget {
  final String message;

  const _AccountUnavailableScreen({required this.message});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.block_outlined,
                    size: 56,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    '账号不可用',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Text(message, textAlign: TextAlign.center),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    key: const ValueKey('disabled-account-logout'),
                    onPressed: context.read<AccountService>().logout,
                    icon: const Icon(Icons.logout),
                    label: const Text('退出账号'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
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
                body: Row(
                  children: [
                    SafeArea(
                      right: false,
                      child: NavigationRail(
                        key: const ValueKey('landscape-navigation'),
                        minWidth: compactRail
                            ? 96
                            : (largeUi
                                  ? (layout.isHighDensityCarDisplay ? 136 : 132)
                                  : 118),
                        selectedIndex: _currentIndex,
                        onDestinationSelected: _selectScreen,
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
                                padding: EdgeInsets.symmetric(horizontal: 4),
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
              );
            },
          );
        }

        return Scaffold(
          body: content,
          bottomNavigationBar: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const MiniPlayer(),
                ClipRRect(
                  borderRadius: BorderRadius.vertical(
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
