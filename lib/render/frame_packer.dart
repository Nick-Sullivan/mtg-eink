import 'dart:typed_data';
import 'dart:ui' as ui;

import '../models/panel_device.dart';
import 'quantiser.dart';

/// Bridges a rendered `ui.Image` to the packed frame the panel expects.
///
/// The interesting part — deciding which ink each pixel becomes — lives in [Quantiser]. Keeping
/// them apart is what lets the quantiser stay a pure function over byte buffers, testable without a
/// rasteriser.
class FramePacker {
  const FramePacker._();

  /// Packs an image already rendered at the device's canvas size — or, when [landscape], at that
  /// size turned on its side.
  static Future<Uint8List> pack(
    PanelDevice device,
    ui.Image image, {
    DitherStyle style = DitherStyle.graphic,
    bool landscape = false,
  }) async {
    final expected = device.canvasSizeFor(landscape: landscape);
    assert(image.width == expected.width);
    assert(image.height == expected.height);

    return packCodes(
      device,
      await quantiseImage(device, image, style),
      landscape: landscape,
    );
  }

  /// One ink code per pixel of [image], row by row, at whatever size it is.
  static Future<Uint8List> quantiseImage(
    PanelDevice device,
    ui.Image image,
    DitherStyle style,
  ) async {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) {
      throw StateError('Could not read pixels back from the rendered frame.');
    }
    return Quantiser.quantiseToCodes(
      device,
      data.buffer.asUint8List(),
      image.width,
      image.height,
      style,
    );
  }
}

/// Writes [codes] — a [width]-wide block, row by row — into [frame] with its top-left at canvas
/// pixel ([left], [top]), replacing whatever was there.
///
/// How a picture quantised on its own goes into a design that was quantised differently: a token's
/// art is dithered, its card is flat.
void overlayCodes(
  PanelDevice device,
  Uint8List frame,
  Uint8List codes,
  int width, {
  required int left,
  required int top,
}) {
  for (var p = 0; p < codes.length; p++) {
    setCanvasPixel(device, frame, left + p % width, top + p ~/ width, codes[p]);
  }
}

/// Packs one ink code per canvas pixel into the device's frame.
///
/// With [landscape], [codes] are for the canvas turned on its side, and each is moved to where it
/// lands upright — see [landscapeToCanvas]. The picture is quantised the way it was drawn and only
/// the finished codes are turned, so error diffusion scans along the picture's own rows, and text
/// is never rasterised on its side.
Uint8List packCodes(
  PanelDevice device,
  Uint8List codes, {
  bool landscape = false,
}) {
  final width = landscape ? device.canvasHeight : device.canvasWidth;
  assert(codes.length == device.canvasWidth * device.canvasHeight);

  final frame = Uint8List(device.packedBytes);
  for (var p = 0; p < codes.length; p++) {
    final x = p % width;
    final y = p ~/ width;
    if (landscape) {
      final point = landscapeToCanvas(device, x, y);
      setCanvasPixel(device, frame, point.u, point.v, codes[p]);
    } else {
      setCanvasPixel(device, frame, x, y, codes[p]);
    }
  }
  return frame;
}
