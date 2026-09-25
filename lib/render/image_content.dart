import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/panel_device.dart';
import 'frame_packer.dart';
import 'quantiser.dart';

/// An imported image, positioned within a panel's frame.
///
/// [offset] and [scale] are in **panel pixels**, not screen pixels, so the same values drive the
/// on-screen crop view and the real render at whatever size each happens to be drawn.
@immutable
class ImageContent {
  const ImageContent({
    required this.device,
    required this.source,
    required this.bytes,
    this.offset = Offset.zero,
    this.scale = 1,
    this.style = DitherStyle.photo,
  });

  final PanelDevice device;
  final ui.Image source;

  /// The encoded original, as picked or as loaded from the library.
  ///
  /// Carried alongside the decoded image so saving a design keeps the *source* rather than the
  /// rendered frame — otherwise reopening one would re-quantise an already-quantised picture.
  final Uint8List bytes;

  final Offset offset;
  final double scale;
  final DitherStyle style;

  ImageContent copyWith({Offset? offset, double? scale, DitherStyle? style}) {
    return ImageContent(
      device: device,
      source: source,
      bytes: bytes,
      offset: offset ?? this.offset,
      scale: scale ?? this.scale,
      style: style ?? this.style,
    );
  }

  /// The scale at which the image just covers the frame.
  double get coverScale {
    final byWidth = device.size.width / source.width;
    final byHeight = device.size.height / source.height;
    return byWidth > byHeight ? byWidth : byHeight;
  }

  /// How far zoomed in relative to just covering the frame. 1 means "fills it exactly".
  double get zoom => scale / coverScale;

  /// Rescales about the centre of the frame, so zooming doesn't also drift the subject away.
  ImageContent zoomedTo(double newZoom) {
    final newScale = coverScale * newZoom;
    final centre = Offset(device.size.width / 2, device.size.height / 2);
    return copyWith(
      scale: newScale,
      offset: centre - (centre - offset) * (newScale / scale),
    );
  }

  /// Back to filling the frame, centred — the state a freshly picked image starts in.
  ImageContent recentred() {
    final scale = coverScale;
    return copyWith(
      scale: scale,
      offset: Offset(
        (device.size.width - source.width * scale) / 2,
        (device.size.height - source.height * scale) / 2,
      ),
    );
  }
}

/// Draws [content] in panel coordinates, on the device's background ink.
void paintImageContent(Canvas canvas, ImageContent content) {
  final size = content.device.size;
  canvas.drawRect(
    Rect.fromLTWH(0, 0, size.width, size.height),
    Paint()..color = content.device.background,
  );

  canvas.save();
  canvas.clipRect(Rect.fromLTWH(0, 0, size.width, size.height));
  paintImageOnly(canvas, content);
  canvas.restore();
}

/// Draws just the image, under its pan and zoom, with no background and no clipping.
///
/// Separate from [paintImageContent] so the crop view can let the image spill past the frame's
/// edges — you can't frame a photo when you can only see the part that's already inside the frame.
void paintImageOnly(Canvas canvas, ImageContent content) {
  canvas.save();
  canvas.translate(content.offset.dx, content.offset.dy);
  canvas.scale(content.scale);
  canvas.drawImage(
    content.source,
    Offset.zero,
    Paint()..filterQuality = FilterQuality.medium,
  );
  canvas.restore();
}

/// Renders [content] into the device's frame and quantises it to the panel's inks.
Future<Uint8List> renderImageFrame(ImageContent content) async {
  final device = content.device;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(
    recorder,
    Rect.fromLTWH(0, 0, device.size.width, device.size.height),
  );

  paintImageContent(canvas, content);

  final image = await recorder.endRecording().toImage(
    device.pixelsPerRow,
    device.frameRows,
  );
  try {
    return await FramePacker.pack(device, image, style: content.style);
  } finally {
    image.dispose();
  }
}

/// Renders [content] to an image showing exactly the inks the panel will use.
///
/// The preview round-trips through the quantiser rather than just drawing the source: on a palette
/// this narrow the difference between an image and its approximation is enormous, and a preview of
/// the original would be actively misleading.
Future<ui.Image> renderImagePreview(ImageContent content) async {
  return decodeFrame(content.device, await renderImageFrame(content));
}

/// Expands a packed frame back into a viewable image, using the palette's on-screen colours.
Future<ui.Image> decodeFrame(PanelDevice device, Uint8List frame) {
  final rgba = Uint8List(device.pixelsPerRow * device.frameRows * 4);

  for (var y = 0; y < device.frameRows; y++) {
    for (var x = 0; x < device.pixelsPerRow; x++) {
      final colour = device.palette[codeAt(device, frame, x, y)];
      final out = (y * device.pixelsPerRow + x) * 4;
      rgba[out] = (colour.r * 255).round();
      rgba[out + 1] = (colour.g * 255).round();
      rgba[out + 2] = (colour.b * 255).round();
      rgba[out + 3] = 255;
    }
  }

  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgba,
    device.pixelsPerRow,
    device.frameRows,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}
