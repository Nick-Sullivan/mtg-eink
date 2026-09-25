import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../models/epaper_display.dart';

/// Turns a rendered image into the 9,472-byte frame the panel expects.
///
/// Layout, confirmed on hardware (see `docs/protocol.md`):
/// 296 rows of 32 bytes, 4 pixels per byte, 2 bits per pixel, most significant pair first.
class FramePacker {
  const FramePacker._();

  /// Packs an image that is already [EPaperDisplay.pixelsPerRow] x [EPaperDisplay.frameRows].
  ///
  /// Each pixel is snapped to the nearest of the four panel colours. Nearest-colour rather than
  /// exact-match is deliberate: Flutter always anti-aliases text, so demanding exact palette values
  /// would leave every glyph edge undefined. Snapping keeps edges crisp and predictable instead.
  static Future<Uint8List> pack(ui.Image image) async {
    assert(image.width == EPaperDisplay.pixelsPerRow);
    assert(image.height == EPaperDisplay.frameRows);

    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) {
      throw StateError('Could not read pixels back from the rendered frame.');
    }
    final rgba = data.buffer.asUint8List();
    final frame = Uint8List(EPaperDisplay.packedBytes);

    for (var y = 0; y < EPaperDisplay.frameRows; y++) {
      for (var x = 0; x < EPaperDisplay.pixelsPerRow; x++) {
        final offset = (y * EPaperDisplay.pixelsPerRow + x) * 4;
        final code = nearestCode(rgba[offset], rgba[offset + 1], rgba[offset + 2]);
        setPixel(frame, x, y, code);
      }
    }
    return frame;
  }

  /// The palette entry closest to a colour, by squared distance in RGB.
  static int nearestCode(int r, int g, int b) {
    var bestCode = EPaperDisplay.codeWhite;
    var bestDistance = double.infinity;

    for (var code = 0; code < EPaperDisplay.palette.length; code++) {
      final candidate = EPaperDisplay.palette[code];
      final distance =
          math.pow(r - (candidate.r * 255).round(), 2) +
          math.pow(g - (candidate.g * 255).round(), 2) +
          math.pow(b - (candidate.b * 255).round(), 2);
      if (distance < bestDistance) {
        bestDistance = distance.toDouble();
        bestCode = code;
      }
    }
    return bestCode;
  }
}

/// Writes a 2-bit [code] at ([x], [y]) in a packed frame.
///
/// Pixels run four to a byte, most significant pair first — the same layout the vendor app packs
/// with (`byte = p3 | p2<<2 | p1<<4 | p0<<6`).
void setPixel(Uint8List frame, int x, int y, int code) {
  if (x < 0 || x >= EPaperDisplay.pixelsPerRow) return;
  if (y < 0 || y >= EPaperDisplay.frameRows) return;

  final index = y * EPaperDisplay.frameBytesPerRow + (x ~/ EPaperDisplay.pixelsPerByte);
  final shift = 6 - 2 * (x % EPaperDisplay.pixelsPerByte);
  frame[index] = (frame[index] & ~(0x03 << shift) & 0xFF) | ((code & 0x03) << shift);
}
