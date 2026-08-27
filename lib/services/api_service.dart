import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/song.dart';
import 'bilibili_service.dart';
import 'bounded_http_response.dart';

/// 音乐 API 服务层
/// - 网易云: interface.music.163.com 官方公开目录接口
/// - 酷狗: mobilecdn.kugou.com 官方公开目录接口
/// - QQ音乐: u.y.qq.com musicu 官方公开目录接口
/// - 三平台播放地址解析: 按用户选择使用 ChKSz 或 QingMusic
///
/// 搜索、歌单、歌词、MV 等功能优先直连平台接口，旧 nginx 反代仅在直连
/// 失败时兜底。播放地址解析不参与自动切换，仍按设置中的音源选择。
class ApiService {
  // 播放解析等请求保留一次重试；目录直连使用更短的单次超时后快速降级。
  static const _requestTimeout = Duration(seconds: 10);
  static const _catalogTimeout = Duration(seconds: 5);
  static const _catalogFallbackTimeout = Duration(seconds: 8);
  static const _retryDelay = Duration(milliseconds: 350);
  static const _maxJsonResponseBytes = 5 * 1024 * 1024;
  // A playlist index may contain up to 100,000 IDs. Retain only the active
  // index so visiting several large playlists cannot keep their ID arrays
  // alive for the lifetime of the player.
  static const _maxNeteasePlaylistIndexes = 1;
  static const _catalogUserAgent =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
      'Chrome/120 Mobile Safari/537.36';

  // ChKSz API 经服务器中转，避免移动网络直连 HTTPS 不稳定。
  static const String _chkszUrl = 'http://161.118.252.183/api-chksz';
  static const String _qingMusicUrl =
      'https://musicserver.haitangw.cc/v1/music/resolve-url';
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

  // 旧 API 中转仅作网络兼容兜底。
  static const String neteaseBaseUrl = 'http://161.118.252.183/api-netease';
  static const String kugouSearchBase =
      'http://161.118.252.183/api-kugou-search';
  static const String qqBaseUrl = 'http://161.118.252.183/api-qq';

  final http.Client _client = http.Client();
  final Map<String, Future<_NeteasePlaylistIndex>> _neteasePlaylistIndexes = {};
  final BilibiliService bilibili;
  String apiKey;

  ApiService({required this.apiKey, BilibiliService? bilibili})
    : bilibili = bilibili ?? BilibiliService();

  void setApiKey(String key) {
    apiKey = key;
  }

  void close() {
    // Playlist indexes can contain tens of thousands of IDs. Release them
    // together with the HTTP client when the owning player is disposed.
    _neteasePlaylistIndexes.clear();
    _client.close();
    bilibili.dispose();
  }

  Future<http.Response> _get(
    Uri uri, {
    Duration timeout = _requestTimeout,
    int maxAttempts = 2,
    Map<String, String> headers = const {},
  }) async {
    Exception? lastError;
    final attempts = maxAttempts < 1 ? 1 : maxAttempts;
    for (var attempt = 0; attempt < attempts; attempt++) {
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
          maxBytes: _maxJsonResponseBytes,
          timeout: timeout,
        );
        if (attempt < attempts - 1 && response.statusCode >= 500) {
          await Future<void>.delayed(_retryDelay);
          continue;
        }
        return response;
      } on HttpResponseTooLargeException {
        throw const ApiException('RESPONSE_TOO_LARGE', '服务返回的数据过大');
      } on Exception catch (error) {
        lastError = error;
        if (attempt < attempts - 1) {
          await Future<void>.delayed(_retryDelay);
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
  }) async {
    Exception? lastError;
    final attempts = maxAttempts < 1 ? 1 : maxAttempts;
    for (var attempt = 0; attempt < attempts; attempt++) {
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
          maxBytes: _maxJsonResponseBytes,
          timeout: timeout,
        );
        if (attempt < attempts - 1 && response.statusCode >= 500) {
          await Future<void>.delayed(_retryDelay);
          continue;
        }
        return response;
      } on HttpResponseTooLargeException {
        throw const ApiException('RESPONSE_TOO_LARGE', '服务返回的数据过大');
      } on Exception catch (error) {
        lastError = error;
        if (attempt < attempts - 1) {
          await Future<void>.delayed(_retryDelay);
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
    Map<String, dynamic> params,
  ) async {
    final uri = Uri.parse(
      '$_chkszUrl$path',
    ).replace(queryParameters: _chkszQuery(params));
    final res = await _get(uri);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ApiException('HTTP_${res.statusCode}', '服务暂时不可用');
    }
    final dynamic body;
    try {
      body = json.decode(utf8.decode(res.bodyBytes));
    } on FormatException {
      throw ApiException('INVALID_RESPONSE', '服务返回了无效数据');
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
  }) async {
    final response = await _postJson(Uri.parse(_qingMusicUrl), {
      'source': switch (platform) {
        MusicPlatform.qq => 'tx',
        MusicPlatform.netease => 'wy',
        MusicPlatform.kugou => 'kg',
        MusicPlatform.bilibili => throw UnsupportedError('B站使用官方播放接口'),
      },
      'rid': id,
      'level': _qingMusicLevel(platform, quality),
    });
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
      throw ApiException('QING_INVALID_RESPONSE', 'QingMusic 返回了无效数据');
    }
    if (body is! Map) {
      throw ApiException('QING_INVALID_RESPONSE', 'QingMusic 返回格式错误');
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
      throw ApiException('QING_EMPTY_URL', 'QingMusic 未返回播放地址');
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
  Future<SongDetail> neteaseMusic(String id, {String level = 'exhigh'}) async {
    final json = await _chkszGet('/api/163_music', {
      'id': id,
      'level': level,
      'type': 'json',
    });
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
  Future<SongDetail> kugouMusic(String hash, {String size = 'flac'}) async {
    final json = await _chkszGet('/api/kugou_music', {
      'id': hash.toUpperCase(),
      'size': size,
      'type': 'json',
    });
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
  Future<SongDetail> qqMusic(String mid, {String size = 'flac'}) async {
    final json = await _chkszGet('/api/qq_music', {
      'mid': mid,
      'size': size,
      'type': 'json',
    });
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
