import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:epaper_nfc/epaper_nfc.dart';
import 'package:flutter/material.dart';

import 'frame_packer.dart';
import 'quantiser.dart';

/// An imported image, positioned within a frame.
///
/// The frame is normally the whole panel canvas, turned on its side when [landscape]. A token's art
/// box passes [box] instead, and the picture fills just that.
///
/// [offset] and [scale] are in **panel pixels** relative to the frame's top-left, not screen pixels,
/// so the same values drive the on-screen crop view and the real render at whatever size each
/// happens to be drawn.
@immutable
class ImageContent {
  const ImageContent({
    required this.device,
    required this.source,
    required this.bytes,
    this.offset = Offset.zero,
    this.scale = 1,
    this.style = DitherStyle.photo,
    this.landscape = false,
    this.box,
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

  /// Framed along the panel's long edge. Ignored when [box] is given.
  final bool landscape;

  /// An explicit frame size, for a picture that fills part of a design rather than the whole panel.
  final Size? box;

  /// What the picture is framed in, in panel pixels.
  Size get frame => box ?? device.canvasSizeFor(landscape: landscape);

  ImageContent copyWith({Offset? offset, double? scale, DitherStyle? style}) {
    return ImageContent(
      device: device,
      source: source,
      bytes: bytes,
      offset: offset ?? this.offset,
      scale: scale ?? this.scale,
      style: style ?? this.style,
      landscape: landscape,
      box: box,
    );
  }

  /// The same picture in a different frame — another panel, the other orientation, or a resized
  /// box — keeping the zoom and whatever was at the centre.
  ///
  /// Pan and zoom are measured in the old frame's pixels, so they can't simply carry over. Callers
  /// that would rather start afresh follow this with [recentred].
  ImageContent reframed({
    PanelDevice? device,
    bool? landscape,
    ValueGetter<Size?>? box,
  }) {
    final next = ImageContent(
      device: device ?? this.device,
      source: source,
      bytes: bytes,
      style: style,
      landscape: landscape ?? this.landscape,
      box: box == null ? this.box : box(),
    );
    final centre = frame.center(Offset.zero);
    final pinned = (centre - offset) / scale;
    final newScale = next.coverScale * zoom;
    return next.copyWith(
      scale: newScale,
      offset: next.frame.center(Offset.zero) - pinned * newScale,
    );
  }

  /// The scale at which the image just covers the frame.
  double get coverScale {
    final byWidth = frame.width / source.width;
    final byHeight = frame.height / source.height;
    return byWidth > byHeight ? byWidth : byHeight;
  }

  /// How far zoomed in relative to just covering the frame. 1 means "fills it exactly".
  double get zoom => scale / coverScale;

  /// Rescales about the centre of the frame, so zooming doesn't also drift the subject away.
  ImageContent zoomedTo(double newZoom) {
    final newScale = coverScale * newZoom;
    final centre = frame.center(Offset.zero);
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
        (frame.width - source.width * scale) / 2,
        (frame.height - source.height * scale) / 2,
      ),
    );
  }
}

/// Draws [content] filling its frame, origin top-left, on the device's background ink.
void paintImageContent(Canvas canvas, ImageContent content) {
  final bounds = Offset.zero & content.frame;
  canvas.drawRect(bounds, Paint()..color = content.device.background);

  canvas.save();
  canvas.clipRect(bounds);
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

/// Renders [content] filling its frame and quantises it: one ink code per pixel, row by row.
///
/// The frame must be whole pixels — a token's art box is snapped before it gets here.
Future<Uint8List> renderImageCodes(ImageContent content) async {
  final size = content.frame;
  assert(size.width == size.width.roundToDouble());
  assert(size.height == size.height.roundToDouble());

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Offset.zero & size);

  paintImageContent(canvas, content);

  final image = await recorder.endRecording().toImage(
    size.width.round(),
    size.height.round(),
  );
  try {
    return await FramePacker.quantiseImage(
      content.device,
      image,
      content.style,
    );
  } finally {
    image.dispose();
  }
}

/// Renders [content] into the device's frame and quantises it to the panel's inks.
///
/// For a picture that fills the panel — one with no [ImageContent.box].
Future<Uint8List> renderImageFrame(ImageContent content) async {
  assert(content.box == null, 'A boxed picture is packed by its owner.');
  return packCodes(
    content.device,
    await renderImageCodes(content),
    landscape: content.landscape,
  );
}

/// Renders [content] to an image showing exactly the inks the panel will use, frame-sized.
///
/// The preview round-trips through the quantiser rather than just drawing the source: on a palette
/// this narrow the difference between an image and its approximation is enormous, and a preview of
/// the original would be actively misleading.
Future<ui.Image> renderImagePreview(ImageContent content) async {
  final size = content.frame;
  return codesToImage(
    content.device,
    await renderImageCodes(content),
    size.width.round(),
    size.height.round(),
  );
}

/// One ink code per pixel, row by row, as a viewable image in the palette's on-screen colours.
Future<ui.Image> codesToImage(
  PanelDevice device,
  Uint8List codes,
  int width,
  int height,
) {
  assert(codes.length == width * height);
  final rgba = Uint8List(width * height * 4);
  for (var p = 0; p < codes.length; p++) {
    final colour = device.palette[codes[p]];
    rgba[p * 4] = (colour.r * 255).round();
    rgba[p * 4 + 1] = (colour.g * 255).round();
    rgba[p * 4 + 2] = (colour.b * 255).round();
    rgba[p * 4 + 3] = 255;
  }

  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgba,
    width,
    height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

/// Expands a packed frame back into a viewable image, the right way up, in the palette's on-screen
/// colours — on its side if it was drawn [landscape].
Future<ui.Image> decodeFrame(
  PanelDevice device,
  Uint8List frame, {
  bool landscape = false,
}) {
  final size = device.canvasSizeFor(landscape: landscape);
  final width = size.width.round();
  final height = size.height.round();
  final codes = Uint8List(width * height);

  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      codes[y * width + x] = landscape
          ? codeAtLandscape(device, frame, x, y)
          : codeAtCanvas(device, frame, x, y);
    }
  }
  return codesToImage(device, codes, width, height);
}
