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
}
