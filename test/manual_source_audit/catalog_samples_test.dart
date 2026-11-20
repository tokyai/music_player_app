// 联网测试将受控 JSON 写入 flutter_test 事件流，供审计报告收集。
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/services/api_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 从项目目录接口核对两首歌曲的原平台标识；SHIXIAOYANG，2026/11/19。
void main() {
  // 联网验证须显式启用，常规离线测试直接跳过。
  if (Platform.environment['SOURCE_AUDIT_ENABLED'] != '1') {
    test(
      'manual catalogue audit',
      _collectSamples,
      skip: 'Set SOURCE_AUDIT_ENABLED=1 to run the live audit',
    );
    return;
  }
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = _CatalogProxy();
  SharedPreferences.setMockInitialValues({});
  test(
    'collects verified recording identities for all three platforms',
    _collectSamples,
    timeout: const Timeout(Duration(seconds: 180)),
  );
}

Future<void> _collectSamples() async {
  // 所有渠道使用同一组已核对元数据，避免把 QQ mid 误配成另一首歌曲。
  final records = <Map<String, dynamic>>[];
  var successful = 0;
  for (final platform in configurableMusicPlatforms) {
    // 网易云公开目录没有《晴天》原唱；QQ/酷狗保留它以核对跨平台曲库限制。
    final queries = [
      {'title': '海阔天空', 'artist': 'Beyond'},
      platform == MusicPlatform.netease
          ? {'title': '光辉岁月', 'artist': 'Beyond'}
          : {'title': '晴天', 'artist': '周杰伦'},
    ];
    for (final query in queries) {
      final record = await _collectOne(
        platform,
        query['title']!,
        query['artist']!,
      );
      records.add(record);
      if (record['catalogSuccess'] == true) successful++;
      print('CATALOG ${jsonEncode(record)}');
    }
  }

  // 即使一个平台失败也保存其余结果；此文件只包含公开歌曲元数据。
  final output = File('tmp/source_audit_20261119/catalog-samples.json');
  await output.parent.create(recursive: true);
  await output.writeAsString(
    const JsonEncoder.withIndent('  ').convert(records),
  );
  expect(successful, 6);
}

Future<Map<String, dynamic>> _collectOne(
  MusicPlatform platform,
  String title,
  String artist,
) async {
  final api = ApiService(apiKey: '');
  final record = <String, dynamic>{
    'platform': platform.code,
    'title': title,
    'artist': artist,
    'catalogSuccess': false,
  };
  try {
    // 优先选择同名原唱录音，跳过现场版和翻唱。
    final songs = await api.search(platform, '$title $artist');
    for (final song in songs) {
      if (song.name.trim() != title ||
          !song.artist.toLowerCase().contains(artist.toLowerCase()) ||
          song.id.isEmpty) {
        continue;
      }
      // 海阔天空的 QQ/酷狗录音为 324 秒，排除网易云同名的 239 秒剪辑版。
      if (title == '海阔天空' &&
          (song.duration == null ||
              song.duration! < 300 ||
              song.duration! > 340)) {
        continue;
      }
      record['catalogSuccess'] = true;
      record['song'] = song.toJson();
      return record;
    }
    record['errorCode'] = 'RECORDING_NOT_FOUND';
  } catch (error) {
    // 不把可能包含 URL 的异常全文写入报告。
    record['errorCode'] = error is ApiException
        ? error.code
        : error.runtimeType.toString();
  } finally {
    // 失败和提前返回也关闭所有 HTTP 与平台资源。
    api.close();
  }
  return record;
}

class _CatalogProxy extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    // 仅目录核对脚本复用本机已有代理；生产应用配置保持原样。
    final client = super.createHttpClient(context);
    client.findProxy = (_) => 'PROXY 127.0.0.1:10808';
    return client;
  }
}
