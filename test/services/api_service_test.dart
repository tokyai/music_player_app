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
}
