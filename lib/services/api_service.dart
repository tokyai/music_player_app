import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/playback_source_config.dart';
import '../models/song.dart';
import 'bilibili_service.dart';
import 'bounded_http_response.dart';

/// 音乐 API 服务层
/// - 网易云: interface.music.163.com 官方公开目录接口
/// - 酷狗: mobilecdn.kugou.com 官方公开目录接口
/// - QQ音乐: u.y.qq.com musicu 官方公开目录接口
/// - 三平台播放地址解析: 支持手动指定音源，或按有界顺序自动回退
///
/// 搜索、歌单、歌词、MV 等功能优先直连平台接口，旧 nginx 反代仅在直连
/// 失败时兜底。播放地址解析在选择“自动备用”时按固定分组并行竞速、分组
/// 回退和有界降音质；手动选择时只请求指定源。
class ApiService {
  // 播放解析等请求保留一次重试；目录直连使用更短的单次超时后快速降级。
  static const _requestTimeout = Duration(seconds: 10);
  static const _resolverTimeout = Duration(seconds: 7);
  static const _xinghaiIpTimeout = Duration(seconds: 3);
  static const _xinghaiTokenLifetime = Duration(minutes: 5);
  static const _catalogTimeout = Duration(seconds: 5);
  static const _catalogFallbackTimeout = Duration(seconds: 8);
  static const _probeTimeout = Duration(seconds: 4);
  static const _automaticPlaybackTimeout = Duration(seconds: 20);
  static const _retryDelay = Duration(milliseconds: 350);
  static const _maxJsonResponseBytes = 5 * 1024 * 1024;
  static const _maxProbeResponseBytes = 64 * 1024;
  static const _maxQualityDowngrades = 3;
  static const _racePollInterval = Duration(milliseconds: 60);
  // A playlist index may contain up to 100,000 IDs. Retain only the active
  // index so visiting several large playlists cannot keep their ID arrays
  // alive for the lifetime of the player.
  static const _maxNeteasePlaylistIndexes = 1;
  static const _catalogUserAgent =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
      'Chrome/120 Mobile Safari/537.36';

  // 官方公开目录入口。
  static const String _neteaseCatalogUrl = 'https://interface.music.163.com';
  static const String _neteaseLyricUrl = 'https://interface3.music.163.com';
  static const String _qqCatalogUrl = 'https://u.y.qq.com/cgi-bin/musicu.fcg';
  static const String _qqWebUrl = 'https://c.y.qq.com';
  static const String _kugouCatalogUrl = 'http://mobilecdn.kugou.com';
  static const Map<String, String> _qqHeaders = {
    'Referer': 'https://y.qq.com/',
    'Origin': 'https://y.qq.com',
  };

  // 高优先级源共同参与竞速；GDStudio 是低优先级的独立兜底组。保持分组
  // 固定且规模有界，避免一次播放把所有后端同时打满。
  static const List<List<PlaybackSource>> _playbackSourceGroups = [
    [
      PlaybackSource.chksz,
      PlaybackSource.qingMusic,
      PlaybackSource.hyw,
      PlaybackSource.xinghai,
    ],
    [PlaybackSource.gdStudio],
  ];

  static const List<String> _neteaseQualityOrder = [
    'jymaster',
    'sky',
    'jyeffect',
    'hires',
    'lossless',
    'exhigh',
    'standard',
  ];
  static const List<String> _commonQualityOrder = [
    'master',
    'hires',
    'flac',
    '320k',
    '128k',
  ];

  // 旧 API 中转仅作网络兼容兜底。
  static const String neteaseBaseUrl = 'http://161.118.252.183/api-netease';
  static const String kugouSearchBase =
      'http://161.118.252.183/api-kugou-search';
  static const String qqBaseUrl = 'http://161.118.252.183/api-qq';

  final http.Client _client = http.Client();
  final Map<String, Future<_NeteasePlaylistIndex>> _neteasePlaylistIndexes = {};
  final BilibiliService bilibili;
  String apiKey;
  PlaybackSourceConfig _playbackSourceConfig;
  String? _xinghaiIp;
  Future<String?>? _xinghaiIpRequest;
  String? _xinghaiToken;
  DateTime? _xinghaiTokenCreatedAt;
  String? _xinghaiTokenDeviceId;
  String? _xinghaiTokenIp;
  bool _closed = false;
  int _playbackGeneration = 0;
  _PlaybackCancellation? _activePlaybackCancellation;

  ApiService({
    required this.apiKey,
    BilibiliService? bilibili,
    PlaybackSourceConfig? playbackSourceConfig,
  }) : bilibili = bilibili ?? BilibiliService(),
       _playbackSourceConfig =
           (playbackSourceConfig ?? PlaybackSourceConfig.defaults())
               .validated();

  void setApiKey(String key) {
    if (apiKey == key) return;
    apiKey = key;
    _playbackGeneration++;
    _activePlaybackCancellation?.cancel();
  }

  void setPlaybackSourceConfig(PlaybackSourceConfig config) {
    final validated = config.validated();
    _playbackGeneration++;
    _activePlaybackCancellation?.cancel();
    _playbackSourceConfig = validated;
    _xinghaiIp = null;
    _xinghaiIpRequest = null;
    _xinghaiToken = null;
    _xinghaiTokenCreatedAt = null;
    _xinghaiTokenDeviceId = null;
    _xinghaiTokenIp = null;
  }

  void close() {
    if (_closed) return;
    // Playlist indexes can contain tens of thousands of IDs. Release them
    // together with the HTTP client when the owning player is disposed.
    _neteasePlaylistIndexes.clear();
    _closed = true;
    _playbackGeneration++;
    _activePlaybackCancellation?.cancel();
    _activePlaybackCancellation = null;
    _xinghaiIpRequest = null;
    _xinghaiToken = null;
    _client.close();
    bilibili.dispose();
  }

  void _ensureOpen() {
    if (_closed) {
      throw const ApiException('RESOLVE_CANCELLED', '播放请求已取消');
    }
  }

  Future<http.Response> _get(
    Uri uri, {
    Duration timeout = _requestTimeout,
    int maxAttempts = 2,
    Map<String, String> headers = const {},
    int maxBytes = _maxJsonResponseBytes,
    Future<void>? cancelSignal,
  }) async {
    _ensureOpen();
    Exception? lastError;
    final attempts = maxAttempts < 1 ? 1 : maxAttempts;
    for (var attempt = 0; attempt < attempts; attempt++) {
      _ensureOpen();
      try {
        final request = http.Request('GET', uri)
          ..headers.addAll({
            'Accept': 'application/json',
            'User-Agent': _catalogUserAgent,
            ...headers,
          });
        final response = await sendBoundedHttpRequest(
          _client,
          request,
          maxBytes: maxBytes,
          timeout: timeout,
          cancelSignal: cancelSignal,
        );
        if (attempt < attempts - 1 && response.statusCode >= 500) {
          await Future<void>.delayed(_retryDelay);
          _ensureOpen();
          continue;
        }
        return response;
      } on HttpRequestCancelledException {
        throw const ApiException('RESOLVE_CANCELLED', '播放请求已取消');
      } on HttpResponseTooLargeException {
        throw const ApiException('RESPONSE_TOO_LARGE', '服务返回的数据过大');
      } on Exception catch (error) {
        if (_closed) {
          throw const ApiException('RESOLVE_CANCELLED', '播放请求已取消');
        }
        lastError = error;
        if (attempt < attempts - 1) {
          await Future<void>.delayed(_retryDelay);
          _ensureOpen();
          continue;
        }
      }
    }
    throw lastError ?? StateError('请求失败');
  }

  Future<http.Response> _postJson(
    Uri uri,
    Map<String, dynamic> body, {
    Map<String, String> headers = const {},
    Duration timeout = _requestTimeout,
    int maxAttempts = 2,
    int maxBytes = _maxJsonResponseBytes,
    Future<void>? cancelSignal,
  }) async {
    _ensureOpen();
    Exception? lastError;
    final attempts = maxAttempts < 1 ? 1 : maxAttempts;
    for (var attempt = 0; attempt < attempts; attempt++) {
      _ensureOpen();
      try {
        final request = http.Request('POST', uri)
          ..headers.addAll({
            'Accept': 'application/json',
            'Content-Type': 'application/json',
            'User-Agent': _catalogUserAgent,
            ...headers,
          })
          ..body = jsonEncode(body);
        final response = await sendBoundedHttpRequest(
          _client,
          request,
          maxBytes: maxBytes,
          timeout: timeout,
          cancelSignal: cancelSignal,
        );
        if (attempt < attempts - 1 && response.statusCode >= 500) {
          await Future<void>.delayed(_retryDelay);
          _ensureOpen();
          continue;
        }
        return response;
      } on HttpRequestCancelledException {
        throw const ApiException('RESOLVE_CANCELLED', '播放请求已取消');
      } on HttpResponseTooLargeException {
        throw const ApiException('RESPONSE_TOO_LARGE', '服务返回的数据过大');
      } on Exception catch (error) {
        if (_closed) {
          throw const ApiException('RESOLVE_CANCELLED', '播放请求已取消');
        }
        lastError = error;
        if (attempt < attempts - 1) {
          await Future<void>.delayed(_retryDelay);
          _ensureOpen();
          continue;
        }
      }
    }
    throw lastError ?? StateError('请求失败');
  }

  // ---- ChKSz 请求 ----
  Map<String, String> _chkszQuery(Map<String, dynamic> params) {
    return {
      ...params.map((k, v) => MapEntry(k, v.toString())),
      'apikey': apiKey,
    };
  }

  Future<Map<String, dynamic>> _chkszGet(
    String path,
    Map<String, dynamic> params, {
    Future<void>? cancelSignal,
  }) async {
    final uri = Uri.parse(
      _joinUrl(_playbackSourceConfig.chkszBaseUrl, path),
    ).replace(queryParameters: _chkszQuery(params));
    final http.Response res;
    try {
      res = await _get(
        uri,
        timeout: _resolverTimeout,
        maxAttempts: 1,
        cancelSignal: cancelSignal,
      );
    } on ApiException {
      rethrow;
    } catch (_) {
      throw const ApiException('CHKSZ_NETWORK', 'ChKSz 网络请求失败');
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ApiException('HTTP_${res.statusCode}', '服务暂时不可用');
    }
    final dynamic body;
    try {
      body = json.decode(utf8.decode(res.bodyBytes));
    } on FormatException {
      throw const ApiException('INVALID_RESPONSE', '服务返回了无效数据');
    }
    if (body is Map<String, dynamic>) {
      if (body['code'] != null && body['code'].toString() != '200') {
        throw ApiException(
          body['code'].toString(),
          body['msg']?.toString() ?? '请求失败',
        );
      }
      return body;
    }
    return {'data': body};
  }

  /// QingMusic 脚本中的备用解析协议。脚本本身只用于说明适配规则，App
  /// 直接调用其 resolve-url 服务，不在客户端执行远程 JavaScript。
  Future<SongDetail> qingMusic(
    MusicPlatform platform,
    String id, {
    required String quality,
    Future<void>? cancelSignal,
  }) async {
    final http.Response response;
    try {
      response = await _postJson(
        Uri.parse(_playbackSourceConfig.qingMusicUrl),
        {
          'source': switch (platform) {
            MusicPlatform.qq => 'tx',
            MusicPlatform.netease => 'wy',
            MusicPlatform.kugou => 'kg',
            MusicPlatform.bilibili => throw UnsupportedError('B站使用官方播放接口'),
          },
          'rid': id,
          'level': _qingMusicLevel(platform, quality),
        },
        timeout: _resolverTimeout,
        maxAttempts: 1,
        cancelSignal: cancelSignal,
      );
    } on ApiException {
      rethrow;
    } catch (_) {
      throw const ApiException('QING_NETWORK', 'QingMusic 网络请求失败');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(
        'QING_HTTP_${response.statusCode}',
        'QingMusic 服务暂时不可用',
      );
    }
    final dynamic body;
    try {
      body = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw const ApiException('QING_INVALID_RESPONSE', 'QingMusic 返回了无效数据');
    }
    if (body is! Map) {
      throw const ApiException('QING_INVALID_RESPONSE', 'QingMusic 返回格式错误');
    }
    final result = Map<String, dynamic>.from(body);
    if (result['code']?.toString() != '0') {
      throw ApiException(
        'QING_${result['code'] ?? 'FAILED'}',
        result['message']?.toString() ?? 'QingMusic 解析失败',
      );
    }
    final rawData = result['data'];
    final data = rawData is Map
        ? Map<String, dynamic>.from(rawData)
        : <String, dynamic>{};
    final url = data['url']?.toString() ?? '';
    if (url.isEmpty) {
      throw const ApiException('QING_EMPTY_URL', 'QingMusic 未返回播放地址');
    }
    final rawHeaders = data['playbackHeaders'] ?? data['headers'];
    final headers = rawHeaders is Map
        ? rawHeaders.map(
            (key, value) => MapEntry(key.toString(), value.toString()),
          )
        : null;
    final path = Uri.tryParse(url)?.path ?? '';
    final dot = path.lastIndexOf('.');
    return SongDetail(
      name: '',
      artist: '',
      album: '',
      url: url,
      format: dot >= 0 && dot < path.length - 1
          ? path.substring(dot + 1)
          : null,
      playbackHeaders: headers?.isEmpty == true ? null : headers,
    );
  }

  static String _qingMusicLevel(MusicPlatform platform, String quality) {
    switch (platform) {
      case MusicPlatform.netease:
        return switch (quality) {
          'standard' => 'standard',
          'exhigh' => 'exhigh',
          'lossless' || 'hires' => 'lossless',
          _ => 'jymaster',
        };
      case MusicPlatform.qq:
        return switch (quality) {
          '128k' => 'standard',
          '320k' => 'exhigh',
          _ => 'lossless',
        };
      case MusicPlatform.kugou:
        return switch (quality) {
          '128k' => 'standard',
          '320k' => 'exhigh',
          'master' => 'clear',
          _ => 'lossless',
        };
      case MusicPlatform.bilibili:
        throw UnsupportedError('B站不使用第三方音质参数');
    }
  }

  /// 按设置解析播放地址。
  ///
  /// 自动模式按质量从高到低逐档处理：每一档先让高优先级源并行竞速，
  /// 全部失败后才进入低优先级 GDStudio 组，再失败才降一档。每个竞速组、
  /// 质量降级次数和请求响应体都有固定上限，旧播放请求失效后会取消其
  /// 余请求并阻止迟到结果继续推进回退链。
  Future<SongDetail> resolvePlayback({
    required PlaybackSource source,
    required MusicPlatform platform,
    required String id,
    required String quality,
    required String name,
    required String artist,
    required String album,
    String? albumId,
    int? duration,
    bool Function()? isCancelled,
  }) async {
    _ensureOpen();
    if (platform == MusicPlatform.bilibili) {
      throw const ApiException('SOURCE_UNSUPPORTED', 'B站使用官方播放接口');
    }
    if (_isExternalPlaybackCancellation(isCancelled)) {
      throw const ApiException('RESOLVE_CANCELLED', '播放请求已取消');
    }
    final operation = _beginPlaybackOperation();
    Timer? overallTimeout;
    try {
      if (source != PlaybackSource.automatic) {
        if (!_playbackSourceConfig.isEnabled(source)) {
          throw ApiException('SOURCE_DISABLED', '${source.label} 已在备用源配置中停用');
        }
        final detail = await _resolveWithSource(
          source,
          platform: platform,
          id: id,
          quality: quality,
          name: name,
          artist: artist,
          album: album,
          albumId: albumId,
          duration: duration,
          cancelSignal: operation.future,
        );
        _ensurePlaybackOperationActive(operation, isCancelled);
        _requirePlayableUrl(detail, source);
        return detail;
      }

      final candidates = _enabledPlaybackSources();
      if (candidates.isEmpty) {
        throw const ApiException('NO_PLAYBACK_SOURCE', '没有可用的备用源，请检查备用源配置');
      }

      final failures = <String>[];
      final qualityCandidates = _qualityCandidates(platform, quality);
      overallTimeout = Timer(
        _automaticPlaybackTimeout,
        () => operation.cancel(reason: 'timeout'),
      );
      for (final candidateQuality in qualityCandidates) {
        _ensurePlaybackOperationActive(operation, isCancelled);
        for (
          var groupIndex = 0;
          groupIndex < _playbackSourceGroups.length;
          groupIndex++
        ) {
          final group = _playbackSourceGroups[groupIndex]
              .where(candidates.contains)
              .toList(growable: false);
          if (group.isEmpty) continue;
          try {
            final detail = await _racePlaybackGroup(
              group,
              operation: operation,
              generation: _playbackGeneration,
              isCancelled: isCancelled,
              platform: platform,
              id: id,
              quality: candidateQuality,
              name: name,
              artist: artist,
              album: album,
              albumId: albumId,
              duration: duration,
            );
            _ensurePlaybackOperationActive(operation, isCancelled);
            return detail;
          } on _PlaybackGroupFailure catch (error) {
            if (failures.length < 12) {
              final groupLabel = groupIndex == 0 ? '主竞速组' : '低优先级兜底组';
              failures.add(
                '$candidateQuality/$groupLabel：${error.failures.join('；')}',
              );
            }
          }
        }
      }
      _ensurePlaybackOperationActive(operation, isCancelled);
      throw ApiException(
        'ALL_PLAYBACK_SOURCES_FAILED',
        '所有已启用备用源均解析失败（${failures.join('；')}）',
      );
    } finally {
      overallTimeout?.cancel();
      _endPlaybackOperation(operation);
    }
  }

  List<PlaybackSource> _enabledPlaybackSources() {
    return [
      for (final source in PlaybackSource.values)
        if (source != PlaybackSource.automatic &&
            _playbackSourceConfig.isEnabled(source) &&
            (source != PlaybackSource.chksz || apiKey.trim().isNotEmpty))
          source,
    ];
  }

  List<String> _qualityCandidates(
    MusicPlatform platform,
    String requestedQuality,
  ) {
    final requested = requestedQuality.trim();
    final order = platform == MusicPlatform.netease
        ? _neteaseQualityOrder
        : _commonQualityOrder;
    final index = order.indexOf(requested);
    if (index < 0) return [requestedQuality];
    final end = min(order.length, index + _maxQualityDowngrades + 1);
    return order.sublist(index, end).toList(growable: false);
  }

  _PlaybackCancellation _beginPlaybackOperation() {
    _activePlaybackCancellation?.cancel();
    _playbackGeneration++;
    final operation = _PlaybackCancellation();
    _activePlaybackCancellation = operation;
    return operation;
  }

  void _endPlaybackOperation(_PlaybackCancellation operation) {
    if (identical(_activePlaybackCancellation, operation)) {
      _activePlaybackCancellation = null;
    }
    operation.cancel();
  }

  bool _isExternalPlaybackCancellation(bool Function()? isCancelled) {
    if (_closed) return true;
    try {
      return isCancelled?.call() == true;
    } catch (_) {
      // A callback owned by a disposed page is no longer trustworthy.
      return true;
    }
  }

  bool _isPlaybackOperationActive(
    _PlaybackCancellation operation,
    int generation,
    bool Function()? isCancelled,
  ) {
    return !_closed &&
        !operation.isCancelled &&
        generation == _playbackGeneration &&
        !_isExternalPlaybackCancellation(isCancelled);
  }

  void _ensurePlaybackOperationActive(
    _PlaybackCancellation operation,
    bool Function()? isCancelled,
  ) {
    if (!_isPlaybackOperationActive(
      operation,
      _playbackGeneration,
      isCancelled,
    )) {
      throw _playbackCancellationException(operation);
    }
  }

  ApiException _playbackCancellationException(
    _PlaybackCancellation operation,
  ) => operation.reason == 'timeout'
      ? const ApiException('PLAYBACK_TIMEOUT', '播放解析超时，请稍后重试')
      : const ApiException('RESOLVE_CANCELLED', '播放请求已取消');

  Future<SongDetail> _racePlaybackGroup(
    List<PlaybackSource> sources, {
    required _PlaybackCancellation operation,
    required int generation,
    required bool Function()? isCancelled,
    required MusicPlatform platform,
    required String id,
    required String quality,
    required String name,
    required String artist,
    required String album,
    String? albumId,
    int? duration,
  }) async {
    final groupCancellation = _PlaybackCancellation();
    final cancelSignal = Future.any<void>([
      operation.future,
      groupCancellation.future,
    ]);
    final completer = Completer<SongDetail>();
    final failures = <String>[];
    var remaining = sources.length;
    var finished = false;
    Timer? cancellationTimer;

    void cancelRace() {
      if (finished) return;
      finished = true;
      groupCancellation.cancel();
      operation.cancel();
      if (!completer.isCompleted) {
        completer.completeError(_playbackCancellationException(operation));
      }
    }

    void recordFailure(PlaybackSource source, Object error) {
      if (finished) return;
      if (failures.length < sources.length) {
        failures.add('${source.label}：${_safeResolverFailure(error)}');
      }
      remaining--;
      if (remaining == 0) {
        finished = true;
        groupCancellation.cancel();
        if (!completer.isCompleted) {
          completer.completeError(_PlaybackGroupFailure(failures));
        }
      }
    }

    Future<void> run(PlaybackSource source) async {
      if (finished) return;
      if (!_isPlaybackOperationActive(operation, generation, isCancelled)) {
        cancelRace();
        return;
      }
      try {
        final detail = await _resolveWithSource(
          source,
          platform: platform,
          id: id,
          quality: quality,
          name: name,
          artist: artist,
          album: album,
          albumId: albumId,
          duration: duration,
          cancelSignal: cancelSignal,
        );
        if (finished) return;
        if (!_isPlaybackOperationActive(operation, generation, isCancelled)) {
          cancelRace();
          return;
        }
        try {
          _requirePlayableUrl(detail, source);
        } catch (error) {
          recordFailure(source, error);
          return;
        }
        finished = true;
        groupCancellation.cancel();
        if (!completer.isCompleted) completer.complete(detail);
      } catch (error) {
        if (finished) return;
        if (!_isPlaybackOperationActive(operation, generation, isCancelled) ||
            _isPlaybackCancellationError(error)) {
          cancelRace();
          return;
        }
        recordFailure(source, error);
      }
    }

    cancellationTimer = Timer.periodic(_racePollInterval, (_) {
      if (!finished &&
          !_isPlaybackOperationActive(operation, generation, isCancelled)) {
        cancelRace();
      }
    });
    for (final source in sources) {
      // Every source in a group starts immediately; each Future is fully
      // observed so a losing request cannot surface an unhandled exception.
      unawaited(run(source));
    }
    try {
      return await completer.future;
    } finally {
      cancellationTimer.cancel();
      groupCancellation.cancel();
    }
  }

  static bool _isPlaybackCancellationError(Object error) {
    return error is HttpRequestCancelledException ||
        error is ApiException && error.code == 'RESOLVE_CANCELLED';
  }

  static void _requirePlayableUrl(SongDetail detail, PlaybackSource source) {
    final url = detail.url.trim();
    final uri = Uri.tryParse(url);
    if (url.isEmpty ||
        uri == null ||
        uri.host.isEmpty ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw ApiException(
        '${source.value.toUpperCase()}_EMPTY_URL',
        '${source.label} 未返回播放地址',
      );
    }
  }

  Future<SongDetail> _resolveWithSource(
    PlaybackSource source, {
    required MusicPlatform platform,
    required String id,
    required String quality,
    required String name,
    required String artist,
    required String album,
    String? albumId,
    int? duration,
    Future<void>? cancelSignal,
  }) {
    switch (source) {
      case PlaybackSource.automatic:
        throw StateError('自动备用源不能递归解析');
      case PlaybackSource.chksz:
        if (apiKey.trim().isEmpty) {
          throw const ApiException('API_KEY_REQUIRED', 'ChKSz 需要配置 API Key');
        }
        return switch (platform) {
          MusicPlatform.netease => neteaseMusic(
            id,
            level: quality,
            cancelSignal: cancelSignal,
          ),
          MusicPlatform.qq => qqMusic(
            id,
            size: quality,
            cancelSignal: cancelSignal,
          ),
          MusicPlatform.kugou => kugouMusic(
            id,
            size: quality,
            cancelSignal: cancelSignal,
          ),
          MusicPlatform.bilibili => throw const ApiException(
            'SOURCE_UNSUPPORTED',
            'B站使用官方播放接口',
          ),
        };
      case PlaybackSource.qingMusic:
        return qingMusic(
          platform,
          id,
          quality: quality,
          cancelSignal: cancelSignal,
        );
      case PlaybackSource.hyw:
        return hywMusic(
          platform,
          id,
          quality: quality,
          name: name,
          artist: artist,
          album: album,
          albumId: albumId,
          duration: duration,
          cancelSignal: cancelSignal,
        );
      case PlaybackSource.xinghai:
        return xinghaiMusic(
          platform,
          id,
          quality: quality,
          name: name,
          artist: artist,
          album: album,
          albumId: albumId,
          duration: duration,
          cancelSignal: cancelSignal,
        );
      case PlaybackSource.gdStudio:
        return gdStudioMusic(
          platform,
          id,
          quality: quality,
          cancelSignal: cancelSignal,
        );
    }
  }

  Future<SongDetail> hywMusic(
    MusicPlatform platform,
    String id, {
    required String quality,
    required String name,
    required String artist,
    required String album,
    String? albumId,
    int? duration,
    Future<void>? cancelSignal,
  }) async {
    final source = _aggregatorSource(platform);
    final params = <String, String>{
      'source': source,
      'platform': source,
      'songId': id,
      'songmid': id,
      if (platform == MusicPlatform.kugou) ...{'hash': id, 'mainHash': id},
      'quality': _aggregatorQuality(platform, quality),
      if (name.trim().isNotEmpty) ...{
        'name': name.trim(),
        'songName': name.trim(),
        'songname': name.trim(),
      },
      if (artist.trim().isNotEmpty) ...{
        'singer': artist.trim(),
        'artist': artist.trim(),
      },
      if (album.trim().isNotEmpty) ...{
        'album': album.trim(),
        'albumName': album.trim(),
      },
      if (albumId?.trim().isNotEmpty == true) ...{
        'albumId': albumId!.trim(),
        'albumMid': albumId.trim(),
      },
      if (duration != null && duration > 0) 'interval': duration.toString(),
      if (_playbackSourceConfig.hywCardKey.isNotEmpty)
        'key': _playbackSourceConfig.hywCardKey,
    };
    final uri = Uri.parse(
      _joinUrl(_playbackSourceConfig.hywBaseUrl, '/api/music/url'),
    ).replace(queryParameters: params);
    final headers = <String, String>{
      if (_playbackSourceConfig.hywCardKey.isNotEmpty)
        'X-Card-Key': _playbackSourceConfig.hywCardKey,
    };
    final http.Response response;
    try {
      response = await _get(
        uri,
        headers: headers,
        timeout: _resolverTimeout,
        maxAttempts: 1,
        cancelSignal: cancelSignal,
      );
    } on ApiException {
      rethrow;
    } catch (_) {
      throw const ApiException('HYW_NETWORK', 'HYW 网络请求失败');
    }
    final body = _resolverResponseMap(response, 'HYW');
    if (body['code']?.toString() != '200') {
      throw ApiException(
        'HYW_${body['code'] ?? 'FAILED'}',
        'HYW 服务拒绝请求或未返回播放地址',
      );
    }
    return _resolvedSongDetail(body, 'HYW');
  }

  Future<SongDetail> xinghaiMusic(
    MusicPlatform platform,
    String id, {
    required String quality,
    required String name,
    required String artist,
    required String album,
    String? albumId,
    int? duration,
    Future<void>? cancelSignal,
  }) async {
    final source = switch (platform) {
      MusicPlatform.qq => 'qq',
      MusicPlatform.netease => 'wy',
      MusicPlatform.kugou => 'kg',
      MusicPlatform.bilibili => throw const ApiException(
        'SOURCE_UNSUPPORTED',
        'B站使用官方播放接口',
      ),
    };
    final mappedQuality = _aggregatorQuality(platform, quality);
    final params = <String, String>{
      'source': source,
      'quality': mappedQuality,
      'songmid': id,
      if (platform == MusicPlatform.kugou) ...{
        'mainHash': id,
        'hash': id,
        if (albumId?.trim().isNotEmpty == true) 'albumId': albumId!.trim(),
      } else ...{
        if (name.trim().isNotEmpty) 'name': name.trim(),
        if (artist.trim().isNotEmpty) 'singer': artist.trim(),
        if (album.trim().isNotEmpty) 'albumName': album.trim(),
        if (albumId?.trim().isNotEmpty == true) 'albumMid': albumId!.trim(),
        if (duration != null && duration > 0) 'interval': duration.toString(),
      },
    };
    final base = Uri.parse(_playbackSourceConfig.xinghaiUrl);
    final uri = base.replace(
      queryParameters: {...base.queryParameters, ...params},
    );
    final http.Response response;
    try {
      response = await _get(
        uri,
        headers: await _xinghaiHeaders(cancelSignal: cancelSignal),
        timeout: _resolverTimeout,
        maxAttempts: 1,
        cancelSignal: cancelSignal,
      );
    } on ApiException {
      rethrow;
    } catch (_) {
      throw const ApiException('XINGHAI_NETWORK', '星海网络请求失败');
    }
    final body = _resolverResponseMap(response, '星海');
    if (body['code']?.toString() != '200') {
      throw ApiException(
        'XINGHAI_${body['code'] ?? 'FAILED'}',
        '星海服务拒绝请求或未返回播放地址',
      );
    }
    return _resolvedSongDetail(body, '星海');
  }

  Future<SongDetail> gdStudioMusic(
    MusicPlatform platform,
    String id, {
    required String quality,
    Future<void>? cancelSignal,
  }) async {
    final source = switch (platform) {
      MusicPlatform.qq => 'qq',
      MusicPlatform.netease => 'netease',
      MusicPlatform.kugou => 'kg',
      MusicPlatform.bilibili => throw const ApiException(
        'SOURCE_UNSUPPORTED',
        'B站使用官方播放接口',
      ),
    };
    final base = Uri.parse(_playbackSourceConfig.gdStudioUrl);

    Future<SongDetail> requestWithBitrate(String bitrate) async {
      final params = <String, String>{
        ...base.queryParameters,
        if (platform == MusicPlatform.netease) ...{
          'use_xbridge3': 'true',
          'loader_name': 'forest',
          'need_sec_link': '1',
          'sec_link_scene': 'im',
          'theme': 'light',
        },
        'types': 'url',
        'source': source,
        'id': id,
        'br': bitrate,
      };
      final http.Response response;
      try {
        response = await _get(
          base.replace(queryParameters: params),
          headers: const {'User-Agent': 'LX-Music-Mobile'},
          timeout: _resolverTimeout,
          maxAttempts: 1,
          cancelSignal: cancelSignal,
        );
      } on ApiException {
        rethrow;
      } catch (_) {
        throw const ApiException('GD_NETWORK', 'GDStudio 网络请求失败');
      }
      final body = _resolverResponseMap(response, 'GDStudio');
      final code = body['code'];
      if (code != null && code.toString() != '0' && code.toString() != '200') {
        throw ApiException('GD_${code.toString()}', 'GDStudio 服务拒绝请求或未返回播放地址');
      }
      return _resolvedSongDetail(body, 'GDStudio');
    }

    final mappedQuality = _aggregatorQuality(platform, quality);
    final bitrate = _gdBitrate(platform, quality);
    try {
      return await requestWithBitrate(bitrate);
    } catch (error) {
      if (_isPlaybackCancellationError(error)) rethrow;
      // The XingHai script retries Netease Hi-Res at standard FLAC when GD
      // cannot serve bitrate 999. Keep this fallback bounded to one request.
      if (platform == MusicPlatform.netease &&
          mappedQuality == 'hires' &&
          bitrate == '999') {
        return requestWithBitrate('740');
      }
      rethrow;
    }
  }

  Future<Map<String, String>> _xinghaiHeaders({
    Future<void>? cancelSignal,
  }) async {
    var config = _playbackSourceConfig;
    var ip = await _xinghaiPublicIp(cancelSignal: cancelSignal) ?? '0.0.0.0';
    if (_closed) {
      throw const ApiException('RESOLVE_CANCELLED', '播放请求已取消');
    }
    if (config.xinghaiDeviceId != _playbackSourceConfig.xinghaiDeviceId ||
        config.xinghaiClient != _playbackSourceConfig.xinghaiClient) {
      config = _playbackSourceConfig;
      ip = _xinghaiIp ?? '0.0.0.0';
    }
    final now = DateTime.now();
    final createdAt = _xinghaiTokenCreatedAt;
    if (_xinghaiToken == null ||
        createdAt == null ||
        now.difference(createdAt) > _xinghaiTokenLifetime ||
        _xinghaiTokenDeviceId != config.xinghaiDeviceId ||
        _xinghaiTokenIp != ip) {
      final payload = <String, dynamic>{
        'device_id': config.xinghaiDeviceId,
        'ip': ip,
        'timestamp': now.millisecondsSinceEpoch ~/ 1000,
        'random': _randomBase36(10),
      };
      _xinghaiToken = base64Encode(utf8.encode(jsonEncode(payload)));
      _xinghaiTokenCreatedAt = now;
      _xinghaiTokenDeviceId = config.xinghaiDeviceId;
      _xinghaiTokenIp = ip;
    }
    return {
      'X-Token': _xinghaiToken!,
      'X-Client': config.xinghaiClient,
      'User-Agent': 'lx-music',
    };
  }

  Future<String?> _xinghaiPublicIp({Future<void>? cancelSignal}) {
    if (_xinghaiIp != null) return Future<String?>.value(_xinghaiIp);
    if (_playbackSourceConfig.xinghaiIpUrl.isEmpty) {
      return Future<String?>.value(null);
    }
    final pending = _xinghaiIpRequest;
    if (pending != null) return awaitWithCancellation(pending, cancelSignal);
    late final Future<String?> request;
    request = () async {
      try {
        final response = await _get(
          Uri.parse(_playbackSourceConfig.xinghaiIpUrl),
          timeout: _xinghaiIpTimeout,
          maxAttempts: 1,
          cancelSignal: cancelSignal,
        );
        if (response.statusCode < 200 || response.statusCode >= 300) {
          return null;
        }
        final dynamic decoded = jsonDecode(utf8.decode(response.bodyBytes));
        final ip = decoded is Map ? decoded['ip']?.toString().trim() : null;
        if (!_closed &&
            identical(_xinghaiIpRequest, request) &&
            ip != null &&
            ip.isNotEmpty) {
          _xinghaiIp = ip;
        }
        return ip?.isNotEmpty == true ? ip : null;
      } catch (error) {
        if (_isPlaybackCancellationError(error)) rethrow;
        return null;
      } finally {
        if (identical(_xinghaiIpRequest, request)) _xinghaiIpRequest = null;
      }
    }();
    _xinghaiIpRequest = request;
    return request;
  }

  static Map<String, dynamic> _resolverResponseMap(
    http.Response response,
    String label,
  ) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(
        '${label.toUpperCase()}_HTTP_${response.statusCode}',
        '$label 服务暂时不可用',
      );
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw ApiException(
        '${label.toUpperCase()}_INVALID_RESPONSE',
        '$label 返回了无效数据',
      );
    }
    if (decoded is! Map) {
      throw ApiException(
        '${label.toUpperCase()}_INVALID_RESPONSE',
        '$label 返回格式错误',
      );
    }
    return Map<String, dynamic>.from(decoded);
  }

  static SongDetail _resolvedSongDetail(
    Map<String, dynamic> body,
    String label,
  ) {
    final url = _findResolverUrl(body);
    if (url == null) {
      throw ApiException('${label.toUpperCase()}_EMPTY_URL', '$label 未返回播放地址');
    }
    final data = body['data'];
    final nested = data is Map ? Map<String, dynamic>.from(data) : null;
    final rawHeaders =
        body['playbackHeaders'] ??
        body['headers'] ??
        nested?['playbackHeaders'] ??
        nested?['headers'];
    final headers = rawHeaders is Map
        ? rawHeaders.map(
            (key, value) => MapEntry(key.toString(), value.toString()),
          )
        : null;
    final rawLyric =
        body['lrc'] ?? body['lyric'] ?? nested?['lrc'] ?? nested?['lyric'];
    final lyric = rawLyric is Map
        ? rawLyric['lyric']?.toString()
        : rawLyric?.toString();
    final cover =
        body['picture'] ??
        body['pic'] ??
        body['cover'] ??
        body['picUrl'] ??
        nested?['picture'] ??
        nested?['pic'] ??
        nested?['cover'] ??
        nested?['picUrl'];
    final path = Uri.parse(url).path;
    final dot = path.lastIndexOf('.');
    return SongDetail(
      name: '',
      artist: '',
      album: '',
      url: url,
      coverUrl: cover?.toString(),
      lyric: lyric,
      format: dot >= 0 && dot < path.length - 1
          ? path.substring(dot + 1)
          : null,
      playbackHeaders: headers?.isEmpty == true ? null : headers,
    );
  }

  static String? _findResolverUrl(dynamic value, [int depth = 0]) {
    if (depth > 4) return null;
    if (value is String) {
      final candidate = value.trim();
      final uri = Uri.tryParse(candidate);
      return uri != null &&
              uri.host.isNotEmpty &&
              (uri.scheme == 'http' || uri.scheme == 'https')
          ? candidate
          : null;
    }
    if (value is Map) {
      for (final key in const [
        'url',
        'playUrl',
        'play_url',
        'musicUrl',
        'musicurl',
        'play_backup_url',
      ]) {
        final found = _findResolverUrl(value[key], depth + 1);
        if (found != null) return found;
      }
      for (final key in const ['data', 'result']) {
        final found = _findResolverUrl(value[key], depth + 1);
        if (found != null) return found;
      }
    } else if (value is List) {
      for (final item in value.take(8)) {
        final found = _findResolverUrl(item, depth + 1);
        if (found != null) return found;
      }
    }
    return null;
  }

  static String _aggregatorSource(MusicPlatform platform) => switch (platform) {
    MusicPlatform.qq => 'tx',
    MusicPlatform.netease => 'wy',
    MusicPlatform.kugou => 'kg',
    MusicPlatform.bilibili => throw const ApiException(
      'SOURCE_UNSUPPORTED',
      'B站使用官方播放接口',
    ),
  };

  static String _aggregatorQuality(MusicPlatform platform, String quality) {
    if (platform != MusicPlatform.netease) return quality;
    return switch (quality) {
      'standard' => '128k',
      'exhigh' => '320k',
      'lossless' => 'flac',
      'hires' => 'hires',
      'jyeffect' => 'atmos',
      'sky' || 'jymaster' => 'master',
      _ => quality,
    };
  }

  static String _gdBitrate(MusicPlatform platform, String quality) {
    final normalized = _aggregatorQuality(platform, quality);
    return switch (normalized) {
      '128k' => '128',
      '320k' => '320',
      'flac' => '740',
      _ => '999',
    };
  }

  static String _joinUrl(String base, String path) {
    final normalizedBase = base.endsWith('/')
        ? base.substring(0, base.length - 1)
        : base;
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    return '$normalizedBase$normalizedPath';
  }

  static String _randomBase36(int length) {
    Random random;
    try {
      random = Random.secure();
    } catch (_) {
      random = Random();
    }
    const chars = '0123456789abcdefghijklmnopqrstuvwxyz';
    return List.generate(
      length,
      (_) => chars[random.nextInt(chars.length)],
    ).join();
  }

  static String _safeResolverFailure(Object error) {
    if (error is ApiException) {
      return switch (error.code) {
        'API_KEY_REQUIRED' ||
        'SOURCE_DISABLED' ||
        'SOURCE_UNSUPPORTED' => error.message,
        _ => '解析失败（${error.code}）',
      };
    }
    return '网络请求失败';
  }

  /// Probes one configured resolver with a small request.
  ///
  /// This checks endpoint reachability and response latency only. It does not
  /// assert that a particular song is licensed or playable, because that
  /// depends on the requested platform, song and current backend state.
  Future<PlaybackSourceTestResult> testPlaybackSource(
    PlaybackSource source, {
    MusicPlatform platform = MusicPlatform.qq,
    PlaybackSourceConfig? config,
    Future<void>? cancelSignal,
  }) async {
    if (source == PlaybackSource.automatic) {
      return const PlaybackSourceTestResult(
        source: PlaybackSource.automatic,
        reachable: false,
        latencyMs: null,
        statusCode: null,
        message: '自动模式不是可探测的独立接口',
      );
    }

    final effective = config ?? _playbackSourceConfig;
    final stopwatch = Stopwatch()..start();
    try {
      _ensureOpen();
      late final http.Response response;
      switch (source) {
        case PlaybackSource.automatic:
          throw const ApiException('SOURCE_UNSUPPORTED', '自动模式不是独立接口');
        case PlaybackSource.chksz:
          final endpoint = switch (platform) {
            MusicPlatform.netease => '/api/163_music',
            MusicPlatform.qq => '/api/qq_music',
            MusicPlatform.kugou => '/api/kugou_music',
            MusicPlatform.bilibili => '/api/qq_music',
          };
          final params = <String, String>{
            'type': 'json',
            'apikey': apiKey,
            if (platform == MusicPlatform.netease) ...{
              'id': '__probe__',
              'level': 'standard',
            } else if (platform == MusicPlatform.kugou) ...{
              'id': '__PROBE__',
              'size': '128k',
            } else ...{
              'mid': '__probe__',
              'size': '128k',
            },
          };
          response = await _get(
            Uri.parse(
              _joinUrl(effective.chkszBaseUrl, endpoint),
            ).replace(queryParameters: params),
            timeout: _probeTimeout,
            maxAttempts: 1,
            maxBytes: _maxProbeResponseBytes,
            cancelSignal: cancelSignal,
          );
        case PlaybackSource.qingMusic:
          response = await _postJson(
            Uri.parse(effective.qingMusicUrl),
            {
              'source': switch (platform) {
                MusicPlatform.qq => 'tx',
                MusicPlatform.netease => 'wy',
                MusicPlatform.kugou => 'kg',
                MusicPlatform.bilibili => 'tx',
              },
              'rid': '__probe__',
              'level': 'standard',
            },
            timeout: _probeTimeout,
            maxAttempts: 1,
            maxBytes: _maxProbeResponseBytes,
            cancelSignal: cancelSignal,
          );
        case PlaybackSource.hyw:
          final sourceCode = _aggregatorSource(platform);
          final params = <String, String>{
            'source': sourceCode,
            'platform': sourceCode,
            'songId': '__probe__',
            'songmid': '__probe__',
            'quality': _aggregatorQuality(platform, '128k'),
            if (effective.hywCardKey.isNotEmpty) 'key': effective.hywCardKey,
          };
          response = await _get(
            Uri.parse(
              _joinUrl(effective.hywBaseUrl, '/api/music/url'),
            ).replace(queryParameters: params),
            headers: {
              if (effective.hywCardKey.isNotEmpty)
                'X-Card-Key': effective.hywCardKey,
            },
            timeout: _probeTimeout,
            maxAttempts: 1,
            maxBytes: _maxProbeResponseBytes,
            cancelSignal: cancelSignal,
          );
        case PlaybackSource.xinghai:
          final base = Uri.parse(effective.xinghaiUrl);
          final sourceCode = switch (platform) {
            MusicPlatform.qq => 'qq',
            MusicPlatform.netease => 'wy',
            MusicPlatform.kugou => 'kg',
            MusicPlatform.bilibili => 'qq',
          };
          response = await _get(
            base.replace(
              queryParameters: {
                ...base.queryParameters,
                'source': sourceCode,
                'quality': '128k',
                'songmid': '__probe__',
              },
            ),
            headers: {
              if (effective.xinghaiClient.trim().isNotEmpty)
                'X-Client': effective.xinghaiClient.trim(),
              'User-Agent': 'lx-music',
            },
            timeout: _probeTimeout,
            maxAttempts: 1,
            maxBytes: _maxProbeResponseBytes,
            cancelSignal: cancelSignal,
          );
        case PlaybackSource.gdStudio:
          final base = Uri.parse(effective.gdStudioUrl);
          final sourceCode = switch (platform) {
            MusicPlatform.qq => 'qq',
            MusicPlatform.netease => 'netease',
            MusicPlatform.kugou => 'kg',
            MusicPlatform.bilibili => 'qq',
          };
          response = await _get(
            base.replace(
              queryParameters: {
                ...base.queryParameters,
                'types': 'url',
                'source': sourceCode,
                'id': '__probe__',
                'br': '128',
              },
            ),
            headers: const {'User-Agent': 'LX-Music-Mobile'},
            timeout: _probeTimeout,
            maxAttempts: 1,
            maxBytes: _maxProbeResponseBytes,
            cancelSignal: cancelSignal,
          );
      }
      stopwatch.stop();
      final statusCode = response.statusCode;
      final reachable = statusCode >= 100 && statusCode <= 599;
      final message = statusCode >= 200 && statusCode < 300
          ? 'HTTP $statusCode'
          : 'HTTP $statusCode（网络可达，接口返回错误）';
      return PlaybackSourceTestResult(
        source: source,
        reachable: reachable,
        latencyMs: stopwatch.elapsedMilliseconds,
        statusCode: statusCode,
        message: message,
      );
    } catch (error) {
      stopwatch.stop();
      return PlaybackSourceTestResult(
        source: source,
        reachable: false,
        latencyMs: stopwatch.elapsedMilliseconds,
        statusCode: null,
        message: _safeProbeFailure(error),
      );
    }
  }

  /// Probes a bounded number of sources at once. The default is the set of
  /// enabled sources, so the same switches that control racing also control
  /// the one-click test. Callers can explicitly request all sources when
  /// diagnosing a disabled endpoint.
  Future<List<PlaybackSourceTestResult>> testPlaybackSources({
    PlaybackSourceConfig? config,
    MusicPlatform platform = MusicPlatform.qq,
    bool enabledOnly = true,
    int maxConcurrent = 3,
    Future<void>? cancelSignal,
  }) async {
    final effective = config ?? _playbackSourceConfig;
    final sources = PlaybackSource.values
        .where((source) => source != PlaybackSource.automatic)
        .where((source) => !enabledOnly || effective.isEnabled(source))
        .toList(growable: false);
    if (sources.isEmpty) return const [];

    final results = List<PlaybackSourceTestResult?>.filled(
      sources.length,
      null,
    );
    final workerCount = min(max(1, maxConcurrent), 3);
    var nextIndex = 0;

    Future<void> worker() async {
      while (true) {
        final index = nextIndex++;
        if (index >= sources.length) return;
        try {
          results[index] = await testPlaybackSource(
            sources[index],
            platform: platform,
            config: effective,
            cancelSignal: cancelSignal,
          );
        } catch (error) {
          results[index] = PlaybackSourceTestResult(
            source: sources[index],
            reachable: false,
            latencyMs: null,
            statusCode: null,
            message: _safeProbeFailure(error),
          );
        }
      }
    }

    await Future.wait(
      List<Future<void>>.generate(workerCount, (_) => worker()),
    );
    return results.whereType<PlaybackSourceTestResult>().toList(
      growable: false,
    );
  }

  static String _safeProbeFailure(Object error) {
    if (error is HttpRequestCancelledException ||
        error is ApiException && error.code == 'RESOLVE_CANCELLED') {
      return '测试已取消';
    }
    if (error is ApiException && error.code == 'RESPONSE_TOO_LARGE') {
      return '响应过大';
    }
    if (error is TimeoutException) return '连接超时';
    if (error is FormatException) return '地址格式无效';
    return '网络不可达';
  }

  /// 查找并解析当前平台中与歌曲对应的 MV 播放地址。
  ///
  /// 播放队列只保留了歌曲 id，因此用户点击 MV 时才按需查询
  /// 对应的 vid/mvid/mvhash，不让每次普通播放都额外请求 MV 数据。
  Future<String> musicVideoUrl({
    required MusicPlatform platform,
    required String songId,
    required String songName,
    required String artist,
  }) async {
    return switch (platform) {
      MusicPlatform.qq => _qqMusicVideoUrl(songId, songName, artist),
      MusicPlatform.netease => _neteaseMusicVideoUrl(songId),
      MusicPlatform.kugou => _kugouMusicVideoUrl(songId, songName, artist),
      MusicPlatform.bilibili => throw UnsupportedError('B站视频需要当前分P信息'),
    };
  }

  Future<String> _neteaseMusicVideoUrl(String songId) async {
    List<Map<String, dynamic>> songs;
    try {
      songs = await _neteaseSongDetails([songId]);
      if (songs.isEmpty) {
        throw const ApiException('NETEASE_MV_METADATA_EMPTY', '网易云歌曲信息为空');
      }
    } catch (error) {
      debugPrint('网易云 MV 元数据直连失败，切换兼容线路: $error');
      final detail = await _httpGet(
        neteaseBaseUrl,
        '/song/detail',
        {'ids': songId},
        timeout: _catalogFallbackTimeout,
        maxAttempts: 1,
      );
      songs = (detail['songs'] as List? ?? const [])
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false);
    }
    final mappedSongs = songs.whereType<Map>();
    final song = mappedSongs.isEmpty ? null : mappedSongs.first;
    final mvId = _usableIdentifier(song?['mv'] ?? song?['mvid']);
    if (mvId == null) {
      throw ApiException('MV_NOT_FOUND', '网易云暂未提供这首歌的 MV');
    }

    for (final resolution in const [1080, 720, 480]) {
      try {
        final response = await _httpGet(
          _neteaseCatalogUrl,
          '/api/song/enhance/play/mv/url',
          {'id': mvId, 'r': resolution},
          timeout: _catalogTimeout,
          maxAttempts: 1,
        );
        final url = response['data']?['url']?.toString().trim() ?? '';
        if (url.isNotEmpty) return url;
        throw const ApiException('NETEASE_MV_URL_EMPTY', '网易云 MV 地址为空');
      } catch (error) {
        debugPrint('网易云 MV 地址直连失败，切换兼容线路: $error');
        final response = await _httpGet(
          neteaseBaseUrl,
          '/mv/url',
          {'id': mvId, 'r': resolution},
          timeout: _catalogFallbackTimeout,
          maxAttempts: 1,
        );
        final url = response['data']?['url']?.toString().trim() ?? '';
        if (url.isNotEmpty) return url;
      }
    }
    throw ApiException('MV_UNAVAILABLE', '网易云中的该 MV 暂时无法播放');
  }

  Future<String> _qqMusicVideoUrl(
    String songId,
    String songName,
    String artist,
  ) async {
    List rows;
    try {
      final response = await _qqMusicu({
        'req_1': {
          'method': 'DoSearchForQQMusicDesktop',
          'module': 'music.search.SearchCgiService',
          'param': {
            'num_per_page': 30,
            'page_num': 1,
            'query': '$songName $artist',
            'search_type': 0,
          },
        },
      });
      final data = _qqResponseData(response, 'req_1');
      final body = data['body'];
      final song = body is Map ? body['song'] : null;
      rows = song is Map ? song['list'] as List? ?? const [] : const [];
      if (rows.isEmpty) {
        throw const ApiException('QQ_MV_METADATA_EMPTY', 'QQ 音乐歌曲信息为空');
      }
    } catch (error) {
      debugPrint('QQ MV 元数据直连失败，切换兼容线路: $error');
      final search = await _httpGet(
        qqBaseUrl,
        '/search',
        {'key': '$songName $artist'},
        timeout: _catalogFallbackTimeout,
        maxAttempts: 1,
      );
      rows = search['data']?['list'] as List? ?? const [];
    }
    Map? matched;
    for (final row in rows.whereType<Map>()) {
      if ((row['mid'] ?? row['songmid'])?.toString() == songId) {
        matched = row;
        break;
      }
    }
    matched ??= _matchSongMetadata(
      rows,
      songName: songName,
      artist: artist,
      nameKeys: const ['name', 'title', 'songname'],
      artistKey: 'singer',
    );
    final mv = matched?['mv'];
    final vid = _usableIdentifier(
      matched?['vid'] ?? (mv is Map ? mv['vid'] : null),
    );
    if (vid == null) {
      throw ApiException('MV_NOT_FOUND', 'QQ音乐暂未提供这首歌的 MV');
    }

    final response = await _postJson(
      Uri.parse('https://u.y.qq.com/cgi-bin/musicu.fcg'),
      {
        'getMvUrl': {
          'module': 'gosrf.Stream.MvUrlProxy',
          'method': 'GetMvUrls',
          'param': {
            'vids': [vid],
            'request_type': 10001,
            'addrtype': 3,
            'format': 264,
          },
        },
        'comm': {'ct': 24, 'cv': 4747474},
      },
      headers: const {
        'Referer': 'https://y.qq.com/',
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/120 Safari/537.36',
      },
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(
        'QQ_MV_HTTP_${response.statusCode}',
        'QQ音乐 MV 服务暂时不可用',
      );
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw ApiException('QQ_MV_INVALID_RESPONSE', 'QQ音乐 MV 返回了无效数据');
    }
    dynamic rawQualities;
    if (decoded is Map) {
      final getMvUrl = decoded['getMvUrl'];
      final data = getMvUrl is Map ? getMvUrl['data'] : null;
      final mv = data is Map ? data[vid] : null;
      rawQualities = mv is Map ? mv['mp4'] : null;
    }
    if (rawQualities is List) {
      for (final quality in rawQualities.reversed.whereType<Map>()) {
        for (final key in const ['freeflow_url', 'comm_url']) {
          final urls = quality[key];
          if (urls is! List) continue;
          for (final rawUrl in urls) {
            final url = rawUrl?.toString().trim() ?? '';
            if (url.startsWith('http://') || url.startsWith('https://')) {
              return url;
            }
          }
        }
      }
    }
    throw ApiException('MV_UNAVAILABLE', 'QQ音乐中的该 MV 暂时无法播放');
  }

  Future<String> _kugouMusicVideoUrl(
    String songId,
    String songName,
    String artist,
  ) async {
    final search = await _kugouCatalogGet('/api/v3/search/song', {
      'keyword': '$songName $artist',
      'page': 1,
      'pagesize': 30,
    });
    final rows = search['data']?['info'] as List? ?? const [];
    Map? matched;
    for (final row in rows.whereType<Map>()) {
      if (row['hash']?.toString().toLowerCase() == songId.toLowerCase()) {
        matched = row;
        break;
      }
    }
    matched ??= _matchSongMetadata(
      rows,
      songName: songName,
      artist: artist,
      nameKeys: const ['songname', 'filename'],
      artistKey: 'singername',
    );
    final mvHash = _usableIdentifier(matched?['mvhash'] ?? matched?['MvHash']);
    if (mvHash == null) {
      throw ApiException('MV_NOT_FOUND', '酷狗音乐暂未提供这首歌的 MV');
    }

    final uri = Uri.parse('https://m.kugou.com/app/i/mv.php').replace(
      queryParameters: {
        'cmd': '100',
        'hash': mvHash,
        'ismp3': '1',
        'ext': 'mp4',
      },
    );
    final response = await _get(uri);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(
        'KUGOU_MV_HTTP_${response.statusCode}',
        '酷狗音乐 MV 服务暂时不可用',
      );
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw ApiException('KUGOU_MV_INVALID_RESPONSE', '酷狗音乐 MV 返回了无效数据');
    }
    final mvData = decoded is Map ? decoded['mvdata'] : null;
    if (mvData is Map) {
      // 优先选择适合 1080p 车机的高清档，再向下兼容。
      for (final quality in const ['sq', 'hd', 'sd', 'le', 'rq']) {
        final data = mvData[quality];
        if (data is! Map) continue;
        final direct = data['downurl']?.toString().trim() ?? '';
        if (direct.isNotEmpty) return direct;
        final backups = data['backupdownurl'];
        if (backups is List) {
          for (final rawUrl in backups) {
            final url = rawUrl?.toString().trim() ?? '';
            if (url.isNotEmpty) return url;
          }
        }
      }
    }
    throw ApiException('MV_UNAVAILABLE', '酷狗音乐中的该 MV 暂时无法播放');
  }

  static Map? _matchSongMetadata(
    List rows, {
    required String songName,
    required String artist,
    required List<String> nameKeys,
    required String artistKey,
  }) {
    final expectedName = _normalizeMatchText(songName);
    final expectedArtist = _normalizeMatchText(artist);
    for (final row in rows.whereType<Map>()) {
      final rawName = nameKeys
          .map((key) => row[key]?.toString() ?? '')
          .firstWhere((value) => value.isNotEmpty, orElse: () => '');
      final name = _normalizeMatchText(rawName);
      final rawArtist = row[artistKey];
      final artistText = rawArtist is List
          ? rawArtist
                .whereType<Map>()
                .map((item) => item['name']?.toString() ?? '')
                .join('/')
          : rawArtist?.toString() ?? '';
      final candidateArtist = _normalizeMatchText(artistText);
      if (name == expectedName &&
          (expectedArtist.isEmpty ||
              candidateArtist.contains(expectedArtist) ||
              expectedArtist.contains(candidateArtist))) {
        return row;
      }
    }
    return null;
  }

  static String _normalizeMatchText(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[\s/\u3001，,&·・-]+'), '');

  static String? _usableIdentifier(dynamic value) {
    final result = value?.toString().trim() ?? '';
    return result.isEmpty || result == '0' ? null : result;
  }

  // ---- 通用 HTTP GET ----
  Future<Map<String, dynamic>> _httpGet(
    String baseUrl,
    String path,
    Map<String, dynamic> params, {
    Duration timeout = _requestTimeout,
    int maxAttempts = 2,
    Map<String, String> headers = const {},
  }) async {
    final uri = Uri.parse(
      '$baseUrl$path',
    ).replace(queryParameters: params.map((k, v) => MapEntry(k, v.toString())));
    final res = await _get(
      uri,
      timeout: timeout,
      maxAttempts: maxAttempts,
      headers: headers,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ApiException('HTTP_${res.statusCode}', '服务暂时不可用');
    }
    final dynamic body;
    try {
      // 部分上游未声明 charset，显式按 UTF-8 解码避免中文乱码。
      body = json.decode(utf8.decode(res.bodyBytes));
    } on FormatException {
      throw ApiException('INVALID_RESPONSE', '服务返回了无效数据');
    }
    if (body is! Map<String, dynamic>) {
      throw ApiException('INVALID_RESPONSE', '服务返回格式错误');
    }
    return body;
  }

  Future<Map<String, dynamic>> _catalogGet({
    required String directBaseUrl,
    required String directPath,
    required String fallbackBaseUrl,
    required String fallbackPath,
    required Map<String, dynamic> params,
    Map<String, dynamic>? fallbackParams,
  }) async {
    try {
      return await _httpGet(
        directBaseUrl,
        directPath,
        params,
        timeout: _catalogTimeout,
        maxAttempts: 1,
      );
    } catch (error) {
      debugPrint('目录直连失败，切换兼容线路: $error');
      return _httpGet(
        fallbackBaseUrl,
        fallbackPath,
        fallbackParams ?? params,
        timeout: _catalogFallbackTimeout,
        maxAttempts: 1,
      );
    }
  }

  Future<Map<String, dynamic>> _qqMusicu(Map<String, dynamic> payload) async {
    final response = await _postJson(
      Uri.parse(_qqCatalogUrl),
      payload,
      headers: const {
        'Referer': 'https://y.qq.com/',
        'Origin': 'https://y.qq.com',
      },
      timeout: _catalogTimeout,
      maxAttempts: 1,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException('QQ_HTTP_${response.statusCode}', 'QQ 音乐目录服务暂时不可用');
    }
    final dynamic body;
    try {
      body = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw ApiException('QQ_INVALID_RESPONSE', 'QQ 音乐返回了无效数据');
    }
    if (body is! Map) {
      throw ApiException('QQ_INVALID_RESPONSE', 'QQ 音乐返回格式错误');
    }
    return Map<String, dynamic>.from(body);
  }

  Map<String, dynamic> _qqResponseData(
    Map<String, dynamic> response,
    String requestKey,
  ) {
    final rawRequest = response[requestKey];
    if (rawRequest is! Map) {
      throw ApiException('QQ_INVALID_RESPONSE', 'QQ 音乐目录数据缺失');
    }
    final request = Map<String, dynamic>.from(rawRequest);
    if (request['code'] != null && request['code'].toString() != '0') {
      throw ApiException(
        'QQ_${request['code']}',
        request['message']?.toString() ?? 'QQ 音乐目录请求失败',
      );
    }
    final rawData = request['data'];
    if (rawData is! Map) {
      throw ApiException('QQ_INVALID_RESPONSE', 'QQ 音乐目录内容为空');
    }
    return Map<String, dynamic>.from(rawData);
  }

  Future<Map<String, dynamic>> _kugouCatalogGet(
    String path,
    Map<String, dynamic> params,
  ) {
    return _catalogGet(
      directBaseUrl: _kugouCatalogUrl,
      directPath: path,
      fallbackBaseUrl: kugouSearchBase,
      fallbackPath: path,
      params: params,
    );
  }

  // ======================== 网易云 (直连) ========================

  /// 搜索网易云歌曲
  Future<List<SongSearchResult>> neteaseSearch(
    String keyword, {
    int limit = 20,
  }) async {
    final json = await _catalogGet(
      directBaseUrl: _neteaseCatalogUrl,
      directPath: '/api/search/get/web',
      fallbackBaseUrl: neteaseBaseUrl,
      fallbackPath: '/search',
      params: {
        's': keyword,
        'type': 1,
        'limit': limit,
        'offset': 0,
        'total': true,
      },
      fallbackParams: {'keywords': keyword, 'limit': limit},
    );
    final list = json['result']?['songs'] as List? ?? [];
    final songs = list
        .map((e) => SongSearchResult.fromNetease(e as Map<String, dynamic>))
        .toList();
    // 搜索接口不带封面，用 /song/detail 批量补充
    await _fillNeteaseCovers(songs);
    return songs;
  }

  /// 网易云歌单搜索 (/search?type=1000)
  Future<List<PlaylistInfo>> neteaseSearchPlaylists(
    String keyword, {
    int limit = 20,
  }) async {
    final json = await _catalogGet(
      directBaseUrl: _neteaseCatalogUrl,
      directPath: '/api/search/get/web',
      fallbackBaseUrl: neteaseBaseUrl,
      fallbackPath: '/search',
      params: {
        's': keyword,
        'type': 1000,
        'limit': limit,
        'offset': 0,
        'total': true,
      },
      fallbackParams: {'keywords': keyword, 'type': 1000, 'limit': limit},
    );
    final list = json['result']?['playlists'] as List? ?? [];
    return list
        .map((e) => PlaylistInfo.fromNeteaseList(e as Map<String, dynamic>))
        .toList();
  }

  /// 批量补充网易云歌曲封面（失败不影响主流程）
  Future<void> _fillNeteaseCovers(List<SongSearchResult> songs) async {
    if (songs.isEmpty) return;
    final missing = songs
        .where((s) => s.coverUrl == null || s.coverUrl!.isEmpty)
        .toList();
    if (missing.isEmpty) return;
    try {
      final details = await _neteaseSongDetails(missing.map((song) => song.id));
      for (final d in details) {
        final id = d['id']?.toString();
        final picUrl = SongSearchResult.fromNetease(d).coverUrl;
        if (id == null || picUrl == null) continue;
        final idx = songs.indexWhere((s) => s.id == id);
        if (idx >= 0) {
          songs[idx] = SongSearchResult(
            platform: songs[idx].platform,
            id: songs[idx].id,
            name: songs[idx].name,
            artist: songs[idx].artist,
            album: songs[idx].album,
            coverUrl: picUrl,
            duration: songs[idx].duration,
          );
        }
      }
    } catch (e) {
      // 封面补充失败不影响列表展示
      debugPrint('补网易云封面失败: $e');
    }
  }

  Future<List<Map<String, dynamic>>> _neteaseSongDetails(
    Iterable<String> songIds,
  ) async {
    final ids = songIds.where((id) => id.isNotEmpty).toList(growable: false);
    if (ids.isEmpty) return const [];
    final officialIds = jsonEncode(ids);
    final songParams = ids
        .map((id) => <String, dynamic>{'id': int.tryParse(id) ?? id})
        .toList(growable: false);
    final json = await _catalogGet(
      directBaseUrl: _neteaseCatalogUrl,
      directPath: '/api/song/detail',
      fallbackBaseUrl: neteaseBaseUrl,
      fallbackPath: '/song/detail',
      params: {'ids': officialIds, 'c': jsonEncode(songParams)},
      fallbackParams: {'ids': ids.join(',')},
    );
    final rows = json['songs'] as List? ?? const [];
    return rows
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList(growable: false);
  }

  /// 解析网易云歌曲播放地址 (ChKSz API /api/163_music)
  Future<SongDetail> neteaseMusic(
    String id, {
    String level = 'exhigh',
    Future<void>? cancelSignal,
  }) async {
    final json = await _chkszGet('/api/163_music', {
      'id': id,
      'level': level,
      'type': 'json',
    }, cancelSignal: cancelSignal);
    final rawData = json['data'];
    final data = rawData is Map
        ? Map<String, dynamic>.from(rawData)
        : <String, dynamic>{};
    final url = data['url']?.toString() ?? '';
    final path = Uri.tryParse(url)?.path ?? '';
    final dot = path.lastIndexOf('.');
    return SongDetail(
      name: data['name']?.toString() ?? '',
      artist: data['artist']?.toString() ?? '',
      album: data['album']?.toString() ?? '',
      url: url,
      coverUrl: data['picUrl']?.toString(),
      duration: null,
      bitrate: data['br']?.toString(),
      format: dot >= 0 && dot < path.length - 1
          ? path.substring(dot + 1)
          : null,
    );
  }

  /// 获取网易云歌词。官方公开接口直连失败后才使用旧中转。
  Future<LyricData> neteaseLyric(String id) => neteasePublicLyric(id);

  Future<LyricData> neteasePublicLyric(String id) async {
    try {
      final json = await _httpGet(
        _neteaseLyricUrl,
        '/api/song/lyric',
        {
          'id': id,
          'cp': false,
          'lv': -1,
          'tv': -1,
          'rv': -1,
          'kv': -1,
          'yv': -1,
          'ytv': -1,
          'yrv': -1,
        },
        timeout: _catalogTimeout,
        maxAttempts: 1,
      );
      final result = _neteaseLyricData(json);
      if (!_hasTimedLyric(result.original) &&
          !_hasTimedLyric(result.wordSynced)) {
        throw const ApiException('NETEASE_LYRIC_EMPTY', '网易云歌词内容为空');
      }
      return result;
    } catch (error) {
      debugPrint('网易云歌词直连失败，切换兼容线路: $error');
      final json = await _httpGet(
        neteaseBaseUrl,
        '/lyric',
        {'id': id},
        timeout: _catalogFallbackTimeout,
        maxAttempts: 1,
      );
      return _neteaseLyricData(json);
    }
  }

  static LyricData _neteaseLyricData(Map<String, dynamic> json) {
    final rawData = json['data'];
    final data = rawData is Map ? rawData : json;
    final rawLrc = data['lrc'];
    final rawTranslated = data['tlyric'];
    final rawRomaji = data['romalrc'];
    final rawYrc = data['yrc'];
    final rawKaraoke = data['klyric'];
    final yrcText = rawYrc is Map
        ? rawYrc['lyric']?.toString()
        : rawYrc?.toString();
    final karaokeText = rawKaraoke is Map
        ? rawKaraoke['lyric']?.toString()
        : rawKaraoke?.toString();
    return LyricData(
      original: rawLrc is Map
          ? rawLrc['lyric']?.toString()
          : rawLrc?.toString(),
      translated: rawTranslated is Map
          ? rawTranslated['lyric']?.toString()
          : rawTranslated?.toString(),
      romaji: rawRomaji is Map
          ? rawRomaji['lyric']?.toString()
          : rawRomaji?.toString(),
      wordSynced: yrcText != null && yrcText.trim().isNotEmpty
          ? yrcText
          : karaokeText,
    );
  }

  /// 网易云热门歌单
  Future<List<PlaylistInfo>> neteaseHotPlaylists({int limit = 20}) async {
    final json = await _catalogGet(
      directBaseUrl: _neteaseCatalogUrl,
      directPath: '/api/playlist/list',
      fallbackBaseUrl: neteaseBaseUrl,
      fallbackPath: '/top/playlist',
      params: {'cat': '全部', 'limit': limit, 'offset': 0, 'order': 'hot'},
      fallbackParams: {'limit': limit, 'order': 'hot'},
    );
    final list = json['playlists'] as List? ?? [];
    return list
        .map((e) => PlaylistInfo.fromNeteaseList(e as Map<String, dynamic>))
        .toList();
  }

  /// 获取网易云歌单详情，官方接口直连优先。
  Future<PlaylistInfo> neteasePlaylist(String id) async {
    final json = await _catalogGet(
      directBaseUrl: _neteaseCatalogUrl,
      directPath: '/api/v6/playlist/detail',
      fallbackBaseUrl: neteaseBaseUrl,
      fallbackPath: '/playlist/detail',
      params: {'id': id, 'n': 1000, 's': 0},
      fallbackParams: {'id': id},
    );
    final rawData = json['playlist'] ?? json['data'];
    final data = rawData is Map ? Map<String, dynamic>.from(rawData) : json;
    final result = PlaylistInfo.fromJson(data);
    // 歌单详情曲目也补充封面
    await _fillNeteaseCovers(result.tracks);
    return result;
  }

  /// 获取网易云歌单元数据，不解析完整曲目列表。
  Future<PlaylistInfo> neteasePlaylistSummary(String id) async {
    final index = await _neteasePlaylistIndex(id);
    final summary = index.summary;
    if (summary == null) {
      _neteasePlaylistIndexes.remove(id);
      throw const ApiException('PLAYLIST_NOT_FOUND', '未找到歌单，请检查链接或 ID');
    }
    return summary;
  }

  /// 网易云歌单曲目分页。
  ///
  /// 首次只从官方详情取得轻量曲目 ID，并缓存本次会话的索引；每一页再按
  /// 20 个 ID 批量获取歌曲详情，避免重复下载或解析完整歌曲对象。
  Future<PlaylistTrackPage> neteasePlaylistTracks(
    String id, {
    int limit = 20,
    int offset = 0,
  }) async {
    final safeLimit = limit.clamp(1, 100);
    final safeOffset = offset < 0 ? 0 : offset;
    final index = await _neteasePlaylistIndex(id);
    final selectedIds = index.trackIds
        .skip(safeOffset)
        .take(safeLimit)
        .toList(growable: false);
    final details = await _neteaseSongDetails(selectedIds);
    final byId = <String, Map<String, dynamic>>{
      for (final detail in details)
        if (detail['id'] != null) detail['id'].toString(): detail,
    };
    final tracks = selectedIds
        .map((songId) => byId[songId])
        .whereType<Map<String, dynamic>>()
        .map(SongSearchResult.fromNetease)
        .toList(growable: false);
    return PlaylistTrackPage(tracks: tracks, total: index.total);
  }

  Future<_NeteasePlaylistIndex> _neteasePlaylistIndex(String id) async {
    final existing = _neteasePlaylistIndexes[id];
    if (existing != null) return existing;
    final request = _loadNeteasePlaylistIndex(id);
    _neteasePlaylistIndexes[id] = request;
    while (_neteasePlaylistIndexes.length > _maxNeteasePlaylistIndexes) {
      final oldest = _neteasePlaylistIndexes.keys.firstWhere(
        (key) => key != id,
        orElse: () => id,
      );
      if (oldest == id) break;
      _neteasePlaylistIndexes.remove(oldest);
    }
    try {
      return await request;
    } catch (_) {
      if (identical(_neteasePlaylistIndexes[id], request)) {
        _neteasePlaylistIndexes.remove(id);
      }
      rethrow;
    }
  }

  Future<_NeteasePlaylistIndex> _loadNeteasePlaylistIndex(String id) async {
    final json = await _catalogGet(
      directBaseUrl: _neteaseCatalogUrl,
      directPath: '/api/v6/playlist/detail',
      fallbackBaseUrl: neteaseBaseUrl,
      fallbackPath: '/playlist/detail',
      params: {'id': id, 'n': 100000, 's': 0},
      fallbackParams: {'id': id},
    );
    final rawPlaylist = json['playlist'];
    final playlist = rawPlaylist is Map
        ? Map<String, dynamic>.from(rawPlaylist)
        : <String, dynamic>{};
    final trackIds = (playlist['trackIds'] as List? ?? const [])
        .whereType<Map>()
        .map((row) => row['id']?.toString() ?? '')
        .where((trackId) => trackId.isNotEmpty)
        .toList();
    if (trackIds.isEmpty) {
      final embedded = playlist['tracks'] as List? ?? const [];
      trackIds.addAll(
        embedded
            .whereType<Map>()
            .map((row) => row['id']?.toString() ?? '')
            .where((trackId) => trackId.isNotEmpty),
      );
    }
    final rawTotal = playlist['trackCount'];
    final total = rawTotal is num
        ? rawTotal.toInt()
        : int.tryParse(rawTotal?.toString() ?? '') ?? trackIds.length;
    final rawId = playlist['id']?.toString().trim() ?? '';
    final name = playlist['name']?.toString().trim() ?? '';
    final summary = rawId.isNotEmpty && name.isNotEmpty
        ? PlaylistInfo(
            id: rawId,
            name: name,
            coverUrl: CoverHelper.normalize(
              playlist['coverImgUrl']?.toString() ??
                  playlist['picUrl']?.toString(),
            ),
            creator: playlist['creator'] is Map
                ? playlist['creator']['nickname']?.toString()
                : null,
            trackCount: total,
            description: playlist['description']?.toString(),
            tracks: const [],
          )
        : null;
    return _NeteasePlaylistIndex(
      trackIds: trackIds,
      total: total,
      summary: summary,
    );
  }

  // ======================== 酷狗 (mobilecdn 官方接口, ChKSz解析) ========================
  // mixdown 源站已不可用，搜索、推荐和新歌统一使用 mobilecdn 官方接口。

  /// 搜索酷狗歌曲 (mobilecdn /api/v3/search/song)
  Future<List<SongSearchResult>> kugouSearch(
    String keyword, {
    int page = 1,
    int pagesize = 20,
  }) async {
    final json = await _kugouCatalogGet('/api/v3/search/song', {
      'keyword': keyword,
      'page': page,
      'pagesize': pagesize,
    });
    final list = json['data']?['info'] as List? ?? [];
    return list
        .map(
          (e) =>
              SongSearchResult.fromKugouSearchSong(e as Map<String, dynamic>),
        )
        .toList();
  }

  /// 酷狗新歌速递（mobilecdn 新歌榜 74534）
  Future<List<SongSearchResult>> kugouNewSongs({
    int page = 1,
    int pagesize = 30,
  }) async {
    final json = await _kugouCatalogGet('/api/v3/rank/song', {
      'rankid': '74534',
      'page': page,
      'pagesize': pagesize,
    });
    final list = json['data']?['info'] as List? ?? [];
    return list
        .map(
          (e) => SongSearchResult.fromKugouRankSong(e as Map<String, dynamic>),
        )
        .toList();
  }

  /// 酷狗每日推荐（mobilecdn 飙升榜 6666）
  Future<List<SongSearchResult>> kugouDailyRecommend({
    int pagesize = 20,
  }) async {
    final json = await _kugouCatalogGet('/api/v3/rank/song', {
      'rankid': '6666',
      'page': 1,
      'pagesize': pagesize,
    });
    final list = json['data']?['info'] as List? ?? [];
    return list
        .map(
          (e) => SongSearchResult.fromKugouRankSong(e as Map<String, dynamic>),
        )
        .toList();
  }

  /// 解析酷狗播放地址 (ChKSz 兜底)
  /// ⚠️ ChKSz 酷狗 id 参数要求大写 hash（mobilecdn 搜索返回小写，需转换）
  Future<SongDetail> kugouMusic(
    String hash, {
    String size = 'flac',
    Future<void>? cancelSignal,
  }) async {
    final json = await _chkszGet('/api/kugou_music', {
      'id': hash.toUpperCase(),
      'size': size,
      'type': 'json',
    }, cancelSignal: cancelSignal);
    return SongDetail.fromKugou(json);
  }

  /// 酷狗脚本的免签名歌词兜底接口。返回 LRC 文本，不参与播放地址解析。
  Future<LyricData> kugouPublicLyric(String hash) async {
    final uri = Uri.parse(
      'https://m.kugou.com/app/i/krc.php',
    ).replace(queryParameters: {'cmd': '100', 'hash': hash, 'timelength': '1'});
    final response = await _get(uri);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(
        'KUGOU_LYRIC_HTTP_${response.statusCode}',
        '酷狗歌词服务暂时不可用',
      );
    }
    final text = utf8
        .decode(response.bodyBytes, allowMalformed: true)
        .replaceAll('\r', '');
    final start = text.indexOf('[');
    return LyricData(original: start >= 0 ? text.substring(start) : null);
  }

  // ======================== QQ音乐 (直连搜索/推荐, ChKSz解析) ========================

  /// 搜索 QQ 音乐（官方 musicu，旧中转仅作失败兜底）。
  Future<List<SongSearchResult>> qqSearch(String keyword) async {
    try {
      final response = await _qqMusicu({
        'req_1': {
          'method': 'DoSearchForQQMusicDesktop',
          'module': 'music.search.SearchCgiService',
          'param': {
            'num_per_page': 20,
            'page_num': 1,
            'query': keyword,
            'search_type': 0,
          },
        },
      });
      final data = _qqResponseData(response, 'req_1');
      final body = data['body'];
      final song = body is Map ? body['song'] : null;
      final rows = song is Map ? song['list'] as List? ?? const [] : const [];
      return rows
          .whereType<Map>()
          .map(
            (row) =>
                SongSearchResult.fromQQMusicu(Map<String, dynamic>.from(row)),
          )
          .toList(growable: false);
    } catch (error) {
      debugPrint('QQ 官方搜索失败，切换兼容线路: $error');
      final json = await _httpGet(
        qqBaseUrl,
        '/search',
        {'key': keyword},
        timeout: _catalogFallbackTimeout,
        maxAttempts: 1,
      );
      final list = json['data']?['list'] as List? ?? [];
      return list
          .map((e) => SongSearchResult.fromQQDirect(e as Map<String, dynamic>))
          .toList();
    }
  }

  /// QQ推荐歌单
  Future<List<PlaylistInfo>> qqRecommendPlaylists() async {
    try {
      final response = await _qqMusicu({
        'comm': {'ct': 24, 'cv': 0},
        'req_0': {
          'module': 'playlist.HotRecommendServer',
          'method': 'get_hot_recommend',
          'param': {'async': 1, 'cmd': 2},
        },
      });
      final data = _qqResponseData(response, 'req_0');
      final list = data['v_hot'] as List? ?? const [];
      return list
          .whereType<Map>()
          .map((row) {
            return PlaylistInfo(
              id: row['content_id']?.toString() ?? '',
              name: row['title']?.toString() ?? '未知歌单',
              coverUrl: CoverHelper.normalize(row['cover']?.toString()),
              creator: row['username']?.toString(),
              trackCount: 0,
              tracks: const [],
            );
          })
          .toList(growable: false);
    } catch (error) {
      debugPrint('QQ 推荐歌单直连失败，切换兼容线路: $error');
      final json = await _httpGet(
        qqBaseUrl,
        '/recommend/playlist',
        const {},
        timeout: _catalogFallbackTimeout,
        maxAttempts: 1,
      );
      final list = json['data']?['list'] as List? ?? const [];
      return list
          .whereType<Map>()
          .map((row) => PlaylistInfo.fromQQList(Map<String, dynamic>.from(row)))
          .toList(growable: false);
    }
  }

  /// QQ 音乐歌单搜索（官方 musicu）。
  Future<List<PlaylistInfo>> qqSearchPlaylists(String keyword) async {
    try {
      final response = await _qqMusicu({
        'req_1': {
          'method': 'DoSearchForQQMusicDesktop',
          'module': 'music.search.SearchCgiService',
          'param': {
            'num_per_page': 20,
            'page_num': 1,
            'query': keyword,
            'search_type': 3,
          },
        },
      });
      final data = _qqResponseData(response, 'req_1');
      final body = data['body'];
      final songlist = body is Map ? body['songlist'] : null;
      final rows = songlist is Map
          ? songlist['list'] as List? ?? const []
          : const [];
      return rows
          .whereType<Map>()
          .map(
            (row) =>
                PlaylistInfo.fromQQSearchList(Map<String, dynamic>.from(row)),
          )
          .toList(growable: false);
    } catch (error) {
      debugPrint('QQ 官方歌单搜索失败，切换兼容线路: $error');
      final json = await _httpGet(
        qqBaseUrl,
        '/search',
        {'key': keyword, 't': 2},
        timeout: _catalogFallbackTimeout,
        maxAttempts: 1,
      );
      final list = json['data']?['list'] as List? ?? [];
      return list
          .map((e) => PlaylistInfo.fromQQSearchList(e as Map<String, dynamic>))
          .toList();
    }
  }

  /// 酷狗歌单搜索 (mobilecdn /api/v3/search/special)
  Future<List<PlaylistInfo>> kugouSearchPlaylists(
    String keyword, {
    int page = 1,
    int pagesize = 20,
  }) async {
    final json = await _kugouCatalogGet('/api/v3/search/special', {
      'keyword': keyword,
      'page': page,
      'pagesize': pagesize,
    });
    final list = json['data']?['info'] as List? ?? [];
    return list
        .map((e) => PlaylistInfo.fromKugouSearchList(e as Map<String, dynamic>))
        .toList();
  }

  /// 酷狗歌单详情 (mobilecdn /api/v3/special/song)
  Future<PlaylistInfo> kugouPlaylist(
    String specialid, {
    int page = 1,
    int pagesize = 200,
  }) async {
    final json = await _kugouCatalogGet('/api/v3/special/song', {
      'specialid': specialid,
      'page': page,
      'pagesize': pagesize,
    });
    final list = json['data']?['info'] as List? ?? [];
    final tracks = list
        .map(
          (e) =>
              SongSearchResult.fromKugouSpecialSong(e as Map<String, dynamic>),
        )
        .toList();
    return PlaylistInfo(
      id: specialid,
      name: '酷狗歌单',
      trackCount: tracks.length,
      tracks: tracks,
    );
  }

  /// 酷狗歌单曲目分页（mobilecdn 原生支持 page/pagesize）。
  Future<PlaylistTrackPage> kugouPlaylistTracks(
    String specialid, {
    int page = 1,
    int limit = 20,
  }) async {
    final safePage = page < 1 ? 1 : page;
    final safeLimit = limit.clamp(1, 100);
    final json = await _kugouCatalogGet('/api/v3/special/song', {
      'specialid': specialid,
      'page': safePage,
      'pagesize': safeLimit,
    });
    final data = json['data'];
    final list = data is Map ? data['info'] as List? ?? const [] : const [];
    final tracks = list
        .whereType<Map>()
        .map(
          (song) => SongSearchResult.fromKugouSpecialSong(
            Map<String, dynamic>.from(song),
          ),
        )
        .toList();
    final rawTotal = data is Map ? data['total'] : null;
    final total = rawTotal is num
        ? rawTotal.toInt()
        : int.tryParse(rawTotal?.toString() ?? '');
    return PlaylistTrackPage(tracks: tracks, total: total);
  }

  /// QQ 歌单详情首屏；官方接口只返回当前 20 首，不再下载完整大歌单。
  Future<PlaylistInfo> qqPlaylist(String tid) async {
    try {
      final data = await _qqPlaylistData(tid, limit: 20, offset: 0);
      final rawDirInfo = data['dirinfo'];
      final dirInfo = rawDirInfo is Map
          ? Map<String, dynamic>.from(rawDirInfo)
          : <String, dynamic>{};
      final rows = data['songlist'] as List? ?? const [];
      final tracks = rows
          .whereType<Map>()
          .map(
            (row) =>
                SongSearchResult.fromQQMusicu(Map<String, dynamic>.from(row)),
          )
          .toList(growable: false);
      final rawCreator = dirInfo['creator'];
      final creator = dirInfo['host_nick']?.toString().trim();
      final rawTotal = dirInfo['songnum'];
      final title = dirInfo['title']?.toString().trim() ?? '';
      if (dirInfo.isEmpty || title.isEmpty) {
        throw const ApiException('PLAYLIST_NOT_FOUND', '未找到歌单，请检查链接或 ID');
      }
      return PlaylistInfo(
        id: (dirInfo['id'] ?? tid).toString(),
        name: title,
        coverUrl: CoverHelper.normalize(dirInfo['picurl']?.toString()),
        creator: creator != null && creator.isNotEmpty
            ? creator
            : rawCreator is Map
            ? rawCreator['nick']?.toString()
            : null,
        trackCount: rawTotal is num
            ? rawTotal.toInt()
            : int.tryParse(rawTotal?.toString() ?? '') ?? tracks.length,
        description: dirInfo['desc']?.toString(),
        tracks: tracks,
      );
    } catch (error) {
      debugPrint('QQ 官方歌单详情失败，切换兼容线路: $error');
      final json = await _httpGet(
        qqBaseUrl,
        '/songlist',
        {'id': tid},
        timeout: _catalogFallbackTimeout,
        maxAttempts: 1,
      );
      final rawData = json['data'] ?? json;
      if (rawData is! Map) {
        throw const ApiException('PLAYLIST_NOT_FOUND', '未找到歌单，请检查链接或 ID');
      }
      final data = Map<String, dynamic>.from(rawData);
      final rawId = data['dissid'] ?? data['dirid'];
      final rawName = data['dissname']?.toString().trim() ?? '';
      if (rawId == null || rawId.toString().trim().isEmpty || rawName.isEmpty) {
        throw const ApiException('PLAYLIST_NOT_FOUND', '未找到歌单，请检查链接或 ID');
      }
      return PlaylistInfo.fromQQDetail(data);
    }
  }

  /// QQ 官方歌单曲目分页；每次网络响应只包含当前页。
  Future<PlaylistTrackPage> qqPlaylistTracks(
    String tid, {
    int limit = 20,
    int offset = 0,
  }) async {
    final safeLimit = limit.clamp(1, 100);
    final safeOffset = offset < 0 ? 0 : offset;
    try {
      final data = await _qqPlaylistData(
        tid,
        limit: safeLimit,
        offset: safeOffset,
      );
      final rawList = data['songlist'] as List? ?? const [];
      final tracks = rawList
          .whereType<Map>()
          .map(
            (song) =>
                SongSearchResult.fromQQMusicu(Map<String, dynamic>.from(song)),
          )
          .toList(growable: false);
      final dirInfo = data['dirinfo'];
      final rawTotal = dirInfo is Map ? dirInfo['songnum'] : null;
      final total = rawTotal is num
          ? rawTotal.toInt()
          : int.tryParse(rawTotal?.toString() ?? '');
      return PlaylistTrackPage(tracks: tracks, total: total);
    } catch (error) {
      debugPrint('QQ 官方歌单分页失败，切换兼容线路: $error');
      final json = await _httpGet(
        qqBaseUrl,
        '/songlist',
        {'id': tid, 'song_begin': safeOffset, 'song_num': safeLimit},
        timeout: _catalogFallbackTimeout,
        maxAttempts: 1,
      );
      final rawData = json['data'] ?? json;
      final data = rawData is Map
          ? Map<String, dynamic>.from(rawData)
          : <String, dynamic>{};
      final rawList = data['songlist'] as List? ?? const [];
      final allTracks = rawList
          .whereType<Map>()
          .map(
            (song) =>
                SongSearchResult.fromQQDirect(Map<String, dynamic>.from(song)),
          )
          .toList();
      final rawTotal = data['songnum'] ?? data['total_song_num'];
      final parsedTotal = rawTotal is num
          ? rawTotal.toInt()
          : int.tryParse(rawTotal?.toString() ?? '');
      final total = parsedTotal ?? allTracks.length;
      final tracks = allTracks.length > safeLimit
          ? allTracks.skip(safeOffset).take(safeLimit).toList()
          : allTracks;
      return PlaylistTrackPage(tracks: tracks, total: total);
    }
  }

  Future<Map<String, dynamic>> _qqPlaylistData(
    String tid, {
    required int limit,
    required int offset,
  }) async {
    final response = await _qqMusicu({
      'comm': {'ct': 24, 'cv': 0},
      'req_0': {
        'module': 'music.srfDissInfo.aiDissInfo',
        'method': 'uniform_get_Dissinfo',
        'param': {
          'disstid': int.tryParse(tid) ?? tid,
          'enc_host_uin': '',
          'tag': 1,
          'userinfo': 1,
          'song_begin': offset,
          'song_num': limit,
          'onlysonglist': 0,
        },
      },
    });
    return _qqResponseData(response, 'req_0');
  }

  /// QQ 歌词。官方歌词接口直连失败后才使用旧中转。
  Future<LyricData> qqLyric(String songmid) async {
    try {
      final json = await _httpGet(
        _qqWebUrl,
        '/lyric/fcgi-bin/fcg_query_lyric_new.fcg',
        {
          'songmid': songmid,
          'format': 'json',
          'nobase64': 1,
          'g_tk': 5381,
          'loginUin': 0,
          'hostUin': 0,
          'inCharset': 'utf8',
          'outCharset': 'utf-8',
          'notice': 0,
          'platform': 'yqq.json',
          'needNewCode': 0,
          'qrc': 1,
        },
        timeout: _catalogTimeout,
        maxAttempts: 1,
        headers: _qqHeaders,
      );
      final result = _qqLyricData(json);
      if (!_hasTimedLyric(result.original) &&
          !_hasTimedLyric(result.wordSynced)) {
        throw const ApiException('QQ_LYRIC_EMPTY', 'QQ 音乐歌词内容为空');
      }
      return result;
    } catch (error) {
      debugPrint('QQ 歌词直连失败，切换兼容线路: $error');
      final json = await _httpGet(
        qqBaseUrl,
        '/lyric',
        {'songmid': songmid},
        timeout: _catalogFallbackTimeout,
        maxAttempts: 1,
      );
      return _qqLyricData(json);
    }
  }

  static LyricData _qqLyricData(Map<String, dynamic> json) {
    final rawData = json['data'];
    final data = rawData is Map ? rawData : json;
    final original = _decodeQqLyricText(data['lyric']);
    final explicitQrc = _decodeQqLyricText(
      data['qrc_lyric'] ?? (data['qrc'] is String ? data['qrc'] : null),
    );
    final embeddedQrc =
        original != null && RegExp(r'\[\d+,\d+\]').hasMatch(original)
        ? original
        : null;
    return LyricData(
      original: original,
      translated: _decodeQqLyricText(data['trans']),
      wordSynced: explicitQrc ?? embeddedQrc,
    );
  }

  static String? _decodeQqLyricText(dynamic value) {
    if (value is num || value is bool) return null;
    var text = value?.toString() ?? '';
    if (text.isEmpty) return null;
    if (!text.contains('[')) {
      try {
        final decoded = utf8.decode(base64Decode(text));
        if (decoded.contains('[') || decoded.contains('LyricContent=')) {
          text = decoded;
        }
      } on FormatException {
        // nobase64=1 正常返回明文；不是 Base64 时保持原值。
      }
    }
    final qrcXml = RegExp(r'LyricContent="([\s\S]*?)"').firstMatch(text);
    if (qrcXml != null) text = qrcXml.group(1)!;
    text = text.replaceAllMapped(RegExp(r'&#(x?[0-9A-Fa-f]+);'), (match) {
      final raw = match.group(1)!;
      final radix = raw.startsWith('x') || raw.startsWith('X') ? 16 : 10;
      final digits = radix == 16 ? raw.substring(1) : raw;
      final codePoint = int.tryParse(digits, radix: radix);
      return codePoint == null
          ? match.group(0)!
          : String.fromCharCode(codePoint);
    });
    return text
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&');
  }

  static bool _hasTimedLyric(String? value) {
    return value != null &&
        (RegExp(r'\[\d{1,3}:\d{2}').hasMatch(value) ||
            RegExp(r'\[\d+,\d+\]').hasMatch(value));
  }

  /// 解析QQ音乐播放地址 (ChKSz 兜底)
  Future<SongDetail> qqMusic(
    String mid, {
    String size = 'flac',
    Future<void>? cancelSignal,
  }) async {
    final json = await _chkszGet('/api/qq_music', {
      'mid': mid,
      'size': size,
      'type': 'json',
    }, cancelSignal: cancelSignal);
    return SongDetail.fromQQ(json);
  }

  // ======================== 统一接口 ========================

  /// 搜索指定平台歌曲
  Future<List<SongSearchResult>> search(
    MusicPlatform platform,
    String keyword,
  ) {
    switch (platform) {
      case MusicPlatform.netease:
        return neteaseSearch(keyword);
      case MusicPlatform.qq:
        return qqSearch(keyword);
      case MusicPlatform.kugou:
        return kugouSearch(keyword);
      case MusicPlatform.bilibili:
        return bilibili.search(keyword);
    }
  }

  /// 搜索可替换的歌词版本，并结合当前歌曲元数据按相关性降序排列。
  Future<List<SongSearchResult>> searchLyricCandidates({
    required MusicPlatform platform,
    required String keyword,
    required String currentName,
    required String currentArtist,
    required String currentAlbum,
  }) async {
    final results = await search(platform, keyword.trim());
    final ranked = <({SongSearchResult song, int score, int index})>[];
    for (var index = 0; index < results.length; index++) {
      final song = results[index];
      ranked.add((
        song: song,
        score: _lyricMatchScore(
          song,
          keyword: keyword,
          currentName: currentName,
          currentArtist: currentArtist,
          currentAlbum: currentAlbum,
        ),
        index: index,
      ));
    }
    ranked.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      return byScore != 0 ? byScore : a.index.compareTo(b.index);
    });
    return ranked.map((item) => item.song).toList(growable: false);
  }

  static int _lyricMatchScore(
    SongSearchResult song, {
    required String keyword,
    required String currentName,
    required String currentArtist,
    required String currentAlbum,
  }) {
    final query = _normalizeMatchText(keyword);
    final expectedName = _normalizeMatchText(currentName);
    final expectedArtist = _normalizeMatchText(currentArtist);
    final expectedAlbum = _normalizeMatchText(currentAlbum);
    final name = _normalizeMatchText(song.name);
    final artist = _normalizeMatchText(song.artist);
    final album = _normalizeMatchText(song.album);
    var score = 0;

    if (query.isNotEmpty) {
      if (name == query) {
        score += 1200;
      } else if (name.startsWith(query)) {
        score += 900;
      } else if (name.contains(query)) {
        score += 700;
      } else if (query.contains(name) && name.isNotEmpty) {
        score += 450;
      }
    }

    if (expectedName.isNotEmpty) {
      if (name == expectedName) {
        score += 500;
      } else if (name.contains(expectedName) || expectedName.contains(name)) {
        score += 220;
      }
    }
    if (expectedArtist.isNotEmpty) {
      if (artist == expectedArtist) {
        score += 320;
      } else if (artist.contains(expectedArtist) ||
          expectedArtist.contains(artist)) {
        score += 140;
      }
    }
    if (album.isNotEmpty && album == expectedAlbum) {
      score += 180;
    }
    return score;
  }

  /// 解析播放地址
  Future<SongDetail> resolve(MusicPlatform platform, String id) {
    switch (platform) {
      case MusicPlatform.netease:
        return neteaseMusic(id);
      case MusicPlatform.qq:
        return qqMusic(id);
      case MusicPlatform.kugou:
        return kugouMusic(id);
      case MusicPlatform.bilibili:
        throw UnsupportedError('B站播放需要当前分P信息');
    }
  }

  /// 获取歌词
  Future<LyricData?> getLyric(MusicPlatform platform, String id) async {
    return switch (platform) {
      MusicPlatform.netease => neteaseLyric(id),
      MusicPlatform.qq => qqLyric(id),
      MusicPlatform.kugou => kugouPublicLyric(id),
      MusicPlatform.bilibili => null,
    };
  }
}

class _NeteasePlaylistIndex {
  final List<String> trackIds;
  final int total;
  final PlaylistInfo? summary;

  const _NeteasePlaylistIndex({
    required this.trackIds,
    required this.total,
    required this.summary,
  });
}

class ApiException implements Exception {
  final String code;
  final String message;
  const ApiException(this.code, this.message);

  @override
  String toString() => '[$code] $message';
}

class _PlaybackCancellation {
  final Completer<void> _completer = Completer<void>();
  bool _cancelled = false;
  String? _reason;

  bool get isCancelled => _cancelled;
  String? get reason => _reason;
  Future<void> get future => _completer.future;

  void cancel({String? reason}) {
    _reason ??= reason;
    if (_cancelled) return;
    _cancelled = true;
    _completer.complete();
  }
}

class _PlaybackGroupFailure implements Exception {
  final List<String> failures;

  _PlaybackGroupFailure(Iterable<String> failures)
    : failures = List<String>.unmodifiable(failures);
}
