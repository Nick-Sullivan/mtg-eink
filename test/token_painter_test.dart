import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mtg_eink/models/panel_device.dart';
import 'package:mtg_eink/models/token_content.dart';
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
}
