import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:music_player_app/screens/local_music_screen.dart';
import 'package:music_player_app/services/favorite_service.dart';
import 'package:music_player_app/services/local_music_library.dart';
import 'package:music_player_app/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const permissions = MethodChannel('flutter.baseflow.com/permissions/methods');
  var granted = true;
  var scans = 0;
  var cancels = 0;
  Completer<Map<String, dynamic>>? pending;
  var malformed = false;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    granted = true;
    scans = 0;
    cancels = 0;
    pending = null;
    malformed = false;
    messenger.setMockMethodCallHandler(permissions, (call) async {
      if (call.method == 'requestPermissions') {
        return {for (final id in call.arguments as List) id: granted ? 1 : 0};
      }
      return granted ? 1 : 0;
    });
    messenger.setMockMethodCallHandler(LocalMusicLibrary.channel, (call) async {
      if (call.method == 'info') return {'sdk': 34};
      if (call.method == 'cancel') {
        cancels++;
        return null;
      }
      if (call.method == 'scan') {
        scans++;
        if (pending != null) return pending!.future;
        return {
          'songs': [
            malformed
                ? {'platform': 'local', 'id': 'file:///private/key'}
                : _song(1).toJson(),
            _song(2).toJson(),
          ],
          'afterId': 2,
          'hasMore': false,
        };
      }
      return null;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(permissions, null);
    messenger.setMockMethodCallHandler(LocalMusicLibrary.channel, null);
  });

  test(
    'scan reads metadata without file writes and handles denied permission',
    () async {
      final library = LocalMusicLibrary();
      await library.scan();
      expect(library.songs, hasLength(2));
      expect(scans, 1);
      granted = false;
      await library.scan();
      expect(library.permissionDenied, isTrue);
      expect(library.songs, hasLength(2));
      expect(scans, 1);
      library.dispose();
    },
  );

  test(
    'overlapping scans are ignored and disposal cancels a late native result',
    () async {
      final library = LocalMusicLibrary();
      pending = Completer<Map<String, dynamic>>();
      final first = library.scan();
      for (var i = 0; i < 10 && scans == 0; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      await library.scan();
      expect(scans, 1);
      library.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(cancels, 1);
      pending!.complete({
        'songs': [_song(1).toJson()],
        'afterId': 1,
        'hasMore': false,
      });
      await first;
      expect(library.songs, isEmpty);
    },
  );

  test('external file and untrusted provider URIs are rejected', () async {
    for (final uri in [
      'file:///secret',
      'https://audio.test/a',
      'content://contacts/external/audio/media/1',
      'content://media/external/audio/media/1?path=secret',
    ]) {
      expect(() => validateLocalAudioUri(uri), throwsFormatException);
    }
    malformed = true;
    final library = LocalMusicLibrary();
    await library.scan();
    expect(library.error, isNotNull);
    expect(library.songs, isEmpty);
    library.dispose();
    expect(
      SongSearchResult.fromJson(_song(1).toJson()).platform,
      MusicPlatform.local,
    );
  });

  test('large libraries stop at the fixed scan budget', () async {
    messenger.setMockMethodCallHandler(LocalMusicLibrary.channel, (call) async {
      if (call.method == 'info') return {'sdk': 34};
      if (call.method != 'scan') return null;
      scans++;
      final after = (call.arguments as Map)['afterId'] as int;
      return {
        'songs': [
          for (var i = after + 1; i <= after + 200; i++) _song(i).toJson(),
        ],
        'afterId': after + 200,
        'hasMore': true,
      };
    });
    final library = LocalMusicLibrary();
    await library.scan();
    expect(library.songs, hasLength(LocalMusicLibrary.maxSongs));
    expect(library.reachedLimit, isTrue);
    expect(scans, 25);
    library.dispose();
  });

  for (final size in const [Size(640, 360), Size(1280, 800), Size(390, 844)]) {
    testWidgets(
      'local library exposes search playback favorites and queue at $size',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        final player = _LocalPlayer();
        final favorites = FavoriteService();
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await player.disposeResources();
          favorites.dispose();
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<PlayerProvider>.value(value: player),
              ChangeNotifierProvider<FavoriteService>.value(value: favorites),
            ],
            child: MaterialApp(
              theme: AppTheme.light(),
              home: const LocalMusicScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('本地歌曲1'), findsOneWidget);
        expect(find.byTooltip('收藏').hitTestable(), findsNWidgets(2));
        await tester.tap(find.byTooltip('收藏').first);
        await tester.pumpAndSettle();
        expect(favorites.favorites.single.platform, MusicPlatform.local);
        await tester.enterText(
          find.byKey(const ValueKey('local-music-search')),
          '歌曲2',
        );
        await tester.pumpAndSettle();
        expect(find.text('本地歌曲1'), findsNothing);
        await tester.tap(find.byKey(const ValueKey('local-music-play-all')));
        await tester.pumpAndSettle();
        expect(player.selected!.id, _song(2).id);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

SongSearchResult _song(int id) => SongSearchResult(
  platform: MusicPlatform.local,
  id: 'content://media/external/audio/media/$id',
  name: '本地歌曲$id',
  artist: '本地歌手',
  album: '本地专辑',
  duration: 180,
);

class _LocalPlayer extends PlayerProvider {
  SongSearchResult? selected;
  @override
  PlayQueueItem? get currentSong =>
      selected == null ? null : PlayQueueItem.fromSearchResult(selected!);
  @override
  Future<void> playFromSearchResults(
    List<SongSearchResult> results,
    int index,
  ) async {
    selected = results[index];
    notifyListeners();
  }
}
