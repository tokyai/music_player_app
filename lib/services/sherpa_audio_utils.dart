import 'dart:typed_data';

/// Converts a stream of little-endian signed PCM16 bytes into normalized
/// samples while preserving a trailing byte split across recorder chunks.
class Pcm16StreamDecoder {
  /// Keep platform-provided PCM batches bounded before allocating the
  /// interleaved copy and decoded float buffer below. Native car capture is
  /// already much smaller; this protects the standard record fallback from a
  /// malformed or unexpectedly large plugin event.
  static const maxInputBytes = 256 * 1024;

  Uint8List _pendingBytes = Uint8List(0);

  Float32List decode(Uint8List bytes, {int channelCount = 1, int? mixDivisor}) {
    if (channelCount < 1) {
      throw ArgumentError.value(
        channelCount,
        'channelCount',
        'must be positive',
      );
    }
    final divisor = mixDivisor ?? channelCount;
    if (divisor < 1) {
      throw ArgumentError.value(mixDivisor, 'mixDivisor', 'must be positive');
    }
    if (bytes.isEmpty && _pendingBytes.isEmpty) return Float32List(0);

    final combinedLength = _pendingBytes.length + bytes.length;
    if (combinedLength > maxInputBytes) {
      throw ArgumentError.value(
        bytes.length,
        'bytes',
        'PCM batch exceeds $maxInputBytes bytes',
      );
    }

    final combined = Uint8List(combinedLength)
      ..setRange(0, _pendingBytes.length, _pendingBytes)
      ..setRange(
        _pendingBytes.length,
        _pendingBytes.length + bytes.length,
        bytes,
      );
    final frameBytes = channelCount * 2;
    final frameCount = combined.length ~/ frameBytes;
    final samples = Float32List(frameCount);

    for (var frame = 0; frame < frameCount; frame++) {
      var mixed = 0;
      final frameOffset = frame * frameBytes;
      for (var channel = 0; channel < channelCount; channel++) {
        final offset = frameOffset + channel * 2;
        final unsignedValue = combined[offset] | (combined[offset + 1] << 8);
        mixed += unsignedValue >= 0x8000
            ? unsignedValue - 0x10000
            : unsignedValue;
      }
      final value = (mixed ~/ divisor).clamp(-32768, 32767);
      samples[frame] = value / 32768.0;
    }

    final consumedBytes = frameCount * frameBytes;
    _pendingBytes = consumedBytes == combined.length
        ? Uint8List(0)
        : Uint8List.fromList(combined.sublist(consumedBytes));
    return samples;
  }

  void reset() => _pendingBytes = Uint8List(0);
}
