// The card's small text on a one-bit panel, rendered with the real font.
//
// Its own file because it loads Roboto: every other test renders with the test font, whose glyphs
// are solid boxes and would hide exactly what this checks.
import 'dart:io';

import 'package:epaper_nfc/epaper_nfc.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mtg_eink/models/token_content.dart';
import 'package:mtg_eink/render/token_painter.dart';

/// Roboto ships with the Flutter SDK, in `bin/cache/artifacts/material_fonts`; the test runner
/// lives in `bin/cache/artifacts/engine/<platform>/`. Null if this SDK is laid out otherwise.
Directory? _sdkFonts() {
  var dir = File(Platform.resolvedExecutable).parent;
  for (var i = 0; i < 4; i++) {
    final fonts = Directory('${dir.path}/material_fonts');
    if (fonts.existsSync()) return fonts;
    dir = dir.parent;
  }
  return null;
}

void main() {
  final fonts = _sdkFonts();

  setUpAll(() async {
    if (fonts == null) return;
    final loader = FontLoader(tokenFontFamily);
    for (final file in [
      'roboto-regular.ttf',
      'roboto-medium.ttf',
      'roboto-bold.ttf',
    ]) {
      final bytes = File('${fonts.path}/$file').readAsBytesSync();
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
    }
    await loader.load();
  });

  testWidgets(
    'thin strokes in the smallest text survive one bit per pixel',
    (tester) async {
      // On 2026-10-10 the 2.9"'s type line read "Gob in Shaman": a one-pixel stroke split across
      // two pixels came out half-grey in each, and half-grey rounds to paper, so strokes vanished.
      // This is that line. Counting the columns that hold an ascender-height stroke: 10 with plain
      // anti-aliased text, 30 with the coverage boost (`_inkGain`).
      const device = PanelDevice.waveshare29G;
      const token = TokenContent(
        type: 'Creature — Goblin Shaman',
        ability: 'Flying, haste. When this enters, draw a card.',
      );
      final frame = (await tester.runAsync(
        () => renderTokenFrame(device, token),
      ))!;

      final box = TokenLayout(device, hasAbility: true).type;
      var strokes = 0;
      for (var x = box.left.ceil(); x < box.right.floor(); x++) {
        var run = 0;
        var longest = 0;
        for (var y = box.top.ceil(); y < box.bottom.floor(); y++) {
          final ink =
              codeAtCanvas(device, frame, x, y) == device.foregroundCode;
          run = ink ? run + 1 : 0;
          if (run > longest) longest = run;
        }
        if (longest >= 5) strokes++;
      }
      expect(strokes, greaterThanOrEqualTo(20));
    },
    // Roboto not found in this Flutter SDK's layout: nothing to judge the glyphs with.
    skip: fonts == null,
  );
}
