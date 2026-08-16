import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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
    Uri? requested;
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
        requested = request.url;
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'code': 200,
              'total': 41,
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
    expect(requested?.queryParameters['limit'], '20');
    expect(requested?.queryParameters['offset'], '40');
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
  });

  test('locally slices a complete QQ response into pages', () async {
    Uri? requested;
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
        requested = request.url;
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'data': {
                'songnum': 21,
                'songlist': List.generate(
                  21,
                  (index) => {
                    'songmid': 'mid-${index + 1}',
                    'songname': '歌曲 ${index + 1}',
                    'singer': [
                      {'name': '歌手'},
                    ],
                    'albumname': '专辑',
                  },
                ),
              },
            }),
          ),
          200,
        );
      }),
    );
    expect(requested?.queryParameters['song_begin'], '20');
    expect(requested?.queryParameters['song_num'], '20');
  });
}
