import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mtg_eink/models/panel_device.dart';
import 'package:mtg_eink/render/quantiser.dart';

const device = PanelDevice.waveshare29G;

/// The bit layout of a frame.
///
/// This is the thing that took three probes and two wrong theories to establish on real hardware
/// (see `docs/protocol.md`). Getting it wrong doesn't throw — it produces a garbled panel — so it's
/// worth pinning down precisely.
void main() {
  group('frame geometry', () {
    test('the frame is 296 rows of 32 bytes', () {
      expect(device.frameRows * device.frameBytesPerRow, device.packedBytes);
      expect(device.packedBytes, 9472);
    });

    test('a row holds 128 pixels at 4 per byte', () {
      expect(
        device.frameBytesPerRow * device.pixelsPerByte,
        device.pixelsPerRow,
      );
    });

    test('38 blocks of 250 bytes covers the frame', () {
      final capacity = device.blockCount * device.blockSize;
      expect(capacity, greaterThanOrEqualTo(device.packedBytes));
      // And not wastefully more — one fewer block would not fit.
      expect(
        (device.blockCount - 1) * device.blockSize,
        lessThan(device.packedBytes),
      );
    });
  });

  group('setPixel', () {
    test('the first pixel of a row occupies the high bits', () {
      final frame = Uint8List(device.packedBytes);
      setPixel(device, frame, 0, 0, 3); // 0b11
      expect(frame[0], 0xC0);
    });

    test('four pixels pack into one byte, left to right', () {
      final frame = Uint8List(device.packedBytes);
      setPixel(device, frame, 0, 0, 0);
      setPixel(device, frame, 1, 0, 1);
      setPixel(device, frame, 2, 0, 2);
      setPixel(device, frame, 3, 0, 3);
      expect(frame[0], 0x1B); // 00 01 10 11
    });

    test('row 1 starts one row-stride in', () {
      final frame = Uint8List(device.packedBytes);
      setPixel(device, frame, 0, 1, 3);
      expect(frame[0], 0);
      expect(frame[device.frameBytesPerRow], 0xC0);
    });

    test('overwriting a pixel leaves its neighbours alone', () {
      final frame = Uint8List(device.packedBytes);
      setPixel(device, frame, 0, 0, 3);
      setPixel(device, frame, 1, 0, 3);
      setPixel(device, frame, 0, 0, 1);
      expect(codeAt(device, frame, 0, 0), 1);
      expect(codeAt(device, frame, 1, 0), 3);
    });

    test(
      'out-of-bounds writes are ignored rather than corrupting a neighbour',
      () {
        final frame = Uint8List(device.packedBytes);
        setPixel(device, frame, -1, 0, 3);
        setPixel(device, frame, device.pixelsPerRow, 0, 3);
        setPixel(device, frame, 0, device.frameRows, 3);
        expect(frame.every((b) => b == 0), isTrue);
      },
    );

    test('codeAt is the inverse of setPixel across the whole frame', () {
      final frame = Uint8List(device.packedBytes);
      final expected = <int>[];
      for (var y = 0; y < device.frameRows; y++) {
        for (var x = 0; x < device.pixelsPerRow; x++) {
          final code = (x + y) % 4;
          expected.add(code);
          setPixel(device, frame, x, y, code);
        }
      }
      var i = 0;
      for (var y = 0; y < device.frameRows; y++) {
        for (var x = 0; x < device.pixelsPerRow; x++) {
          expect(codeAt(device, frame, x, y), expected[i++]);
        }
      }
    });
  });
}
