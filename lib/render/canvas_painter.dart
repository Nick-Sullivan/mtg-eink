import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/epaper_display.dart';
import 'frame_packer.dart';

/// What to put on the panel. Deliberately small — this is a label maker, not a drawing app.
class PanelContent {
  const PanelContent({
    this.text = '',
    this.fontSize = 28,
    this.textColor = EPaperDisplay.black,
    this.background = EPaperDisplay.white,
    this.border = true,
    this.borderColor = EPaperDisplay.red,
  });

  final String text;
  final double fontSize;
  final Color textColor;
  final Color background;
  final bool border;
  final Color borderColor;

  PanelContent copyWith({
    String? text,
    double? fontSize,
    Color? textColor,
    Color? background,
    bool? border,
    Color? borderColor,
  }) {
    return PanelContent(
      text: text ?? this.text,
      fontSize: fontSize ?? this.fontSize,
      textColor: textColor ?? this.textColor,
      background: background ?? this.background,
      border: border ?? this.border,
      borderColor: borderColor ?? this.borderColor,
    );
  }
}

/// The panel stands with its long edge vertical, so "up" runs along the 296 axis.
///
/// That happens to be the frame buffer's own orientation — row 0 is the top — so content is drawn
/// directly into it with no rotation at all.
const Size panelSize = Size(128, 296);

/// Draws [content] in panel coordinates: 128 wide, 296 tall, origin top-left.
void paintContent(Canvas canvas, PanelContent content) {
  final width = panelSize.width;
  final height = panelSize.height;

  canvas.drawRect(
    Rect.fromLTWH(0, 0, width, height),
    Paint()..color = content.background,
  );

  if (content.border) {
    const inset = 3.0;
    canvas.drawRect(
      Rect.fromLTWH(inset, inset, width - 2 * inset, height - 2 * inset),
      Paint()
        ..color = content.borderColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
  }

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

/// Renders [content] to the panel's native 128 x 296 frame and packs it.
Future<Uint8List> renderFrame(PanelContent content) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(
    recorder,
    Rect.fromLTWH(
      0,
      0,
      EPaperDisplay.pixelsPerRow.toDouble(),
      EPaperDisplay.frameRows.toDouble(),
    ),
  );

  paintContent(canvas, content);

  final image = await recorder.endRecording().toImage(
    EPaperDisplay.pixelsPerRow,
    EPaperDisplay.frameRows,
  );
  try {
    return await FramePacker.pack(image);
  } finally {
    image.dispose();
  }
}

/// Live preview of what will be sent, at the panel's true aspect ratio.
///
/// Renders the same [paintContent] as the real frame, so the preview and the panel can't drift
/// apart — but without the quantisation, so it shows intent rather than exact ink.
class PanelPreview extends StatelessWidget {
  const PanelPreview({required this.content, super.key});

  final PanelContent content;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: panelSize.width / panelSize.height,
      child: CustomPaint(painter: _PreviewPainter(content)),
    );
  }
}

class _PreviewPainter extends CustomPainter {
  const _PreviewPainter(this.content);

  final PanelContent content;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / panelSize.width);
    paintContent(canvas, content);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PreviewPainter oldDelegate) => true;
}
