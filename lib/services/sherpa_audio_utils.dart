import 'dart:typed_data';

/// Converts a stream of little-endian signed PCM16 bytes into normalized
/// samples while preserving a trailing byte split across recorder chunks.
class Pcm16StreamDecoder {
  int? _pendingByte;

  Float32List decode(Uint8List bytes) {
    if (bytes.isEmpty) return Float32List(0);

    final byteCount = bytes.length + (_pendingByte == null ? 0 : 1);
    final samples = Float32List(byteCount ~/ 2);
    var sourceIndex = 0;
    var sampleIndex = 0;

    if (_pendingByte case final lowByte?) {
      samples[sampleIndex++] = _normalize(lowByte | (bytes[0] << 8));
      sourceIndex = 1;
      _pendingByte = null;
    }

    while (sourceIndex + 1 < bytes.length) {
      final value = bytes[sourceIndex] | (bytes[sourceIndex + 1] << 8);
      samples[sampleIndex++] = _normalize(value);
      sourceIndex += 2;
    }
    if (sourceIndex < bytes.length) _pendingByte = bytes[sourceIndex];
    return samples;
  }

  void reset() => _pendingByte = null;

  double _normalize(int unsignedValue) {
    final signed = unsignedValue >= 0x8000
        ? unsignedValue - 0x10000
        : unsignedValue;
    return signed / 32768.0;
  }
}
