import 'dart:typed_data';

import 'panel_device.dart';

/// Reads the ink code at ([x], [y]) in a packed frame. The inverse of [setPixel].
int codeAt(PanelDevice device, Uint8List frame, int x, int y) {
  final index = y * device.frameBytesPerRow + (x ~/ device.pixelsPerByte);
  final shift = 8 - device.bitsPerPixel * (x % device.pixelsPerByte + 1);
  return (frame[index] >> shift) & ((1 << device.bitsPerPixel) - 1);
}

/// Writes an ink [code] at ([x], [y]) in a packed frame.
///
/// Pixels run several to a byte, most significant first — the same layout the vendor app packs with
/// (`byte = p0<<6 | p1<<4 | p2<<2 | p3` at two bits per pixel).
void setPixel(PanelDevice device, Uint8List frame, int x, int y, int code) {
  if (x < 0 || x >= device.pixelsPerRow) return;
  if (y < 0 || y >= device.frameRows) return;

  final index = y * device.frameBytesPerRow + (x ~/ device.pixelsPerByte);
  final shift = 8 - device.bitsPerPixel * (x % device.pixelsPerByte + 1);
  final mask = (1 << device.bitsPerPixel) - 1;
  frame[index] =
      (frame[index] & ~(mask << shift) & 0xFF) | ((code & mask) << shift);
}

/// Writes an ink [code] at canvas pixel ([u], [v]) — where the picture puts it, not where the
/// controller stores it. See [PanelDevice.framePoint].
void setCanvasPixel(
  PanelDevice device,
  Uint8List frame,
  int u,
  int v,
  int code,
) {
  if (u < 0 || u >= device.canvasWidth || v < 0 || v >= device.canvasHeight) {
    return;
  }
  final point = device.framePoint(u, v);
  setPixel(device, frame, point.x, point.y, code);
}

/// Reads the ink code at canvas pixel ([u], [v]). The inverse of [setCanvasPixel].
int codeAtCanvas(PanelDevice device, Uint8List frame, int u, int v) {
  final point = device.framePoint(u, v);
  return codeAt(device, frame, point.x, point.y);
}
