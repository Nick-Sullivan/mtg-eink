import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mtg_eink/models/panel_device.dart';
import 'package:mtg_eink/models/token_content.dart';
import 'package:mtg_eink/render/image_content.dart';
import 'package:mtg_eink/render/quantiser.dart';
import 'package:mtg_eink/render/token_painter.dart';

void main() {
  const device = PanelDevice.waveshare29G;
  final layout = TokenLayout(device);

  Future<Uint8List> render(WidgetTester tester, TokenContent token) async =>
      (await tester.runAsync(() => renderTokenFrame(device, token)))!;

  int codeAtPoint(Uint8List frame, Offset p) =>
      codeAt(device, frame, p.dx.floor(), p.dy.floor());

  testWidgets('renders a full frame', (tester) async {
    final frame = await render(tester, const TokenContent());
    expect(frame.length, device.packedBytes);
  });

  testWidgets('frame is black and the bars are white', (tester) async {
    final frame = await render(tester, const TokenContent());
    final u = layout.unit;

    expect(codeAtPoint(frame, Offset.zero), device.foregroundCode);
    expect(
      codeAtPoint(frame, Offset(device.size.width - 1, device.size.height - 1)),
      device.foregroundCode,
    );
    // Just inside each bar's left edge, before any text starts.
    for (final bar in [layout.title, layout.type]) {
      expect(
        codeAtPoint(frame, Offset(bar.left + 2 * u, bar.center.dy)),
        device.backgroundCode,
      );
    }
    // Just inside the P/T box's right edge, clear of the centred text.
    expect(
      codeAtPoint(frame, Offset(layout.pt.right - 2 * u, layout.pt.center.dy)),
      device.backgroundCode,
    );
  });

  testWidgets('art box is hatched in both inks', (tester) async {
    final frame = await render(tester, const TokenContent());
    final codes = <int>{};
    final art = layout.art;
    for (var x = art.left.ceil(); x < art.right.floor(); x++) {
      codes.add(codeAt(device, frame, x, art.center.dy.floor()));
    }
    expect(codes, {device.foregroundCode, device.backgroundCode});
  });

  testWidgets('an absurdly long name still renders', (tester) async {
    final frame = await render(
      tester,
      const TokenContent(name: 'Eldrazi Scion of the Endless Void Beyond'),
    );
    expect(frame.length, device.packedBytes);
  });

  group('ability text', () {
    const withAbility = TokenContent(ability: 'Flying, haste');

    test('only takes space when there is some', () {
      final plain = TokenLayout(device);
      final boxed = TokenLayout(device, hasAbility: true);

      expect(plain.ability, isNull);
      expect(boxed.ability, isNotNull);
      // The art gives up the height; the title and P/T stay put.
      expect(boxed.art.height, lessThan(plain.art.height));
      expect(boxed.title, plain.title);
      expect(boxed.pt, plain.pt);
      expect(boxed.ability!.top, greaterThan(boxed.type.bottom));
      expect(boxed.ability!.bottom, lessThan(boxed.pt.top));
    });

    testWidgets('draws a white text box', (tester) async {
      final frame = await render(tester, withAbility);
      final box = TokenLayout(device, hasAbility: true).ability!;
      final u = layout.unit;

      // Just inside the box's right edge, clear of the left-aligned text.
      expect(
        codeAtPoint(frame, Offset(box.right - 2 * u, box.center.dy)),
        device.backgroundCode,
      );
    });

    testWidgets('whitespace alone draws no box', (tester) async {
      final frame = await render(tester, const TokenContent(ability: '  \n '));
      final box = TokenLayout(device, hasAbility: true).ability!;
      final u = layout.unit;

      // Where the box would be is still frame black, not white.
      expect(
        codeAtPoint(frame, Offset(box.right - 2 * u, box.center.dy)),
        device.foregroundCode,
      );
    });

    testWidgets('a wall of text still renders', (tester) async {
      final frame = await render(
        tester,
        TokenContent(
          ability: List.filled(40, 'Flying, trample, lifelink.').join(' '),
        ),
      );
      expect(frame.length, device.packedBytes);
    });
  });

  group('JSON', () {
    test('round-trips every field, ability included', () {
      const token = TokenContent(
        name: 'Angel',
        type: 'Token Creature — Angel',
        power: '4',
        toughness: '4',
        ability: 'Flying\nVigilance',
      );
      expect(TokenContent.fromJson(token.toJson()), token);
    });

    test('tokens saved before ability text load with none', () {
      final token = TokenContent.fromJson(const {
        'name': 'Gobby',
        'type': 'Creature — Goblin',
        'power': '1',
        'toughness': '1',
      });
      expect(token.ability, '');
    });
  });

  group('creature art', () {
    testWidgets('replaces the hatch with the silhouette', (tester) async {
      // A diagonal hatch puts ink in every row of the art box. A centred silhouette leaves the
      // top rows clear wherever the art is wider than it is tall.
      final hatched = await render(tester, const TokenContent());
      final withArt = await render(tester, const TokenContent(art: 'goblin'));
      final art = layout.art;

      int inkIn(Uint8List frame, int y) {
        var n = 0;
        for (var x = art.left.ceil(); x < art.right.floor(); x++) {
          if (codeAt(device, frame, x, y) == device.foregroundCode) n++;
        }
        return n;
      }

      final top = (art.top + 3).ceil();
      expect(inkIn(hatched, top), greaterThan(0));
      expect(inkIn(withArt, top), 0);
      expect(inkIn(withArt, art.center.dy.floor()), greaterThan(0));
    });

    testWidgets('an unknown id falls back to the hatch', (tester) async {
      final hatched = await render(tester, const TokenContent());
      final unknown = await render(
        tester,
        const TokenContent(art: 'mind-flayer'),
      );
      expect(unknown, hatched);
    });
  });

  group('a picture in the art box', () {
    /// A solid picture of one colour, as if picked from the gallery.
    Future<ImageContent> solid(PanelDevice device, Color colour) async {
      const size = 16;
      final rgba = Uint8List(size * size * 4);
      for (var p = 0; p < size * size; p++) {
        rgba[p * 4] = (colour.r * 255).round();
        rgba[p * 4 + 1] = (colour.g * 255).round();
        rgba[p * 4 + 2] = (colour.b * 255).round();
        rgba[p * 4 + 3] = 255;
      }
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        rgba,
        size,
        size,
        ui.PixelFormat.rgba8888,
        completer.complete,
      );
      return ImageContent(
        device: device,
        source: await completer.future,
        bytes: Uint8List(0),
        style: DitherStyle.graphic,
        box: tokenArtBox(device, const TokenContent()),
      ).recentred();
    }

    for (final panel in PanelDevice.supported) {
      test('${panel.name}: the art box snaps inward to whole pixels', () {
        for (final hasAbility in [false, true]) {
          final layout = TokenLayout(panel, hasAbility: hasAbility);
          final box = layout.artPixels;
          for (final edge in [box.left, box.top, box.right, box.bottom]) {
            expect(edge, edge.roundToDouble());
          }
          expect(layout.art.contains(box.topLeft), isTrue);
          expect(box.right, lessThanOrEqualTo(layout.art.right));
          expect(box.bottom, lessThanOrEqualTo(layout.art.bottom));
        }
      });

      testWidgets('${panel.name}: fills the box, and only the box', (
        tester,
      ) async {
        // Red where the panel has it; otherwise the pen ink.
        final ink = panel.palette.length > 2 ? 3 : panel.foregroundCode;
        final frame = (await tester.runAsync(() async {
          final picture = await solid(panel, panel.palette[ink]);
          return renderTokenFrame(
            panel,
            const TokenContent(),
            picture: picture,
          );
        }))!;
        final layout = TokenLayout(panel);
        final box = layout.artPixels;

        // Every pixel of the box is the picture — no hatch shows through.
        for (var v = box.top.round(); v < box.bottom.round(); v++) {
          for (var u = box.left.round(); u < box.right.round(); u++) {
            expect(codeAtCanvas(panel, frame, u, v), ink);
          }
        }
        // The card around it is untouched: the title bar is still paper.
        expect(
          codeAtCanvas(
            panel,
            frame,
            (layout.title.left + 2 * layout.unit).floor(),
            layout.title.center.dy.floor(),
          ),
          panel.backgroundCode,
        );
      });
    }

    testWidgets('a picture framed for a stale box is refitted, not smeared', (
      tester,
    ) async {
      // Framed for a card without ability text; rendered for one with it, whose art box is
      // shorter. Nothing may spill into the ability box below.
      const token = TokenContent(ability: 'Flying');
      final frame = (await tester.runAsync(() async {
        final picture = await solid(device, device.palette[3]);
        return renderTokenFrame(device, token, picture: picture);
      }))!;
      final ability = TokenLayout(device, hasAbility: true).ability!;
      expect(
        codeAtCanvas(
          device,
          frame,
          (ability.left + 2).ceil(),
          (ability.top + 2).ceil(),
        ),
        device.backgroundCode,
      );
    });
  });
}
