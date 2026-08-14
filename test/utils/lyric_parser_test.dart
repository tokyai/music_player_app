import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/utils/lyric_parser.dart';

void main() {
  test('parses, expands and sorts LRC timestamps', () {
    final lines = LyricParser.parse(
      '[00:02.50]second\n[00:01.125][00:03.00]shared',
    );

    expect(lines.map((line) => line.text), ['shared', 'second', 'shared']);
    expect(lines[0].time, const Duration(seconds: 1, milliseconds: 125));
    expect(lines[1].time, const Duration(seconds: 2, milliseconds: 500));
  });

  test('merges a nearby translation and finds the active line', () {
    final original = [
      LyricLine(const Duration(seconds: 1), 'one'),
      LyricLine(const Duration(seconds: 3), 'three'),
    ];
    final translated = [
      LyricLine(const Duration(milliseconds: 1400), '一'),
    ];

    final merged = LyricParser.mergeTranslation(original, translated);

    expect(merged.first.text, 'one\n一');
    expect(
      LyricParser.findCurrentIndex(
        merged,
        const Duration(seconds: 2),
      ),
      0,
    );
  });
}
