import 'dart:math';

import 'song.dart';

/// A lightweight result for the configuration-page source probe.
///
/// [reachable] means that the configured endpoint returned an HTTP response;
/// [successful] additionally requires a 2xx response. A reachable 4xx/5xx is
/// useful information because it distinguishes an online service from a DNS,
/// TLS, timeout, or connection failure.
class PlaybackSourceTestResult {
  final PlaybackSource source;
  final bool reachable;
  final int? latencyMs;
  final int? statusCode;
  final String message;

  const PlaybackSourceTestResult({
    required this.source,
    required this.reachable,
    required this.latencyMs,
    required this.statusCode,
    required this.message,
  });

  bool get successful =>
      reachable &&
      statusCode != null &&
      statusCode! >= 200 &&
      statusCode! < 300;

  @override
  String toString() =>
      'PlaybackSourceTestResult(source: ${source.value}, reachable: $reachable, '
      'latencyMs: $latencyMs, statusCode: $statusCode, message: $message)';
}

/// 可编辑的第三方播放解析配置。
///
/// 默认值来自项目 `tmp/yinyuan` 中已分析的音源脚本。配置只描述请求入口和
/// 必需请求头；脚本本身不会在应用内执行。
class PlaybackSourceConfig {
  static const preferenceKey = 'playback_source_config_v1';
  static const maxSerializedChars = 32 * 1024;

  static const defaultChkszBaseUrl = 'http://161.118.252.183/api-chksz';
  static const defaultQingMusicUrl =
      'https://musicserver.haitangw.cc/v1/music/resolve-url';
  static const defaultHywBaseUrl = 'http://103.79.184.97';
  static const defaultHywCardKey = 'PYPW-QFRL-3DBF-95O6';
  static const defaultXinghaiUrl = 'https://yy.zddyr.top/lx/api/';
  static const defaultXinghaiIpUrl = 'https://yy.zddyr.top/ip.php';
  static const defaultXinghaiClient = 'XingHaiMusicSource/v3.2.13 (Android)';
  static const defaultGdStudioUrl = 'https://music-api.gdstudio.xyz/api.php';

  static const _maxUrlLength = 2048;
  static const _maxSecretLength = 1024;
  static const _maxHeaderLength = 256;

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
  final String gdStudioUrl;

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
    required this.gdStudioUrl,
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

    return PlaybackSourceConfig(
      chkszEnabled: flag('chkszEnabled', defaults.chkszEnabled),
      qingMusicEnabled: flag('qingMusicEnabled', defaults.qingMusicEnabled),
      hywEnabled: flag('hywEnabled', defaults.hywEnabled),
      xinghaiEnabled: flag('xinghaiEnabled', defaults.xinghaiEnabled),
      gdStudioEnabled: flag('gdStudioEnabled', defaults.gdStudioEnabled),
      chkszBaseUrl: text('chkszBaseUrl', defaults.chkszBaseUrl),
      qingMusicUrl: text('qingMusicUrl', defaults.qingMusicUrl),
      hywBaseUrl: text('hywBaseUrl', defaults.hywBaseUrl),
      hywCardKey: text('hywCardKey', defaults.hywCardKey),
      xinghaiUrl: text('xinghaiUrl', defaults.xinghaiUrl),
      xinghaiIpUrl: text('xinghaiIpUrl', defaults.xinghaiIpUrl),
      xinghaiClient: text('xinghaiClient', defaults.xinghaiClient),
      xinghaiDeviceId: text('xinghaiDeviceId', defaults.xinghaiDeviceId),
      gdStudioUrl: text('gdStudioUrl', defaults.gdStudioUrl),
    ).validated();
  }

  bool isEnabled(PlaybackSource source) => switch (source) {
    PlaybackSource.automatic => true,
    PlaybackSource.chksz => chkszEnabled,
    PlaybackSource.qingMusic => qingMusicEnabled,
    PlaybackSource.hyw => hywEnabled,
    PlaybackSource.xinghai => xinghaiEnabled,
    PlaybackSource.gdStudio => gdStudioEnabled,
  };

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
    if (normalizedCardKey.length > _maxSecretLength) {
      throw const FormatException('HYW Card Key 过长');
    }
    if (normalizedClient.length > _maxHeaderLength) {
      throw const FormatException('星海 X-Client 过长');
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
    return copyWith(
      chkszBaseUrl: normalizedChksz,
      qingMusicUrl: normalizedQing,
      hywBaseUrl: normalizedHyw,
      hywCardKey: normalizedCardKey,
      xinghaiUrl: normalizedXinghai,
      xinghaiIpUrl: normalizedXinghaiIp,
      xinghaiClient: normalizedClient,
      xinghaiDeviceId: normalizedDeviceId,
      gdStudioUrl: normalizedGd,
    );
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
    String? gdStudioUrl,
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
    gdStudioUrl: gdStudioUrl ?? this.gdStudioUrl,
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
    'gdStudioUrl': gdStudioUrl,
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
          other.gdStudioUrl == gdStudioUrl;

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
    gdStudioUrl,
  );

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
