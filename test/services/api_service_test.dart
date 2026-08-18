import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/services/api_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'falls back when the official QQ recommendation request fails',
    () async {
      var requestCount = 0;
      final requestedHosts = <String>[];

      await http.runWithClient(
        () async {
          final api = ApiService(apiKey: '');
          try {
            final playlists = await api.qqRecommendPlaylists();
            expect(playlists, isEmpty);
          } finally {
            api.close();
          }
        },
        () {
          return MockClient((request) async {
            requestCount++;
            requestedHosts.add(request.url.host);
            if (requestCount == 1) {
              return http.Response('temporarily unavailable', 503);
            }
            return http.Response(
              '{"data":{"list":[]}}',
              200,
              headers: const {
                'content-type': 'application/json; charset=utf-8',
              },
            );
          });
        },
      );

      expect(requestCount, 2);
      expect(requestedHosts, ['u.y.qq.com', '161.118.252.183']);
    },
  );

  test('fills Netease search covers from the official album schema', () async {
    final requested = <Uri>[];

    await http.runWithClient(
      () async {
        final api = ApiService(apiKey: '');
        try {
          final songs = await api.neteaseSearch('周杰伦');
          expect(songs, hasLength(1));
          expect(songs.single.id, '509781655');
          expect(
            songs.single.coverUrl,
            'https://music.126.net/official-cover.jpg',
          );
        } finally {
          api.close();
        }
      },
      () => MockClient((request) async {
        requested.add(request.url);
        if (request.url.path == '/api/search/get/web') {
          return _jsonResponse({
            'code': 200,
            'result': {
              'songs': [
                {
                  'id': 509781655,
                  'name': '想你就写信 (Live)',
                  'artists': [
                    {'name': '周杰伦'},
                  ],
                  'album': {'name': '演唱会'},
                  'duration': 240000,
                },
              ],
            },
          });
        }
        if (request.url.path == '/api/song/detail') {
          return _jsonResponse({
            'code': 200,
            'songs': [
              {
                'id': 509781655,
                'name': '想你就写信 (Live)',
                'artists': [
                  {'name': '周杰伦'},
                ],
                'album': {
                  'name': '演唱会',
                  'picUrl': 'http://music.126.net/official-cover.jpg',
                },
              },
            ],
          });
        }
        return http.Response('not found', 404);
      }),
    );

    expect(requested.map((uri) => uri.path), [
      '/api/search/get/web',
      '/api/song/detail',
    ]);
    expect(
      requested.every((uri) => uri.host == 'interface.music.163.com'),
      isTrue,
    );
  });

  test('requests twenty-song Netease pages with an offset', () async {
    final requested = <Uri>[];
    await http.runWithClient(
      () async {
        final api = ApiService(apiKey: '');
        try {
          final page = await api.neteasePlaylistTracks(
            'playlist-id',
            limit: 20,
            offset: 40,
          );
          expect(page.tracks, hasLength(1));
          expect(page.total, 41);
        } finally {
          api.close();
        }
      },
      () => MockClient((request) async {
        requested.add(request.url);
        if (request.url.path == '/api/v6/playlist/detail') {
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'code': 200,
                'playlist': {
                  'trackCount': 41,
                  'trackIds': List.generate(41, (index) => {'id': index + 1}),
                },
              }),
            ),
            200,
          );
        }
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'code': 200,
              'songs': [
                {
                  'id': 41,
                  'name': '最后一首',
                  'ar': [
                    {'name': '歌手'},
                  ],
                  'al': {'name': '专辑', 'picUrl': 'https://cover.test/a.jpg'},
                },
              ],
            }),
          ),
          200,
        );
      }),
    );
    expect(requested.map((uri) => uri.path), [
      '/api/v6/playlist/detail',
      '/api/song/detail',
    ]);
    expect(
      requested.every((uri) => uri.host == 'interface.music.163.com'),
      isTrue,
    );
    expect(requested.last.queryParameters['ids'], contains('41'));
  });

  test('requests native Kugou pages', () async {
    Uri? requested;
    await http.runWithClient(
      () async {
        final api = ApiService(apiKey: '');
        try {
          final page = await api.kugouPlaylistTracks(
            'special-id',
            page: 3,
            limit: 20,
          );
          expect(page.tracks, hasLength(1));
          expect(page.total, 41);
        } finally {
          api.close();
        }
      },
      () => MockClient((request) async {
        requested = request.url;
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'data': {
                'total': 41,
                'info': [
                  {'hash': 'hash-41', 'filename': '歌手 - 最后一首'},
                ],
              },
            }),
          ),
          200,
        );
      }),
    );
    expect(requested?.queryParameters['page'], '3');
    expect(requested?.queryParameters['pagesize'], '20');
    expect(requested?.host, 'mobilecdn.kugou.com');
  });

  test('requests a real twenty-song QQ page from musicu', () async {
    Map<String, dynamic>? requestedBody;
    Uri? requestedUrl;
    await http.runWithClient(
      () async {
        final api = ApiService(apiKey: '');
        try {
          final page = await api.qqPlaylistTracks(
            'diss-id',
            limit: 20,
            offset: 20,
          );
          expect(page.tracks, hasLength(1));
          expect(page.tracks.single.id, 'mid-21');
          expect(page.total, 21);
        } finally {
          api.close();
        }
      },
      () => MockClient((request) async {
        requestedUrl = request.url;
        requestedBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'req_0': {
                'code': 0,
                'data': {
                  'dirinfo': {'songnum': 21},
                  'songlist': [
                    {
                      'mid': 'mid-21',
                      'name': '歌曲 21',
                      'singer': [
                        {'name': '歌手'},
                      ],
                      'album': {'name': '专辑', 'mid': 'album-mid'},
                    },
                  ],
                },
              },
            }),
          ),
          200,
        );
      }),
    );
    final req = requestedBody!['req_0'] as Map<String, dynamic>;
    final params = req['param'] as Map<String, dynamic>;
    expect(requestedUrl?.host, 'u.y.qq.com');
    expect(params['song_begin'], 20);
    expect(params['song_num'], 20);
  });

  test('maps all three platforms to the QingMusic resolver contract', () async {
    final requests = <Map<String, dynamic>>[];
    await http.runWithClient(
      () async {
        final api = ApiService(apiKey: 'unused-by-qing');
        try {
          final qq = await api.qingMusic(
            MusicPlatform.qq,
            'qq-mid',
            quality: 'hires',
          );
          final netease = await api.qingMusic(
            MusicPlatform.netease,
            '163-id',
            quality: 'jymaster',
          );
          final kugou = await api.qingMusic(
            MusicPlatform.kugou,
            'kg-hash',
            quality: 'master',
          );

          expect(qq.url, 'https://audio.test/song.flac');
          expect(qq.playbackHeaders, {'Referer': 'https://player.test/'});
          expect(netease.url, isNotEmpty);
          expect(kugou.url, isNotEmpty);
        } finally {
          api.close();
        }
      },
      () => MockClient((request) async {
        expect(
          request.url.toString(),
          'https://musicserver.haitangw.cc/v1/music/resolve-url',
        );
        expect(request.method, 'POST');
        requests.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response(
          jsonEncode({
            'code': 0,
            'message': 'ok',
            'data': {
              'url': 'https://audio.test/song.flac',
              'playbackHeaders': {'Referer': 'https://player.test/'},
            },
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      }),
    );

    expect(requests, [
      {'source': 'tx', 'rid': 'qq-mid', 'level': 'lossless'},
      {'source': 'wy', 'rid': '163-id', 'level': 'jymaster'},
      {'source': 'kg', 'rid': 'kg-hash', 'level': 'clear'},
    ]);
  });

  test('lyrics use platform endpoints without touching the proxy', () async {
    final requests = <Uri>[];
    await http.runWithClient(
      () async {
        final api = ApiService(apiKey: 'not-needed');
        try {
          final netease = await api.neteaseLyric('163-id');
          final qq = await api.qqLyric('qq-mid');
          final kugou = await api.getLyric(MusicPlatform.kugou, 'kg-hash');

          expect(netease.original, contains('网易直连歌词'));
          expect(netease.wordSynced, contains('(1000,500,0)网'));
          expect(qq.original, contains('QQ & 直连歌词'));
          expect(qq.wordSynced, contains('Q(1000,500)'));
          expect(kugou?.original, contains('酷狗直连歌词'));
        } finally {
          api.close();
        }
      },
      () => MockClient((request) async {
        requests.add(request.url);
        if (request.url.host == 'interface3.music.163.com') {
          return _jsonResponse({
            'code': 200,
            'lrc': {'lyric': '[00:01.00]网易直连歌词'},
            'tlyric': {'lyric': '[00:01.00]Netease translation'},
            'yrc': {'lyric': '[1000,1000](1000,500,0)网(1500,500,0)易'},
          });
        }
        if (request.url.host == 'c.y.qq.com') {
          return _jsonResponse({
            'code': 0,
            'lyric': '[00:01.00]QQ &#38; 直连歌词',
            'trans': '',
            'qrc': '[1000,1000]Q(1000,500)Q(1500,500)',
          });
        }
        if (request.url.host == 'm.kugou.com') {
          return http.Response.bytes(utf8.encode('[00:01.00]酷狗直连歌词'), 200);
        }
        return http.Response('unexpected proxy request', 500);
      }),
    );

    expect(requests.map((request) => request.host), [
      'interface3.music.163.com',
      'c.y.qq.com',
      'm.kugou.com',
    ]);
    expect(
      requests.any((request) => request.host == '161.118.252.183'),
      isFalse,
    );
  });

  test(
    'Netease and QQ lyrics use the proxy only after direct failure',
    () async {
      final requests = <Uri>[];
      await http.runWithClient(
        () async {
          final api = ApiService(apiKey: 'not-needed');
          try {
            expect(
              (await api.neteaseLyric('163-id')).original,
              contains('网易兜底歌词'),
            );
            expect((await api.qqLyric('qq-mid')).original, contains('QQ兜底歌词'));
          } finally {
            api.close();
          }
        },
        () => MockClient((request) async {
          requests.add(request.url);
          if (request.url.host != '161.118.252.183') {
            return http.Response('direct unavailable', 503);
          }
          if (request.url.path == '/api-netease/lyric') {
            return _jsonResponse({
              'lrc': {'lyric': '[00:01.00]网易兜底歌词'},
            });
          }
          if (request.url.path == '/api-qq/lyric') {
            return _jsonResponse({
              'data': {'lyric': '[00:01.00]QQ兜底歌词', 'trans': ''},
            });
          }
          return http.Response('not found', 404);
        }),
      );

      expect(requests.map((request) => request.host), [
        'interface3.music.163.com',
        '161.118.252.183',
        'c.y.qq.com',
        '161.118.252.183',
      ]);
    },
  );

  test('lyric candidates are sorted by metadata relevance', () async {
    await http.runWithClient(
      () async {
        final api = ApiService(apiKey: '');
        try {
          final results = await api.searchLyricCandidates(
            platform: MusicPlatform.qq,
            keyword: '晴天',
            currentName: '晴天',
            currentArtist: '周杰伦',
            currentAlbum: '叶惠美',
          );
          expect(results.map((song) => song.id), [
            'exact-current',
            'exact-other',
            'live-version',
          ]);
        } finally {
          api.close();
        }
      },
      () => MockClient((request) async {
        expect(request.url.host, 'u.y.qq.com');
        return _jsonResponse({
          'req_1': {
            'code': 0,
            'data': {
              'body': {
                'song': {
                  'list': [
                    {
                      'mid': 'live-version',
                      'name': '晴天 (Live)',
                      'singer': [
                        {'name': '其他歌手'},
                      ],
                      'album': {'name': '现场专辑'},
                    },
                    {
                      'mid': 'exact-other',
                      'name': '晴天',
                      'singer': [
                        {'name': '其他歌手'},
                      ],
                      'album': {'name': '其他专辑'},
                    },
                    {
                      'mid': 'exact-current',
                      'name': '晴天',
                      'singer': [
                        {'name': '周杰伦'},
                      ],
                      'album': {'name': '叶惠美'},
                    },
                  ],
                },
              },
            },
          },
        });
      }),
    );
  });

  test('resolves platform-specific MV URLs for all three platforms', () async {
    final requests = <Uri>[];
    await http.runWithClient(
      () async {
        final api = ApiService(apiKey: '');
        try {
          expect(
            await api.musicVideoUrl(
              platform: MusicPlatform.qq,
              songId: 'qq-mid',
              songName: 'QQ测试歌',
              artist: 'QQ歌手',
            ),
            'https://video.test/qq-1080.mp4',
          );
          expect(
            await api.musicVideoUrl(
              platform: MusicPlatform.netease,
              songId: '163-id',
              songName: '网易测试歌',
              artist: '网易歌手',
            ),
            'https://video.test/netease-1080.mp4',
          );
          expect(
            await api.musicVideoUrl(
              platform: MusicPlatform.kugou,
              songId: 'kg-hash',
              songName: '酷狗测试歌',
              artist: '酷狗歌手',
            ),
            'http://video.test/kugou-1080.mp4',
          );
        } finally {
          api.close();
        }
      },
      () => MockClient((request) async {
        requests.add(request.url);
        if (request.url.host == 'u.y.qq.com') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (body.containsKey('req_1')) {
            return _jsonResponse({
              'req_1': {
                'code': 0,
                'data': {
                  'body': {
                    'song': {
                      'list': [
                        {
                          'mid': 'qq-mid',
                          'name': 'QQ测试歌',
                          'singer': [
                            {'name': 'QQ歌手'},
                          ],
                          'mv': {'vid': 'qq-vid'},
                        },
                      ],
                    },
                  },
                },
              },
            });
          }
          expect(body['getMvUrl']['param']['vids'], ['qq-vid']);
          return _jsonResponse({
            'getMvUrl': {
              'data': {
                'qq-vid': {
                  'mp4': [
                    {
                      'freeflow_url': ['https://video.test/qq-720.mp4'],
                    },
                    {
                      'freeflow_url': ['https://video.test/qq-1080.mp4'],
                    },
                  ],
                },
              },
            },
          });
        }
        if (request.url.host == 'interface.music.163.com' &&
            request.url.path == '/api/song/detail') {
          return _jsonResponse({
            'songs': [
              {'id': '163-id', 'mv': 163001},
            ],
          });
        }
        if (request.url.host == 'interface.music.163.com' &&
            request.url.path == '/api/song/enhance/play/mv/url') {
          expect(request.url.queryParameters['r'], '1080');
          return _jsonResponse({
            'data': {'url': 'https://video.test/netease-1080.mp4'},
          });
        }
        if (request.url.host == 'mobilecdn.kugou.com' &&
            request.url.path == '/api/v3/search/song') {
          return _jsonResponse({
            'data': {
              'info': [
                {
                  'hash': 'kg-hash',
                  'songname': '酷狗测试歌',
                  'singername': '酷狗歌手',
                  'mvhash': 'kg-mv-hash',
                },
              ],
            },
          });
        }
        if (request.url.host == 'm.kugou.com') {
          expect(request.url.queryParameters['hash'], 'kg-mv-hash');
          return _jsonResponse({
            'mvdata': {
              'sq': {'downurl': 'http://video.test/kugou-1080.mp4'},
            },
          });
        }
        return http.Response('not found', 404);
      }),
    );

    expect(requests, hasLength(6));
    expect(
      requests.any((request) => request.host == '161.118.252.183'),
      isFalse,
    );
  });

  test('rejects an empty Netease playlist response', () async {
    await http.runWithClient(() async {
      final api = ApiService(apiKey: '');
      try {
        await expectLater(
          api.neteasePlaylistSummary('12345'),
          throwsA(
            isA<ApiException>()
                .having((error) => error.code, 'code', 'PLAYLIST_NOT_FOUND')
                .having((error) => error.message, 'message', contains('未找到歌单')),
          ),
        );
      } finally {
        api.close();
      }
    }, () => MockClient((_) async => _jsonResponse({'code': 200})));
  });

  test('rejects empty QQ playlist responses from both routes', () async {
    var requests = 0;
    await http.runWithClient(
      () async {
        final api = ApiService(apiKey: '');
        try {
          await expectLater(
            api.qqPlaylist('12345'),
            throwsA(
              isA<ApiException>()
                  .having((error) => error.code, 'code', 'PLAYLIST_NOT_FOUND')
                  .having(
                    (error) => error.message,
                    'message',
                    contains('未找到歌单'),
                  ),
            ),
          );
        } finally {
          api.close();
        }
      },
      () => MockClient((request) async {
        requests++;
        if (request.url.host == 'u.y.qq.com') {
          return _jsonResponse({
            'req_0': {'code': 0, 'data': <String, dynamic>{}},
          });
        }
        return _jsonResponse({'data': <String, dynamic>{}});
      }),
    );
    expect(requests, 2);
  });
}

http.Response _jsonResponse(Map<String, dynamic> body) => http.Response(
  jsonEncode(body),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);
