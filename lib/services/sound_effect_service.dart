import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/sound_effect.dart';

class SoundEffectService {
  static const MethodChannel _channel = MethodChannel(
    'music_player/sound_effect',
  );

  static Future<SoundEffectAvailability> initialize() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return const SoundEffectAvailability.unsupported();
    }
    try {
      final result = await _channel.invokeMapMethod<Object?, Object?>(
        'initialize',
      );
      if (result == null) {
        return const SoundEffectAvailability.unsupported('DSP 初始化没有返回结果');
      }
      return SoundEffectAvailability.fromMap(result);
    } on MissingPluginException {
      return const SoundEffectAvailability.unsupported();
    } on PlatformException catch (error) {
      return SoundEffectAvailability.unsupported(error.message ?? 'DSP 初始化失败');
    }
  }

  static Future<bool> setEffect({required int type, required int id}) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      return await _channel.invokeMethod<bool>('setEffect', {
            'type': type,
            'id': id,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
