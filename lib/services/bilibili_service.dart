import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/song.dart';
import 'bounded_http_response.dart';

class BilibiliUser {
  final int mid;
  final String name;
  final String? avatarUrl;

  const BilibiliUser({required this.mid, required this.name, this.avatarUrl});
}

class BilibiliQrCode {
  final String key;
  final String url;

  const BilibiliQrCode({required this.key, required this.url});
}

/// 可供内置视频播放器尝试的 B 站视频地址集合。
///
/// B 站会同时返回多个 CDN 地址，部分网络只能访问其中的 mcdn 地址，
/// 因此不能像普通音乐源一样只保留一个 URL。
class BilibiliVideoSource {
  final List<String> urls;

  /// DASH 音频流的候选地址。B站 DASH 将音视频拆成两条流，内置 MV
  /// 播放器需要把这条音轨和 [urls] 中的视频流一起播放。
  final List<String> audioUrls;
  final Map<String, String> headers;

  const BilibiliVideoSource({
    required this.urls,
    this.audioUrls = const [],
    required this.headers,
  });

  /// Returns an empty value for a malformed/empty response instead of letting
  /// a UI caller crash while opening the built-in player.
  String get url => urls.isEmpty ? '' : urls.first;
  String? get audioUrl => audioUrls.isEmpty ? null : audioUrls.first;
}

enum BilibiliQrStatus { waiting, scanned, expired, success }

class BilibiliQrPollResult {
  final BilibiliQrStatus status;
  final String message;

  const BilibiliQrPollResult(this.status, this.message);
}

class BilibiliApiException implements Exception {
  final String code;
  final String message;

  const BilibiliApiException(this.code, this.message);

  @override
  String toString() => message;
}

class BilibiliService extends ChangeNotifier {
  static const _apiBase = 'https://api.bilibili.com';
  static const _passportBase = 'https://passport.bilibili.com';
  static const _cookiePreferenceKey = 'bilibili_cookie';
  static const _maxJsonResponseBytes = 5 * 1024 * 1024;
  static const _userAgent =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
      'Chrome/120 Mobile Safari/537.36';
  static const _mixinKeyEncTab = <int>[
    46,
    47,
    18,
    2,
    53,
    8,
    23,
    32,
    15,
    50,
    10,
    31,
    58,
    3,
    45,
    35,
    27,
    43,
    5,
    49,
    33,
    9,
    42,
    19,
    29,
    28,
    14,
    39,
    12,
    38,
    41,
    13,
  ];

  final http.Client _client;
  final bool _ownsClient;
  late final Future<void> ready;
  String? _cookie;
  String? _mixinKey;
  DateTime? _mixinKeyExpiresAt;
  BilibiliUser? _user;
  bool _accountLoading = false;
  bool _disposed = false;

  BilibiliService({http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null {
    ready = _loadSession();
  }

  bool get isLoggedIn => _user != null;
  bool get hasCookie => _cookie?.isNotEmpty == true;
  bool get accountLoading => _accountLoading;
  BilibiliUser? get user => _user;

  Map<String, String> get playbackHeaders =>
      _playbackHeaders(referer: 'https://www.bilibili.com/');

  Map<String, String> playbackHeadersForVideo(String bvid) {
    return _playbackHeaders(referer: 'https://www.bilibili.com/video/$bvid');
  }

  Map<String, String> _playbackHeaders({required String referer}) {
    return {
      'User-Agent': _userAgent,
      'Referer': referer,
      'Origin': 'https://www.bilibili.com',
      if (hasCookie) 'Cookie': _cookie!,
    };
  }

  Future<void> _loadSession() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      _cookie = preferences.getString(_cookiePreferenceKey);
    } catch (error) {
      _cookie = null;
      debugPrint('读取 B 站会话失败: $error');
    }
  }

  Future<void> refreshAccount() async {
    await ready;
    if (_disposed) return;
    if (!hasCookie) {
      _user = null;
      if (!_disposed) notifyListeners();
      return;
    }
    _accountLoading = true;
    if (!_disposed) notifyListeners();
    try {
      final response = await _getJson('$_apiBase/x/web-interface/nav');
      final data = response['data'];
      if (data is Map && data['isLogin'] == true) {
        _user = BilibiliUser(
          mid: _asInt(data['mid']) ?? 0,
          name: data['uname']?.toString() ?? 'B站用户',
          avatarUrl: data['face']?.toString(),
        );
      } else {
        _user = null;
      }
    } catch (_) {
      _user = null;
    } finally {
      _accountLoading = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<BilibiliQrCode> createQrCode() async {
    final response = await _getJson(
      '$_passportBase/x/passport-login/web/qrcode/generate',
    );
    _expectCode(response);
    final data = response['data'];
    if (data is! Map) {
      throw const BilibiliApiException('QR_INVALID', '二维码数据格式错误');
    }
    final key = data['qrcode_key']?.toString() ?? '';
    final url = data['url']?.toString() ?? '';
    if (key.isEmpty || url.isEmpty) {
      throw const BilibiliApiException('QR_EMPTY', 'B站未返回登录二维码');
    }
    return BilibiliQrCode(key: key, url: url);
  }

  Future<BilibiliQrPollResult> pollQrCode(String key) async {
    final uri = Uri.parse(
      '$_passportBase/x/passport-login/web/qrcode/poll',
    ).replace(queryParameters: {'qrcode_key': key, 'source': 'main_web'});
    final response = await _getResponse(uri);
    final body = _decodeResponse(response);
    _expectCode(body);
    final data = body['data'];
    final statusCode = data is Map ? _asInt(data['code']) : null;
    final message = data is Map ? data['message']?.toString() ?? '' : '';
    switch (statusCode) {
      case 0:
        await _completeQrLogin(
          response,
          Map<String, dynamic>.from(data as Map),
        );
        return const BilibiliQrPollResult(BilibiliQrStatus.success, '登录成功');
      case 86090:
        return BilibiliQrPollResult(
          BilibiliQrStatus.scanned,
          message.isEmpty ? '已扫码，请在手机端确认' : message,
        );
      case 86038:
        return BilibiliQrPollResult(
          BilibiliQrStatus.expired,
          message.isEmpty ? '二维码已过期' : message,
        );
      default:
        return BilibiliQrPollResult(
          BilibiliQrStatus.waiting,
          message.isEmpty ? '等待扫码' : message,
        );
    }
  }

  Future<void> _completeQrLogin(
    http.Response response,
    Map<String, dynamic> data,
  ) async {
    final cookies = <String, String>{};
    final callback = Uri.tryParse(data['url']?.toString() ?? '');
    if (callback != null) {
      for (final name in _loginCookieNames) {
        final value = callback.queryParameters[name];
        if (value != null && value.isNotEmpty) cookies[name] = value;
      }
    }
    final rawSetCookie = response.headers['set-cookie'];
    if (rawSetCookie != null) {
      for (final name in _loginCookieNames) {
        final match = RegExp(
          '(?:^|,\\s*)$name=([^;,]*)',
        ).firstMatch(rawSetCookie);
        if (match != null && match.group(1)?.isNotEmpty == true) {
          cookies[name] = match.group(1)!;
        }
      }
    }
    if (cookies['SESSDATA']?.isEmpty != false) {
      throw const BilibiliApiException('QR_COOKIE_EMPTY', '登录成功但未收到会话信息');
    }
    _cookie = cookies.entries
        .map((entry) => '${entry.key}=${entry.value}')
        .join('; ');
    final preferences = await SharedPreferences.getInstance();
    if (_disposed) return;
    await preferences.setString(_cookiePreferenceKey, _cookie!);
    if (_disposed) return;
    await refreshAccount();
  }

  static const _loginCookieNames = <String>[
    'SESSDATA',
    'bili_jct',
    'DedeUserID',
    'DedeUserID__ckMd5',
    'sid',
  ];

  Future<void> logout() async {
    if (_disposed) return;
    _cookie = null;
    _user = null;
    _mixinKey = null;
    _mixinKeyExpiresAt = null;
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.remove(_cookiePreferenceKey);
    } catch (error) {
      debugPrint('清除 B 站会话失败: $error');
    }
    if (!_disposed) notifyListeners();
  }

  Future<List<SongSearchResult>> search(String keyword) async {
    final response = await _bilibiliGet(
      '/x/web-interface/wbi/search/type',
      {
        'search_type': 'video',
        'keyword': keyword,
        'page': 1,
        'page_size': 20,
        'platform': 'pc',
        'web_location': 1430654,
      },
      wbi: true,
      headers: {
        'Origin': 'https://search.bilibili.com',
        'Referer':
            'https://search.bilibili.com/video?keyword=${Uri.encodeComponent(keyword)}',
      },
    );
    final data = response['data'];
    final rows = data is Map ? data['result'] as List? ?? const [] : const [];
    return rows
        .whereType<Map>()
        .map(
          (row) =>
              SongSearchResult.fromBilibili(Map<String, dynamic>.from(row)),
        )
        .where((item) => item.id.isNotEmpty)
        .toList(growable: false);
  }

  Future<BilibiliVideoInfo> videoInfo(String bvid) async {
    final response = await _bilibiliGet('/x/web-interface/view', {
      'bvid': bvid,
    });
    final rawData = response['data'];
    if (rawData is! Map) {
      throw const BilibiliApiException('VIDEO_INVALID', '视频详情格式错误');
    }
    final data = Map<String, dynamic>.from(rawData);
    final owner = data['owner'];
    final stat = data['stat'];
    final pages = (data['pages'] as List? ?? const [])
        .whereType<Map>()
        .map(
          (page) => BilibiliPageInfo.fromJson(Map<String, dynamic>.from(page)),
        )
        .where((page) => page.cid > 0)
        .toList(growable: false);
    if (pages.isEmpty) {
      throw const BilibiliApiException('VIDEO_NO_PAGE', '视频没有可播放的分P');
    }
    final rawCover = data['pic']?.toString() ?? '';
    return BilibiliVideoInfo(
      bvid: data['bvid']?.toString() ?? bvid,
      title: data['title']?.toString() ?? '未知视频',
      description: data['desc']?.toString().trim() ?? '',
      ownerName: owner is Map ? owner['name']?.toString() ?? '未知UP主' : '未知UP主',
      coverUrl: rawCover.startsWith('//') ? 'https:$rawCover' : rawCover,
      duration: _asInt(data['duration']),
      viewCount: stat is Map ? _asInt(stat['view']) : null,
      likeCount: stat is Map ? _asInt(stat['like']) : null,
      pages: pages,
    );
  }

  Future<BilibiliPlayInfo> playInfo(String bvid, int cid) async {
    final response = await _bilibiliGet('/x/player/wbi/playurl', {
      'bvid': bvid,
      'cid': cid,
      'qn': 127,
      'fnver': 0,
      'fnval': 4048,
      'fourk': 1,
    }, wbi: true);
    final rawData = response['data'];
    final data = rawData is Map
        ? Map<String, dynamic>.from(rawData)
        : <String, dynamic>{};
    final rawDash = data['dash'];
    final dash = rawDash is Map
        ? Map<String, dynamic>.from(rawDash)
        : <String, dynamic>{};
    final audio = <BilibiliStream>[
      ..._parseStreams(dash['audio'], audio: true),
      if (dash['dolby'] is Map)
        ..._parseStreams((dash['dolby'] as Map)['audio'], audio: true),
      if (dash['flac'] is Map && (dash['flac'] as Map)['audio'] is Map)
        ..._parseStreams([(dash['flac'] as Map)['audio']], audio: true),
    ];
    final video = _parseStreams(dash['video'], audio: false);
    if (audio.isEmpty) {
      throw const BilibiliApiException('PLAY_NO_AUDIO', '当前分P没有可播放的音频');
    }
    audio.sort((a, b) => b.bandwidth.compareTo(a.bandwidth));
    video.sort(_compareVideoStreams);
    return BilibiliPlayInfo(
      audioStreams: _deduplicateStreams(audio),
      videoStreams: _deduplicateStreams(video),
      duration: (_asInt(data['timelength']) ?? 0) ~/ 1000,
    );
  }

  Future<BilibiliVideoSource> videoSource(
    String bvid,
    int cid,
    int quality, {
    int? audioQuality,
  }) async {
    // The HTML5 route returns a progressive MP4 containing both video and
    // audio. Prefer it for the built-in MV players: it avoids DASH stream
    // merging and is supported by both Media3 and libmpv.
    try {
      final progressiveResponse = await _bilibiliGet('/x/player/wbi/playurl', {
        'bvid': bvid,
        'cid': cid,
        'qn': quality,
        'fnver': 0,
        'fnval': 0,
        'fourk': 1,
        'platform': 'html5',
        'high_quality': 1,
      }, wbi: true);
      final rawProgressiveData = progressiveResponse['data'];
      final progressiveData = rawProgressiveData is Map
          ? Map<String, dynamic>.from(rawProgressiveData)
          : <String, dynamic>{};
      final progressiveUrls = _durlUrls(progressiveData);
      if (progressiveUrls.isNotEmpty) {
        return BilibiliVideoSource(
          urls: progressiveUrls,
          headers: playbackHeadersForVideo(bvid),
        );
      }
    } catch (_) {
      // Some videos do not expose an HTML5 MP4. Continue with DASH below.
    }

    final response = await _bilibiliGet('/x/player/wbi/playurl', {
      'bvid': bvid,
      'cid': cid,
      'qn': quality,
      'fnver': 0,
      // DASH supplies multiple CDN URLs.  The first durl is frequently an
      // upos address that returns 403 on mobile networks.
      'fnval': 4048,
      'fourk': 1,
    }, wbi: true);
    final rawData = response['data'];
    final data = rawData is Map
        ? Map<String, dynamic>.from(rawData)
        : <String, dynamic>{};
    final rawDash = data['dash'];
    final dash = rawDash is Map
        ? Map<String, dynamic>.from(rawDash)
        : <String, dynamic>{};
    // DASH 的音频和视频是两条独立流。默认使用普通音频列表中的 AAC；
    // 只有用户明确选中对应音质时才使用 Dolby/FLAC。
    final regularAudioStreams = _parseStreams(dash['audio'], audio: true)
      ..sort((a, b) => b.bandwidth.compareTo(a.bandwidth));
    final audioStreams = <BilibiliStream>[
      ...regularAudioStreams,
      if (dash['dolby'] is Map)
        ..._parseStreams((dash['dolby'] as Map)['audio'], audio: true),
      if (dash['flac'] is Map && (dash['flac'] as Map)['audio'] is Map)
        ..._parseStreams([(dash['flac'] as Map)['audio']], audio: true),
    ];
    BilibiliStream? selectedAudio;
    if (audioQuality != null) {
      for (final stream in audioStreams) {
        if (stream.quality == audioQuality) {
          selectedAudio = stream;
          break;
        }
      }
    }
    if (selectedAudio == null && regularAudioStreams.isNotEmpty) {
      selectedAudio = regularAudioStreams.first;
    }
    final streams = _parseStreams(dash['video'], audio: false)
      ..sort(_compareVideoStreams);
    if (streams.isNotEmpty) {
      final availableQualities =
          streams
              .map((stream) => stream.quality)
              .where((value) => value > 0)
              .toSet()
              .toList()
            ..sort();
      final targetQuality = availableQualities.isEmpty
          ? 0
          : availableQualities.lastWhere(
              (value) => value <= quality,
              orElse: () => availableQualities.first,
            );
      final selected = streams.where(
        (stream) => stream.quality == targetQuality,
      );
      final urls = _orderedUrls(selected.expand((stream) => stream.playUrls));
      if (urls.isNotEmpty) {
        return BilibiliVideoSource(
          urls: urls,
          audioUrls: selectedAudio?.playUrls ?? const [],
          headers: playbackHeadersForVideo(bvid),
        );
      }
    }

    // A few older/paid videos still return only a progressive MP4.  Keep it
    // as a compatibility fallback, including every backup_url supplied by
    // the official endpoint.
    final urls = _durlUrls(data);
    if (urls.isEmpty) {
      throw const BilibiliApiException('PLAY_NO_VIDEO', 'B站未返回视频地址');
    }
    return BilibiliVideoSource(
      urls: urls,
      audioUrls: const [],
      headers: playbackHeadersForVideo(bvid),
    );
  }

  Future<String> videoUrl(String bvid, int cid, int quality) async {
    return (await videoSource(bvid, cid, quality)).url;
  }

  List<String> _durlUrls(Map<String, dynamic> data) {
    final rows = data['durl'] is List
        ? (data['durl'] as List).whereType<Map>()
        : const Iterable<Map>.empty();
    for (final row in rows) {
      final base = row['url']?.toString() ?? '';
      final backups = _stringList(row['backupUrl'] ?? row['backup_url']);
      final urls = _orderedUrls([if (base.isNotEmpty) base, ...backups]);
      if (urls.isNotEmpty) return urls;
    }
    return const [];
  }

  List<BilibiliStream> _parseStreams(dynamic raw, {required bool audio}) {
    final rows = raw is List ? raw : const [];
    return rows
        .whereType<Map>()
        .map((row) {
          final quality = _asInt(row['id']) ?? 0;
          final base = (row['baseUrl'] ?? row['base_url'])?.toString() ?? '';
          final urls = _orderedUrls([
            if (base.isNotEmpty) base,
            ..._stringList(row['backupUrl'] ?? row['backup_url']),
          ]);
          return BilibiliStream(
            quality: quality,
            label: audio ? _audioLabel(quality) : _videoLabel(quality),
            url: urls.isEmpty ? '' : urls.first,
            playUrls: urls,
            bandwidth: _asInt(row['bandwidth']) ?? 0,
            mimeType: (row['mimeType'] ?? row['mime_type'])?.toString(),
            codecs: row['codecs']?.toString(),
          );
        })
        .where((stream) => stream.url.isNotEmpty)
        .toList(growable: false);
  }

  static List<String> _stringList(dynamic value) {
    if (value is! List) return const [];
    return value
        .map((item) => item?.toString() ?? '')
        .where((url) => url.isNotEmpty)
        .toList(growable: false);
  }

  static List<String> _deduplicateUrls(Iterable<String> urls) {
    final seen = <String>{};
    return urls
        .where((url) {
          final uri = Uri.tryParse(url.trim());
          return uri != null &&
              (uri.scheme == 'http' || uri.scheme == 'https') &&
              uri.host.isNotEmpty &&
              seen.add(url);
        })
        .toList(growable: false);
  }

  static List<String> _orderedUrls(Iterable<String> urls) {
    final result = _deduplicateUrls(urls).toList();
    result.sort((a, b) => _urlPriority(b).compareTo(_urlPriority(a)));
    return result;
  }

  static int _compareVideoStreams(BilibiliStream a, BilibiliStream b) {
    final quality = b.quality.compareTo(a.quality);
    if (quality != 0) return quality;
    final network = _urlPriority(b.url).compareTo(_urlPriority(a.url));
    if (network != 0) return network;
    final codec = _codecPriority(b.codecs).compareTo(_codecPriority(a.codecs));
    if (codec != 0) return codec;
    return b.bandwidth.compareTo(a.bandwidth);
  }

  static int _urlPriority(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    if (host.contains('.mcdn.bilivideo.')) return 3;
    if (host.contains('bilivideo.')) return 2;
    return 1;
  }

  static int _codecPriority(String? codecs) {
    final value = codecs ?? '';
    if (value.startsWith('avc1')) return 3;
    if (value.startsWith('hev1') || value.startsWith('hvc1')) return 2;
    if (value.startsWith('av01')) return 1;
    return 0;
  }

  static List<BilibiliStream> _deduplicateStreams(
    List<BilibiliStream> streams,
  ) {
    final qualities = <int>{};
    return streams
        .where((stream) => qualities.add(stream.quality))
        .toList(growable: false);
  }

  static String _audioLabel(int quality) => switch (quality) {
    30251 => 'Hi-Res',
    30250 || 30255 => '杜比全景声',
    30280 => '192K',
    30232 => '132K',
    30216 => '64K',
    _ => '${quality}K',
  };

  static String _videoLabel(int quality) => switch (quality) {
    127 => '8K',
    126 => '杜比视界',
    125 => 'HDR',
    120 => '4K',
    116 => '1080P60',
    112 => '1080P+',
    80 => '1080P',
    74 => '720P60',
    64 => '720P',
    32 => '480P',
    16 => '360P',
    6 => '240P',
    _ => '清晰度 $quality',
  };

  Future<Map<String, dynamic>> _bilibiliGet(
    String path,
    Map<String, dynamic> params, {
    bool wbi = false,
    Map<String, String> headers = const {},
  }) async {
    await ready;
    final query = wbi ? await _signParams(params) : params;
    final uri = Uri.parse('$_apiBase$path').replace(
      queryParameters: query.map((key, value) => MapEntry(key, '$value')),
    );
    final response = await _getJson(uri.toString(), headers: headers);
    _expectCode(response);
    return response;
  }

  Future<Map<String, dynamic>> _signParams(Map<String, dynamic> params) async {
    final mixinKey = await _getMixinKey();
    final result = <String, dynamic>{...params};
    result['wts'] = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final keys = result.keys.toList()..sort();
    final query = keys
        .map(
          (key) =>
              '${Uri.encodeComponent(key)}='
              '${Uri.encodeComponent(result[key].toString().replaceAll(RegExp(r"[!'()*]"), ''))}',
        )
        .join('&');
    result['w_rid'] = md5.convert(utf8.encode('$query$mixinKey')).toString();
    return result;
  }

  Future<String> _getMixinKey() async {
    final now = DateTime.now();
    if (_mixinKey != null && _mixinKeyExpiresAt?.isAfter(now) == true) {
      return _mixinKey!;
    }
    final response = await _getJson('$_apiBase/x/web-interface/nav');
    final data = response['data'];
    final wbiImage = data is Map ? data['wbi_img'] : null;
    if (wbiImage is! Map) {
      throw const BilibiliApiException('WBI_KEY', '无法获取B站签名密钥');
    }
    final source =
        '${_fileKey(wbiImage['img_url'])}${_fileKey(wbiImage['sub_url'])}';
    if (source.length < 59) {
      throw const BilibiliApiException('WBI_KEY', 'B站签名密钥格式错误');
    }
    _mixinKey = String.fromCharCodes(
      _mixinKeyEncTab.map((index) => source.codeUnitAt(index)),
    );
    _mixinKeyExpiresAt = now.add(const Duration(hours: 2));
    return _mixinKey!;
  }

  static String _fileKey(dynamic rawUrl) {
    final uri = Uri.tryParse(rawUrl?.toString() ?? '');
    if (uri == null || uri.pathSegments.isEmpty) return '';
    return uri.pathSegments.last.split('.').first;
  }

  Future<Map<String, dynamic>> _getJson(
    String url, {
    Map<String, String> headers = const {},
  }) async {
    final response = await _getResponse(Uri.parse(url), headers: headers);
    return _decodeResponse(response);
  }

  Future<http.Response> _getResponse(
    Uri uri, {
    Map<String, String> headers = const {},
  }) async {
    await ready;
    final request = http.Request('GET', uri)
      ..headers.addAll({
        'Accept': 'application/json',
        'User-Agent': _userAgent,
        'Referer': 'https://www.bilibili.com/',
        if (hasCookie) 'Cookie': _cookie!,
        ...headers,
      });
    final http.Response response;
    try {
      response = await sendBoundedHttpRequest(
        _client,
        request,
        maxBytes: _maxJsonResponseBytes,
        timeout: const Duration(seconds: 10),
      );
    } on HttpResponseTooLargeException {
      throw const BilibiliApiException('RESPONSE_TOO_LARGE', 'B站返回的数据过大');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw BilibiliApiException('HTTP_${response.statusCode}', 'B站服务暂时不可用');
    }
    return response;
  }

  static Map<String, dynamic> _decodeResponse(http.Response response) {
    final dynamic body;
    try {
      body = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw const BilibiliApiException('INVALID_RESPONSE', 'B站返回了无效数据');
    }
    if (body is! Map) {
      throw const BilibiliApiException('INVALID_RESPONSE', 'B站返回格式错误');
    }
    return Map<String, dynamic>.from(body);
  }

  static void _expectCode(Map<String, dynamic> response) {
    if (response['code']?.toString() != '0') {
      throw BilibiliApiException(
        'BILIBILI_${response['code'] ?? 'FAILED'}',
        response['message']?.toString() ?? 'B站请求失败',
      );
    }
  }

  static int? _asInt(dynamic value) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  @override
  void dispose() {
    _disposed = true;
    if (_ownsClient) _client.close();
    super.dispose();
  }
}
