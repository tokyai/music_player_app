import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/models/playback_source_config.dart';
import 'package:music_player_app/models/remote_playback.dart';
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/providers/player_provider.dart';
import 'package:music_player_app/services/api_service.dart';
import 'package:music_player_app/services/audio_cache_service.dart';
import 'package:music_player_app/services/user_data_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('new server source can be selected, backed up, and restored', () async {
    final api = _CatalogApi();
    final player = PlayerProvider(
      apiService: api,
      activateRestoredSession: false,
    );
    final restored = PlayerProvider(
      apiService: _CatalogApi(),
      activateRestoredSession: false,
    );
    try {
      await _ready(player);
      await _ready(restored);
      final source = player.playbackSourceOptions(MusicPlatform.qq).last;
      expect(source.value, 'new_provider');
      expect(source.label, '服务器新增音源');
      await player.setPlaybackSource(MusicPlatform.qq, source);
      final backup = player.toBackupJson();
      PlayerProvider.validateBackupJson(backup);
      await restored.restoreBackupJson(backup);
      expect(restored.playbackSourceFor(MusicPlatform.qq), source);
      expect(restored.playbackSourceFor(MusicPlatform.qq).label, '服务器新增音源');
      expect(
        (await SharedPreferences.getInstance()).getString('playback_source_qq'),
        'new_provider',
      );
    } finally {
      await player.disposeResources();
      await restored.disposeResources();
    }
  });

  test('unknown source preference survives offline catalog recovery', () async {
    SharedPreferences.setMockInitialValues({
      'playback_source_qq': 'new_provider',
      PlaybackSourceCatalog.preferenceKey: jsonEncode(_catalog().toJson()),
    });
    final api = _CatalogApi()..failure = StateError('Offline');
    final player = PlayerProvider(
      apiService: api,
      activateRestoredSession: false,
    );
    try {
      await _ready(player);
      expect(player.playbackSourceFor(MusicPlatform.qq).value, 'new_provider');
      expect(player.playbackSourceFor(MusicPlatform.qq).label, '服务器新增音源');
      expect(player.playbackSourcesError, isNotNull);
      expect(player.playbackSourceOptions(MusicPlatform.qq).length, 2);
      expect(player.playbackSourceOptions(MusicPlatform.local), isEmpty);
    } finally {
      await player.disposeResources();
    }
  });

  test(
    'removed server source falls back without erasing its saved ID',
    () async {
      SharedPreferences.setMockInitialValues({
        'playback_source_qq': 'removed_provider',
      });
      final player = PlayerProvider(
        apiService: _CatalogApi(),
        activateRestoredSession: false,
      );
      try {
        await _ready(player);
        expect(
          player.playbackSourceFor(MusicPlatform.qq),
          PlaybackSource.automatic,
        );
        expect(
          (player.toBackupJson()['playbackSources'] as Map)['qq'],
          'removed_provider',
        );
        await player.setPlaybackSource(
          MusicPlatform.qq,
          PlaybackSource.automatic,
        );
        expect(
          (await SharedPreferences.getInstance()).getString(
            'playback_source_qq',
          ),
          'automatic',
        );
      } finally {
        await player.disposeResources();
      }
    },
  );

  test(
    'parallel refreshes share one request and retain catalog on failure',
    () async {
      final api = _CatalogApi();
      final player = PlayerProvider(
        apiService: api,
        activateRestoredSession: false,
      );
      try {
        await _ready(player);
        api.pending = Completer<PlaybackSourceCatalog>();
        final first = player.refreshPlaybackSources();
        final second = player.refreshPlaybackSources();
        expect(second, same(first));
        await Future<void>.delayed(Duration.zero);
        expect(api.calls, 2);
        expect(player.playbackSourcesLoading, isTrue);
        api.pending!.completeError(StateError('Server unavailable'));
        await first;
        expect(
          player.remotePlaybackSources.single.source.value,
          'new_provider',
        );
        expect(player.playbackSourcesLoading, isFalse);
        expect(player.playbackSourcesError, isNotNull);
        api.pending = null;
        await player.refreshPlaybackSources();
        expect(player.playbackSourcesError, isNull);
      } finally {
        await player.disposeResources();
      }
    },
  );

  test('late catalog response does not notify a disposed player', () async {
    final api = _CatalogApi();
    final player = PlayerProvider(
      apiService: api,
      activateRestoredSession: false,
    );
    await _ready(player);
    api.pending = Completer<PlaybackSourceCatalog>();
    var changes = 0;
    player.addListener(() => changes++);
    final request = player.refreshPlaybackSources();
    await Future<void>.delayed(Duration.zero);
    final changesBeforeDispose = changes;
    await player.disposeResources();
    api.pending!.complete(_catalog());
    await request;
    expect(api.closed, isTrue);
    expect(changes, changesBeforeDispose);
  });

  test('failed source and credential saves preserve memory and disk', () async {
    final store = _SourceStore();
    SharedPreferencesStorePlatform.instance = store;
    final player = PlayerProvider(
      apiService: _CatalogApi(),
      activateRestoredSession: false,
    );
    try {
      await _ready(player);
      store.failKey = 'playback_source_qq';
      await expectLater(
        player.setPlaybackSource(
          MusicPlatform.qq,
          PlaybackSource.fromId('new_provider'),
        ),
        throwsStateError,
      );
      expect(
        player.playbackSourceFor(MusicPlatform.qq),
        PlaybackSource.automatic,
      );
      final before = player.playbackSourceConfig;
      store.failKey = PlaybackSourceConfig.preferenceKey;
      await expectLater(
        player.setRemotePlaybackSourceSettings(
          disabledSources: const ['new_provider'],
          credentials: const {
            'new_provider': {'cardKey': 'personal-key'},
          },
        ),
        throwsStateError,
      );
      expect(player.playbackSourceConfig, before);
      expect(player.savingPlaybackSourceSettings, isFalse);
    } finally {
      store.failKey = null;
      await player.disposeResources();
      SharedPreferences.setMockInitialValues({});
    }
  });

  test(
    'API key failure rolls back the previously written generic credentials',
    () async {
      final store = _SourceStore();
      SharedPreferencesStorePlatform.instance = store;
      await store.setValue('String', 'flutter.api_key', 'previous-key');
      final before = PlaybackSourceConfig.defaults().toJson();
      await store.setValue(
        'String',
        'flutter.${PlaybackSourceConfig.preferenceKey}',
        jsonEncode(before),
      );
      final player = PlayerProvider(
        apiService: _CatalogApi(),
        activateRestoredSession: false,
      );
      try {
        await _ready(player);
        store.failKey = 'api_key';
        await expectLater(
          player.setApiKey('replacement-key'),
          throwsStateError,
        );
        expect(player.apiKey, 'previous-key');
        final prefs = await SharedPreferences.getInstance();
        await prefs.reload();
        expect(prefs.getString('api_key'), 'previous-key');
        expect(
          jsonDecode(prefs.getString(PlaybackSourceConfig.preferenceKey)!),
          before,
        );
        store.failKey = null;
        await player.setApiKey('replacement-key');
        expect(player.apiKey, 'replacement-key');
        expect(
          player.playbackSourceConfig.remoteCredentials['chksz']?['apiKey'],
          'replacement-key',
        );
      } finally {
        store.failKey = null;
        await player.disposeResources();
        SharedPreferences.setMockInitialValues({});
      }
    },
  );

  test(
    'duplicate source saves are rejected and disposal waits for storage',
    () async {
      final store = _SourceStore();
      SharedPreferencesStorePlatform.instance = store;
      final player = PlayerProvider(
        apiService: _CatalogApi(),
        activateRestoredSession: false,
      );
      await _ready(player);
      store.gate = Completer<void>();
      final saving = player.setPlaybackSource(
        MusicPlatform.qq,
        PlaybackSource.fromId('new_provider'),
      );
      await store.entered.future;
      await expectLater(
        player.setPlaybackSource(MusicPlatform.qq, PlaybackSource.automatic),
        throwsStateError,
      );
      await expectLater(
        player.setRemotePlaybackSourceSettings(
          disabledSources: const ['new_provider'],
          credentials: const {},
        ),
        throwsStateError,
      );
      var disposed = false;
      final disposing = player.disposeResources().then((_) => disposed = true);
      await Future<void>.delayed(Duration.zero);
      expect(disposed, isFalse);
      store.gate!.complete();
      await saving;
      await disposing;
      expect(
        (await SharedPreferences.getInstance()).getString('playback_source_qq'),
        'new_provider',
      );
      SharedPreferences.setMockInitialValues({});
    },
  );

  test('remote credentials are validated, copied, and kept in backups', () {
    final fields = {'cardKey': 'personal-key'};
    final config = PlaybackSourceConfig.defaults()
        .copyWith(
          disabledRemoteSources: ['new_provider'],
          remoteCredentials: {'new_provider': fields},
        )
        .validated();
    fields['cardKey'] = 'mutated-input';
    expect(
      config.remoteCredentials['new_provider']?['cardKey'],
      'personal-key',
    );
    expect(config.isEnabled(PlaybackSource.fromId('new_provider')), isFalse);
    expect(
      () => config.remoteCredentials['new_provider']!['cardKey'] =
          'mutated-output',
      throwsUnsupportedError,
    );
    expect(PlaybackSourceConfig.fromJson(config.toJson()), config);
    expect(
      () => config
          .copyWith(
            remoteCredentials: const {
              'new_provider': {'cardKey': 'line\nbreak'},
            },
          )
          .validated(),
      throwsFormatException,
    );
    expect(
      () => config
          .copyWith(disabledRemoteSources: const ['../invalid'])
          .validated(),
      throwsFormatException,
    );
    expect(
      () => config
          .copyWith(
            remoteCredentials: {
              'new_provider': {'cardKey': 'a' * 1025},
            },
          )
          .validated(),
      throwsFormatException,
    );
  });

  test(
    'old flags and personal credentials migrate without overriding new values',
    () {
      final config = PlaybackSourceConfig.defaults()
          .copyWith(
            hywEnabled: false,
            hywCardKey: 'old-key',
            remoteCredentials: const {
              'hyw': {'hywCardKey': ''},
              'new_provider': {'cardKey': 'new-key'},
            },
          )
          .validated();
      expect(config.disabledSourceIds, contains('hyw'));
      final credentials = config.credentialsForServer(
        apiKey: 'personal-api-key',
      );
      expect(credentials['hyw']?['hywCardKey'], '');
      expect(credentials['chksz']?['apiKey'], 'personal-api-key');
      expect(credentials['new_provider']?['cardKey'], 'new-key');
      final tooMany = <String, Map<String, String>>{};
      for (var index = 0; index < 33; index++) {
        tooMany['source_$index'] = const {};
      }
      expect(
        () => config.copyWith(remoteCredentials: tooMany).validated(),
        throwsFormatException,
      );
    },
  );
  test('expired playback URL is resolved again before queue replay', () async {
    final probe = await _AudioProbe.create();
    final api = _PlaybackApi(probe.baseUrl)
      ..expiryLifetime = const Duration(milliseconds: 100);
    final player = PlayerProvider(
      apiService: api,
      dataScope: probe.scope,
      activateRestoredSession: false,
    );
    try {
      await _ready(player);
      await player.playSingle(_testSong());
      expect(player.errorMessage, isNull);
      expect(api.resolves, 1);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      api.expiryLifetime = const Duration(minutes: 10);
      await player.playQueueItem(0);
      expect(player.errorMessage, isNull);
      expect(api.resolves, 2);
      expect(probe.loaded, hasLength(2));
      expect(probe.loaded.last, endsWith('/audio-2.mp3'));
    } finally {
      await player.disposeResources();
      await probe.close();
    }
  });

  test(
    'reused URL failure excludes the dynamic source on re-resolution',
    () async {
      final probe = await _AudioProbe.create();
      final api = _PlaybackApi(probe.baseUrl);
      final player = PlayerProvider(
        apiService: api,
        dataScope: probe.scope,
        activateRestoredSession: false,
      );
      try {
        await _ready(player);
        await player.playSingle(_testSong());
        await player.playQueueItem(0);
        expect(api.resolves, 1);
        expect(player.currentPlaybackSource?.value, 'new_provider');
        probe.failNextLoad = true;
        await player.playQueueItem(0);
        expect(player.errorMessage, isNull);
        expect(api.resolves, 2);
        expect(
          api.exclusions.last,
          contains(PlaybackSource.fromId('new_provider')),
        );
        expect(player.currentPlaybackSource?.value, 'alternate_provider');
      } finally {
        await player.disposeResources();
        await probe.close();
      }
    },
  );
}

Future<void> _ready(PlayerProvider player) => Future.wait([
  player.settingsReady,
  player.historyReady,
  player.playbackStateReady,
  player.playbackSourcesReady,
]);

PlaybackSourceCatalog _catalog() => PlaybackSourceCatalog.fromJson({
  'protocolVersion': 1,
  'revision': 'test-v1',
  'sources': [
    {
      'id': 'new_provider',
      'name': '服务器新增音源',
      'description': '只在服务器新增的解析服务',
      'platforms': ['qq', '163'],
      'credentials': [
        {
          'key': 'cardKey',
          'label': '个人卡密',
          'requiredPlatforms': ['qq'],
        },
      ],
    },
  ],
});

class _CatalogApi extends ApiService {
  _CatalogApi() : super(apiKey: '', useRemotePlayback: false);
  int calls = 0;
  bool closed = false;
  Object? failure;
  Completer<PlaybackSourceCatalog>? pending;

  @override
  Future<PlaybackSourceCatalog> loadPlaybackSources() async {
    calls++;
    final error = failure;
    if (error != null) throw error;
    return pending?.future ?? _catalog();
  }

  @override
  void close() {
    closed = true;
    super.close();
  }
}

class _SourceStore extends InMemorySharedPreferencesStore {
  _SourceStore() : super.empty();
  String? failKey;
  Completer<void>? gate;
  final entered = Completer<void>();

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    final pending = gate;
    if (pending != null) {
      if (!entered.isCompleted) entered.complete();
      await pending.future;
    }
    if (key == failKey || key == 'flutter.$failKey') return false;
    return super.setValue(valueType, key, value);
  }
}

SongSearchResult _testSong() => SongSearchResult(
  platform: MusicPlatform.qq,
  id: 'remote-expiry-song',
  name: '测试歌曲',
  artist: '测试歌手',
  album: '测试专辑',
);

class _PlaybackApi extends _CatalogApi {
  final String baseUrl;
  int resolves = 0;
  Duration expiryLifetime = const Duration(minutes: 10);
  final List<Set<PlaybackSource>> exclusions = [];

  _PlaybackApi(this.baseUrl);

  @override
  Future<SongDetail> resolvePlayback({
    required PlaybackSource source,
    required MusicPlatform platform,
    required String id,
    required String quality,
    String name = '',
    String artist = '',
    String album = '',
    String? albumId,
    int? duration,
    bool Function()? isCancelled,
    Set<PlaybackSource> excludedSources = const {},
  }) async {
    resolves++;
    exclusions.add(Set<PlaybackSource>.from(excludedSources));
    var providerId = 'new_provider';
    if (excludedSources.contains(PlaybackSource.fromId(providerId))) {
      providerId = 'alternate_provider';
    }
    return SongDetail(
      name: name,
      artist: artist,
      album: album,
      url: '$baseUrl/audio-$resolves.mp3',
      format: 'mp3',
      playbackSource: PlaybackSource.fromId(providerId),
      playbackExpiresAt: DateTime.now().add(expiryLifetime),
    );
  }

  @override
  Future<LyricData?> getLyric(MusicPlatform platform, String id) async =>
      LyricData(original: '[00:00.00]测试歌词');
}

class _AudioProbe {
  final Directory directory;
  final HttpServer server;
  final UserDataScope scope;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final List<MethodChannel> channels = [];
  final List<String> loaded = [];
  String? playerId;
  bool failNextLoad = false;
  StreamSubscription<HttpRequest>? requests;

  _AudioProbe(this.directory, this.server)
    : scope = UserDataScope(
        'remote-expiry-${DateTime.now().microsecondsSinceEpoch}',
      );

  String get baseUrl => 'http://127.0.0.1:${server.port}';

  static Future<_AudioProbe> create() async {
    final directory = await Directory.systemTemp.createTemp(
      'remote_expiry_test_',
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final probe = _AudioProbe(directory, server);
    probe.requests = server.listen(probe._rejectDiskCaching);
    probe._install(
      const MethodChannel('plugins.flutter.io/path_provider'),
      probe._directoryCall,
    );
    probe._install(
      const MethodChannel('com.ryanheise.audio_session'),
      probe._emptyCall,
    );
    probe._install(
      const MethodChannel('com.ryanheise.just_audio.methods'),
      probe._rootCall,
    );
    return probe;
  }

  void _rejectDiskCaching(HttpRequest request) {
    request.response.statusCode = HttpStatus.notFound;
    unawaited(request.response.close());
  }

  void _install(
    MethodChannel channel,
    Future<Object?> Function(MethodCall) handler,
  ) {
    channels.add(channel);
    messenger.setMockMethodCallHandler(channel, handler);
  }

  Future<Object?> _directoryCall(MethodCall call) async => directory.path;
  Future<Object?> _emptyCall(MethodCall call) async => null;

  Future<Object?> _rootCall(MethodCall call) async {
    if (call.method == 'init') {
      final id = (call.arguments as Map)['id'] as String;
      playerId = id;
      _install(
        MethodChannel('com.ryanheise.just_audio.events.$id'),
        _emptyCall,
      );
      _install(MethodChannel('com.ryanheise.just_audio.data.$id'), _emptyCall);
      _install(
        MethodChannel('com.ryanheise.just_audio.methods.$id'),
        _playerCall,
      );
    }
    return <String, dynamic>{};
  }

  Future<Object?> _playerCall(MethodCall call) async {
    if (call.method == 'load') {
      final url =
          ((call.arguments as Map)['audioSource'] as Map)['uri'] as String;
      loaded.add(url);
      if (failNextLoad) {
        failNextLoad = false;
        throw PlatformException(code: '404', message: 'audio unavailable');
      }
      await messenger.handlePlatformMessage(
        'com.ryanheise.just_audio.events.$playerId',
        const StandardMethodCodec().encodeSuccessEnvelope({
          'processingState': 3,
          'updateTime': DateTime.now().millisecondsSinceEpoch,
          'updatePosition': 0,
          'bufferedPosition': 0,
          'duration': 180000000,
          'currentIndex': 0,
        }),
        (_) {},
      );
      return {'duration': 180000000};
    }
    return <String, dynamic>{};
  }

  Future<void> close() async {
    await server.close(force: true);
    await requests?.cancel();
    for (final channel in channels) {
      messenger.setMockMethodCallHandler(channel, null);
    }
    await AudioCacheService.releaseMemoryContext(scope);
    await directory.delete(recursive: true);
  }
}
