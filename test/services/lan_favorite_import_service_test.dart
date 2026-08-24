import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:music_player_app/services/lan_favorite_import_service.dart';

void main() {
  test('parses the ideographic separator, trims and deduplicates names', () {
    expect(LanFavoriteImportService.parseSongNames(' 倒带 、七里香、倒 带、半岛铁盒 '), [
      '倒带',
      '七里香',
      '半岛铁盒',
    ]);
    expect(
      () => LanFavoriteImportService.parseSongNames('  、  '),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => LanFavoriteImportService.parseSongNames('歌' * 101),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => LanFavoriteImportService.parseSongNames(
        List<String>.generate(31, (index) => '歌曲$index').join('、'),
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('LAN page accepts one bounded song list and rejects repeats', () async {
    final session = await LanFavoriteImportService.start();
    addTearDown(session.stop);
    final localUri = Uri.parse(session.url).replace(host: '127.0.0.1');

    expect(session.url, matches(RegExp(r'^http://.+:\d+/.+/$')));
    final home = await http.get(localUri).timeout(const Duration(seconds: 5));
    expect(home.statusCode, 200);
    expect(home.body, contains('批量加入收藏歌曲'));
    expect(home.body, contains('倒带、七里香、半岛铁盒'));
    expect(home.headers['cache-control'], 'no-store');

    final missing = await http
        .get(localUri.replace(path: '/invalid/'))
        .timeout(const Duration(seconds: 5));
    expect(missing.statusCode, 404);

    final empty = await http
        .post(localUri.resolve('submit'), body: '  、  ')
        .timeout(const Duration(seconds: 5));
    expect(empty.statusCode, 400);

    final oversized = await http
        .post(localUri.resolve('submit'), body: 'x' * (16 * 1024 + 1))
        .timeout(const Duration(seconds: 5));
    expect(oversized.statusCode, 413);

    final received = session.receivedSongNames.timeout(
      const Duration(seconds: 5),
    );
    final submitted = await http
        .post(localUri.resolve('submit'), body: ' 倒带、七里香、倒带、半岛铁盒 ')
        .timeout(const Duration(seconds: 5));
    expect(submitted.statusCode, 200);
    expect(await received, ['倒带', '七里香', '半岛铁盒']);

    final duplicate = await http
        .post(localUri.resolve('submit'), body: '夜曲')
        .timeout(const Duration(seconds: 5));
    expect(duplicate.statusCode, 409);
  });

  test('stopping an unused LAN session completes its receiver', () async {
    final session = await LanFavoriteImportService.start();
    final received = session.receivedSongNames;

    await session.stop();
    await session.stop();

    expect(await received, isNull);
    expect(session.isActive, isFalse);
  });
}
