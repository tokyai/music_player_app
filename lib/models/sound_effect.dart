class SoundEffectPreset {
  final int id;
  final int type;
  final String name;
  final String description;
  final List<String> tags;

  const SoundEffectPreset({
    required this.id,
    required this.type,
    required this.name,
    required this.description,
    this.tags = const [],
  });

  factory SoundEffectPreset.fromMap(Map<Object?, Object?> map) {
    return SoundEffectPreset(
      id: (map['id'] as num?)?.toInt() ?? 0,
      type: (map['type'] as num?)?.toInt() ?? 1,
      name: map['name'] as String? ?? '',
      description: map['description'] as String? ?? '',
      tags: (map['tags'] as List<Object?>? ?? const [])
          .whereType<String>()
          .where((tag) => tag.trim().isNotEmpty)
          .toList(growable: false),
    );
  }
}

class SoundEffectAvailability {
  final bool available;
  final String state;
  final String message;
  final List<SoundEffectPreset> presets;

  const SoundEffectAvailability({
    required this.available,
    required this.state,
    required this.message,
    required this.presets,
  });

  const SoundEffectAvailability.unsupported([this.message = '当前平台不支持 DSP'])
    : available = false,
      state = 'unsupported',
      presets = const [];

  factory SoundEffectAvailability.fromMap(Map<Object?, Object?> map) {
    final presets = (map['presets'] as List<Object?>? ?? const [])
        .whereType<Map<Object?, Object?>>()
        .map(SoundEffectPreset.fromMap)
        .where((preset) => preset.id > 0 && preset.name.isNotEmpty)
        .toList(growable: false);
    return SoundEffectAvailability(
      available: map['available'] == true,
      state: map['state'] as String? ?? 'error',
      message: map['message'] as String? ?? '',
      presets: presets,
    );
  }
}
