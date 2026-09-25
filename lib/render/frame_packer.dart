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

  /// Packs an image already rendered at the device's frame size.
  static Future<Uint8List> pack(
    PanelDevice device,
    ui.Image image, {
    DitherStyle style = DitherStyle.graphic,
  }) async {
    assert(image.width == device.pixelsPerRow);
    assert(image.height == device.frameRows);

    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) {
      throw StateError('Could not read pixels back from the rendered frame.');
    }
    return Quantiser.quantiseToFrame(device, data.buffer.asUint8List(), style);
  }
}
