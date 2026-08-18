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
    final translated = [LyricLine(const Duration(milliseconds: 1400), '一')];

    final merged = LyricParser.mergeTranslation(original, translated);

    expect(merged.first.text, 'one\n一');
    expect(LyricParser.findCurrentIndex(merged, const Duration(seconds: 2)), 0);
  });

  test('parses YRC words and calculates glyph-level progress', () {
    final lines = LyricParser.parseEnhanced(
      '[1000,2000](1000,1000,0)你(2000,1000,0)好',
    );

    expect(lines, hasLength(1));
    expect(lines.single.text, '你好');
    expect(lines.single.words, hasLength(2));
    expect(lines.single.words.first.time, const Duration(seconds: 1));
    expect(lines.single.words.last.time, const Duration(seconds: 2));
    expect(
      lines.single.progressAt(const Duration(milliseconds: 1500)),
      closeTo(0.25, 0.001),
    );
    expect(
      lines.single.progressAt(const Duration(milliseconds: 2500)),
      closeTo(0.75, 0.001),
    );
  });

  test('parses QRC absolute and KRC relative word timing', () {
    final qrc = LyricParser.parseEnhanced(
      '[1000,800]你(1000,300)好(1300,500)',
    ).single;
    final krc = LyricParser.parseEnhanced(
      '[2000,600]<0,200,0>今<200,400,0>天',
    ).single;

    expect(qrc.text, '你好');
    expect(qrc.words.last.time, const Duration(milliseconds: 1300));
    expect(krc.text, '今天');
    expect(krc.words.first.time, const Duration(milliseconds: 2000));
    expect(krc.words.last.time, const Duration(milliseconds: 2200));
  });

  test('plain LRC progress falls back to the next line timestamp', () {
    final line = LyricParser.parse('[00:01.00]普通歌词').single;

    expect(
      line.progressAt(
        const Duration(seconds: 2),
        fallbackEnd: const Duration(seconds: 3),
      ),
      closeTo(0.5, 0.001),
    );
  });
}
