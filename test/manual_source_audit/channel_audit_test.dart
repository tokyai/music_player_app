// 联网测试将受控 JSON 写入 flutter_test 事件流，供审计报告收集。
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:music_player_app/models/playback_source_config.dart';
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/services/api_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _root = 'tmp/source_audit_20261119';
const _audioLimit = 512;
const _audioTimeout = Duration(seconds: 8);

/// 按源、平台、歌曲和网络保存真实读取证据；SHIXIAOYANG，2026/11/19。
void main() {
  // 开关关闭时不读取临时目录记录，也不创建 HTTP 客户端。
  if (Platform.environment['SOURCE_AUDIT_ENABLED'] != '1') {
    test(
      'manual channel audit',
      _verifyFlacInfo,
      skip: 'Set SOURCE_AUDIT_ENABLED=1 to run the live audit',
    );
    return;
  }
  TestWidgetsFlutterBinding.ensureInitialized();
  final network = Platform.environment['SOURCE_AUDIT_NETWORK'] ?? 'direct';
  final phase = Platform.environment['SOURCE_AUDIT_PHASE'] ?? 'standard';
  if (!const {'direct', 'proxy'}.contains(network) ||
      !const {'standard', 'quality', 'retry'}.contains(phase)) {
    throw const FormatException('无效的音源审计模式');
  }
  HttpOverrides.global = network == 'proxy' ? _AuditProxy() : null;
  SharedPreferences.setMockInitialValues({});
  test('reads the independent RFC 9639 STREAMINFO example', _verifyFlacInfo);

  // 仅读取本次已核对的六条目录记录，不读取用户个人密钥或修改应用设置。
  final fixture = File('$_root/catalog-samples.json');
  if (fixture.lengthSync() > 64 * 1024) throw const FormatException('目录记录过大');
  final rows = jsonDecode(fixture.readAsStringSync()) as List;
  final songs = <SongSearchResult>[];
  for (final row in rows) {
    if (row is! Map || row['catalogSuccess'] != true) {
      throw const FormatException('歌曲目录核对未完成');
    }
    songs.add(
      SongSearchResult.fromJson(Map<String, dynamic>.from(row['song'] as Map)),
    );
  }
  if (songs.length != 6) throw const FormatException('目录记录数量不正确');

  // 默认接口、Qing 备用入口及自动模式均使用同一组歌曲进行比较。
  const routes = [
    _Route(PlaybackSource.chksz, 'ChKSz'),
    _Route(PlaybackSource.qingMusic, 'QingMusic'),
    _Route(PlaybackSource.hyw, 'HYWmusic'),
    _Route(PlaybackSource.xinghai, '星海'),
    _Route(PlaybackSource.gdStudio, 'GDStudio'),
    _Route(
      PlaybackSource.qingMusic,
      'QingMusic备用',
      qingUrl: 'https://qt.haitangw.net/v1/music/resolve-url',
    ),
    _Route(PlaybackSource.automatic, '自动模式'),
    // 模拟播放器排除已失败的 QingMusic 后重新竞速，只用于定向恢复复验。
    _Route(
      PlaybackSource.automatic,
      '自动恢复重解析',
      excludedSources: {PlaybackSource.qingMusic},
    ),
  ];
  final selected = (Platform.environment['SOURCE_AUDIT_PAIRS'] ?? '').split(
    ',',
  );
  final onlySong = Platform.environment['SOURCE_AUDIT_ONLY_SONG'] ?? '';
  final filter = <String>{};
  for (final pair in selected) {
    if (pair.isNotEmpty) filter.add(pair);
  }
  final report = File(
    '$_root/results-$network-$phase-${DateTime.now().millisecondsSinceEpoch}.jsonl',
  );
  report.writeAsStringSync('');
  print('AUDIT_FILE=${report.path}');

  // 测试逐条运行；高音质仅抽测每个平台的第一首，避免无界请求。
  for (final route in routes) {
    if (route.excludedSources.isNotEmpty && phase != 'retry') continue;
    for (final song in songs) {
      final pair = '${route.key}:${song.platform.code}';
      if (filter.isNotEmpty && !filter.contains(pair)) continue;
      if (onlySong.isNotEmpty && song.name != onlySong) continue;
      if (phase == 'quality' && song.name != '海阔天空') continue;
      for (final quality in _qualities(song.platform, phase)) {
        test(
          '$network ${route.label} ${song.platform.label} ${song.name} $quality',
          () async {
            final result = await _auditOne(route, song, quality, network);
            await report.writeAsString(
              '${jsonEncode(result)}\n',
              mode: FileMode.append,
            );
            print('AUDIT ${jsonEncode(result)}');
            expect(
              result['readable'],
              isTrue,
              reason: result['errorCode'] as String?,
            );
          },
          timeout: const Timeout(Duration(seconds: 40)),
        );
      }
    }
  }
}

List<String> _qualities(MusicPlatform platform, String phase) {
  // 区分请求音质和实际音频容器，解析方可能自行回退。
  if (phase != 'quality') {
    return [platform == MusicPlatform.netease ? 'standard' : '128k'];
  }
  if (platform == MusicPlatform.netease) {
    return const ['exhigh', 'lossless', 'hires', 'jymaster'];
  }
  return const ['320k', 'flac', 'hires', 'master'];
}

Future<Map<String, dynamic>> _auditOne(
  _Route route,
  SongSearchResult song,
  String quality,
  String network,
) async {
  var config = PlaybackSourceConfig.defaults();
  if (route.qingUrl != null) {
    config = config.copyWith(qingMusicUrl: route.qingUrl);
  }
  final api = ApiService(apiKey: '', playbackSourceConfig: config);
  final watch = Stopwatch()..start();
  final result = <String, dynamic>{
    'source': route.key,
    'sourceLabel': route.label,
    'platform': song.platform.code,
    'songId': song.id,
    'song': song.name,
    'artist': song.artist,
    'requestedQuality': quality,
    'network': network,
    'startedAtUtc': DateTime.now().toUtc().toIso8601String(),
    'personalApiKeyConfigured': false,
    'xinghaiLicenseConfigured': false,
    'excludedQingMusic': route.excludedSources.contains(
      PlaybackSource.qingMusic,
    ),
    'resolved': false,
    'readable': false,
  };
  try {
    // 手动源只解析指定源；自动模式另行记录最终胜出的源。
    final detail = await api.resolvePlayback(
      source: route.source,
      platform: song.platform,
      id: song.id,
      quality: quality,
      name: song.name,
      artist: song.artist,
      album: song.album,
      albumId: song.albumId,
      duration: song.duration,
      excludedSources: route.excludedSources,
    );
    result['resolved'] = true;
    result['resolvedSource'] = detail.playbackSource?.value;
    final format = detail.format;
    if (format != null && RegExp(r'^[a-zA-Z0-9]{1,12}$').hasMatch(format)) {
      result['declaredFormat'] = format;
    }
    await _readAudio(detail, result);
  } catch (error) {
    // 报告不保留播放 URL、签名或异常全文，只保存定位所需的阶段和错误码。
    result['readable'] = false;
    result['failedStage'] = result['resolved'] == true ? 'audio' : 'resolve';
    result['errorCode'] = _safeErrorCode(error);
  } finally {
    api.close();
    result['elapsedMs'] = watch.elapsedMilliseconds;
  }
  return result;
}

Future<void> _readAudio(SongDetail detail, Map<String, dynamic> result) async {
  final client = http.Client();
  StreamIterator<List<int>>? iterator;
  final watch = Stopwatch()..start();
  try {
    // 使用项目解析出的播放请求头；即使服务忽略 Range，也只保留固定前缀。
    final request = http.Request('GET', Uri.parse(detail.url));
    request.headers.addAll(detail.playbackHeaders ?? const {});
    request.headers['Range'] = 'bytes=0-511';
    final response = await client.send(request).timeout(_audioTimeout);
    result['audioHttp'] = response.statusCode;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException('AUDIO_HTTP_${response.statusCode}', '音频端点拒绝读取');
    }
    iterator = StreamIterator<List<int>>(response.stream);
    final prefix = <int>[];
    while (prefix.length < _audioLimit) {
      final remaining = _audioTimeout - watch.elapsed;
      if (remaining <= Duration.zero) throw TimeoutException('音频读取超时');
      if (!await iterator.moveNext().timeout(remaining)) break;
      final chunk = iterator.current;
      final count = (_audioLimit - prefix.length).clamp(0, chunk.length);
      prefix.addAll(chunk.sublist(0, count));
    }
    result['audioBytes'] = prefix.length;
    result['container'] = _container(prefix);
    result.addAll(_flacInfo(prefix));
    if (prefix.length != _audioLimit || result['container'] == 'unknown') {
      throw const ApiException('AUDIO_PREFIX_INVALID', '未读取到完整有效音频前缀');
    }
    result['readable'] = true;
  } finally {
    // 关闭连接并取消流，超时、失败和达到前缀上限均走同一清理路径。
    client.close();
    await iterator?.cancel();
  }
}

String _container(List<int> bytes) {
  if (bytes.length < 8) return 'unknown';
  final prefix = String.fromCharCodes(bytes.sublist(0, 8));
  if (prefix.startsWith('ID3')) return 'MP3';
  if (prefix.startsWith('fLaC')) return 'FLAC';
  if (prefix.startsWith('OggS')) return 'Ogg';
  if (prefix.startsWith('RIFF')) return 'WAV';
  if (prefix.substring(4, 8) == 'ftyp') return 'MP4';
  if (bytes[0] == 0xff &&
      (bytes[1] & 0xe0) == 0xe0 &&
      (bytes[1] & 0x06) != 0 &&
      ((bytes[1] >> 3) & 3) != 1) {
    return 'MP3';
  }
  if (bytes[0] == 0xff && (bytes[1] & 0xf6) == 0xf0) return 'AAC';
  return 'unknown';
}

String _safeErrorCode(Object error) {
  if (error is ApiException) {
    return RegExp(r'^[A-Za-z0-9_]{1,64}$').hasMatch(error.code)
        ? error.code
        : 'RESOLVE_ERROR';
  }
  if (error is TimeoutException) return 'TIMEOUT';
  if (error is HandshakeException) return 'TLS_FAILED';
  if (error is http.ClientException) {
    // 只输出固定分类，不输出可能带有临时播放 URL 的错误消息。
    final message = error.message.toLowerCase();
    if (message.contains('proxy') && message.contains('tunnel')) {
      return 'PROXY_TUNNEL_FAILED';
    }
    if (message.contains('failed host lookup')) return 'DNS_FAILED';
    if (message.contains('connection closed')) return 'CONNECTION_CLOSED';
    if (message.contains('connection reset')) return 'CONNECTION_RESET';
    if (message.contains('certificate_verify_failed')) return 'TLS_FAILED';
  }
  return error.runtimeType.toString();
}

Map<String, int> _flacInfo(List<int> bytes) {
  // RFC 9639 §8.2 要求首个块为 34 字节 STREAMINFO；字段范围先校验。
  if (bytes.length < 42) return const {};
  final signature = String.fromCharCodes(bytes.sublist(0, 4));
  final blockType = bytes[4] & 0x7f;
  final blockBytes = (bytes[5] << 16) | (bytes[6] << 8) | bytes[7];
  if (signature != 'fLaC' || blockType != 0 || blockBytes != 34) {
    return const {};
  }

  // 字节 18–21 以位字段存放采样率、声道和位深；直接按规范提取。
  final sampleRate = (bytes[18] << 12) | (bytes[19] << 4) | (bytes[20] >> 4);
  final channels = ((bytes[20] & 0x0e) >> 1) + 1;
  final bitDepth = (((bytes[20] & 1) << 4) | (bytes[21] >> 4)) + 1;
  if (sampleRate == 0 || bitDepth < 4 || bitDepth > 32) return const {};
  return {
    'flacSampleRateHz': sampleRate,
    'flacChannels': channels,
    'flacBitsPerSample': bitDepth,
  };
}

void _verifyFlacInfo() {
  // 规范附录 D.1.3 的独立实例：44100 Hz、双声道、16 bit。
  const bytes = [
    0x66,
    0x4c,
    0x61,
    0x43,
    0x80,
    0x00,
    0x00,
    0x22,
    0x10,
    0x00,
    0x10,
    0x00,
    0x00,
    0x00,
    0x0f,
    0x00,
    0x00,
    0x0f,
    0x0a,
    0xc4,
    0x42,
    0xf0,
    0x00,
    0x00,
    0x00,
    0x01,
    0x3e,
    0x84,
    0xb4,
    0x18,
    0x07,
    0xdc,
    0x69,
    0x03,
    0x07,
    0x58,
    0x6a,
    0x3d,
    0xad,
    0x1a,
    0x2e,
    0x0f,
  ];
  expect(_flacInfo(bytes), {
    'flacSampleRateHz': 44100,
    'flacChannels': 2,
    'flacBitsPerSample': 16,
  });
  expect(_flacInfo(const [1, 2]), isEmpty);
}

class _Route {
  final PlaybackSource source;
  final String label;
  final String? qingUrl;
  final Set<PlaybackSource> excludedSources;
  const _Route(
    this.source,
    this.label, {
    this.qingUrl,
    this.excludedSources = const {},
  });
  String get key {
    if (excludedSources.isNotEmpty) return 'automatic_recovery';
    if (qingUrl != null) return 'qing_mirror';
    return source.value;
  }
}

class _AuditProxy extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    // 临时脚本使用已存在的系统代理，应用自身网络配置不变。
    final client = super.createHttpClient(context);
    client.findProxy = (_) => 'PROXY 127.0.0.1:10808';
    return client;
  }
}
