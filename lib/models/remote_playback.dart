import 'song.dart';

/// 服务端声明的用户凭据字段；字段定义不包含任何凭据值。
class PlaybackCredentialField {
  final String key;
  final String label;
  final List<String> requiredPlatforms;

  const PlaybackCredentialField({
    required this.key,
    required this.label,
    required this.requiredPlatforms,
  });

  factory PlaybackCredentialField.fromJson(Map<String, dynamic> json) {
    final key = _text(json, 'key', 64);
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9_]{0,63}$').hasMatch(key)) {
      throw const FormatException('音源凭据字段无效');
    }
    return PlaybackCredentialField(
      key: key,
      label: _text(json, 'label', 80),
      requiredPlatforms: _platforms(json['requiredPlatforms'] ?? const []),
    );
  }

  Map<String, dynamic> toJson() => {
    'key': key,
    'label': label,
    'requiredPlatforms': requiredPlatforms,
  };
}

/// 通用音源能力；新增音源不需要客户端增加枚举或解析分支。
class RemotePlaybackSource {
  final PlaybackSource source;
  final String description;
  final List<String> platforms;
  final List<String> experimentalPlatforms;
  final List<PlaybackCredentialField> credentials;

  const RemotePlaybackSource({
    required this.source,
    required this.description,
    required this.platforms,
    this.experimentalPlatforms = const [],
    this.credentials = const [],
  });

  factory RemotePlaybackSource.fromJson(Map<String, dynamic> json) {
    final id = _text(json, 'id', 64);
    if (id == PlaybackSource.automatic.value) {
      throw const FormatException('服务端音源不能使用自动模式标识');
    }
    final rawFields = json['credentials'] ?? const [];
    if (rawFields is! List || rawFields.length > 16) {
      throw const FormatException('音源凭据字段过多或格式无效');
    }
    final fields = <PlaybackCredentialField>[];
    final fieldKeys = <String>{};
    for (final raw in rawFields) {
      if (raw is! Map<String, dynamic>) {
        throw const FormatException('音源凭据字段格式无效');
      }
      final field = PlaybackCredentialField.fromJson(raw);
      if (!fieldKeys.add(field.key)) {
        throw const FormatException('音源凭据字段重复');
      }
      fields.add(field);
    }
    return RemotePlaybackSource(
      source: PlaybackSource.fromId(id, label: _text(json, 'name', 80)),
      description: _text(json, 'description', 512, allowEmpty: true),
      platforms: _platforms(json['platforms']),
      experimentalPlatforms: _platforms(
        json['experimentalPlatforms'] ?? const [],
      ),
      credentials: List.unmodifiable(fields),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': source.value,
    'name': source.label,
    'description': description,
    'platforms': platforms,
    'experimentalPlatforms': experimentalPlatforms,
    'credentials': credentials.map((field) => field.toJson()).toList(),
  };
}

/// 已验证的服务端能力快照，供选择音源和离线显示使用。
class PlaybackSourceCatalog {
  static const preferenceKey = 'remote_playback_catalog_v1';
  final String revision;
  final List<RemotePlaybackSource> sources;

  const PlaybackSourceCatalog({required this.revision, required this.sources});

  factory PlaybackSourceCatalog.fromJson(Map<String, dynamic> json) {
    if (json['protocolVersion'] != 1) {
      throw const FormatException('音源服务协议不兼容，请更新客户端');
    }
    final rawSources = json['sources'];
    if (rawSources is! List || rawSources.length > 32) {
      throw const FormatException('音源列表格式无效或超过上限');
    }
    final sources = <RemotePlaybackSource>[];
    final ids = <String>{};
    for (final raw in rawSources) {
      if (raw is! Map<String, dynamic>) {
        throw const FormatException('音源列表条目无效');
      }
      final source = RemotePlaybackSource.fromJson(raw);
      if (!ids.add(source.source.value)) {
        throw const FormatException('音源列表标识重复');
      }
      sources.add(source);
    }
    return PlaybackSourceCatalog(
      revision: _text(json, 'revision', 64),
      sources: List.unmodifiable(sources),
    );
  }

  /// 按稳定 ID 查找名称和支持能力，不依赖客户端内置音源列表。
  RemotePlaybackSource? sourceFor(PlaybackSource source) {
    for (final item in sources) {
      if (item.source == source) return item;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'protocolVersion': 1,
    'revision': revision,
    'sources': sources.map((source) => source.toJson()).toList(),
  };
}

String _text(
  Map<String, dynamic> json,
  String key,
  int maximum, {
  bool allowEmpty = false,
}) {
  final value = json[key] ?? (allowEmpty ? '' : null);
  if (value is! String ||
      value.length > maximum ||
      (!allowEmpty && value.trim().isEmpty) ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
    throw FormatException('音源能力字段无效：$key');
  }
  return value;
}

List<String> _platforms(dynamic raw) {
  if (raw is! List || raw.length > 3) {
    throw const FormatException('音源支持平台无效');
  }
  final result = <String>[];
  for (final value in raw) {
    if (value is! String ||
        !const ['qq', '163', 'kugou'].contains(value) ||
        result.contains(value)) {
      throw const FormatException('音源支持平台无效');
    }
    result.add(value);
  }
  return List.unmodifiable(result);
}
