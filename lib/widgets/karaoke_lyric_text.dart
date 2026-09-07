import 'package:flutter/material.dart';

import '../utils/lyric_parser.dart';

class KaraokeLyricText extends StatelessWidget {
  const KaraokeLyricText({
    super.key,
    required this.line,
    required this.position,
    required this.style,
    required this.activeColor,
    required this.pendingColor,
  });

  final LyricLine line;
  final Duration position;
  final TextStyle style;
  final Color activeColor;
  final Color pendingColor;

  static bool canHighlight(LyricLine line) =>
      line.words.length <= 256 &&
      line.primaryText.length <= 2048 &&
      line.hasReliableTokenTiming;

  @override
  Widget build(BuildContext context) {
    if (!canHighlight(line)) {
      return Text(
        line.primaryText,
        style: style,
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }
    return Text.rich(
      TextSpan(
        children: [
          for (final word in line.words)
            TextSpan(
              text: word.text,
              style: TextStyle(
                color: position >= word.endTime
                    ? style.color
                    : position >= word.time
                    ? activeColor
                    : pendingColor,
              ),
            ),
        ],
      ),
      semanticsLabel: line.primaryText,
      style: style,
      textAlign: TextAlign.center,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}
