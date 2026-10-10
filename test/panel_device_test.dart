import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:mtg_eink/models/panel_device.dart';

/// A device's derived geometry.
///
/// These look trivial, but they're the numbers the whole write path is built on: get [blockCount]
/// wrong and a write silently truncates rather than failing. Deriving them from the dimensions —
/// rather than hardcoding — is what makes adding a second panel safe, and this checks the
/// derivation against the values established on real hardware.
void main() {
  const device = PanelDevice.waveshare29G;

  group('Waveshare 2.9" (G)', () {
    test('has the frame shape found on hardware', () {
      expect(device.pixelsPerRow, 128);
      expect(device.frameRows, 296);
      expect(device.bitsPerPixel, 2);
      expect(device.pixelsPerByte, 4);
      expect(device.frameBytesPerRow, 32);
      expect(device.packedBytes, 9472);
    });

    test('needs 38 blocks, matching the vendor app', () {
      expect(device.blockCount, 38);
      expect(
        device.blockCount * device.blockSize,
        greaterThanOrEqualTo(device.packedBytes),
      );
    });

    test('has four inks, with paper and pen among them', () {
      expect(device.palette, hasLength(4));
      expect(device.background, const Color(0xFFFFFFFF));
      expect(device.foreground, const Color(0xFF000000));
    });
  });

  group('Waveshare 4.2" (Rev2.2)', () {
    const big = PanelDevice.waveshare42;

    test('has the frame shape found on hardware', () {
      expect(big.pixelsPerRow, 400);
      expect(big.frameRows, 300);
      expect(big.bitsPerPixel, 1);
      expect(big.frameBytesPerRow, 50);
      expect(big.packedBytes, 15000);
    });

    test('needs exactly 60 blocks, matching the vendor app', () {
      expect(big.blockCount, 60);
      expect(big.blockCount * big.blockSize, big.packedBytes);
    });

    test('composes on a portrait canvas', () {
      expect(big.canvasWidth, 300);
      expect(big.canvasHeight, 400);
      expect(big.size, const Size(300, 400));
    });

    test('has two inks, white paper and black pen, with 1 as black', () {
      expect(big.palette, hasLength(2));
      expect(big.palette[1], const Color(0xFF000000));
      expect(big.background, const Color(0xFFFFFFFF));
      expect(big.foreground, const Color(0xFF000000));
    });
  });

  group('the 2.9" canvas is its frame', () {
    test('no rotation, so canvas and frame points coincide', () {
      expect(device.size, const Size(128, 296));
      expect(device.framePoint(5, 7), (x: 5, y: 7));
    });
  });

  group('detection by ATS', () {
    // Measured on hardware: every other radio property is identical between the two panels.
    test('"YZRCOS" is the 4.2" Rev2.2', () {
      expect(
        PanelDevice.forAts('59 5A 52 43 4F 53 03 00'),
        PanelDevice.waveshare42,
      );
    });

    test("the (G) panel's ATS — 90 and its UID — is the 2.9\"", () {
      expect(PanelDevice.forAts('90 D2 48 58 52 00'), PanelDevice.waveshare29G);
    });

    test('no ATS means no ISO-DEP, so no verdict', () {
      expect(PanelDevice.forAts(null), isNull);
      expect(PanelDevice.forAts(''), isNull);
    });
  });

  group('the registry', () {
    test('every supported device has a unique id', () {
      final ids = PanelDevice.supported.map((d) => d.id).toSet();
      expect(ids, hasLength(PanelDevice.supported.length));
    });

    test('every supported device is internally consistent', () {
      for (final device in PanelDevice.supported) {
        expect(
          8 % device.bitsPerPixel,
          0,
          reason: '${device.name}: pixels must pack evenly into bytes',
        );
        expect(
          device.pixelsPerRow % device.pixelsPerByte,
          0,
          reason: '${device.name}: rows must pack evenly into bytes',
        );
        expect(
          device.backgroundCode,
          lessThan(device.palette.length),
          reason: '${device.name}: background ink must exist',
        );
        expect(
          device.foregroundCode,
          lessThan(device.palette.length),
          reason: '${device.name}: foreground ink must exist',
        );
        expect(
          device.palette.length,
          1 << device.bitsPerPixel,
          reason: '${device.name}: one ink per code',
        );
        expect(
          device.canvasWidth,
          lessThanOrEqualTo(device.canvasHeight),
          reason: '${device.name}: the canvas is portrait',
        );
      }
    });

    test('byId falls back rather than throwing on an unknown id', () {
      expect(PanelDevice.byId('waveshare-2.9-g'), PanelDevice.waveshare29G);
      expect(PanelDevice.byId('waveshare-4.2-rev2.2'), PanelDevice.waveshare42);
      expect(PanelDevice.byId('nonsense'), PanelDevice.waveshare29G);
    });
  });
}
