import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/panel_device.dart';
import 'frame_packer.dart';

/// Text to put on the panel. Deliberately small — this is a label maker, not a drawing app.
@immutable
class PanelContent {
  const PanelContent({
    this.text = '',
    this.fontSize = 28,
    required this.textColor,
    required this.background,
  });

  /// Sensible starting content for a device, using its own paper and pen inks.
  factory PanelContent.forDevice(PanelDevice device, {String text = ''}) =>
      PanelContent(
        text: text,
        textColor: device.foreground,
        background: device.background,
      );

  final String text;
  final double fontSize;
  final Color textColor;
  final Color background;

  PanelContent copyWith({
    String? text,
    double? fontSize,
    Color? textColor,
    Color? background,
  }) {
    return PanelContent(
      text: text ?? this.text,
      fontSize: fontSize ?? this.fontSize,
      textColor: textColor ?? this.textColor,
      background: background ?? this.background,
    );
  }
}

/// Draws [content] in panel coordinates, origin top-left.
///
/// The panel stands with its long edge vertical, which is the frame buffer's own orientation, so
/// there's no rotation anywhere in the pipeline.
void paintContent(Canvas canvas, PanelDevice device, PanelContent content) {
  final width = device.size.width;
  final height = device.size.height;

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
    renderPainted(device, (canvas) => paintContent(canvas, device, content));

/// Records whatever [paint] draws in panel coordinates, then packs it to the device's frame.
///
/// Packed as flat nearest-colour: every caller draws flat art, and dithering it would only add
/// speckle.
Future<Uint8List> renderPainted(
  PanelDevice device,
  void Function(Canvas canvas) paint,
) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(
    recorder,
    Rect.fromLTWH(0, 0, device.size.width, device.size.height),
  );

  paint(canvas);

  final image = await recorder.endRecording().toImage(
    device.pixelsPerRow,
    device.frameRows,
  );
  try {
    return FramePacker.pack(device, image);
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
      paint: (canvas) => paintContent(canvas, device, content),
    );
  }
}

/// Shows whatever [paint] draws in panel coordinates, scaled to fit, at the panel's aspect ratio.
///
/// Give it the same paint function the frame is rendered from, so the preview can't drift from
/// what gets written.
class PaintedPreview extends StatelessWidget {
  const PaintedPreview({required this.device, required this.paint, super.key});

  final PanelDevice device;
  final void Function(Canvas canvas) paint;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: device.size.width / device.size.height,
      child: CustomPaint(painter: _PreviewPainter(device, paint)),
    );
  }
}

class _PreviewPainter extends CustomPainter {
  const _PreviewPainter(this.device, this.paintPanel);

  final PanelDevice device;
  final void Function(Canvas canvas) paintPanel;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / device.size.width);
    paintPanel(canvas);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PreviewPainter oldDelegate) => true;
}
