import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_player_app/services/bilibili_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('uses official signed video, play and QR endpoints', () async {
    final signedPaths = <String>[];
    final service = BilibiliService(
      client: MockClient((request) async {
        final path = request.url.path;
        if (path == '/x/web-interface/nav') {
          return _json({
            'code': 0,
            'data': {
              'wbi_img': {
                'img_url':
                    'https://i0.hdslb.com/bfs/wbi/abcdefghijklmnopqrstuvwxyz012345.png',
                'sub_url':
                    'https://i0.hdslb.com/bfs/wbi/9876543210abcdefghijklmnopqrstuvwxyz.png',
              },
            },
          });
        }
        if (path == '/x/web-interface/wbi/search/type') {
          signedPaths.add(path);
          expect(request.url.queryParameters['w_rid'], isNotEmpty);
          return _json({
            'code': 0,
            'data': {
              'result': [
                {
                  'bvid': 'BV1test',
                  'title': '<em>测试</em>视频',
                  'author': '测试UP主',
                  'pic': '//example.com/cover.jpg',
                  'duration': '02:03',
                },
              ],
            },
          });
        }
        if (path == '/x/web-interface/view') {
          return _json({
            'code': 0,
            'data': {
              'bvid': 'BV1test',
              'title': '视频总标题',
              'desc': '视频简介',
              'duration': 123,
              'owner': {'name': '测试UP主'},
              'pages': [
                {'cid': 101, 'page': 1, 'part': '第一P', 'duration': 123},
              ],
            },
          });
        }
        if (path == '/x/player/wbi/playurl') {
          signedPaths.add(path);
          expect(request.url.queryParameters['w_rid'], isNotEmpty);
          if (request.url.queryParameters['fnval'] == '0') {
            return _json({
              'code': 0,
              'data': {
                'durl': [
                  {'url': 'https://example.com/video.mp4'},
                ],
              },
            });
          }
          return _json({
            'code': 0,
            'data': {
              'timelength': 123000,
              'dash': {
                'audio': [
                  {
                    'id': 30280,
                    'baseUrl': 'https://example.com/audio.m4s',
                    'bandwidth': 192000,
                  },
                ],
                'video': [
                  {
                    'id': 80,
                    'baseUrl': 'https://example.com/video.m4s',
                    'bandwidth': 2500000,
                  },
                ],
              },
            },
          });
        }
        if (path.endsWith('/qrcode/generate')) {
          return _json({
            'code': 0,
            'data': {
              'qrcode_key': 'qr-key',
              'url': 'https://passport.bilibili.com/login',
            },
          });
        }
        if (path.endsWith('/qrcode/poll')) {
          return _json({
            'code': 0,
            'data': {'code': 86101, 'message': '未扫码'},
          });
        }
        return _json({'code': -404, 'message': 'not found'});
      }),
    );
    addTearDown(service.dispose);

    final search = await service.search('测试');
    expect(search.single.name, '测试视频');
    expect(search.single.duration, 123);
    final info = await service.videoInfo('BV1test');
    expect(info.pages.single.title, '第一P');
    final play = await service.playInfo('BV1test', 101);
    expect(play.audioStreams.single.label, '192K');
    expect(play.videoStreams.single.label, '1080P');
    expect(await service.videoUrl('BV1test', 101, 80), endsWith('video.mp4'));
    final qr = await service.createQrCode();
    expect(qr.key, 'qr-key');
    expect((await service.pollQrCode(qr.key)).status, BilibiliQrStatus.waiting);
    expect(signedPaths, hasLength(3));
  });
}

http.Response _json(Map<String, dynamic> body) => http.Response(
  jsonEncode(body),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);
