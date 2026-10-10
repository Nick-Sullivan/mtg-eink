import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:epaper_nfc/epaper_nfc.dart';
import 'package:flutter/material.dart';

import 'frame_packer.dart';
import 'quantiser.dart';

/// Text to put on the panel. Deliberately small — this is a label maker, not a drawing app.
@immutable
class PanelContent {
  const PanelContent({
    this.text = '',
    this.fontSize = 28,
    required this.textColor,
    required this.background,
    this.landscape = false,
  });

  /// Sensible starting content for a device, using its own paper and pen inks.
  factory PanelContent.forDevice(
    PanelDevice device, {
    String text = '',
    bool landscape = false,
  }) => PanelContent(
    text: text,
    textColor: device.foreground,
    background: device.background,
    landscape: landscape,
  );

  final String text;
  final double fontSize;
  final Color textColor;
  final Color background;

  /// Laid out along the panel's long edge rather than across it.
  final bool landscape;

  PanelContent copyWith({
    String? text,
    double? fontSize,
    Color? textColor,
    Color? background,
    bool? landscape,
  }) {
    return PanelContent(
      text: text ?? this.text,
      fontSize: fontSize ?? this.fontSize,
      textColor: textColor ?? this.textColor,
      background: background ?? this.background,
      landscape: landscape ?? this.landscape,
    );
  }
}

/// Draws [content] on the device's canvas, origin top-left — turned on its side when
/// [PanelContent.landscape].
///
/// Where the controller's frame isn't the same way round as the drawing, the packer turns it —
/// nothing that draws needs to know.
void paintContent(Canvas canvas, PanelDevice device, PanelContent content) {
  final size = device.canvasSizeFor(landscape: content.landscape);
  final width = size.width;
  final height = size.height;

  canvas.drawRect(
    Rect.fromLTWH(0, 0, width, height),
    Paint()..color = content.background,
  );

  if (content.text.trim().isEmpty) return;

  const margin = 14.0;
  final painter = TextPainter(
    text: TextSpan(
      text: content.text,
      style: TextStyle(
        color: content.textColor,
        fontSize: content.fontSize,
        height: 1.15,
        fontWeight: FontWeight.w600,
      ),
    ),
    textAlign: TextAlign.center,
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: width - 2 * margin);

  painter.paint(
    canvas,
    Offset((width - painter.width) / 2, (height - painter.height) / 2),
  );
}

/// Renders [content] to the device's frame and packs it.
Future<Uint8List> renderFrame(PanelDevice device, PanelContent content) =>
    renderPainted(
      device,
      (canvas) => paintContent(canvas, device, content),
      landscape: content.landscape,
    );

/// Records whatever [paint] draws in panel coordinates, then packs it to the device's frame.
///
/// [landscape] means [paint] draws on the canvas turned on its side; the packer turns it upright.
/// Packed as [style] — flat nearest-colour by default: most callers draw flat art, and dithering it
/// would only add speckle.
Future<Uint8List> renderPainted(
  PanelDevice device,
  void Function(Canvas canvas) paint, {
  bool landscape = false,
  DitherStyle style = DitherStyle.graphic,
}) async {
  final size = device.canvasSizeFor(landscape: landscape);
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Offset.zero & size);

  paint(canvas);

  final image = await recorder.endRecording().toImage(
    size.width.round(),
    size.height.round(),
  );
  try {
    return await FramePacker.pack(
      device,
      image,
      style: style,
      landscape: landscape,
    );
  } finally {
    image.dispose();
  }
}

/// Live preview at the panel's true aspect ratio.
///
/// Renders the same [paintContent] as the real frame, so the preview and the panel can't drift
/// apart — but without the quantisation, so it shows intent rather than exact ink.
class PanelPreview extends StatelessWidget {
  const PanelPreview({required this.device, required this.content, super.key});

  final PanelDevice device;
  final PanelContent content;

  @override
  Widget build(BuildContext context) {
    return PaintedPreview(
      device: device,
      landscape: content.landscape,
      paint: (canvas) => paintContent(canvas, device, content),
    );
  }
}

/// Shows whatever [paint] draws in panel coordinates, scaled to fit, at the panel's aspect ratio —
/// or the panel on its side, when [landscape].
///
/// Give it the same paint function the frame is rendered from, so the preview can't drift from
/// what gets written.
class PaintedPreview extends StatelessWidget {
  const PaintedPreview({
    required this.device,
    required this.paint,
    this.landscape = false,
    super.key,
  });

  final PanelDevice device;
  final void Function(Canvas canvas) paint;
  final bool landscape;

  @override
  Widget build(BuildContext context) {
    final size = device.canvasSizeFor(landscape: landscape);
    return AspectRatio(
      aspectRatio: size.width / size.height,
      child: CustomPaint(painter: _PreviewPainter(size, paint)),
    );
  }
}

class _PreviewPainter extends CustomPainter {
  const _PreviewPainter(this.panelSize, this.paintPanel);

  final Size panelSize;
  final void Function(Canvas canvas) paintPanel;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / panelSize.width);
    paintPanel(canvas);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PreviewPainter oldDelegate) => true;
}
