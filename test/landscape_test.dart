import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:mtg_eink/models/panel_device.dart';
import 'package:mtg_eink/models/saved_design.dart';
import 'package:mtg_eink/render/canvas_painter.dart';
import 'package:mtg_eink/render/frame_packer.dart';
import 'package:mtg_eink/render/quantiser.dart';

void main() {
  for (final device in PanelDevice.supported) {
    group(device.name, () {
      final w = device.canvasWidth;
      final h = device.canvasHeight;

      test('the landscape canvas is the portrait one on its side', () {
        expect(
          device.canvasSizeFor(landscape: true),
          Size(h.toDouble(), w.toDouble()),
        );
        expect(device.canvasSizeFor(landscape: false), device.size);
      });

      test('a landscape drawing turns a quarter turn clockwise', () {
        // Landscape top-left lands top-right; landscape bottom-left lands top-left.
        expect(landscapeToCanvas(device, 0, 0), (u: w - 1, v: 0));
        expect(landscapeToCanvas(device, 0, w - 1), (u: 0, v: 0));
        expect(landscapeToCanvas(device, h - 1, w - 1), (u: 0, v: h - 1));
      });

      test('packing and decoding landscape codes round-trips every pixel', () {
        // A code per pixel that differs from its neighbours both ways, so any transposition shows.
        final codes = Uint8List(w * h);
        for (var p = 0; p < codes.length; p++) {
          final x = p % h;
          final y = p ~/ h;
          codes[p] = (x + 2 * y) % device.palette.length;
        }

        final frame = packCodes(device, codes, landscape: true);
        for (var y = 0; y < w; y++) {
          for (var x = 0; x < h; x++) {
            expect(codeAtLandscape(device, frame, x, y), codes[y * h + x]);
          }
        }
      });

      testWidgets('a landscape render puts its top-left corner top-right', (
        tester,
      ) async {
        // Paper everywhere, with a pen-coloured block in the landscape drawing's top-left corner.
        final frame = (await tester.runAsync(
          () => renderPainted(device, (canvas) {
            canvas.drawRect(
              Offset.zero & device.canvasSizeFor(landscape: true),
              Paint()..color = device.background,
            );
            canvas.drawRect(
              const Rect.fromLTWH(0, 0, 10, 4),
              Paint()
                ..color = device.foreground
                ..isAntiAlias = false,
            );
          }, landscape: true),
        ))!;

        // Ten pixels along the landscape top edge run down the portrait right edge, four deep.
        expect(codeAtCanvas(device, frame, w - 1, 0), device.foregroundCode);
        expect(codeAtCanvas(device, frame, w - 4, 9), device.foregroundCode);
        expect(codeAtCanvas(device, frame, w - 5, 0), device.backgroundCode);
        expect(codeAtCanvas(device, frame, w - 1, 10), device.backgroundCode);
        expect(codeAtCanvas(device, frame, 0, 0), device.backgroundCode);
      });
    });
  }

  test('overlayCodes replaces exactly the block it is given', () {
    const device = PanelDevice.waveshare29G;
    final frame = Uint8List(device.packedBytes);
    final block = Uint8List(3 * 2)..fillRange(0, 6, 3);

    overlayCodes(device, frame, block, 3, left: 5, top: 7);

    for (var v = 0; v < device.canvasHeight; v++) {
      for (var u = 0; u < device.canvasWidth; u++) {
        final inside = u >= 5 && u < 8 && v >= 7 && v < 9;
        expect(codeAtCanvas(device, frame, u, v), inside ? 3 : 0);
      }
    }
  });

  group('saved orientation', () {
    test('landscape survives a JSON round trip', () {
      const settings = ImageSettings(
        offset: Offset(1, 2),
        scale: 3,
        style: DitherStyle.photo,
        landscape: true,
      );
      expect(ImageSettings.fromJson(settings.toJson()).landscape, isTrue);
    });

    test('settings saved before there was a choice load as portrait', () {
      final json = {'dx': 0, 'dy': 0, 'scale': 1, 'style': 'photo'};
      expect(ImageSettings.fromJson(json).landscape, isFalse);
    });
  });
}
