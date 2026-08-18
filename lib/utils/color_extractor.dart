import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:palette_generator/palette_generator.dart';

// Palette extraction is relatively expensive compared with reading an image
// from the image cache.  Keep a small process-local cache so opening the same
// song's player page again does not repeat the image analysis during a route
// transition.  The bound keeps long listening sessions from retaining every
// cover ever played.
const _maxDominantColorCacheEntries = 32;
final Map<String, Color> _dominantColorCache = <String, Color>{};
final Map<String, Future<Color?>> _dominantColorInFlight =
    <String, Future<Color?>>{};

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
  if (urls.isEmpty) return null;

  final cacheKey = urls.join('|');
  final cached = _dominantColorCache[cacheKey];
  if (cached != null) return cached;

  final pending = _dominantColorInFlight[cacheKey];
  if (pending != null) return pending;

  final future = _extractFromUrls(urls);
  _dominantColorInFlight[cacheKey] = future;
  try {
    final color = await future;
    if (color != null) {
      _dominantColorCache[cacheKey] = color;
      while (_dominantColorCache.length > _maxDominantColorCacheEntries) {
        _dominantColorCache.remove(_dominantColorCache.keys.first);
      }
    }
    return color;
  } finally {
    _dominantColorInFlight.remove(cacheKey);
  }
}

Future<Color?> _extractFromUrls(Iterable<String> urls) async {
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
