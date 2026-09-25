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
      }
    });

    test('byId falls back rather than throwing on an unknown id', () {
      expect(PanelDevice.byId('waveshare-2.9-g'), PanelDevice.waveshare29G);
      expect(PanelDevice.byId('nonsense'), PanelDevice.waveshare29G);
    });
  });
}
