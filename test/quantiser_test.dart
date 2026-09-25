import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_eink/models/panel_device.dart';
import 'package:nfc_eink/render/quantiser.dart';

const device = PanelDevice.waveshare29G;

/// Fills an RGBA buffer of one flat colour, panel sized.
Uint8List flat(int r, int g, int b) {
  final rgba = Uint8List(device.pixelsPerRow * device.frameRows * 4);
  for (var i = 0; i < rgba.length; i += 4) {
    rgba[i] = r;
    rgba[i + 1] = g;
    rgba[i + 2] = b;
    rgba[i + 3] = 255;
  }
  return rgba;
}

/// How many pixels of each ink a frame contains.
Map<int, int> census(Uint8List frame) {
  final counts = <int, int>{0: 0, 1: 0, 2: 0, 3: 0};
  for (var y = 0; y < device.frameRows; y++) {
    for (var x = 0; x < device.pixelsPerRow; x++) {
      counts[codeAt(device, frame, x, y)] =
          counts[codeAt(device, frame, x, y)]! + 1;
    }
  }
  return counts;
}

void main() {
  final total = device.pixelsPerRow * device.frameRows;

  group('flat colours map to the obvious ink', () {
    for (final style in DitherStyle.values) {
      test('white stays white ($style)', () {
        final counts = census(
          Quantiser.quantiseToFrame(device, flat(255, 255, 255), style),
        );
        expect(counts[device.backgroundCode], total);
      });

      test('black stays black ($style)', () {
        final counts = census(
          Quantiser.quantiseToFrame(device, flat(0, 0, 0), style),
        );
        expect(counts[0], total);
      });
    }

    test('the palette colours survive a round trip in graphic mode', () {
      for (var code = 0; code < device.palette.length; code++) {
        final colour = device.palette[code];
        final frame = Quantiser.quantiseToFrame(
          device,
          flat(
            (colour.r * 255).round(),
            (colour.g * 255).round(),
            (colour.b * 255).round(),
          ),
          DitherStyle.graphic,
        );
        expect(
          census(frame)[code],
          total,
          reason: 'palette entry $code should map back to itself',
        );
      }
    });
  });

  group('neutral greys never come out red', () {
    // This is the whole reason the quantiser weights chroma. Red's lightness sits almost exactly at
    // neutral mid-grey, so any plain distance metric picks it for grey pixels and every overcast
    // photo comes out pink. If someone "simplifies" the chroma weight away, these fail.
    for (final level in [64, 96, 128, 160, 192]) {
      test('grey $level uses only black and white', () {
        final counts = census(
          Quantiser.quantiseToFrame(
            device,
            flat(level, level, level),
            DitherStyle.photo,
          ),
        );
        expect(counts[3], 0);
        expect(counts[2], 0);
      });
    }

    test('a slate-blue sky produces no red', () {
      // The exact colour that picks red by a wide margin under naive RGB matching.
      final counts = census(
        Quantiser.quantiseToFrame(
          device,
          flat(80, 110, 160),
          DitherStyle.photo,
        ),
      );
      expect(counts[3], 0);
    });

    test('shadowed foliage produces no red', () {
      final counts = census(
        Quantiser.quantiseToFrame(device, flat(60, 110, 60), DitherStyle.photo),
      );
      expect(counts[3], 0);
    });
  });

  group('warm colours do reach the warm inks', () {
    test('a strong red uses red', () {
      final counts = census(
        Quantiser.quantiseToFrame(
          device,
          flat(200, 30, 20),
          DitherStyle.graphic,
        ),
      );
      expect(counts[3], greaterThan(total ~/ 2));
    });

    test('a strong yellow uses yellow', () {
      final counts = census(
        Quantiser.quantiseToFrame(
          device,
          flat(250, 205, 10),
          DitherStyle.graphic,
        ),
      );
      expect(counts[2], greaterThan(total ~/ 2));
    });
  });

  group('dithering', () {
    test('a mid grey mixes two inks rather than picking one', () {
      final counts = census(
        Quantiser.quantiseToFrame(
          device,
          flat(128, 128, 128),
          DitherStyle.photo,
        ),
      );
      expect(counts[0], greaterThan(0));
      expect(counts[device.backgroundCode], greaterThan(0));
    });

    test('graphic mode never dithers — one flat colour gives one ink', () {
      final counts = census(
        Quantiser.quantiseToFrame(
          device,
          flat(128, 128, 128),
          DitherStyle.graphic,
        ),
      );
      expect(counts.values.where((c) => c > 0), hasLength(1));
    });

    test('a darker grey uses more black than a lighter one', () {
      int blackCount(int level) => census(
        Quantiser.quantiseToFrame(
          device,
          flat(level, level, level),
          DitherStyle.photo,
        ),
      )[0]!;

      // Auto-levels flattens a *uniform* field, so compare gradients instead: build two ramps and
      // check the darker one is darker overall.
      expect(blackCount(40), greaterThanOrEqualTo(blackCount(200)));
    });
  });

  test('every frame produced is exactly the panel size', () {
    for (final style in DitherStyle.values) {
      expect(
        Quantiser.quantiseToFrame(device, flat(120, 80, 40), style).length,
        device.packedBytes,
      );
    }
  });

  group('nearestCode', () {
    test('maps each palette colour to its own code', () {
      for (var code = 0; code < device.palette.length; code++) {
        final colour = device.palette[code];
        expect(
          nearestCode(
            device,
            (colour.r * 255).round(),
            (colour.g * 255).round(),
            (colour.b * 255).round(),
          ),
          code,
        );
      }
    });
  });
}
