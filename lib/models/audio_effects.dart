import 'package:flutter/foundation.dart';

enum EqualizerPreset {
  flat('原声', [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
  pop('流行', [1, 2, 3, 1, 0, -1, 1, 3, 3, 2]),
  rock('摇滚', [4, 3, 2, 0, -2, -1, 1, 3, 4, 4]),
  jazz('爵士', [3, 2, 1, 2, -1, -1, 0, 1, 2, 3]),
  classical('古典', [3, 2, 1, 0, -1, -1, 0, 1, 2, 3]),
  vocal('人声', [-2, -1, 0, 2, 3, 3, 2, 1, 0, -1]);

  const EqualizerPreset(this.label, this.bands);
  final String label;
  final List<double> bands;
}

@immutable
class AudioEffectsSettings {
  static const preferenceKey = 'audio_effects_v1';
  static const frequencies = <double>[
    31,
    62,
    125,
    250,
    500,
    1000,
    2000,
    4000,
    8000,
    16000,
  ];
  static const frequencyLabels = [
    '31',
    '62',
    '125',
    '250',
    '500',
    '1k',
    '2k',
    '4k',
    '8k',
    '16k',
  ];

  const AudioEffectsSettings({
    this.enabled = false,
    this.equalizerEnabled = false,
    this.bands = const [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    this.bassEnabled = false,
    this.bassStrength = 0.3,
    this.surroundEnabled = false,
    this.surroundStrength = 0.3,
    this.balanceEnabled = false,
    this.balance = 0,
  });

  final bool enabled;
  final bool equalizerEnabled;
  final List<double> bands;
  final bool bassEnabled;
  final double bassStrength;
  final bool surroundEnabled;
  final double surroundStrength;
  final bool balanceEnabled;
  final double balance;

  EqualizerPreset? get preset {
    for (final preset in EqualizerPreset.values) {
      if (listEquals(bands, preset.bands)) return preset;
    }
    return null;
  }

  AudioEffectsSettings copyWith({
    bool? enabled,
    bool? equalizerEnabled,
    List<double>? bands,
    bool? bassEnabled,
    double? bassStrength,
    bool? surroundEnabled,
    double? surroundStrength,
    bool? balanceEnabled,
    double? balance,
  }) => AudioEffectsSettings(
    enabled: enabled ?? this.enabled,
    equalizerEnabled: equalizerEnabled ?? this.equalizerEnabled,
    bands: List.unmodifiable(bands ?? this.bands),
    bassEnabled: bassEnabled ?? this.bassEnabled,
    bassStrength: bassStrength ?? this.bassStrength,
    surroundEnabled: surroundEnabled ?? this.surroundEnabled,
    surroundStrength: surroundStrength ?? this.surroundStrength,
    balanceEnabled: balanceEnabled ?? this.balanceEnabled,
    balance: balance ?? this.balance,
  );

  Map<String, dynamic> toJson() => {
    'version': 1,
    'enabled': enabled,
    'equalizerEnabled': equalizerEnabled,
    'bands': bands,
    'bassEnabled': bassEnabled,
    'bassStrength': bassStrength,
    'surroundEnabled': surroundEnabled,
    'surroundStrength': surroundStrength,
    'balanceEnabled': balanceEnabled,
    'balance': balance,
  };

  factory AudioEffectsSettings.fromJson(Map<String, dynamic> json) {
    bool flag(String key) {
      final value = json[key];
      if (value is! bool) throw FormatException('音效 $key 无效');
      return value;
    }

    double number(Object? value, double min, double max) {
      if (value is! num || !value.isFinite || value < min || value > max) {
        throw const FormatException('音效参数超出范围');
      }
      return value.toDouble();
    }

    final bands = json['bands'];
    if (json['version'] != 1 || bands is! List || bands.length != 10) {
      throw const FormatException('音效设置格式无效');
    }
    return AudioEffectsSettings(
      enabled: flag('enabled'),
      equalizerEnabled: flag('equalizerEnabled'),
      bands: List.unmodifiable(bands.map((v) => number(v, -12, 12))),
      bassEnabled: flag('bassEnabled'),
      bassStrength: number(json['bassStrength'], 0, 1),
      surroundEnabled: flag('surroundEnabled'),
      surroundStrength: number(json['surroundStrength'], 0, 0.7),
      balanceEnabled: flag('balanceEnabled'),
      balance: number(json['balance'], -1, 1),
    );
  }
}
