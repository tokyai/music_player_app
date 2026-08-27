import 'dart:math' as math;
import 'dart:typed_data';

/// A small, allocation-free gate used only while assistant TTS is speaking.
/// It deliberately favors a little latency over false triggers from a single
/// loud PCM packet (music, a click, or a transient audio-focus change).
class AiBargeInVoiceGate {
  AiBargeInVoiceGate({
    this.sampleRate = 16000,
    this.warmup = const Duration(milliseconds: 280),
    this.requiredSpeech = const Duration(milliseconds: 100),
    this.minimumRms = 0.018,
    this.minimumPeak = 0.045,
    this.ratio = 2.0,
  }) : _warmupSamples = sampleRate * warmup.inMilliseconds ~/ 1000,
       _requiredSamples = sampleRate * requiredSpeech.inMilliseconds ~/ 1000;

  final int sampleRate;
  final Duration warmup;
  final Duration requiredSpeech;
  final double minimumRms;
  final double minimumPeak;
  final double ratio;
  final int _warmupSamples;
  final int _requiredSamples;

  int _seenSamples = 0;
  int _speechSamples = 0;
  double _noiseFloor = 0.008;
  bool _triggered = false;

  bool get triggered => _triggered;

  /// Returns true once a sustained voice-like energy segment is observed.
  bool accept(Float32List samples) {
    if (_triggered || samples.isEmpty) return _triggered;
    var sumSquares = 0.0;
    var peak = 0.0;
    for (final sample in samples) {
      final magnitude = sample.abs();
      if (magnitude > peak) peak = magnitude;
      sumSquares += sample * sample;
    }
    final rms = math.sqrt(sumSquares / samples.length);
    final wasWarmup = _seenSamples < _warmupSamples;
    _seenSamples += samples.length;

    // Learn a slowly changing noise floor only from quiet frames. During the
    // initial warmup we also learn the TTS/road-noise baseline, so a steady
    // assistant voice does not immediately trigger itself.
    if (rms < _noiseFloor * 1.35 || wasWarmup) {
      _noiseFloor = _noiseFloor * 0.94 + rms * 0.06;
    }
    if (wasWarmup) return false;

    final loudEnough =
        rms >= math.max(minimumRms, _noiseFloor * ratio) &&
        peak >= math.max(minimumPeak, _noiseFloor * 2.4);
    if (loudEnough) {
      _speechSamples += samples.length;
    } else {
      _speechSamples = math.max(0, _speechSamples - samples.length * 2);
    }
    if (_speechSamples >= _requiredSamples) {
      _triggered = true;
    }
    return _triggered;
  }

  void reset() {
    _seenSamples = 0;
    _speechSamples = 0;
    _noiseFloor = 0.008;
    _triggered = false;
  }
}

/// Fixed-size PCM ring buffer. The maximum retained audio is intentionally
/// small (normally 240 ms of mono 16-bit PCM) so barge-in cannot grow memory.
class AiPcmRingBuffer {
  AiPcmRingBuffer({this.capacityBytes = 16000 * 2 * 240 ~/ 1000})
    : assert(capacityBytes > 0),
      _buffer = Uint8List(capacityBytes);

  final int capacityBytes;
  final Uint8List _buffer;
  int _start = 0;
  int _length = 0;

  int get length => _length;

  void add(Uint8List bytes) {
    if (bytes.isEmpty) return;
    if (bytes.length >= capacityBytes) {
      final offset = bytes.length - capacityBytes;
      _buffer.setRange(0, capacityBytes, bytes, offset);
      _start = 0;
      _length = capacityBytes;
      return;
    }
    final writeOffset = (_start + _length) % capacityBytes;
    final first = math.min(bytes.length, capacityBytes - writeOffset);
    _buffer.setRange(writeOffset, writeOffset + first, bytes);
    if (first < bytes.length) {
      _buffer.setRange(0, bytes.length - first, bytes, first);
    }
    if (_length + bytes.length <= capacityBytes) {
      _length += bytes.length;
    } else {
      final overflow = _length + bytes.length - capacityBytes;
      _start = (_start + overflow) % capacityBytes;
      _length = capacityBytes;
    }
  }

  Uint8List snapshot({int? maxBytes}) {
    final requested = maxBytes == null
        ? _length
        : math.min(math.max(0, maxBytes), _length);
    if (requested == 0) return Uint8List(0);
    final offset = (_start + _length - requested) % capacityBytes;
    final result = Uint8List(requested);
    final first = math.min(requested, capacityBytes - offset);
    result.setRange(0, first, _buffer, offset);
    if (first < requested) {
      result.setRange(first, requested, _buffer, 0);
    }
    return result;
  }

  void clear() {
    _start = 0;
    _length = 0;
  }
}
