import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/services/sherpa_audio_utils.dart';

void main() {
  test('decodes signed little-endian PCM16 into normalized samples', () {
    final decoder = Pcm16StreamDecoder();

    final samples = decoder.decode(
      Uint8List.fromList([0x00, 0x80, 0x00, 0x00, 0xff, 0x7f]),
    );

    expect(samples, hasLength(3));
    expect(samples[0], -1.0);
    expect(samples[1], 0.0);
    expect(samples[2], closeTo(32767 / 32768, 0.000001));
  });

  test('preserves a PCM sample split across recorder chunks', () {
    final decoder = Pcm16StreamDecoder();

    expect(decoder.decode(Uint8List.fromList([0x00])), isEmpty);
    final samples = decoder.decode(Uint8List.fromList([0x40, 0x00, 0xc0]));

    expect(samples, hasLength(2));
    expect(samples[0], 0.5);
    expect(samples[1], -0.5);
  });

  test('reset discards an unmatched trailing byte', () {
    final decoder = Pcm16StreamDecoder();
    decoder.decode(Uint8List.fromList([0xff]));

    decoder.reset();
    final samples = decoder.decode(Uint8List.fromList([0x00, 0x20]));

    expect(samples, [0.25]);
  });

  test('mixes four-channel car-array PCM using the Baidu divisor', () {
    final decoder = Pcm16StreamDecoder();
    final bytes = _pcm16([1000, 2000, 3000, 4000, -1000, -2000, -3000, -4000]);

    final samples = decoder.decode(bytes, channelCount: 4, mixDivisor: 2);

    expect(samples, hasLength(2));
    expect(samples[0], closeTo(5000 / 32768, 0.000001));
    expect(samples[1], closeTo(-5000 / 32768, 0.000001));
  });

  test('downmixes Flyme stereo PCM for Zipformer', () {
    final decoder = Pcm16StreamDecoder();
    final bytes = _pcm16([1000, 3000, -2000, -4000]);

    final samples = decoder.decode(bytes, channelCount: 2, mixDivisor: 2);

    expect(samples, hasLength(2));
    expect(samples[0], closeTo(2000 / 32768, 0.000001));
    expect(samples[1], closeTo(-3000 / 32768, 0.000001));
  });

  test('preserves an incomplete multi-channel frame between chunks', () {
    final decoder = Pcm16StreamDecoder();
    final bytes = _pcm16([1000, 2000, 3000, 4000]);

    expect(
      decoder.decode(
        Uint8List.sublistView(bytes, 0, 5),
        channelCount: 4,
        mixDivisor: 2,
      ),
      isEmpty,
    );
    final samples = decoder.decode(
      Uint8List.sublistView(bytes, 5),
      channelCount: 4,
      mixDivisor: 2,
    );

    expect(samples.single, closeTo(5000 / 32768, 0.000001));
  });

  test('rejects an unexpectedly large PCM batch before allocating buffers', () {
    final decoder = Pcm16StreamDecoder();

    expect(
      () => decoder.decode(
        Uint8List(Pcm16StreamDecoder.maxInputBytes + 1),
      ),
      throwsArgumentError,
    );
  });
}

Uint8List _pcm16(List<int> samples) {
  final bytes = Uint8List(samples.length * 2);
  final data = ByteData.sublistView(bytes);
  for (var index = 0; index < samples.length; index++) {
    data.setInt16(index * 2, samples[index], Endian.little);
  }
  return bytes;
}
