import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_player_app/models/song.dart';
import 'package:music_player_app/services/api_service.dart';

void main() {
  test('retries one server error and returns the recovered response', () async {
    var requestCount = 0;

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
          if (requestCount == 1) {
            return http.Response('temporarily unavailable', 503);
          }
          return http.Response(
            '{"data":{"list":[]}}',
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        });
      },
    );

    expect(requestCount, 2);
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
        if (request.url.path == '/api-qq/search') {
          return _jsonResponse({
            'data': {
              'list': [
                {
                  'songmid': 'qq-mid',
                  'songname': 'QQ测试歌',
                  'singer': [
                    {'name': 'QQ歌手'},
                  ],
                  'vid': 'qq-vid',
                },
              ],
            },
          });
        }
        if (request.url.host == 'u.y.qq.com') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
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
        if (request.url.path == '/api-netease/song/detail') {
          return _jsonResponse({
            'songs': [
              {'id': '163-id', 'mv': 163001},
            ],
          });
        }
        if (request.url.path == '/api-netease/mv/url') {
          expect(request.url.queryParameters['r'], '1080');
          return _jsonResponse({
            'data': {'url': 'https://video.test/netease-1080.mp4'},
          });
        }
        if (request.url.path == '/api-kugou-search/api/v3/search/song') {
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
  });
}

http.Response _jsonResponse(Map<String, dynamic> body) => http.Response(
  jsonEncode(body),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);
