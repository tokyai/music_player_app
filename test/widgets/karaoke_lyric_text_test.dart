import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/utils/lyric_parser.dart';
import 'package:music_player_app/widgets/karaoke_lyric_text.dart';

void main() {
  final line = LyricParser.parseEnhanced(
    '[0,2000](0,1000,0)hello (1000,1000,0)world',
  ).single;
  testWidgets(
    'whole timed tokens change color without invented character timing',
    (tester) async {
      expect(line.hasReliableWordTiming, isFalse);
      expect(line.hasReliableTokenTiming, isTrue);
      Future<void> pump(Duration position) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: KaraokeLyricText(
              line: line,
              position: position,
              style: const TextStyle(color: Colors.white, fontSize: 42),
              activeColor: Colors.green,
              pendingColor: Colors.grey,
            ),
          ),
        ),
      );
      await pump(const Duration(milliseconds: 500));
      var spans = (tester.widget<Text>(find.byType(Text)).textSpan as TextSpan)
          .children!
          .cast<TextSpan>();
      expect(spans.map((span) => span.style!.color), [
        Colors.green,
        Colors.grey,
      ]);
      await pump(const Duration(milliseconds: 1500));
      spans = (tester.widget<Text>(find.byType(Text)).textSpan as TextSpan)
          .children!
          .cast<TextSpan>();
      expect(spans.map((span) => span.style!.color), [
        Colors.white,
        Colors.green,
      ]);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'plain, overlapping and oversized timing falls back to line highlighting',
    () {
      expect(
        KaraokeLyricText.canHighlight(const LyricLine(Duration.zero, 'plain')),
        isFalse,
      );
      final invalid = LyricParser.parseEnhanced(
        '[0,2000](0,1200,0)a(1000,1000,0)b',
      ).single;
      expect(KaraokeLyricText.canHighlight(invalid), isFalse);
      final oversized = LyricLine(
        Duration.zero,
        List.filled(300, 'a').join(),
        endTime: const Duration(seconds: 300),
        words: [
          for (var i = 0; i < 300; i++)
            LyricWord(
              time: Duration(seconds: i),
              duration: const Duration(seconds: 1),
              text: 'a',
            ),
        ],
      );
      expect(KaraokeLyricText.canHighlight(oversized), isFalse);
    },
  );
}
