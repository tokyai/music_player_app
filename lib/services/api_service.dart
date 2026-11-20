import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/playback_source_config.dart';
import '../models/remote_playback.dart';
import '../models/song.dart';
import '../utils/song_source_matcher.dart';
import 'bilibili_service.dart';
import 'bounded_http_response.dart';
import 'qing_gateway_auth.dart';
import 'playback_resolver_service.dart';

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
  static const _xinghaiTokenTimeout = Duration(seconds: 3);
  static const _xinghaiTokenLifetime = Duration(minutes: 4);
  static const _catalogTimeout = Duration(seconds: 5);
  static const _catalogFallbackTimeout = Duration(seconds: 8);
  static const _probeTimeout = Duration(seconds: 4);
  static const _automaticPlaybackTimeout = Duration(seconds: 20);
  static const _manualPlaybackTimeout = Duration(seconds: 14);
  static const _retryDelay = Duration(milliseconds: 350);
  static const _maxJsonResponseBytes = 5 * 1024 * 1024;
  static const _maxProbeResponseBytes = 64 * 1024;
  static const _maxQualityDowngrades = 3;
  // 精确曲名（70 分）加匹配歌手（至少 20 分），避免用现场版或翻唱兜底。
  static const _gdMinimumMatchScore = 90;
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
  String? _qingDeviceId;
  Future<String>? _xinghaiTokenRequest;
  _PlaybackCancellation? _xinghaiTokenCancellation;
  String? _xinghaiToken;
  DateTime? _xinghaiTokenCreatedAt;
  PlaybackSourceConfig? _xinghaiTokenConfig;
  String? _gdMatchKey;
  String? _gdMatchedId;
  final Set<String> _gdAttemptedBitrates = <String>{};
  bool _closed = false;
  int _playbackGeneration = 0;
  _PlaybackCancellation? _activePlaybackCancellation;
  final PlaybackResolverService _playbackResolver;
  final bool _useRemotePlayback;
  PlaybackSourceCatalog? _playbackSourceCatalog;

  PlaybackSourceCatalog? get playbackSourceCatalog => _playbackSourceCatalog;

  ApiService({
    required this.apiKey,
    BilibiliService? bilibili,
    PlaybackSourceConfig? playbackSourceConfig,
    PlaybackResolverService? playbackResolver,
    bool useRemotePlayback = true,
  }) : _playbackResolver = playbackResolver ?? PlaybackResolverService(),
       _useRemotePlayback = useRemotePlayback,
       bilibili = bilibili ?? BilibiliService(),
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
    _clearXinghaiTokenState();
    _gdMatchKey = null;
    _gdMatchedId = null;
    _gdAttemptedBitrates.clear();
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
    _clearXinghaiTokenState();
    _gdMatchKey = null;
    _gdMatchedId = null;
    _gdAttemptedBitrates.clear();
    _client.close();
    _playbackResolver.close();
    _qingDeviceId = null;
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
          totalTimeout: timeout,
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
          totalTimeout: timeout,
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
    final uri = _endpointUri(
      _playbackSourceConfig.chkszBaseUrl,
      path,
      _chkszQuery(params),
    );
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
      if (res.statusCode == 401) {
        throw const ApiException('API_KEY_INVALID', 'ChKSz API Key 无效或已过期');
      }
      throw ApiException('HTTP_${res.statusCode}', '服务暂时不可用');
    }
    final dynamic body;
    try {
      body = json.decode(utf8.decode(res.bodyBytes));
    } on FormatException {
      throw const ApiException('INVALID_RESPONSE', '服务返回了无效数据');
    }
    if (body is Map<String, dynamic>) {
      if (body['code']?.toString() == '401') {
        throw const ApiException('API_KEY_INVALID', 'ChKSz API Key 无效或已过期');
      }
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

  /// 解析 QingMusic 播放地址，官方网关自动使用 v1.4.1 请求签名。
  ///
  /// [id] 为原平台歌曲标识，[quality] 按该平台映射；自定义服务继续原来的
  /// JSON POST 契约，不执行远程脚本，也不向自定义地址发送官方认证头。
  Future<SongDetail> qingMusic(
    MusicPlatform platform,
    String id, {
    required String quality,
    Future<void>? cancelSignal,
  }) async {
    final uri = Uri.parse(_playbackSourceConfig.qingMusicUrl);
    final payload = <String, dynamic>{
      'source': switch (platform) {
        MusicPlatform.local => throw UnsupportedError('本地音频不使用在线接口'),
        MusicPlatform.qq => 'tx',
        MusicPlatform.netease => 'wy',
        MusicPlatform.kugou => 'kg',
        MusicPlatform.bilibili => throw UnsupportedError('B站使用官方播放接口'),
      },
      'rid': id,
      'level': _qingMusicLevel(platform, quality),
    };
    final http.Response response;
    try {
      response = await _postJson(
        uri,
        payload,
        headers: _qingAuthHeaders(uri, payload),
        timeout: _resolverTimeout,
        maxAttempts: 1,
        cancelSignal: cancelSignal,
      );
    } on ApiException {
      rethrow;
    } catch (_) {
      throw const ApiException('QING_NETWORK', 'QingMusic 网络请求失败');
    }
    final httpError = response.statusCode < 200 || response.statusCode >= 300
        ? ApiException('QING_HTTP_${response.statusCode}', 'QingMusic 服务暂时不可用')
        : null;
    final dynamic body;
    try {
      body = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      if (httpError != null) throw httpError;
      throw const ApiException('QING_INVALID_RESPONSE', 'QingMusic 返回了无效数据');
    }
    if (body is! Map) {
      if (httpError != null) throw httpError;
      throw const ApiException('QING_INVALID_RESPONSE', 'QingMusic 返回格式错误');
    }
    final result = Map<String, dynamic>.from(body);
    // 新版官方网关要求签名及票据，升级门禁不能通过降音质解决。
    final responseCode = result['code']?.toString();
    if (responseCode == 'APP_UPGRADE_REQUIRED' ||
        responseCode?.startsWith('APP_SIGN_') == true) {
      throw const ApiException(
        'QING_UPGRADE_REQUIRED',
        'QingMusic 客户端认证已失效，请更新音源或使用自动备用',
      );
    }
    if (httpError != null) throw httpError;
    if (result['code']?.toString() != '0') {
      throw ApiException(
        'QING_${result['code'] ?? 'FAILED'}',
        result['message']?.toString() ?? 'QingMusic 解析失败',
      );
    }
    // 复用统一响应校验，授权接口声明的加密流也不能交给原生播放器。
    return _resolvedSongDetail(result, 'QING');
  }

  Map<String, String> _qingAuthHeaders(Uri uri, Map<String, dynamic> payload) {
    _ensureOpen();
    if (!QingGatewayAuth.supports(uri)) return const {};
    // 匿名设备标识只保留一个；每次签名绑定当前 JSON 和新的随机 nonce。
    try {
      final deviceId = _qingDeviceId ??= QingGatewayAuth.createDeviceId();
      return QingGatewayAuth.headersFor(
        uri,
        jsonEncode(payload),
        deviceId: deviceId,
      );
    } catch (_) {
      throw const ApiException(
        'QING_SIGN_UNAVAILABLE',
        '无法生成 QingMusic 客户端认证参数',
      );
    }
  }

  static String _qingMusicLevel(MusicPlatform platform, String quality) {
    switch (platform) {
      case MusicPlatform.local:
        throw UnsupportedError('本地音频不使用在线接口');
      case MusicPlatform.netease:
        return switch (quality) {
          'standard' => 'standard',
          'exhigh' => 'exhigh',
          'lossless' => 'lossless',
          'hires' => 'hires',
          'sky' => 'sky',
          'jyeffect' => 'jyeffect',
          _ => 'jymaster',
        };
      case MusicPlatform.qq:
        return switch (quality) {
          '128k' => 'standard',
          '320k' => 'exhigh',
          'master' => 'jymaster',
          _ => 'lossless',
        };
      case MusicPlatform.kugou:
        return switch (quality) {
          '128k' => 'standard',
          '320k' => 'exhigh',
          'master' => 'clear',
          'hires' => 'hires',
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
  /// 同步服务端能力；应用关闭后的响应不能替换当前快照。
  Future<PlaybackSourceCatalog> loadPlaybackSources() async {
    _ensureOpen();
    final catalog = await _playbackResolver.loadSources();
    _ensureOpen();
    _playbackSourceCatalog = catalog;
    return catalog;
  }

  /// 三平台统一解析入口，生产客户端仅消费服务器结果。
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
    // 旧协议实现仅保留用于定向协议回归，不参与线上失败兜底。
    if (!_useRemotePlayback) {
      return _resolveLegacyPlayback(
        source: source,
        platform: platform,
        id: id,
        quality: quality,
        name: name,
        artist: artist,
        album: album,
        albumId: albumId,
        duration: duration,
        isCancelled: isCancelled,
        excludedSources: excludedSources,
      );
    }
    _ensureOpen();
    if (_isExternalPlaybackCancellation(isCancelled)) {
      throw const ApiException('RESOLVE_CANCELLED', '播放请求已取消');
    }
    _activePlaybackCancellation?.cancel();
    final cancellation = _PlaybackCancellation();
    _activePlaybackCancellation = cancellation;
    final generation = ++_playbackGeneration;
    Timer? poll;
    if (isCancelled != null) {
      poll = Timer.periodic(_racePollInterval, (_) {
        if (_isExternalPlaybackCancellation(isCancelled)) cancellation.cancel();
      });
    }
    try {
      final credentials = _playbackSourceConfig.credentialsForServer(
        apiKey: apiKey,
      );
      final disabledSources = _playbackSourceConfig.disabledSourceIds.toSet();
      var catalog = _playbackSourceCatalog;
      if ((credentials.length > 32 || disabledSources.length > 32) &&
          catalog == null) {
        catalog = await _playbackResolver.loadSources(
          cancelSignal: cancellation.future,
        );
        if (_closed ||
            generation != _playbackGeneration ||
            cancellation.isCancelled) {
          throw const ApiException('RESOLVE_CANCELLED', '播放请求已取消');
        }
        _playbackSourceCatalog = catalog;
      }
      if (catalog != null) {
        final activeIds = catalog.sources
            .map((item) => item.source.value)
            .toSet();
        credentials.removeWhere((id, _) => !activeIds.contains(id));
        disabledSources.removeWhere((id) => !activeIds.contains(id));
      }
      if (_isExternalPlaybackCancellation(isCancelled) ||
          cancellation.isCancelled) {
        throw const ApiException('RESOLVE_CANCELLED', '播放请求已取消');
      }
      final result = await _playbackResolver.resolve({
        'platform': platform.code,
        'id': id,
        'source': source.value,
        'quality': quality,
        'name': name,
        'artist': artist,
        'album': album,
        if (albumId != null) 'albumId': albumId,
        if (duration != null) 'duration': duration,
        'excludedSources': excludedSources.map((item) => item.value).toList(),
        'disabledSources': disabledSources.toList(),
        'credentials': credentials,
      }, cancelSignal: cancellation.future);
      if (_closed ||
          generation != _playbackGeneration ||
          cancellation.isCancelled ||
          _isExternalPlaybackCancellation(isCancelled)) {
        throw const ApiException('RESOLVE_CANCELLED', '播放请求已取消');
      }
      return result;
    } on HttpRequestCancelledException {
      throw const ApiException('RESOLVE_CANCELLED', '播放请求已取消');
    } on PlaybackServerException catch (error) {
      throw ApiException(error.code, error.message);
    } finally {
      poll?.cancel();
      cancellation.cancel();
      if (identical(_activePlaybackCancellation, cancellation)) {
        _activePlaybackCancellation = null;
      }
    }
  }

  Future<SongDetail> _resolveLegacyPlayback({
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
    Set<PlaybackSource> excludedSources = const {},
  }) async {
    _ensureOpen();
    if (platform == MusicPlatform.local) {
      throw const ApiException('SOURCE_UNSUPPORTED', '本地音频不使用在线接口');
    }
    if (platform == MusicPlatform.bilibili) {
      throw const ApiException('SOURCE_UNSUPPORTED', 'B站使用官方播放接口');
    }
    if (_isExternalPlaybackCancellation(isCancelled)) {
      throw const ApiException('RESOLVE_CANCELLED', '播放请求已取消');
    }
    final operation = _beginPlaybackOperation();
    final overallTimeout = Timer(
      source == PlaybackSource.automatic
          ? _automaticPlaybackTimeout
          : _manualPlaybackTimeout,
      () => operation.cancel(reason: 'timeout'),
    );
    final cancellationTimer = isCancelled == null
        ? null
        : Timer.periodic(_racePollInterval, (_) {
            if (_isExternalPlaybackCancellation(isCancelled)) {
              operation.cancel();
            }
          });
    try {
      if (source != PlaybackSource.automatic) {
        if (!_playbackSourceConfig.isEnabled(source)) {
          throw ApiException('SOURCE_DISABLED', '${source.label} 已在备用源配置中停用');
        }
        if (excludedSources.contains(source)) {
          throw ApiException('SOURCE_EXCLUDED', '${source.label} 已被本次播放排除');
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
        return detail.copyWith(playbackSource: source);
      }

      final candidates = _enabledPlaybackSources();
      if (candidates.isEmpty) {
        throw const ApiException('NO_PLAYBACK_SOURCE', '没有可用的备用源，请检查备用源配置');
      }

      final failures = <String>[];
      final attempted = <(PlaybackSource, String)>{};
      final unavailableSources = <PlaybackSource>{...excludedSources};
      final qualityCandidates = _qualityCandidates(platform, quality);
      for (final candidateQuality in qualityCandidates) {
        _ensurePlaybackOperationActive(operation, isCancelled);
        for (
          var groupIndex = 0;
          groupIndex < _playbackSourceGroups.length;
          groupIndex++
        ) {
          final group = _playbackSourceGroups[groupIndex]
              .where(candidates.contains)
              .where((source) => !unavailableSources.contains(source))
              .where(
                (source) => attempted.add((
                  source,
                  _effectivePlaybackQuality(source, platform, candidateQuality),
                )),
              )
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
            // 停服、鉴权和网络错误与音质无关，本轮播放不再重复请求该源。
            unavailableSources.addAll(error.unavailableSources);
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
    } catch (_) {
      _ensurePlaybackOperationActive(operation, isCancelled);
      rethrow;
    } finally {
      overallTimeout.cancel();
      cancellationTimer?.cancel();
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
    // Keep the requested quality, but reserve the bounded fallback slots for
    // lossless, high and standard instead of only other premium-only tiers.
    final fallbackStart = max(index + 1, order.length - _maxQualityDowngrades);
    return [requested, ...order.skip(fallbackStart)];
  }

  String _effectivePlaybackQuality(
    PlaybackSource source,
    MusicPlatform platform,
    String quality,
  ) => switch (source) {
    PlaybackSource.qingMusic => _qingMusicLevel(platform, quality),
    PlaybackSource.hyw => _hywPlaybackQuality(platform, quality),
    PlaybackSource.xinghai => _aggregatorQuality(platform, quality),
    PlaybackSource.gdStudio => _gdBitrate(platform, quality),
    _ => quality,
  };

  _PlaybackCancellation _beginPlaybackOperation() {
    _activePlaybackCancellation?.cancel();
    _gdMatchKey = null;
    _gdMatchedId = null;
    _gdAttemptedBitrates.clear();
    _playbackGeneration++;
    final operation = _PlaybackCancellation();
    _activePlaybackCancellation = operation;
    return operation;
  }

  void _endPlaybackOperation(_PlaybackCancellation operation) {
    if (identical(_activePlaybackCancellation, operation)) {
      _activePlaybackCancellation = null;
      _gdMatchKey = null;
      _gdMatchedId = null;
      _gdAttemptedBitrates.clear();
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
    final unavailableSources = <PlaybackSource>{};
    var remaining = sources.length;
    var finished = false;

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
      if (_qualityRetryCannotHelp(error)) unavailableSources.add(source);
      remaining--;
      if (remaining == 0) {
        finished = true;
        groupCancellation.cancel();
        if (!completer.isCompleted) {
          completer.completeError(
            _PlaybackGroupFailure(failures, unavailableSources),
          );
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
        final sourcedDetail = detail.copyWith(playbackSource: source);
        try {
          _requirePlayableUrl(sourcedDetail, source);
        } catch (error) {
          recordFailure(source, error);
          return;
        }
        finished = true;
        groupCancellation.cancel();
        if (!completer.isCompleted) completer.complete(sourcedDetail);
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

    final cancellationSubscription = operation.future.asStream().listen(
      (_) => cancelRace(),
    );
    for (final source in sources) {
      // Every source in a group starts immediately; each Future is fully
      // observed so a losing request cannot surface an unhandled exception.
      unawaited(run(source));
    }
    try {
      return await completer.future;
    } finally {
      unawaited(cancellationSubscription.cancel());
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
    // just_audio 不负责解密 QMC 文件，不能把已知加密流交给原生解码器。
    final format = detail.format?.toLowerCase();
    final path = uri.path.toLowerCase();
    if (format == 'mflac' ||
        format == 'mgg' ||
        format == 'cenc' ||
        path.endsWith('.mflac') ||
        path.endsWith('.mgg')) {
      throw ApiException(
        '${source.value.toUpperCase()}_ENCRYPTED_AUDIO',
        '${source.label} 返回了加密音频，请降低音质或更换接口',
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
          MusicPlatform.local => throw UnsupportedError('本地音频不使用在线接口'),
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
          name: name,
          artist: artist,
          album: album,
          duration: duration,
          cancelSignal: cancelSignal,
        );
      default:
        throw const ApiException('SOURCE_UNSUPPORTED', '此音源由统一服务器解析');
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
    _ensureHywPlatformSupported(platform, _playbackSourceConfig);
    final source = _aggregatorSource(platform);
    final params = <String, String>{
      'source': source,
      'platform': source,
      'songId': id,
      'songmid': id,
      if (platform == MusicPlatform.kugou) ...{'hash': id, 'mainHash': id},
      'quality': _hywPlaybackQuality(platform, quality),
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
    final uri = _endpointUri(
      _playbackSourceConfig.hywBaseUrl,
      '/api/music/url',
      params,
    );
    final headers = <String, String>{
      // HYW 发布脚本的无 LX 版本回退标识，不能沿用目录请求的浏览器 UA。
      'User-Agent': 'lx-music-request/1.0.0',
      // 中文卡密只放在已编码的 query；原生 HTTP 请求头只接受 ASCII。
      if (_playbackSourceConfig.hywCardKey.isNotEmpty &&
          !RegExp(r'[^\x20-\x7e]').hasMatch(_playbackSourceConfig.hywCardKey))
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
    const authError = ApiException(
      'HYW_KEY_INVALID',
      'HYW Card Key 无效或已过期，请更新备用源配置中的卡密',
    );
    if (response.statusCode == 401) throw authError;
    final body = _resolverResponseMap(response, 'HYW');
    if (body['code']?.toString() == '401') throw authError;
    if (body['code']?.toString() != '200') {
      throw ApiException(
        'HYW_${body['code'] ?? 'FAILED'}',
        'HYW 服务拒绝请求或未返回播放地址',
      );
    }
    return _resolvedSongDetail(body, 'HYW');
  }

  String _hywPlaybackQuality(MusicPlatform platform, String quality) {
    // v1.1.0 公益版最高声明 flac24bit；用户独立服务保留原有音质契约。
    final mapped = _aggregatorQuality(platform, quality);
    if (!_playbackSourceConfig.usesHywPublicSource) return mapped;
    return switch (mapped) {
      'master' || 'hires' || 'flac24bit' => 'flac24bit',
      _ => mapped,
    };
  }

  static void _ensureHywPlatformSupported(
    MusicPlatform platform,
    PlaybackSourceConfig config,
  ) {
    // 官方 v1.1.0 暂停酷狗，独立服务和用户授权卡密仍允许自行解析。
    if (platform == MusicPlatform.kugou && config.usesHywPublicSource) {
      throw const ApiException('HYW_SOURCE_UNSUPPORTED', 'HYW 当前公益版暂不支持酷狗');
    }
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
      MusicPlatform.local => throw UnsupportedError('本地音频不使用在线接口'),
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
    // 服务器会将令牌绑定到 IP；换网或令牌失效时，只刷新并重试一次。
    for (var attempt = 0; attempt < 2; attempt++) {
      final http.Response response;
      final headers = await _xinghaiHeaders(cancelSignal: cancelSignal);
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
        throw const ApiException('XINGHAI_NETWORK', '星海网络请求失败');
      }
      if (attempt == 0 && _xinghaiNeedsTokenRefresh(response)) {
        if (_xinghaiToken == headers['X-Token']) {
          _xinghaiToken = null;
          _xinghaiTokenCreatedAt = null;
        }
        continue;
      }
      if (response.statusCode == 401) {
        throw _xinghaiAuthorizationError(_playbackSourceConfig);
      }
      final body = _resolverResponseMap(response, 'XINGHAI');
      if (body['code']?.toString() == '401') {
        throw _xinghaiAuthorizationError(_playbackSourceConfig);
      }
      if (body['code']?.toString() != '200') {
        throw ApiException(
          'XINGHAI_${body['code'] ?? 'FAILED'}',
          '星海当前线路不可用，请检查授权及服务状态',
        );
      }
      return _resolvedSongDetail(body, '星海');
    }
    throw const ApiException('XINGHAI_TOKEN_INVALID', '星海服务器令牌失效');
  }

  /// 使用 GD音乐台（music.gdstudio.xyz）的公开接口解析歌曲。
  ///
  /// [name]、[artist]、[album] 和 [duration] 用于将 QQ/酷狗歌曲匹配到
  /// 当前可用的网易云线路；网易云歌曲沿用自己的 [id]。返回对应播放地址。
  Future<SongDetail> gdStudioMusic(
    MusicPlatform platform,
    String id, {
    required String quality,
    String name = '',
    String artist = '',
    String album = '',
    int? duration,
    Future<void>? cancelSignal,
  }) async {
    if (!configurableMusicPlatforms.contains(platform)) {
      throw const ApiException('SOURCE_UNSUPPORTED', '该平台不使用 GDStudio 解析');
    }
    final base = Uri.parse(_playbackSourceConfig.gdStudioUrl);
    // GD 当前公开源不包含 QQ/酷狗，先按元数据找同一首歌再使用网易云 ID。
    final resolvedId = platform == MusicPlatform.netease
        ? id
        : await _gdStudioMatchedId(
            platform,
            id,
            name: name,
            artist: artist,
            album: album,
            duration: duration,
            cancelSignal: cancelSignal,
          );

    final operation = _activePlaybackCancellation;
    Future<SongDetail> requestWithBitrate(String bitrate) async {
      // 最高档内部降级后，外层不能再次请求同一码率；状态只活到本次解析结束。
      if (operation != null &&
          identical(_activePlaybackCancellation, operation) &&
          !operation.isCancelled &&
          !_gdAttemptedBitrates.add(bitrate)) {
        throw const ApiException('GD_QUALITY_FAILED', 'GDStudio 本轮已尝试该音质');
      }
      final params = <String, String>{
        ...base.queryParameters,
        'use_xbridge3': 'true',
        'loader_name': 'forest',
        'need_sec_link': '1',
        'sec_link_scene': 'im',
        'theme': 'light',
        'types': 'url',
        'source': 'netease',
        'id': resolvedId,
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

    final bitrate = _gdBitrate(platform, quality);
    try {
      return await requestWithBitrate(bitrate);
    } catch (error) {
      if (_isPlaybackCancellationError(error)) rethrow;
      // 最高档缺少资源时只降级一次；网络、鉴权和取消错误不会重复请求。
      if (!_qualityRetryCannotHelp(error) && bitrate == '999') {
        return requestWithBitrate('740');
      }
      rethrow;
    }
  }

  Future<String> _gdStudioMatchedId(
    MusicPlatform platform,
    String id, {
    required String name,
    required String artist,
    required String album,
    int? duration,
    Future<void>? cancelSignal,
  }) async {
    // 缺少曲名或歌手时无法可靠匹配，保持原歌曲的身份并报告失败。
    if (name.trim().isEmpty ||
        artist.trim().isEmpty ||
        artist.trim() == '未知歌手') {
      throw const ApiException('GD_MATCH_NOT_FOUND', 'GDStudio 换源需要曲名和歌手');
    }
    // 同一次解析降音质时复用匹配 ID；新歌曲、取消和结束解析都会释放缓存。
    final operation = _activePlaybackCancellation;
    final matchKey = jsonEncode([
      platform.code,
      id,
      name,
      artist,
      album,
      duration,
    ]);
    if (operation != null &&
        !operation.isCancelled &&
        _gdMatchKey == matchKey &&
        _gdMatchedId != null) {
      return _gdMatchedId!;
    }
    // 使用曲名和歌手发起一次有界搜索，原平台 ID 只用于关联本次请求。
    final original = SongSearchResult(
      platform: platform,
      id: id,
      name: name,
      artist: artist,
      album: album,
      duration: duration,
    );
    final base = Uri.parse(_playbackSourceConfig.gdStudioUrl);
    final uri = base.replace(
      queryParameters: {
        ...base.queryParameters,
        'types': 'search',
        'source': 'netease',
        'name': '${name.trim()} ${artist.trim()}',
        'count': '20',
        'pages': '1',
      },
    );
    final http.Response response;
    try {
      response = await _get(
        uri,
        headers: const {'User-Agent': 'LX-Music-Mobile'},
        timeout: _resolverTimeout,
        maxAttempts: 1,
        cancelSignal: cancelSignal,
      );
    } on ApiException {
      rethrow;
    } catch (_) {
      throw const ApiException('GD_NETWORK', 'GDStudio 备用搜索网络请求失败');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException('GD_HTTP_${response.statusCode}', 'GDStudio 备用搜索失败');
    }
    final dynamic rows;
    try {
      rows = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw const ApiException('GD_INVALID_RESPONSE', 'GDStudio 搜索返回了无效数据');
    }
    if (rows is! List) {
      throw const ApiException('GD_INVALID_RESPONSE', 'GDStudio 搜索返回格式错误');
    }

    // 最多检查 20 个候选；复用既有换源匹配器，并排除时长明显不同的版本。
    final candidates = <SongSearchResult>[];
    final expectedTitle = _normalizeMatchText(name);
    for (final row in rows.take(20)) {
      if (row is! Map || row['source'] != 'netease') continue;
      final candidateId = row['id']?.toString() ?? '';
      if (!RegExp(r'^[0-9]{1,20}$').hasMatch(candidateId)) continue;
      final candidateName = row['name']?.toString() ?? '';
      if (_normalizeMatchText(candidateName) != expectedTitle) continue;
      final rawArtist = row['artist'];
      final candidateArtist = rawArtist is List
          ? rawArtist.whereType<String>().join(' / ')
          : rawArtist?.toString() ?? '';
      final extra = row['extra_data'];
      final candidateDuration = int.tryParse(
        (extra is Map ? extra['duration'] : row['duration'])?.toString() ?? '',
      );
      if (duration != null &&
          candidateDuration != null &&
          (duration - candidateDuration).abs() > 10) {
        continue;
      }
      candidates.add(
        SongSearchResult(
          platform: MusicPlatform.netease,
          id: candidateId,
          name: candidateName,
          artist: candidateArtist,
          album: row['album']?.toString() ?? '',
          duration: candidateDuration,
        ),
      );
    }
    final match = SongSourceMatcher.bestMatch(original, candidates);
    if (match == null ||
        SongSourceMatcher.score(original, match) < _gdMinimumMatchScore) {
      throw const ApiException('GD_MATCH_NOT_FOUND', 'GDStudio 未找到同一首歌曲');
    }
    if (operation != null &&
        !operation.isCancelled &&
        identical(_activePlaybackCancellation, operation)) {
      _gdMatchKey = matchKey;
      _gdMatchedId = match.id;
    }
    return match.id;
  }

  Future<Map<String, String>> _xinghaiHeaders({
    PlaybackSourceConfig? config,
    bool useCache = true,
    Future<void>? cancelSignal,
  }) async {
    _ensureOpen();
    final effective = config ?? _playbackSourceConfig;
    // 当前配置的令牌请求由服务持有，切歌仅取消等待；草稿探测单独请求。
    final request = useCache && effective == _playbackSourceConfig
        ? _xinghaiServerToken()
        : _requestXinghaiToken(effective, cancelSignal: cancelSignal);
    final String token;
    try {
      token = await awaitWithCancellation(request, cancelSignal);
    } on HttpRequestCancelledException {
      throw const ApiException('RESOLVE_CANCELLED', '播放请求已取消');
    }
    _ensureOpen();
    return {
      'X-Token': token,
      'X-Client': effective.xinghaiClient,
      if (effective.xinghaiLicenseKey.isNotEmpty)
        'X-License': effective.xinghaiLicenseKey,
      'User-Agent': 'lx-music',
    };
  }

  Future<String> _xinghaiServerToken() {
    _ensureOpen();
    final config = _playbackSourceConfig;
    final createdAt = _xinghaiTokenCreatedAt;
    if (_xinghaiToken != null &&
        _xinghaiTokenConfig == config &&
        createdAt != null &&
        DateTime.now().difference(createdAt) < _xinghaiTokenLifetime) {
      return Future<String>.value(_xinghaiToken!);
    }
    final pending = _xinghaiTokenRequest;
    if (pending != null) return pending;

    // 单飞请求最多保留一个；改配置和关闭服务时主动取消底层 HTTP。
    final cancellation = _PlaybackCancellation();
    _xinghaiTokenCancellation = cancellation;
    late final Future<String> request;
    request = () async {
      try {
        final token = await _requestXinghaiToken(
          config,
          cancelSignal: cancellation.future,
        );
        // 迟到响应不能覆盖新配置或已释放服务的状态。
        if (!_closed &&
            identical(_xinghaiTokenRequest, request) &&
            _playbackSourceConfig == config) {
          _xinghaiToken = token;
          _xinghaiTokenCreatedAt = DateTime.now();
          _xinghaiTokenConfig = config;
        }
        return token;
      } finally {
        if (identical(_xinghaiTokenRequest, request)) {
          _xinghaiTokenRequest = null;
        }
        if (identical(_xinghaiTokenCancellation, cancellation)) {
          _xinghaiTokenCancellation = null;
        }
        cancellation.cancel();
      }
    }();
    _xinghaiTokenRequest = request;
    return request;
  }

  Future<String> _requestXinghaiToken(
    PlaybackSourceConfig config, {
    Future<void>? cancelSignal,
  }) async {
    // v3.2.20 明确要求从聚合接口同目录的 token.php 获取服务器签发令牌。
    final base = Uri.parse(config.xinghaiUrl);
    final directory = base.path.replaceFirst(RegExp(r'/+$'), '');
    final uri = base.replace(
      path: '$directory/token.php',
      queryParameters: {
        ...base.queryParameters,
        'device_id': config.xinghaiDeviceId,
      },
    );
    final http.Response response;
    try {
      response = await _get(
        uri,
        headers: {'X-Client': config.xinghaiClient, 'User-Agent': 'lx-music'},
        timeout: _xinghaiTokenTimeout,
        maxAttempts: 1,
        maxBytes: _maxProbeResponseBytes,
        cancelSignal: cancelSignal,
      );
    } on ApiException {
      rethrow;
    } catch (_) {
      throw const ApiException('XINGHAI_TOKEN_NETWORK', '获取星海服务器令牌失败');
    }
    _ensureOpen();
    // 只接受短且可作为请求头的令牌，避免异常响应进入后续原生请求。
    final body = _resolverResponseMap(response, 'XINGHAI_TOKEN');
    final data = body['data'];
    final token = data is Map ? data['token'] : null;
    if ((body['code']?.toString() != '0' &&
            body['code']?.toString() != '200') ||
        token is! String ||
        token.isEmpty ||
        token.length > 4096 ||
        RegExp(r'[^\x21-\x7e]').hasMatch(token)) {
      throw const ApiException('XINGHAI_TOKEN_INVALID', '星海未返回有效的服务器令牌');
    }
    return token;
  }

  void _clearXinghaiTokenState() {
    _xinghaiTokenCancellation?.cancel();
    _xinghaiTokenCancellation = null;
    _xinghaiTokenRequest = null;
    _xinghaiToken = null;
    _xinghaiTokenCreatedAt = null;
    _xinghaiTokenConfig = null;
  }

  static bool _xinghaiNeedsTokenRefresh(http.Response response) {
    // 仅响应中明确的令牌错误触发刷新，歌曲不存在、授权不足等错误不重试。
    try {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      final auth = body is Map ? body['auth'] : null;
      if (auth is! Map) return false;
      final error = auth['tk_error'];
      return auth['tk_mismatch'] == true ||
          auth['device_id'] == 'untrusted-token' ||
          error != null && error != false && error != '';
    } on FormatException {
      return false;
    }
  }

  static ApiException _xinghaiAuthorizationError(PlaybackSourceConfig config) {
    // QQ 等认证线路不能靠刷新令牌或更换音质解决未授权问题。
    if (config.xinghaiLicenseKey.isEmpty) {
      return const ApiException('XINGHAI_LICENSE_REQUIRED', '星海当前线路需要有效授权卡密');
    }
    return const ApiException('XINGHAI_AUTH_FAILED', '星海授权失败，请检查卡密及上游状态');
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
    // 后端已声明加密时直接降音质，不能依赖解码器尝试识别随机数据。
    if (body['encrypted'] == true ||
        nested?['encrypted'] == true ||
        body['encryption'] == 'cenc' ||
        nested?['encryption'] == 'cenc') {
      throw ApiException(
        '${label.toUpperCase()}_ENCRYPTED_AUDIO',
        '$label 返回了加密音频',
      );
    }
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
    // 无扩展名的地址也可能返回加密流，因此优先检查后端声明的格式。
    final rawFormat = body['format'] ?? nested?['format'];
    final declaredFormat = rawFormat is String ? rawFormat.toLowerCase() : '';
    final String? format;
    if (RegExp(r'^[a-z0-9]{1,12}$').hasMatch(declaredFormat)) {
      format = declaredFormat;
    } else if (dot >= 0 && dot < path.length - 1) {
      format = path.substring(dot + 1);
    } else {
      format = null;
    }
    return SongDetail(
      name: '',
      artist: '',
      album: '',
      url: url,
      coverUrl: cover?.toString(),
      lyric: lyric,
      format: format,
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
    MusicPlatform.local => throw UnsupportedError('本地音频不使用在线接口'),
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

  static Uri _endpointUri(
    String base,
    String path,
    Map<String, String> params,
  ) {
    final uri = Uri.parse(base);
    final basePath = uri.path.replaceFirst(RegExp(r'/+$'), '');
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    return uri.replace(
      path: '$basePath$normalizedPath',
      queryParameters: {...uri.queryParameters, ...params},
    );
  }

  static bool _qualityRetryCannotHelp(Object error) {
    if (error is! ApiException) return false;
    final code = error.code;
    // 这些失败发生在网络或权限层，改变码率不会改变结果。
    return code.endsWith('_NETWORK') ||
        code.endsWith('_INVALID_RESPONSE') ||
        RegExp(r'(?:^|_)HTTP_(401|404|410|429)$').hasMatch(code) ||
        const {
          'API_KEY_REQUIRED',
          'API_KEY_INVALID',
          'RESPONSE_TOO_LARGE',
          'SOURCE_DISABLED',
          'SOURCE_UNSUPPORTED',
          'QING_UPGRADE_REQUIRED',
          'QING_SIGN_UNAVAILABLE',
          'HYW_KEY_INVALID',
          'HYW_SOURCE_UNSUPPORTED',
          'XINGHAI_TOKEN_INVALID',
          'XINGHAI_LICENSE_REQUIRED',
          'XINGHAI_AUTH_FAILED',
          'GD_MATCH_NOT_FOUND',
          'XINGHAI_401',
          'XINGHAI_403',
          'XINGHAI_429',
          'XINGHAI_HTTP_403',
          '401',
          '404',
          '429',
        }.contains(code);
  }

  static String _safeResolverFailure(Object error) {
    if (error is ApiException) {
      if (error.code.endsWith('_ENCRYPTED_AUDIO')) return '当前音质返回加密音频';
      return switch (error.code) {
        'API_KEY_REQUIRED' => '需要配置 API Key',
        'API_KEY_INVALID' => 'API Key 无效或已过期',
        'SOURCE_DISABLED' => '音源已停用',
        'SOURCE_UNSUPPORTED' => '音源不支持当前平台',
        'QING_UPGRADE_REQUIRED' => '客户端认证已失效，请更新音源',
        'QING_SIGN_UNAVAILABLE' => '无法生成客户端认证参数',
        'HYW_KEY_INVALID' || 'HYW_HTTP_401' => 'Card Key 无效或已过期，请更新卡密',
        'HYW_SOURCE_UNSUPPORTED' => '当前公益版暂不支持酷狗，请选择其他音源',
        'XINGHAI_LICENSE_REQUIRED' => '当前线路需要有效授权卡密',
        'XINGHAI_AUTH_FAILED' => '授权失败，请检查卡密及上游状态',
        'XINGHAI_TOKEN_NETWORK' => '无法获取服务器令牌',
        'XINGHAI_TOKEN_INVALID' => '服务器未返回有效令牌',
        'GD_MATCH_NOT_FOUND' => '未找到曲名、歌手和版本相符的备用歌曲',
        _ =>
          RegExp(r'^[A-Za-z0-9_]{1,64}$').hasMatch(error.code)
              ? '解析失败（${error.code}）'
              : '解析失败',
      };
    }
    return '网络请求失败';
  }

  /// Probes one configured resolver with a small request.
  ///
  /// 检查连接、响应速度和服务明确返回的业务/鉴权错误；实际歌曲能否播放
  /// 仍取决于平台、歌曲和后端状态。星海探测会取得当前网络的服务器令牌。
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

    if (source == PlaybackSource.chksz && apiKey.trim().isEmpty) {
      return const PlaybackSourceTestResult(
        source: PlaybackSource.chksz,
        reachable: false,
        latencyMs: 0,
        statusCode: null,
        message: '需要先填写 ChKSz API Key',
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
            MusicPlatform.local => throw UnsupportedError('本地音频不使用在线接口'),
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
            _endpointUri(effective.chkszBaseUrl, endpoint, params),
            timeout: _probeTimeout,
            maxAttempts: 1,
            maxBytes: _maxProbeResponseBytes,
            cancelSignal: cancelSignal,
          );
        case PlaybackSource.qingMusic:
          final base = Uri.parse(effective.qingMusicUrl);
          final payload = <String, dynamic>{
            'source': switch (platform) {
              MusicPlatform.local => throw UnsupportedError('本地音频不使用在线接口'),
              MusicPlatform.qq => 'tx',
              MusicPlatform.netease => 'wy',
              MusicPlatform.kugou => 'kg',
              MusicPlatform.bilibili => 'tx',
            },
            'rid': QingGatewayAuth.supports(base)
                ? _probeSongId(platform)
                : '__probe__',
            'level': 'standard',
          };
          response = await _postJson(
            base,
            payload,
            headers: _qingAuthHeaders(base, payload),
            timeout: _probeTimeout,
            maxAttempts: 1,
            maxBytes: _maxProbeResponseBytes,
            cancelSignal: cancelSignal,
          );
        case PlaybackSource.hyw:
          _ensureHywPlatformSupported(platform, effective);
          final sourceCode = _aggregatorSource(platform);
          final params = <String, String>{
            'source': sourceCode,
            'platform': sourceCode,
            'songId': effective.usesHywPublicSource
                ? _probeSongId(platform)
                : '__probe__',
            'songmid': effective.usesHywPublicSource
                ? _probeSongId(platform)
                : '__probe__',
            'quality': _aggregatorQuality(platform, '128k'),
            if (effective.hywCardKey.isNotEmpty) 'key': effective.hywCardKey,
          };
          response = await _get(
            _endpointUri(effective.hywBaseUrl, '/api/music/url', params),
            headers: {
              'User-Agent': 'lx-music-request/1.0.0',
              if (effective.hywCardKey.isNotEmpty &&
                  !RegExp(r'[^\x20-\x7e]').hasMatch(effective.hywCardKey))
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
            MusicPlatform.local => throw UnsupportedError('本地音频不使用在线接口'),
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
            headers: await _xinghaiHeaders(
              config: effective,
              useCache: false,
              cancelSignal: cancelSignal,
            ),
            timeout: _probeTimeout,
            maxAttempts: 1,
            maxBytes: _maxProbeResponseBytes,
            cancelSignal: cancelSignal,
          );
        case PlaybackSource.gdStudio:
          final base = Uri.parse(effective.gdStudioUrl);
          final sourceCode = switch (platform) {
            MusicPlatform.local => throw UnsupportedError('本地音频不使用在线接口'),
            MusicPlatform.qq => 'netease',
            MusicPlatform.netease => 'netease',
            MusicPlatform.kugou => 'netease',
            MusicPlatform.bilibili => 'netease',
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
      final businessError = _probeBusinessError(source, response, effective);
      final String message;
      if (businessError != null) {
        message = _safeResolverFailure(businessError);
      } else if (statusCode >= 200 && statusCode < 300) {
        message = 'HTTP $statusCode';
      } else {
        message = 'HTTP $statusCode（网络可达，接口返回错误）';
      }
      return PlaybackSourceTestResult(
        source: source,
        reachable: reachable,
        latencyMs: stopwatch.elapsedMilliseconds,
        statusCode: statusCode,
        message: message,
        errorCode: businessError?.code,
      );
    } catch (error) {
      stopwatch.stop();
      if (_isPlaybackCancellationError(error)) rethrow;
      return PlaybackSourceTestResult(
        source: source,
        reachable: false,
        latencyMs: stopwatch.elapsedMilliseconds,
        statusCode: null,
        message: _safeProbeFailure(error),
        errorCode: error is ApiException ? error.code : null,
      );
    }
  }

  static ApiException? _probeBusinessError(
    PlaybackSource source,
    http.Response response,
    PlaybackSourceConfig config,
  ) {
    // 鉴权错误也可能返回 HTML/空响应，先识别 HTTP 状态再读取业务码。
    if (response.statusCode == 401) {
      if (source == PlaybackSource.chksz) {
        return const ApiException('API_KEY_INVALID', 'ChKSz API Key 无效或已过期');
      }
      if (source == PlaybackSource.hyw) {
        return const ApiException('HYW_KEY_INVALID', 'HYW Card Key 无效或已过期');
      }
      if (source == PlaybackSource.xinghai) {
        return _xinghaiAuthorizationError(config);
      }
    }
    // 网关经常用 HTTP 200 返回停服或卡密错误，不能把它显示为正常响应。
    final dynamic body;
    try {
      body = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      return null;
    }
    if (body is! Map) return null;
    final code = body['code']?.toString();
    if (code == null || code == '0' || code == '200') return null;
    if (source == PlaybackSource.qingMusic &&
        (code == 'APP_UPGRADE_REQUIRED' || code.startsWith('APP_SIGN_'))) {
      return const ApiException('QING_UPGRADE_REQUIRED', '客户端认证已失效，请更新音源');
    }
    if (source == PlaybackSource.hyw && code == '401') {
      return const ApiException('HYW_KEY_INVALID', 'HYW Card Key 无效或已过期');
    }
    if (source == PlaybackSource.chksz && code == '401') {
      return const ApiException('API_KEY_INVALID', 'ChKSz API Key 无效或已过期');
    }
    if (source == PlaybackSource.xinghai && code == '401') {
      return _xinghaiAuthorizationError(config);
    }
    final safeCode = RegExp(r'^[A-Za-z0-9_]{1,64}$').hasMatch(code)
        ? code
        : 'FAILED';
    return ApiException('${source.value.toUpperCase()}_$safeCode', '接口返回业务错误');
  }

  static String _probeSongId(MusicPlatform platform) => switch (platform) {
    // 使用已核对的标准音质样本，避免合法认证因虚构歌曲 ID 被误报失败。
    MusicPlatform.netease => '347230',
    MusicPlatform.qq || MusicPlatform.bilibili => '0039MnYb0qxYhV',
    MusicPlatform.kugou => 'c41e80a18d1448fa47086372999c7f43',
    MusicPlatform.local => '__probe__',
  };

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
        .where(
          (source) =>
              source != PlaybackSource.chksz || apiKey.trim().isNotEmpty,
        )
        .toList(growable: false);
    if (sources.isEmpty) return const [];

    final results = List<PlaybackSourceTestResult?>.filled(
      sources.length,
      null,
    );
    final workerCount = min(max(1, maxConcurrent), 3);
    var nextIndex = 0;
    var cancelled = false;

    Future<void> worker() async {
      while (!cancelled) {
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
          if (_isPlaybackCancellationError(error)) {
            cancelled = true;
            rethrow;
          }
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
    if (error is ApiException) return _safeResolverFailure(error);
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
      MusicPlatform.local => throw UnsupportedError('本地音频不使用在线接口'),
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
      case MusicPlatform.local:
        throw UnsupportedError('本地音频不使用在线接口');
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
    if (!configurableMusicPlatforms.contains(platform)) {
      throw UnsupportedError('此平台不使用统一音源解析');
    }
    return resolvePlayback(
      source: PlaybackSource.automatic,
      platform: platform,
      id: id,
      quality: platform == MusicPlatform.netease ? 'exhigh' : '320k',
    );
  }

  /// 获取歌词
  Future<LyricData?> getLyric(MusicPlatform platform, String id) async {
    return switch (platform) {
      MusicPlatform.local => throw UnsupportedError('本地音频不使用在线接口'),
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
  final Set<PlaybackSource> unavailableSources;

  _PlaybackGroupFailure(
    Iterable<String> failures,
    Iterable<PlaybackSource> unavailableSources,
  ) : failures = List<String>.unmodifiable(failures),
      unavailableSources = Set<PlaybackSource>.unmodifiable(unavailableSources);
}
