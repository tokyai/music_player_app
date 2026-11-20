import 'dart:convert';
import 'dart:math';

import 'song.dart';

/// A lightweight result for the configuration-page source probe.
///
/// [reachable] means that the configured endpoint returned an HTTP response;
/// [successful] additionally requires a 2xx response without a reported
/// business/authentication error. A reachable 4xx/5xx is
/// useful information because it distinguishes an online service from a DNS,
/// TLS, timeout, or connection failure.
class PlaybackSourceTestResult {
  final PlaybackSource source;
  final bool reachable;
  final int? latencyMs;
  final int? statusCode;
  final String message;
  final String? errorCode;

  const PlaybackSourceTestResult({
    required this.source,
    required this.reachable,
    required this.latencyMs,
    required this.statusCode,
    required this.message,
    this.errorCode,
  });

  bool get successful =>
      reachable &&
      errorCode == null &&
      statusCode != null &&
      statusCode! >= 200 &&
      statusCode! < 300;

  @override
  String toString() =>
      'PlaybackSourceTestResult(source: ${source.value}, reachable: $reachable, '
      'latencyMs: $latencyMs, statusCode: $statusCode, message: $message)';
}

/// 用户保存的音源启停和个人凭据，兼容旧版本的接口配置字段。
///
/// 新音源按稳定 ID 和通用凭据字段保存；线上请求协议由服务器维护。
/// 旧接口地址仅用于历史配置、备份和定向协议回归，不作为线上解析入口。
class PlaybackSourceConfig {
  static const preferenceKey = 'playback_source_config_v1';
  static const maxSerializedChars = 32 * 1024;

  static const defaultChkszBaseUrl = 'https://api.chksz.com';
  static const defaultQingMusicUrl =
      'https://musicserver.haitangw.cc/v1/music/resolve-url';
  static const defaultHywBaseUrl = 'http://103.79.184.97';
  static const defaultHywCardKey = '6C1F-53W0-GRKI-EVFG';
  static const defaultXinghaiUrl = 'https://yy1.zddyr.top/lx/api/';
  static const defaultXinghaiIpUrl = '';
  static const defaultXinghaiClient = 'XingHaiMusicSource/v3.2.20 (Android)';
  static const defaultGdStudioUrl = 'https://music-api.gdstudio.xyz/api.php';

  static const _maxUrlLength = 2048;
  static const _maxSecretLength = 1024;
  static const _maxHeaderLength = 256;

  // 仅迁移已随应用发布的旧默认值；用户自行填写的地址、请求头保持原样。
  static const _legacyChkszBaseUrl = 'http://161.118.252.183/api-chksz';
  static const _legacyHywCardKey = 'PYPW-QFRL-3DBF-95O6';
  static const _legacyXinghaiUrl = 'https://yy.zddyr.top/lx/api/';
  static const _legacyXinghaiIpUrl = 'https://yy.zddyr.top/ip.php';
  static const _legacyXinghaiClient = 'XingHaiMusicSource/v3.2.13 (Android)';

  final bool chkszEnabled;
  final bool qingMusicEnabled;
  final bool hywEnabled;
  final bool xinghaiEnabled;
  final bool gdStudioEnabled;
  final String chkszBaseUrl;
  final String qingMusicUrl;
  final String hywBaseUrl;
  final String hywCardKey;
  final String xinghaiUrl;
  final String xinghaiIpUrl;
  final String xinghaiClient;
  final String xinghaiDeviceId;
  final String xinghaiLicenseKey;
  final String gdStudioUrl;
  final List<String> disabledRemoteSources;
  final Map<String, Map<String, String>> remoteCredentials;

  const PlaybackSourceConfig({
    required this.chkszEnabled,
    required this.qingMusicEnabled,
    required this.hywEnabled,
    required this.xinghaiEnabled,
    required this.gdStudioEnabled,
    required this.chkszBaseUrl,
    required this.qingMusicUrl,
    required this.hywBaseUrl,
    required this.hywCardKey,
    required this.xinghaiUrl,
    required this.xinghaiIpUrl,
    required this.xinghaiClient,
    required this.xinghaiDeviceId,
    this.xinghaiLicenseKey = '',
    required this.gdStudioUrl,
    this.disabledRemoteSources = const [],
    this.remoteCredentials = const {},
  });

  factory PlaybackSourceConfig.defaults() => PlaybackSourceConfig(
    chkszEnabled: true,
    qingMusicEnabled: true,
    hywEnabled: true,
    xinghaiEnabled: true,
    gdStudioEnabled: true,
    chkszBaseUrl: defaultChkszBaseUrl,
    qingMusicUrl: defaultQingMusicUrl,
    hywBaseUrl: defaultHywBaseUrl,
    hywCardKey: defaultHywCardKey,
    xinghaiUrl: defaultXinghaiUrl,
    xinghaiIpUrl: defaultXinghaiIpUrl,
    xinghaiClient: defaultXinghaiClient,
    xinghaiDeviceId: _newXinghaiDeviceId(),
    gdStudioUrl: defaultGdStudioUrl,
  );

  factory PlaybackSourceConfig.fromJson(Map<String, dynamic> json) {
    final defaults = PlaybackSourceConfig.defaults();
    bool flag(String key, bool fallback) {
      final value = json[key];
      if (value == null) return fallback;
      if (value is! bool) throw FormatException('$key 必须是布尔值');
      return value;
    }

    String text(String key, String fallback) {
      final value = json[key];
      if (value == null) return fallback;
      if (value is! String) throw FormatException('$key 必须是字符串');
      return value;
    }

    // 读取旧备份与已保存的设置时，同步更新失效的预置入口。
    String migratedText(String key, String previous, String current) {
      final value = text(key, current);
      return value.trim() == previous ? current : value;
    }

    // 公益卡密只随官方预置服务迁移，不能覆盖自建服务或用户的授权卡密。
    final savedHywBase = text('hywBaseUrl', defaults.hywBaseUrl);
    final savedHywKey = text('hywCardKey', defaults.hywCardKey);
    final migrateHywKey =
        savedHywBase.trim().replaceFirst(RegExp(r'/+$'), '') ==
            defaultHywBaseUrl &&
        savedHywKey.trim() == _legacyHywCardKey;

    return PlaybackSourceConfig(
      chkszEnabled: flag('chkszEnabled', defaults.chkszEnabled),
      qingMusicEnabled: flag('qingMusicEnabled', defaults.qingMusicEnabled),
      hywEnabled: flag('hywEnabled', defaults.hywEnabled),
      xinghaiEnabled: flag('xinghaiEnabled', defaults.xinghaiEnabled),
      gdStudioEnabled: flag('gdStudioEnabled', defaults.gdStudioEnabled),
      chkszBaseUrl: migratedText(
        'chkszBaseUrl',
        _legacyChkszBaseUrl,
        defaults.chkszBaseUrl,
      ),
      qingMusicUrl: text('qingMusicUrl', defaults.qingMusicUrl),
      hywBaseUrl: savedHywBase,
      hywCardKey: migrateHywKey ? defaults.hywCardKey : savedHywKey,
      xinghaiUrl: migratedText(
        'xinghaiUrl',
        _legacyXinghaiUrl,
        defaults.xinghaiUrl,
      ),
      xinghaiIpUrl: migratedText(
        'xinghaiIpUrl',
        _legacyXinghaiIpUrl,
        defaults.xinghaiIpUrl,
      ),
      xinghaiClient: migratedText(
        'xinghaiClient',
        _legacyXinghaiClient,
        defaults.xinghaiClient,
      ),
      xinghaiDeviceId: text('xinghaiDeviceId', defaults.xinghaiDeviceId),
      xinghaiLicenseKey: text('xinghaiLicenseKey', ''),
      gdStudioUrl: text('gdStudioUrl', defaults.gdStudioUrl),
      disabledRemoteSources: _readDisabledSources(
        json['disabledRemoteSources'],
      ),
      remoteCredentials: _readRemoteCredentials(json['remoteCredentials']),
    ).validated();
  }

  bool isEnabled(PlaybackSource source) {
    if (source == PlaybackSource.automatic) return true;
    if (disabledRemoteSources.contains(source.value)) return false;
    return switch (source) {
      PlaybackSource.chksz => chkszEnabled,
      PlaybackSource.qingMusic => qingMusicEnabled,
      PlaybackSource.hyw => hywEnabled,
      PlaybackSource.xinghai => xinghaiEnabled,
      PlaybackSource.gdStudio => gdStudioEnabled,
      _ => true,
    };
  }

  /// 服务端解析需排除的音源，兼容升级前保存的启停状态。
  List<String> get disabledSourceIds {
    final result = <String>{...disabledRemoteSources};
    for (final source in PlaybackSource.values) {
      if (!isEnabled(source)) result.add(source.value);
    }
    return List<String>.unmodifiable(result);
  }

  /// 合并旧版本个人凭据；显式保存的空值表示用户清除了该凭据。
  ///
  /// [apiKey] 是升级前独立保存的个人 ChKSz API Key。
  /// SHIXIAOYANG，2026/11/20。
  Map<String, Map<String, String>> credentialsForServer({
    required String apiKey,
  }) {
    final result = <String, Map<String, String>>{};
    for (final entry in remoteCredentials.entries) {
      result[entry.key] = Map<String, String>.from(entry.value);
    }
    final chksz = result.putIfAbsent('chksz', () => <String, String>{});
    chksz.putIfAbsent('apiKey', () => apiKey);
    // 公开预置卡密由服务器更新；只迁移用户自定义的个人卡密。
    if (!usesHywPublicSource) {
      final hyw = result.putIfAbsent('hyw', () => <String, String>{});
      hyw.putIfAbsent('hywCardKey', () => hywCardKey);
    }
    final xinghai = result.putIfAbsent('xinghai', () => <String, String>{});
    xinghai.putIfAbsent('xinghaiLicenseKey', () => xinghaiLicenseKey);
    return result;
  }

  /// 是否使用官方公益配置，用于匹配该发行版实际开放的平台和音质。
  bool get usesHywPublicSource =>
      hywBaseUrl.replaceFirst(RegExp(r'/+$'), '') == defaultHywBaseUrl &&
      hywCardKey == defaultHywCardKey;

  PlaybackSourceConfig validated() {
    final normalizedChksz = _validateUrl(
      chkszBaseUrl,
      'ChKSz URL',
      required: chkszEnabled,
    );
    final normalizedQing = _validateUrl(
      qingMusicUrl,
      'QingMusic URL',
      required: qingMusicEnabled,
    );
    final normalizedHyw = _validateUrl(
      hywBaseUrl,
      'HYW URL',
      required: hywEnabled,
    );
    final normalizedXinghai = _validateUrl(
      xinghaiUrl,
      '星海 URL',
      required: xinghaiEnabled,
    );
    final normalizedXinghaiIp = _validateUrl(
      xinghaiIpUrl,
      '星海 IP URL',
      required: false,
    );
    final normalizedGd = _validateUrl(
      gdStudioUrl,
      'GDStudio URL',
      required: gdStudioEnabled,
    );
    final normalizedCardKey = hywCardKey.trim();
    final normalizedClient = xinghaiClient.trim();
    final normalizedDeviceId = xinghaiDeviceId.trim();
    final normalizedLicenseKey = xinghaiLicenseKey.trim();
    if (normalizedCardKey.length > _maxSecretLength) {
      throw const FormatException('HYW Card Key 过长');
    }
    if (normalizedClient.length > _maxHeaderLength) {
      throw const FormatException('星海 X-Client 过长');
    }
    if (normalizedLicenseKey.length > _maxSecretLength) {
      throw const FormatException('星海授权卡密过长');
    }
    final invalidHeader = RegExp(r'[^\x20-\x7e]');
    // HYW 允许中文卡密通过 query 传递，但任何卡密都不能包含控制字符。
    if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(normalizedCardKey)) {
      throw const FormatException('HYW Card Key 不能包含换行或控制字符');
    }
    if (invalidHeader.hasMatch(normalizedClient) ||
        invalidHeader.hasMatch(normalizedLicenseKey)) {
      throw const FormatException('X-Client 和授权卡密只能包含单行 ASCII 字符');
    }
    if (normalizedDeviceId.length > _maxHeaderLength) {
      throw const FormatException('星海设备 ID 过长');
    }
    if (xinghaiEnabled && normalizedClient.isEmpty) {
      throw const FormatException('启用星海时必须填写 X-Client');
    }
    if (xinghaiEnabled && normalizedDeviceId.isEmpty) {
      throw const FormatException('启用星海时必须填写设备 ID');
    }
    final normalizedDisabled = _readDisabledSources(disabledRemoteSources);
    final normalizedCredentials = _readRemoteCredentials(remoteCredentials);
    final result = copyWith(
      chkszBaseUrl: normalizedChksz,
      qingMusicUrl: normalizedQing,
      hywBaseUrl: normalizedHyw,
      hywCardKey: normalizedCardKey,
      xinghaiUrl: normalizedXinghai,
      xinghaiIpUrl: normalizedXinghaiIp,
      xinghaiClient: normalizedClient,
      xinghaiDeviceId: normalizedDeviceId,
      xinghaiLicenseKey: normalizedLicenseKey,
      gdStudioUrl: normalizedGd,
      disabledRemoteSources: normalizedDisabled,
      remoteCredentials: normalizedCredentials,
    );
    if (jsonEncode(result.toJson()).length > maxSerializedChars) {
      throw const FormatException('备用源配置过大');
    }
    return result;
  }

  PlaybackSourceConfig copyWith({
    bool? chkszEnabled,
    bool? qingMusicEnabled,
    bool? hywEnabled,
    bool? xinghaiEnabled,
    bool? gdStudioEnabled,
    String? chkszBaseUrl,
    String? qingMusicUrl,
    String? hywBaseUrl,
    String? hywCardKey,
    String? xinghaiUrl,
    String? xinghaiIpUrl,
    String? xinghaiClient,
    String? xinghaiDeviceId,
    String? xinghaiLicenseKey,
    String? gdStudioUrl,
    List<String>? disabledRemoteSources,
    Map<String, Map<String, String>>? remoteCredentials,
  }) => PlaybackSourceConfig(
    chkszEnabled: chkszEnabled ?? this.chkszEnabled,
    qingMusicEnabled: qingMusicEnabled ?? this.qingMusicEnabled,
    hywEnabled: hywEnabled ?? this.hywEnabled,
    xinghaiEnabled: xinghaiEnabled ?? this.xinghaiEnabled,
    gdStudioEnabled: gdStudioEnabled ?? this.gdStudioEnabled,
    chkszBaseUrl: chkszBaseUrl ?? this.chkszBaseUrl,
    qingMusicUrl: qingMusicUrl ?? this.qingMusicUrl,
    hywBaseUrl: hywBaseUrl ?? this.hywBaseUrl,
    hywCardKey: hywCardKey ?? this.hywCardKey,
    xinghaiUrl: xinghaiUrl ?? this.xinghaiUrl,
    xinghaiIpUrl: xinghaiIpUrl ?? this.xinghaiIpUrl,
    xinghaiClient: xinghaiClient ?? this.xinghaiClient,
    xinghaiDeviceId: xinghaiDeviceId ?? this.xinghaiDeviceId,
    xinghaiLicenseKey: xinghaiLicenseKey ?? this.xinghaiLicenseKey,
    gdStudioUrl: gdStudioUrl ?? this.gdStudioUrl,
    disabledRemoteSources: disabledRemoteSources ?? this.disabledRemoteSources,
    remoteCredentials: remoteCredentials ?? this.remoteCredentials,
  );

  Map<String, dynamic> toJson() => {
    'version': 1,
    'chkszEnabled': chkszEnabled,
    'qingMusicEnabled': qingMusicEnabled,
    'hywEnabled': hywEnabled,
    'xinghaiEnabled': xinghaiEnabled,
    'gdStudioEnabled': gdStudioEnabled,
    'chkszBaseUrl': chkszBaseUrl,
    'qingMusicUrl': qingMusicUrl,
    'hywBaseUrl': hywBaseUrl,
    'hywCardKey': hywCardKey,
    'xinghaiUrl': xinghaiUrl,
    'xinghaiIpUrl': xinghaiIpUrl,
    'xinghaiClient': xinghaiClient,
    'xinghaiDeviceId': xinghaiDeviceId,
    'xinghaiLicenseKey': xinghaiLicenseKey,
    'gdStudioUrl': gdStudioUrl,
    'disabledRemoteSources': disabledRemoteSources,
    'remoteCredentials': remoteCredentials,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlaybackSourceConfig &&
          other.chkszEnabled == chkszEnabled &&
          other.qingMusicEnabled == qingMusicEnabled &&
          other.hywEnabled == hywEnabled &&
          other.xinghaiEnabled == xinghaiEnabled &&
          other.gdStudioEnabled == gdStudioEnabled &&
          other.chkszBaseUrl == chkszBaseUrl &&
          other.qingMusicUrl == qingMusicUrl &&
          other.hywBaseUrl == hywBaseUrl &&
          other.hywCardKey == hywCardKey &&
          other.xinghaiUrl == xinghaiUrl &&
          other.xinghaiIpUrl == xinghaiIpUrl &&
          other.xinghaiClient == xinghaiClient &&
          other.xinghaiDeviceId == xinghaiDeviceId &&
          other.xinghaiLicenseKey == xinghaiLicenseKey &&
          other.gdStudioUrl == gdStudioUrl &&
          _sameDisabledSources(
            other.disabledRemoteSources,
            disabledRemoteSources,
          ) &&
          _sameRemoteCredentials(other.remoteCredentials, remoteCredentials);

  @override
  int get hashCode => Object.hash(
    chkszEnabled,
    qingMusicEnabled,
    hywEnabled,
    xinghaiEnabled,
    gdStudioEnabled,
    chkszBaseUrl,
    qingMusicUrl,
    hywBaseUrl,
    hywCardKey,
    xinghaiUrl,
    xinghaiIpUrl,
    xinghaiClient,
    xinghaiDeviceId,
    xinghaiLicenseKey,
    gdStudioUrl,
    Object.hashAll(disabledRemoteSources),
    _remoteCredentialsHash(remoteCredentials),
  );

  static List<String> _readDisabledSources(Object? value) {
    if (value == null) return const [];
    if (value is! List || value.length > 32) {
      throw const FormatException('停用音源列表无效或过大');
    }
    final result = <String>{};
    for (final item in value) {
      if (item is! String ||
          !PlaybackSource.isValidId(item) ||
          item == PlaybackSource.automatic.value) {
        throw const FormatException('停用音源标识无效');
      }
      result.add(item);
    }
    final sorted = result.toList()..sort();
    return List<String>.unmodifiable(sorted);
  }

  static Map<String, Map<String, String>> _readRemoteCredentials(
    Object? value,
  ) {
    if (value == null) return const {};
    if (value is! Map || value.length > 32) {
      throw const FormatException('音源凭据无效或过大');
    }
    final result = <String, Map<String, String>>{};
    for (final entry in value.entries) {
      final sourceId = entry.key;
      final fields = entry.value;
      if (sourceId is! String ||
          !PlaybackSource.isValidId(sourceId) ||
          sourceId == PlaybackSource.automatic.value ||
          fields is! Map ||
          fields.length > 16) {
        throw const FormatException('音源凭据字段无效');
      }
      result[sourceId] = _validatedCredentialFields(fields);
    }
    return Map<String, Map<String, String>>.unmodifiable(result);
  }

  static Map<String, String> _validatedCredentialFields(Map fields) {
    final result = <String, String>{};
    for (final entry in fields.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is! String ||
          !RegExp(r'^[a-zA-Z][a-zA-Z0-9_]{0,63}$').hasMatch(key) ||
          value is! String ||
          value.length > _maxSecretLength ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
        throw const FormatException('音源凭据必须是有限长度的单行文本');
      }
      result[key] = value;
    }
    return Map<String, String>.unmodifiable(result);
  }

  static bool _sameDisabledSources(List<String> first, List<String> second) {
    if (first.length != second.length) return false;
    for (var index = 0; index < first.length; index++) {
      if (first[index] != second[index]) return false;
    }
    return true;
  }

  static bool _sameRemoteCredentials(
    Map<String, Map<String, String>> first,
    Map<String, Map<String, String>> second,
  ) {
    if (first.length != second.length) return false;
    for (final source in first.entries) {
      final otherFields = second[source.key];
      if (otherFields == null || otherFields.length != source.value.length) {
        return false;
      }
      for (final field in source.value.entries) {
        if (otherFields[field.key] != field.value) return false;
      }
    }
    return true;
  }

  static int _remoteCredentialsHash(Map<String, Map<String, String>> value) {
    final hashes = <int>[];
    final sources = value.keys.toList()..sort();
    for (final source in sources) {
      final fields = value[source]!;
      final keys = fields.keys.toList()..sort();
      for (final key in keys) {
        hashes.add(Object.hash(source, key, fields[key]));
      }
    }
    return Object.hashAll(hashes);
  }

  static String _validateUrl(
    String value,
    String label, {
    required bool required,
  }) {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      if (required) throw FormatException('$label 不能为空');
      return '';
    }
    if (normalized.length > _maxUrlLength) {
      throw FormatException('$label 过长');
    }
    final uri = Uri.tryParse(normalized);
    if (uri == null ||
        !uri.hasScheme ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        RegExp(r'[\x00-\x20\x7f]').hasMatch(normalized) ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw FormatException('$label 必须是有效的 HTTP/HTTPS 地址');
    }
    return normalized;
  }

  static String _newXinghaiDeviceId() {
    final time = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    var randomPart = '';
    try {
      randomPart = Random.secure().nextInt(0x7fffffff).toRadixString(36);
    } catch (_) {
      randomPart = Random().nextInt(0x7fffffff).toRadixString(36);
    }
    return 'lx-online-${randomPart.padLeft(6, '0').substring(0, 6)}'
        '${time.length > 4 ? time.substring(time.length - 4) : time}';
  }
}
