import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/song.dart';

/// 音乐 API 服务层
/// - 网易云: http://60.204.152.87:3000 (NeteaseCloudMusicApi)
/// - 酷狗: mobilecdn.kugou.com 官方接口搜索/推荐
/// - QQ音乐: http://101.34.65.200:3500 (jsososo) 搜索/推荐
/// - 三平台播放地址解析: ChKSz API（经 nginx 中转）
///
/// 说明：上述直连域名在部分手机网络下不稳定（如 music.126.net 封面、
/// mobilecdn.kugou.com 歌单），故统一经服务器 161.118.252.183 的 nginx
/// 反代中转（/api-netease /api-qq /api-kugou-search /api-kugou）。
class ApiService {
  // 分页请求体积更小；给移动网络保留少量余量，仍以两次尝试快速失败。
  static const _requestTimeout = Duration(seconds: 10);
  static const _retryDelay = Duration(milliseconds: 350);

  // ChKSz API 经服务器中转，避免移动网络直连 HTTPS 不稳定。
  static const String _chkszUrl = 'http://161.118.252.183/api-chksz';
  static const String _qingMusicUrl =
      'https://musicserver.haitangw.cc/v1/music/resolve-url';
  // API 中转入口（服务器反代到各平台，规避手机直连不稳定）
  static const String neteaseBaseUrl = 'http://161.118.252.183/api-netease';
  static const String kugouSearchBase =
      'http://161.118.252.183/api-kugou-search';
  static const String qqBaseUrl = 'http://161.118.252.183/api-qq';

  final http.Client _client = http.Client();
  String apiKey;

  ApiService({required this.apiKey});

  void setApiKey(String key) {
    apiKey = key;
  }

  void close() => _client.close();

  Future<http.Response> _get(Uri uri) async {
    Exception? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final response = await _client
            .get(uri, headers: const {'Accept': 'application/json'})
            .timeout(_requestTimeout);
        if (attempt == 0 && response.statusCode >= 500) {
          await Future<void>.delayed(_retryDelay);
          continue;
        }
        return response;
      } on Exception catch (error) {
        lastError = error;
        if (attempt == 0) {
          await Future<void>.delayed(_retryDelay);
          continue;
        }
      }
    }
    throw lastError ?? StateError('请求失败');
  }

  Future<http.Response> _postJson(Uri uri, Map<String, dynamic> body) async {
    Exception? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final response = await _client
            .post(
              uri,
              headers: const {
                'Accept': 'application/json',
                'Content-Type': 'application/json',
              },
              body: jsonEncode(body),
            )
            .timeout(_requestTimeout);
        if (attempt == 0 && response.statusCode >= 500) {
          await Future<void>.delayed(_retryDelay);
          continue;
        }
        return response;
      } on Exception catch (error) {
        lastError = error;
        if (attempt == 0) {
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
    }
  }

  // ---- 通用 HTTP GET ----
  Future<Map<String, dynamic>> _httpGet(
    String baseUrl,
    String path,
    Map<String, dynamic> params,
  ) async {
    final uri = Uri.parse(
      '$baseUrl$path',
    ).replace(queryParameters: params.map((k, v) => MapEntry(k, v.toString())));
    final res = await _get(uri);
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

  // ======================== 网易云 (直连) ========================

  /// 搜索网易云歌曲
  Future<List<SongSearchResult>> neteaseSearch(
    String keyword, {
    int limit = 20,
  }) async {
    final json = await _httpGet(neteaseBaseUrl, '/search', {
      'keywords': keyword,
      'limit': limit,
    });
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
    final json = await _httpGet(neteaseBaseUrl, '/search', {
      'keywords': keyword,
      'type': 1000,
      'limit': limit,
    });
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
      final ids = missing.map((s) => s.id).join(',');
      final json = await _httpGet(neteaseBaseUrl, '/song/detail', {'ids': ids});
      final details = json['songs'] as List? ?? [];
      for (final d in details) {
        if (d is! Map<String, dynamic>) continue;
        final id = d['id']?.toString();
        final picUrl = CoverHelper.normalize(d['al']?['picUrl']?.toString());
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

  /// 获取网易云歌词 (ChKSz API /api/163_lyric)
  Future<LyricData> neteaseLyric(String id) async {
    final json = await _chkszGet('/api/163_lyric', {'id': id});
    return LyricData(
      original: json['lrc']?.toString() ?? json['data']?['lrc']?.toString(),
      translated:
          json['tlyric']?.toString() ?? json['data']?['tlyric']?.toString(),
      romaji:
          json['romalrc']?.toString() ?? json['data']?['romalrc']?.toString(),
    );
  }

  /// 备用源使用网易云公开歌词接口，不依赖 ChKSz API Key。
  Future<LyricData> neteasePublicLyric(String id) async {
    final json = await _httpGet(neteaseBaseUrl, '/lyric', {'id': id});
    return LyricData(
      original: json['lrc']?['lyric']?.toString(),
      translated: json['tlyric']?['lyric']?.toString(),
      romaji: json['romalrc']?['lyric']?.toString(),
    );
  }

  /// 网易云热门歌单
  Future<List<PlaylistInfo>> neteaseHotPlaylists({int limit = 20}) async {
    final json = await _httpGet(neteaseBaseUrl, '/top/playlist', {
      'limit': limit,
      'order': 'hot',
    });
    final list = json['playlists'] as List? ?? [];
    return list
        .map((e) => PlaylistInfo.fromNeteaseList(e as Map<String, dynamic>))
        .toList();
  }

  /// 获取网易云歌单详情 (ChKSz API /api/163_playlist)
  Future<PlaylistInfo> neteasePlaylist(String id) async {
    final json = await _chkszGet('/api/163_playlist', {'id': id});
    final data = json['data'] as Map<String, dynamic>? ?? json;
    final result = PlaylistInfo.fromJson(data);
    // 歌单详情曲目也补充封面
    await _fillNeteaseCovers(result.tracks);
    return result;
  }

  /// 网易云歌单曲目分页。
  ///
  /// `/playlist/detail` 会把最多 1000 首歌曲一起返回，容易在车机网络下
  /// 超时；曲目页改用官方分页接口，每次只取一页。
  Future<PlaylistTrackPage> neteasePlaylistTracks(
    String id, {
    int limit = 20,
    int offset = 0,
  }) async {
    final safeLimit = limit.clamp(1, 100);
    final safeOffset = offset < 0 ? 0 : offset;
    final json = await _httpGet(neteaseBaseUrl, '/playlist/track/all', {
      'id': id,
      'limit': safeLimit,
      'offset': safeOffset,
    });
    final rawSongs = json['songs'] as List? ?? const [];
    final tracks = rawSongs
        .whereType<Map>()
        .map(
          (song) =>
              SongSearchResult.fromNetease(Map<String, dynamic>.from(song)),
        )
        .toList();
    final rawTotal = json['total'] ?? json['trackCount'];
    final total = rawTotal is num
        ? rawTotal.toInt()
        : int.tryParse(rawTotal?.toString() ?? '');
    return PlaylistTrackPage(tracks: tracks, total: total);
  }

  // ======================== 酷狗 (mobilecdn 官方接口, ChKSz解析) ========================
  // mixdown 源站已不可用，搜索、推荐和新歌统一使用 mobilecdn 官方接口。

  /// 搜索酷狗歌曲 (mobilecdn /api/v3/search/song)
  Future<List<SongSearchResult>> kugouSearch(
    String keyword, {
    int page = 1,
    int pagesize = 20,
  }) async {
    final json = await _httpGet(kugouSearchBase, '/api/v3/search/song', {
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
    final json = await _httpGet(kugouSearchBase, '/api/v3/rank/song', {
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
    final json = await _httpGet(kugouSearchBase, '/api/v3/rank/song', {
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

  /// 搜索QQ音乐 (jsososo)
  Future<List<SongSearchResult>> qqSearch(String keyword) async {
    final json = await _httpGet(qqBaseUrl, '/search', {'key': keyword});
    final list = json['data']?['list'] as List? ?? [];
    return list
        .map((e) => SongSearchResult.fromQQDirect(e as Map<String, dynamic>))
        .toList();
  }

  /// QQ推荐歌单
  Future<List<PlaylistInfo>> qqRecommendPlaylists() async {
    final json = await _httpGet(qqBaseUrl, '/recommend/playlist', {});
    final list = json['data']?['list'] as List? ?? [];
    return list
        .map((e) => PlaylistInfo.fromQQList(e as Map<String, dynamic>))
        .toList();
  }

  /// QQ音乐歌单搜索 (jsososo /search?t=2)
  Future<List<PlaylistInfo>> qqSearchPlaylists(String keyword) async {
    final json = await _httpGet(qqBaseUrl, '/search', {'key': keyword, 't': 2});
    final list = json['data']?['list'] as List? ?? [];
    return list
        .map((e) => PlaylistInfo.fromQQSearchList(e as Map<String, dynamic>))
        .toList();
  }

  /// 酷狗歌单搜索 (mobilecdn /api/v3/search/special)
  Future<List<PlaylistInfo>> kugouSearchPlaylists(
    String keyword, {
    int page = 1,
    int pagesize = 20,
  }) async {
    final json = await _httpGet(kugouSearchBase, '/api/v3/search/special', {
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
    final json = await _httpGet(kugouSearchBase, '/api/v3/special/song', {
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
    final json = await _httpGet(kugouSearchBase, '/api/v3/special/song', {
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

  /// QQ歌单详情
  Future<PlaylistInfo> qqPlaylist(String tid) async {
    final json = await _httpGet(qqBaseUrl, '/songlist', {'id': tid});
    final data = json['data'] ?? json;
    return PlaylistInfo.fromQQDetail(data as Map<String, dynamic>);
  }

  /// QQ 歌单曲目分页兼容层。
  ///
  /// jsososo 的 `/songlist` 路由目前没有把 offset 透传给 QQ 上游，
  /// 因此先传递分页参数（便于未来中转服务支持），收到完整列表时在本地
  /// 截取当前页，避免页面一次创建数百个条目。
  Future<PlaylistTrackPage> qqPlaylistTracks(
    String tid, {
    int limit = 20,
    int offset = 0,
  }) async {
    final safeLimit = limit.clamp(1, 100);
    final safeOffset = offset < 0 ? 0 : offset;
    final json = await _httpGet(qqBaseUrl, '/songlist', {
      'id': tid,
      'song_begin': safeOffset,
      'song_num': safeLimit,
    });
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
    // 若中转层已实现分页，返回值长度不会超过 limit；否则从完整列表切页。
    final tracks = allTracks.length > safeLimit
        ? allTracks.skip(safeOffset).take(safeLimit).toList()
        : allTracks;
    return PlaylistTrackPage(tracks: tracks, total: total);
  }

  /// QQ歌词
  Future<LyricData> qqLyric(String songmid) async {
    final json = await _httpGet(qqBaseUrl, '/lyric', {'songmid': songmid});
    final data = json['data'] ?? json;
    return LyricData(original: data['lyric'], translated: data['trans']);
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
    }
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
    }
  }

  /// 获取歌词
  Future<LyricData?> getLyric(MusicPlatform platform, String id) async {
    if (platform == MusicPlatform.netease) {
      return neteaseLyric(id);
    } else if (platform == MusicPlatform.qq) {
      return qqLyric(id);
    }
    // 酷狗歌词随解析接口返回
    return null;
  }
}

class ApiException implements Exception {
  final String code;
  final String message;
  ApiException(this.code, this.message);

  @override
  String toString() => '[$code] $message';
}
