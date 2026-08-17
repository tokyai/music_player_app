import 'package:flutter/services.dart';

/// 把视频地址交给 Android 系统视频播放器或浏览器。
///
/// 使用原生通道而不引入额外视频 SDK，避免明显增大 APK。
class ExternalMediaService {
  static const MethodChannel _channel = MethodChannel(
    'music_player/external_media',
  );

  static Future<bool> playVideo(String url) async {
    try {
      return await _channel.invokeMethod<bool>('playVideo', {'url': url}) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
