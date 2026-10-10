import 'dart:typed_data';

import 'package:epaper_nfc/epaper_nfc.dart';
import 'package:flutter_test/flutter_test.dart';

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

  group('the 4.2" frame is the canvas turned a quarter turn clockwise', () {
    // Pinned to a photograph of a probe frame on the real panel: the bar written along frame row 0
    // ran down the left edge, and the bar along frame column 0 ran along the bottom. A diagonal
    // drawn with the most significant bit leftmost came out smooth, not 8-pixel sawtoothed.
    const big = PanelDevice.waveshare42;

    test('the canvas origin is the end of frame row 0', () {
      final frame = Uint8List(big.packedBytes);
      setCanvasPixel(big, frame, 0, 0, 1);
      expect(frame[49], 0x01);
      expect(frame.where((b) => b != 0), hasLength(1));
    });

    test('the bottom-left of the canvas is the frame origin', () {
      final frame = Uint8List(big.packedBytes);
      setCanvasPixel(big, frame, 0, big.canvasHeight - 1, 1);
      expect(frame[0], 0x80);
    });

    test('the left edge of the canvas is all of frame row 0', () {
      final frame = Uint8List(big.packedBytes);
      for (var v = 0; v < big.canvasHeight; v++) {
        setCanvasPixel(big, frame, 0, v, 1);
      }
      expect(frame.sublist(0, 50).every((b) => b == 0xFF), isTrue);
      expect(frame.sublist(50).every((b) => b == 0), isTrue);
    });

    test('the bottom edge of the canvas is all of frame column 0', () {
      final frame = Uint8List(big.packedBytes);
      for (var u = 0; u < big.canvasWidth; u++) {
        setCanvasPixel(big, frame, u, big.canvasHeight - 1, 1);
      }
      for (var y = 0; y < big.frameRows; y++) {
        expect(frame[y * 50], 0x80, reason: 'row $y');
      }
    });

    test('codeAtCanvas is the inverse of setCanvasPixel everywhere', () {
      final frame = Uint8List(big.packedBytes);
      for (var v = 0; v < big.canvasHeight; v++) {
        for (var u = 0; u < big.canvasWidth; u++) {
          setCanvasPixel(big, frame, u, v, (u * 7 + v * 3) % 5 == 0 ? 1 : 0);
        }
      }
      for (var v = 0; v < big.canvasHeight; v++) {
        for (var u = 0; u < big.canvasWidth; u++) {
          expect(
            codeAtCanvas(big, frame, u, v),
            (u * 7 + v * 3) % 5 == 0 ? 1 : 0,
          );
        }
      }
    });

    test('out-of-canvas writes are ignored', () {
      final frame = Uint8List(big.packedBytes);
      setCanvasPixel(big, frame, big.canvasWidth, 0, 1);
      setCanvasPixel(big, frame, 0, big.canvasHeight, 1);
      setCanvasPixel(big, frame, -1, 0, 1);
      expect(frame.every((b) => b == 0), isTrue);
    });
  });
}
