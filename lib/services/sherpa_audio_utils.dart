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

/// Downmixes interleaved signed little-endian PCM16 into mono PCM16 while
/// preserving an incomplete source frame between recorder callbacks.
class Pcm16MonoStreamConverter {
  static const maxInputBytes = Pcm16StreamDecoder.maxInputBytes;

  Uint8List _pendingBytes = Uint8List(0);

  Uint8List convert(Uint8List bytes, {int channelCount = 1, int? mixDivisor}) {
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
    if (bytes.isEmpty && _pendingBytes.isEmpty) return Uint8List(0);

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
    final sourceFrameBytes = channelCount * 2;
    final frameCount = combined.length ~/ sourceFrameBytes;
    final mono = Uint8List(frameCount * 2);
    final monoData = ByteData.sublistView(mono);

    for (var frame = 0; frame < frameCount; frame++) {
      var mixed = 0;
      final frameOffset = frame * sourceFrameBytes;
      for (var channel = 0; channel < channelCount; channel++) {
        final offset = frameOffset + channel * 2;
        final unsignedValue = combined[offset] | (combined[offset + 1] << 8);
        mixed += unsignedValue >= 0x8000
            ? unsignedValue - 0x10000
            : unsignedValue;
      }
      monoData.setInt16(
        frame * 2,
        (mixed ~/ divisor).clamp(-32768, 32767),
        Endian.little,
      );
    }

    final consumedBytes = frameCount * sourceFrameBytes;
    _pendingBytes = consumedBytes == combined.length
        ? Uint8List(0)
        : Uint8List.fromList(combined.sublist(consumedBytes));
    return mono;
  }

  void reset() => _pendingBytes = Uint8List(0);
}

/// Splits mono PCM into fixed-size frames with less than one frame retained.
class Pcm16FrameBuffer {
  final int frameBytes;
  final Uint8List _pending;
  int _pendingLength = 0;

  Pcm16FrameBuffer({required this.frameBytes})
    : assert(frameBytes > 0),
      _pending = Uint8List(frameBytes) {
    if (frameBytes <= 0) {
      throw ArgumentError.value(frameBytes, 'frameBytes', 'must be positive');
    }
  }

  bool get hasPendingData => _pendingLength > 0;

  void add(Uint8List bytes, void Function(Uint8List frame) onFrame) {
    if (bytes.length > Pcm16StreamDecoder.maxInputBytes) {
      throw ArgumentError.value(
        bytes.length,
        'bytes',
        'PCM batch exceeds ${Pcm16StreamDecoder.maxInputBytes} bytes',
      );
    }
    var offset = 0;
    if (_pendingLength > 0) {
      final needed = frameBytes - _pendingLength;
      final copied = bytes.length < needed ? bytes.length : needed;
      _pending.setRange(_pendingLength, _pendingLength + copied, bytes);
      _pendingLength += copied;
      offset += copied;
      if (_pendingLength == frameBytes) {
        onFrame(Uint8List.fromList(_pending));
        _pendingLength = 0;
      }
    }

    while (offset + frameBytes <= bytes.length) {
      onFrame(Uint8List.sublistView(bytes, offset, offset + frameBytes));
      offset += frameBytes;
    }
    if (offset < bytes.length) {
      _pending.setRange(0, bytes.length - offset, bytes, offset);
      _pendingLength = bytes.length - offset;
    }
  }

  Uint8List takePaddedFrame() {
    if (_pendingLength == 0) return Uint8List(0);
    final frame = Uint8List(frameBytes)..setRange(0, _pendingLength, _pending);
    _pendingLength = 0;
    return frame;
  }

  void reset() {
    _pendingLength = 0;
  }
}
