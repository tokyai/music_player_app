import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:music_player_app/providers/search_session.dart';
import 'package:music_player_app/providers/theme_controller.dart';
import 'package:music_player_app/screens/discover_screen.dart';
import 'package:music_player_app/screens/player_screen.dart';
import 'package:music_player_app/screens/settings_screen.dart';
import 'package:music_player_app/screens/video_player_screen.dart';
import 'package:music_player_app/services/bilibili_service.dart';
import 'package:music_player_app/services/favorite_service.dart';
import 'package:music_player_app/theme/app_layout.dart';
import 'package:music_player_app/theme/app_theme.dart';
import 'package:music_player_app/utils/lyric_parser.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AppColors.isDark = false;
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('large landscape keeps all three favorite previews on screen', (
    tester,
  ) async {
    final music = _song(MusicPlatform.qq, 'music-1', '收藏歌曲');
    final bilibili = _song(MusicPlatform.bilibili, 'BV1favorite', 'B站收藏视频');
    final playlist = FavoritePlaylist(
      platform: MusicPlatform.netease,
      playlist: PlaylistInfo(
        id: 'playlist-1',
        name: '收藏歌单',
        creator: '创建者',
        trackCount: 10,
        tracks: const [],
      ),
    );
    SharedPreferences.setMockInitialValues({
      'favorites': jsonEncode([music.toJson(), bilibili.toJson()]),
      'favorite_playlists': jsonEncode([playlist.toJson()]),
    });

    await http.runWithClient(() async {
      final player = PlayerProvider();
      final favorites = FavoriteService();
      final theme = ThemeController();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        player.dispose();
        favorites.dispose();
        theme.dispose();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await _pump(
        tester,
        const DiscoverScreen(),
        player,
        favorites,
        theme,
        const Size(1280, 800),
      );

      expect(favorites.bilibiliFavorites, hasLength(1));
      expect(find.text('收藏歌曲'), findsWidgets);
      expect(find.text('收藏歌单'), findsWidgets);
      expect(find.text('B站收藏'), findsOneWidget);
      for (final key in const [
        'home-favorites-carousel',
        'home-favorite-playlists-carousel',
        'home-bilibili-favorites-carousel',
      ]) {
        final finder = find.byKey(ValueKey(key));
        expect(finder, findsOneWidget);
        expect(finder.hitTestable(), findsOneWidget);
        expect(tester.getBottomRight(finder).dy, lessThanOrEqualTo(800));
      }
      expect(tester.takeException(), isNull);
    }, () => MockClient((_) async => http.Response('{}', 200)));
  });

  testWidgets(
    'Bilibili player exposes pages lyrics quality and MV in landscape',
    (tester) async {
      for (final size in const [Size(640, 360), Size(1280, 800)]) {
        final player = _BilibiliPlayer();
        expect(
          player.lyricSearchQueryFor(
            player.currentSong.copyWith(name: '001. If You,re Happy'),
          ),
          "If You're Happy",
        );
        final favorites = FavoriteService();
        final theme = ThemeController();
        await _pump(
          tester,
          const PlayerScreen(),
          player,
          favorites,
          theme,
          size,
        );

        expect(
          find.byKey(const ValueKey('bilibili-info-pane')),
          findsOneWidget,
        );
        expect(find.text('第一P标题'), findsWidgets);
        expect(find.byKey(const ValueKey('bilibili-page-102')), findsOneWidget);
        expect(
          find
              .byKey(const ValueKey('bilibili-lyric-search-action'))
              .hitTestable(),
          findsOneWidget,
        );
        expect(
          find
              .byKey(const ValueKey('player-bilibili-quality-control'))
              .hitTestable(),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('player-mv-action')), findsOneWidget);
        expect(find.text('分P'), findsWidgets);
        expect(find.text('队列'), findsNothing);

        await tester.tap(
          find
              .byKey(const ValueKey('player-bilibili-pages-action'))
              .hitTestable(),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('bilibili-page-sheet')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('bilibili-page-sheet-102')));
        await tester.pumpAndSettle();
        expect(player.currentSong.name, '第二P标题');
        expect(find.text('第二P标题'), findsWidgets);
        expect(tester.takeException(), isNull);

        await tester.tap(
          find
              .byKey(const ValueKey('bilibili-lyric-search-action'))
              .hitTestable(),
        );
        await tester.pumpAndSettle();
        expect(find.text('QQ音乐 · 匹配歌手 · 匹配专辑'), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey('lyric-search-result-qq-lyric-candidate')),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('player-lyric-list')), findsOneWidget);
        expect(find.text('已匹配的第一行歌词'), findsOneWidget);
        expect(find.byKey(const ValueKey('bilibili-info-pane')), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const ValueKey('player-mv-action')).hitTestable(),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        final videoScreen = tester.widget<VideoPlayerScreen>(
          find.byType(VideoPlayerScreen),
        );
        expect(videoScreen.url, contains('.mcdn.bilivideo.cn'));
        expect(videoScreen.alternateUrls, hasLength(1));
        expect(
          videoScreen.audioUrl,
          'https://test.mcdn.bilivideo.cn/audio.m4s',
        );
        expect(
          videoScreen.headers?['Referer'],
          'https://www.bilibili.com/video/BV1player',
        );
        expect(videoScreen.headers?['Origin'], 'https://www.bilibili.com');
        expect(find.byKey(const ValueKey('mv-player-back')), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox.shrink());
        player.dispose();
        favorites.dispose();
        theme.dispose();
      }
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    },
  );

  testWidgets('Bilibili QR login is reachable in both landscape sizes', (
    tester,
  ) async {
    for (final size in const [Size(640, 360), Size(1280, 800)]) {
      final player = _BilibiliPlayer();
      final favorites = FavoriteService();
      final theme = ThemeController();
      await _pump(
        tester,
        const SettingsScreen(),
        player,
        favorites,
        theme,
        size,
      );

      final account = find.byKey(const ValueKey('bilibili-account-setting'));
      expect(account.hitTestable(), findsOneWidget);
      await tester.tap(account);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('bilibili-login-dialog')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('bilibili-login-qr')), findsOneWidget);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      player.dispose();
      favorites.dispose();
      theme.dispose();
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

Future<void> _pump(
  WidgetTester tester,
  Widget screen,
  PlayerProvider player,
  FavoriteService favorites,
  ThemeController theme,
  Size size,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<PlayerProvider>.value(value: player),
        ChangeNotifierProvider<FavoriteService>.value(value: favorites),
        ChangeNotifierProvider<ThemeController>.value(value: theme),
        ChangeNotifierProvider(create: (_) => SearchSession()),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        builder: (context, child) => MediaQuery(
          data: AppLayout.adaptiveMediaQueryOf(context),
          child: child!,
        ),
        home: screen,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

SongSearchResult _song(MusicPlatform platform, String id, String name) {
  return SongSearchResult(
    platform: platform,
    id: id,
    name: name,
    artist: platform == MusicPlatform.bilibili ? '测试UP主' : '测试歌手',
    album: name,
  );
}

class _BilibiliPlayer extends PlayerProvider {
  PlayQueueItem _song = PlayQueueItem(
    platform: MusicPlatform.bilibili,
    id: 'BV1player',
    name: '第一P标题',
    artist: '测试UP主',
    album: '视频总标题',
    duration: 120,
    bilibiliVideoTitle: '视频总标题',
    bilibiliDescription: '这是用于横屏测试的视频简介。',
    bilibiliCid: 101,
    bilibiliPage: 1,
    bilibiliPages: const [
      BilibiliPageInfo(cid: 101, page: 1, title: '第一P标题', duration: 120),
      BilibiliPageInfo(cid: 102, page: 2, title: '第二P标题', duration: 180),
    ],
  );
  int _audioQuality = 30280;
  int _videoQuality = 80;
  List<LyricLine> _matchedLyrics = const [];

  @override
  PlayQueueItem get currentSong => _song;

  @override
  List<PlayQueueItem> get queue => [_song];

  @override
  int get currentIndex => 0;

  @override
  Duration get duration => Duration(seconds: _song.duration ?? 0);

  @override
  List<LyricLine> get lyrics => _matchedLyrics;

  @override
  int get currentLyricIndex => 0;

  @override
  bool get lyricsLoading => false;

  @override
  List<BilibiliStream> get bilibiliAudioQualities => const [
    BilibiliStream(
      quality: 30280,
      label: '192K',
      url: 'https://example.com/audio.m4s',
      bandwidth: 192000,
    ),
  ];

  @override
  List<BilibiliStream> get bilibiliVideoQualities => const [
    BilibiliStream(
      quality: 80,
      label: '1080P',
      url: 'https://example.com/video.m4s',
      bandwidth: 2500000,
    ),
  ];

  @override
  int get bilibiliAudioQuality => _audioQuality;

  @override
  int get bilibiliVideoQuality => _videoQuality;

  @override
  Future<void> selectBilibiliPage(int pageIndex) async {
    final page = _song.bilibiliPages[pageIndex];
    _song = _song.copyWith(
      name: page.title,
      duration: page.duration,
      bilibiliCid: page.cid,
      bilibiliPage: page.page,
    );
    notifyListeners();
  }

  @override
  Future<void> setBilibiliAudioQuality(int quality) async {
    _audioQuality = quality;
    notifyListeners();
  }

  @override
  Future<void> setBilibiliVideoQuality(int quality) async {
    _videoQuality = quality;
    notifyListeners();
  }

  @override
  Future<List<SongSearchResult>> searchLyricCandidates(String keyword) async {
    return [
      SongSearchResult(
        platform: MusicPlatform.qq,
        id: 'lyric-candidate',
        name: '第二P标题',
        artist: '匹配歌手',
        album: '匹配专辑',
        duration: 180,
      ),
    ];
  }

  @override
  Future<void> applyLyricCandidate(SongSearchResult candidate) async {
    _matchedLyrics = const [
      LyricLine(Duration.zero, '已匹配的第一行歌词'),
      LyricLine(Duration(seconds: 10), '已匹配的第二行歌词'),
    ];
    notifyListeners();
  }

  @override
  Future<BilibiliVideoSource> currentBilibiliVideoSource() async =>
      const BilibiliVideoSource(
        urls: [
          'https://test.mcdn.bilivideo.cn/video.m4s',
          'https://backup.bilivideo.com/video.m4s',
        ],
        audioUrls: ['https://test.mcdn.bilivideo.cn/audio.m4s'],
        headers: {
          'Referer': 'https://www.bilibili.com/video/BV1player',
          'Origin': 'https://www.bilibili.com',
        },
      );

  @override
  Future<BilibiliQrCode> createBilibiliQrCode() async => const BilibiliQrCode(
    key: 'test-key',
    url: 'https://passport.bilibili.com/test-login',
  );
}
