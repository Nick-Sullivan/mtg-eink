import 'dart:async';
import 'dart:ui' as ui;

import 'package:epaper_nfc/epaper_nfc.dart';
import 'package:flutter/material.dart';

import '../models/token_content.dart';
import '../render/canvas_painter.dart';
import '../render/image_content.dart';
import '../render/token_painter.dart';

/// The token card exactly as the panel will show it: the packed frame, decoded back to pixels.
///
/// Not a live drawing of the card. That looked smooth on the phone while the panel's one bit per
/// pixel lost whole letters of the small text, and nothing on screen said so. Rendering the frame
/// takes a few milliseconds, so it's debounced while typing; the last real frame stays up until
/// the next is ready, so what's shown is always something that was actually rendered.
class TokenPreview extends StatefulWidget {
  const TokenPreview({
    required this.device,
    required this.token,
    this.picture,
    super.key,
  });

  final PanelDevice device;
  final TokenContent token;
  final ImageContent? picture;

  @override
  State<TokenPreview> createState() => _TokenPreviewState();
}

class _TokenPreviewState extends State<TokenPreview> {
  ui.Image? _frame;
  Timer? _debounce;

  /// Bumped per render, so a slow render finishing after a newer one is thrown away.
  var _generation = 0;

  @override
  void initState() {
    super.initState();
    _schedule(immediately: true);
  }

  @override
  void didUpdateWidget(TokenPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.token != widget.token ||
        oldWidget.picture != widget.picture ||
        oldWidget.device != widget.device) {
      _schedule();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _frame?.dispose();
    super.dispose();
  }

  void _schedule({bool immediately = false}) {
    _debounce?.cancel();
    _debounce = Timer(
      immediately ? Duration.zero : const Duration(milliseconds: 80),
      _render,
    );
  }

  Future<void> _render() async {
    final generation = ++_generation;
    final device = widget.device;
    final packed = await renderTokenFrame(
      device,
      widget.token,
      picture: widget.picture,
    );
    final image = await decodeFrame(device, packed);
    if (!mounted || generation != _generation) {
      image.dispose();
      return;
    }
    setState(() {
      _frame?.dispose();
      _frame = image;
    });
  }

  @override
  Widget build(BuildContext context) {
    final device = widget.device;
    final frame = _frame;
    // The very first render is a few milliseconds away; draw the card until then, not a blank.
    if (frame == null || frame.width != device.canvasWidth) {
      return PaintedPreview(
        device: device,
        paint: (canvas) =>
            paintToken(canvas, device, widget.token, picture: widget.picture),
      );
    }
    return AspectRatio(
      aspectRatio: device.size.width / device.size.height,
      child: CustomPaint(painter: _FramePainter(frame)),
    );
  }
}

/// Draws a decoded frame scaled to fit, pixels kept sharp — smoothing would hide exactly what this
/// preview is for.
class _FramePainter extends CustomPainter {
  const _FramePainter(this.frame);

  final ui.Image frame;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      frame,
      Rect.fromLTWH(0, 0, frame.width.toDouble(), frame.height.toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.none,
    );
  }

  @override
  bool shouldRepaint(_FramePainter oldDelegate) => oldDelegate.frame != frame;
}
