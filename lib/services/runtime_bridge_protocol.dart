import '../models/song.dart';

/// 原生桥接的输入边界，不让页面直接指定文件或平台通道。SHIXIAOYANG，2026/11/19。
class RuntimeBridgeProtocol {
  /// 获取有界文字；错误字段名只描述业务含义。
  static String text(
    Map<String, dynamic> data,
    String key, {
    int max = 512,
    bool required = true,
  }) {
    final value = data[key];
    if (!required && value == null) return '';
    if (value is! String ||
        value.length > max ||
        (required && value.trim().isEmpty)) {
      throw FormatException('$key 字段无效');
    }
    return value;
  }

  /// 读取有上下限的索引、页码或播放位置。
  static int integer(
    Map<String, dynamic> data,
    String key, {
    int minimum = 0,
    int maximum = 100000,
    int fallback = 0,
  }) {
    final value = data[key] ?? fallback;
    if (value is! int || value < minimum || value > maximum) {
      throw FormatException('$key 超出范围');
    }
    return value;
  }

  /// 只接收框架已有的音乐平台，音源本身由服务器动态定义。
  static MusicPlatform platform(String code) {
    for (final value in MusicPlatform.values) {
      if (value.code == code) return value;
    }
    throw const FormatException('音乐平台无效');
  }

  /// 拒绝不完整或过大的歌曲，离线标识仍交给已有模型校验。
  static SongSearchResult song(dynamic value) {
    if (value is! Map) throw const FormatException('歌曲数据无效');
    final data = Map<String, dynamic>.from(value);
    platform(text(data, 'platform', max: 32));
    text(data, 'id', max: 256);
    text(data, 'name');
    text(data, 'artist', required: false);
    text(data, 'album', required: false);
    text(data, 'albumId', max: 128, required: false);
    text(data, 'coverUrl', max: 2048, required: false);
    integer(data, 'duration', maximum: 86400);
    if (data['bilibiliPages'] != null &&
        (data['bilibiliPages'] is! List ||
            (data['bilibiliPages'] as List).length > 500)) {
      throw const FormatException('B站分P数量无效');
    }
    return SongSearchResult.fromJson(data);
  }

  /// 页面不得指定任意协议、身份信息或超长的视频地址。
  static String mediaUrl(String value) {
    final url = Uri.tryParse(value);
    if (value.length > 8192 ||
        url == null ||
        !['http', 'https'].contains(url.scheme) ||
        url.host.isEmpty ||
        url.userInfo.isNotEmpty ||
        url.hasFragment) {
      throw const FormatException('媒体地址无效');
    }
    return value;
  }
}
