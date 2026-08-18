/// 带独立时间范围的歌词字词。
class LyricWord {
  final Duration time;
  final Duration duration;
  final String text;

  const LyricWord({
    required this.time,
    required this.duration,
    required this.text,
  });

  Duration get endTime => time + duration;
}

/// 歌词解析工具：将 LRC / YRC / QRC / KRC 文本解析为时间轴歌词。
class LyricLine {
  final Duration time;
  final String text;
  final Duration? endTime;
  final List<LyricWord> words;

  const LyricLine(this.time, this.text, {this.endTime, this.words = const []});

  String get primaryText => text.split('\n').first;

  /// 当前行的演唱进度。增强歌词按真实字词时间计算；普通 LRC 则在
  /// 当前行与下一行之间做连续估算。
  double progressAt(Duration position, {Duration? fallbackEnd}) {
    if (position <= time) return 0;

    if (words.isNotEmpty) {
      final totalWeight = words.fold<int>(
        0,
        (total, word) => total + _textWeight(word.text),
      );
      if (totalWeight > 0) {
        var playedWeight = 0.0;
        for (final word in words) {
          final weight = _textWeight(word.text).toDouble();
          if (position >= word.endTime || word.duration <= Duration.zero) {
            playedWeight += weight;
            continue;
          }
          if (position > word.time) {
            final elapsed = (position - word.time).inMicroseconds;
            final total = word.duration.inMicroseconds;
            if (total > 0) {
              playedWeight += weight * (elapsed / total).clamp(0.0, 1.0);
            }
          }
          break;
        }
        return (playedWeight / totalWeight).clamp(0.0, 1.0);
      }
    }

    var resolvedEnd = endTime ?? fallbackEnd;
    if (resolvedEnd == null || resolvedEnd <= time) {
      resolvedEnd = time + const Duration(seconds: 4);
    }
    if (position >= resolvedEnd) return 1;
    final total = (resolvedEnd - time).inMicroseconds;
    if (total <= 0) return 1;
    return ((position - time).inMicroseconds / total).clamp(0.0, 1.0);
  }

  static int _textWeight(String value) {
    final count = value.runes.length;
    return count == 0 ? 1 : count;
  }
}

class LyricParser {
  /// 解析 LRC 格式歌词
  static List<LyricLine> parse(String? lrcText) {
    if (lrcText == null || lrcText.isEmpty) return [];

    final lines = <LyricLine>[];
    final regex = RegExp(r'\[(\d{2}):(\d{2})[.:](\d{2,3})\]');
    final lrcLines = lrcText.split('\n');

    for (final line in lrcLines) {
      final matches = regex.allMatches(line);
      if (matches.isEmpty) continue;
      final text = line.replaceAll(regex, '').trim();
      if (text.isEmpty) continue;
      for (final match in matches) {
        final min = int.parse(match.group(1)!);
        final sec = int.parse(match.group(2)!);
        final msStr = match.group(3)!;
        final ms = msStr.length == 2 ? int.parse(msStr) * 10 : int.parse(msStr);
        final duration = Duration(minutes: min, seconds: sec, milliseconds: ms);
        lines.add(LyricLine(duration, text));
      }
    }

    lines.sort((a, b) => a.time.compareTo(b.time));
    return lines;
  }

  /// 解析网易 YRC、QQ QRC 与酷狗 KRC 常见的逐字歌词格式。
  ///
  /// - YRC: `[行开始,行时长](字开始,字时长,0)字`
  /// - QRC: `[行开始,行时长]字(字开始,字时长)`
  /// - KRC: `[行开始,行时长]<相对开始,字时长,0>字`
  static List<LyricLine> parseEnhanced(String? lyricText) {
    if (lyricText == null || lyricText.trim().isEmpty) return const [];

    final lines = <LyricLine>[];
    final linePattern = RegExp(r'^\s*\[(\d+),(\d+)\](.*)$');
    for (final rawLine in lyricText.replaceAll('\r', '').split('\n')) {
      final lineMatch = linePattern.firstMatch(rawLine);
      if (lineMatch == null) continue;
      final startMs = int.tryParse(lineMatch.group(1)!) ?? 0;
      final durationMs = int.tryParse(lineMatch.group(2)!) ?? 0;
      final content = lineMatch.group(3)?.trim() ?? '';
      if (content.isEmpty) continue;

      final words = _trimOuterWordWhitespace(
        _parseEnhancedWords(
          content,
          lineStartMs: startMs,
          lineDurationMs: durationMs,
        ),
      );
      final plainText = words.isEmpty
          ? _stripEnhancedTiming(content)
          : words.map((word) => word.text).join();
      if (plainText.trim().isEmpty) continue;

      final lineStart = Duration(milliseconds: startMs);
      final declaredEnd = lineStart + Duration(milliseconds: durationMs);
      final wordEnd = words.fold<Duration?>(null, (latest, word) {
        if (latest == null || word.endTime > latest) return word.endTime;
        return latest;
      });
      final resolvedEnd = wordEnd != null && wordEnd > declaredEnd
          ? wordEnd
          : declaredEnd;
      lines.add(
        LyricLine(
          lineStart,
          plainText.trim(),
          endTime: resolvedEnd > lineStart ? resolvedEnd : null,
          words: words,
        ),
      );
    }

    lines.sort((a, b) => a.time.compareTo(b.time));
    return lines;
  }

  /// 优先使用逐字格式，普通 LRC 自动回退到行级时间。
  static List<LyricLine> parseBestEffort(String? lyricText) {
    final enhanced = parseEnhanced(lyricText);
    if (enhanced.any((line) => line.words.isNotEmpty)) return enhanced;
    final lrc = parse(lyricText);
    return lrc.isNotEmpty ? lrc : enhanced;
  }

  static List<LyricWord> _parseEnhancedWords(
    String content, {
    required int lineStartMs,
    required int lineDurationMs,
  }) {
    final trimmed = content.trimLeft();
    if (trimmed.startsWith('<')) {
      return _wordsAfterTiming(
        content,
        RegExp(r'<(\d+),(\d+)(?:,[^>]*)?>([^<]*)'),
        lineStartMs: lineStartMs,
        lineDurationMs: lineDurationMs,
        relative: true,
      );
    }
    if (trimmed.startsWith('(')) {
      return _wordsAfterTiming(
        content,
        RegExp(r'\((\d+),(\d+)(?:,[^)]*)?\)([^()]*)'),
        lineStartMs: lineStartMs,
        lineDurationMs: lineDurationMs,
      );
    }

    // QRC 把时间写在对应字词之后。
    final result = <LyricWord>[];
    final qrcPattern = RegExp(r'([^()]+)\((\d+),(\d+)(?:,[^)]*)?\)');
    for (final match in qrcPattern.allMatches(content)) {
      final text = match.group(1) ?? '';
      if (text.isEmpty) continue;
      final rawStart = int.tryParse(match.group(2)!) ?? lineStartMs;
      final duration = int.tryParse(match.group(3)!) ?? 0;
      result.add(
        LyricWord(
          time: Duration(
            milliseconds: _absoluteWordStart(
              lineStartMs,
              lineDurationMs,
              rawStart,
            ),
          ),
          duration: Duration(milliseconds: duration),
          text: text,
        ),
      );
    }
    return result;
  }

  static List<LyricWord> _trimOuterWordWhitespace(List<LyricWord> words) {
    if (words.isEmpty) return words;
    final result = List<LyricWord>.of(words);
    final first = result.first;
    result[0] = LyricWord(
      time: first.time,
      duration: first.duration,
      text: first.text.trimLeft(),
    );
    final lastIndex = result.length - 1;
    final last = result[lastIndex];
    result[lastIndex] = LyricWord(
      time: last.time,
      duration: last.duration,
      text: last.text.trimRight(),
    );
    result.removeWhere((word) => word.text.isEmpty);
    return result;
  }

  static List<LyricWord> _wordsAfterTiming(
    String content,
    RegExp pattern, {
    required int lineStartMs,
    required int lineDurationMs,
    bool relative = false,
  }) {
    final result = <LyricWord>[];
    for (final match in pattern.allMatches(content)) {
      final rawStart = int.tryParse(match.group(1)!) ?? lineStartMs;
      final duration = int.tryParse(match.group(2)!) ?? 0;
      final text = match.group(3) ?? '';
      if (text.isEmpty) continue;
      final absoluteStart = relative
          ? lineStartMs + rawStart
          : _absoluteWordStart(lineStartMs, lineDurationMs, rawStart);
      result.add(
        LyricWord(
          time: Duration(milliseconds: absoluteStart),
          duration: Duration(milliseconds: duration),
          text: text,
        ),
      );
    }
    return result;
  }

  static int _absoluteWordStart(
    int lineStartMs,
    int lineDurationMs,
    int rawStart,
  ) {
    // KRC/YRC 的部分实现会返回相对行首时间。若数值明显早于行首且落在
    // 当前行时长内，则按相对值处理；其他情况视为歌曲绝对时间。
    if (rawStart < lineStartMs && rawStart <= lineDurationMs + 1000) {
      return lineStartMs + rawStart;
    }
    return rawStart;
  }

  static String _stripEnhancedTiming(String content) {
    return content
        .replaceAll(RegExp(r'<\d+,\d+(?:,[^>]*)?>'), '')
        .replaceAll(RegExp(r'\(\d+,\d+(?:,[^)]*)?\)'), '')
        .trim();
  }

  /// 合并原文歌词与翻译歌词
  static List<LyricLine> mergeTranslation(
    List<LyricLine> original,
    List<LyricLine>? translation,
  ) {
    if (translation == null || translation.isEmpty) return original;

    final result = <LyricLine>[];
    for (final o in original) {
      // 找最接近的翻译行（1秒内）
      String? trans;
      Duration? bestDelta;
      for (final t in translation) {
        final delta = (t.time - o.time).abs();
        if (delta.inMilliseconds < 1000) {
          if (bestDelta == null || delta < bestDelta) {
            bestDelta = delta;
            trans = t.text;
          }
        }
      }
      result.add(
        LyricLine(
          o.time,
          trans != null ? '${o.text}\n$trans' : o.text,
          endTime: o.endTime,
          words: o.words,
        ),
      );
    }
    return result;
  }

  /// 根据当前播放进度找到对应歌词索引
  static int findCurrentIndex(List<LyricLine> lines, Duration position) {
    if (lines.isEmpty) return 0;
    int index = 0;
    for (int i = 0; i < lines.length; i++) {
      if (lines[i].time <= position) {
        index = i;
      } else {
        break;
      }
    }
    return index;
  }
}
