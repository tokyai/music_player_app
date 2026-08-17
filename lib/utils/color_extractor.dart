import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:palette_generator/palette_generator.dart';

/// 提取图片主色调，用于播放页背景渐变。原始 CDN 失败后才尝试兼容地址。
Future<Color?> extractDominantColor(
  String? imageUrl, {
  String? fallbackImageUrl,
}) async {
  final urls = <String>{
    if (imageUrl != null && imageUrl.isNotEmpty) imageUrl,
    if (fallbackImageUrl != null && fallbackImageUrl.isNotEmpty)
      fallbackImageUrl,
  };
  for (final url in urls) {
    try {
      final provider = CachedNetworkImageProvider(url);
      final palette = await PaletteGenerator.fromImageProvider(
        provider,
        size: const Size(100, 100),
        maximumColorCount: 8,
      );
      final color = palette.dominantColor?.color;
      if (color != null) return color;
    } catch (_) {
      // 继续尝试兼容地址。
    }
  }
  return null;
}
