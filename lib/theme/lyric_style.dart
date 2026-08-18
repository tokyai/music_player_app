import 'package:flutter/material.dart';

/// 歌词显示偏好的持久化键与可选项。
abstract final class LyricStylePreferences {
  static const fontSizeKey = 'lyric_font_size';
  static const lineSpacingKey = 'lyric_line_spacing';
  static const fontFamilyKey = 'lyric_font_family';
  static const fontWeightKey = 'lyric_font_weight';
}

enum LyricFontFamilyPreset {
  system(value: 'system', label: '系统默认', description: '跟随设备字体，兼容性最好'),
  heiti(
    value: 'heiti',
    label: '黑体',
    description: '笔画清晰，适合车机远距离阅读',
    fontFamily: 'sans-serif',
    fontFamilyFallback: ['Noto Sans CJK SC', 'Noto Sans SC'],
  ),
  songti(
    value: 'songti',
    label: '宋体',
    description: '衬线风格，长歌词阅读更柔和',
    fontFamily: 'serif',
    fontFamilyFallback: [
      'Noto Serif CJK SC',
      'Noto Serif SC',
      'Songti SC',
      'STSong',
    ],
  ),
  kaiti(
    value: 'kaiti',
    label: '楷体',
    description: '手写楷书风格，随设备字体能力回退',
    fontFamily: 'KaiTi',
    fontFamilyFallback: ['STKaiti', 'Kaiti SC', 'FZKai-Z03', 'serif'],
  );

  final String value;
  final String label;
  final String description;
  final String? fontFamily;
  final List<String>? fontFamilyFallback;

  const LyricFontFamilyPreset({
    required this.value,
    required this.label,
    required this.description,
    this.fontFamily,
    this.fontFamilyFallback,
  });

  static LyricFontFamilyPreset fromValue(String? value) {
    for (final preset in values) {
      if (preset.value == value) return preset;
    }
    return system;
  }
}

enum LyricFontWeightPreset {
  regular(
    value: 400,
    label: '常规',
    weight: FontWeight.w400,
    currentLineWeight: FontWeight.w700,
  ),
  medium(
    value: 500,
    label: '中等',
    weight: FontWeight.w500,
    currentLineWeight: FontWeight.w800,
  ),
  semiBold(
    value: 600,
    label: '半粗',
    weight: FontWeight.w600,
    currentLineWeight: FontWeight.w900,
  ),
  bold(
    value: 700,
    label: '粗体',
    weight: FontWeight.w700,
    currentLineWeight: FontWeight.w900,
  );

  final int value;
  final String label;
  final FontWeight weight;
  final FontWeight currentLineWeight;

  const LyricFontWeightPreset({
    required this.value,
    required this.label,
    required this.weight,
    required this.currentLineWeight,
  });

  static LyricFontWeightPreset fromValue(int? value) {
    for (final preset in values) {
      if (preset.value == value) return preset;
    }
    return medium;
  }
}
