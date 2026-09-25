import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../render/image_content.dart';

/// How far outside the frame the crop view lets you see, in panel pixels.
///
/// Showing only what's inside the frame makes framing guesswork — you can't tell whether the thing
/// you want is just off the edge or miles away. This is the margin that turns positioning into
/// something you can aim.
const double _margin = 40;

/// Drag and pinch to place an image within the panel's frame.
///
/// Inside the frame you see the **quantised** result — what the panel will actually print — because
/// on a narrow palette that looks nothing like the source. Outside the frame the original image
/// continues, dimmed, so you can see what you're about to crop away. Quantising takes a few
/// milliseconds, so the smooth source is shown while you're adjusting and the dithered version
/// settles in shortly after you stop.
class CropView extends StatefulWidget {
  const CropView({required this.content, required this.onChanged, super.key});

  final ImageContent content;
  final ValueChanged<ImageContent> onChanged;

  @override
  State<CropView> createState() => _CropViewState();
}

class _CropViewState extends State<CropView> {
  ui.Image? _preview;
  Timer? _debounce;

  /// True while the on-screen dither no longer matches the content.
  ///
  /// Showing a stale quantised frame while the image moves under it looks broken — the pixels lag
  /// behind the gesture. The smooth source image is shown instead until the new dither is ready.
  bool _stale = true;

  Offset _startOffset = Offset.zero;
  double _startScale = 1;
  Offset _startFocal = Offset.zero;

  Size get _viewport => Size(
    widget.content.device.size.width + _margin * 2,
    widget.content.device.size.height + _margin * 2,
  );

  Rect get _frameRect => Rect.fromLTWH(
    _margin,
    _margin,
    widget.content.device.size.width,
    widget.content.device.size.height,
  );

  @override
  void initState() {
    super.initState();
    _schedulePreview();
  }

  @override
  void didUpdateWidget(CropView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content != widget.content) {
      setState(() => _stale = true);
      _schedulePreview();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _preview?.dispose();
    super.dispose();
  }

  void _schedulePreview() {
    // The debounce restarts on every change, so the dither only reappears once you've stopped
    // moving — whether you were pinching or dragging the zoom slider.
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 120), () async {
      final image = await renderImagePreview(widget.content);
      if (!mounted) {
        image.dispose();
        return;
      }
      setState(() {
        _preview?.dispose();
        _preview = image;
        _stale = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final viewport = _viewport;

    return AspectRatio(
      aspectRatio: viewport.width / viewport.height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Gestures arrive in widget pixels; everything else is in panel pixels.
          final toPanel = viewport.height / constraints.biggest.height;

          return RawGestureDetector(
            behavior: HitTestBehavior.opaque,
            gestures: {
              // A plain GestureDetector loses vertical drags to the surrounding ListView, so the
              // image could only be moved sideways. This recognizer refuses to yield, which is
              // right here: a drag that starts on the crop area is always about the image.
              _EagerScaleRecognizer:
                  GestureRecognizerFactoryWithHandlers<_EagerScaleRecognizer>(
                    _EagerScaleRecognizer.new,
                    (recognizer) => recognizer
                      ..onStart = (details) {
                        _startOffset = widget.content.offset;
                        _startScale = widget.content.scale;
                        _startFocal = details.localFocalPoint * toPanel;
                      }
                      ..onUpdate = (details) {
                        final focal = details.localFocalPoint * toPanel;
                        final scale = (_startScale * details.scale).clamp(
                          widget.content.coverScale * 0.2,
                          widget.content.coverScale * 8,
                        );
                        // Keep the point under the fingers put: scale about the focal point, then
                        // apply the pan since the gesture began.
                        final scaleChange = scale / _startScale;
                        final anchored =
                            _startFocal -
                            (_startFocal - _startOffset) * scaleChange;

                        widget.onChanged(
                          widget.content.copyWith(
                            scale: scale,
                            offset: anchored + (focal - _startFocal),
                          ),
                        );
                      },
                  ),
            },
            child: ClipRect(
              child: CustomPaint(
                painter: _CropPainter(
                  content: widget.content,
                  preview: _stale ? null : _preview,
                  viewport: viewport,
                  frameRect: _frameRect,
                ),
                size: constraints.biggest,
              ),
            ),
          );
        },
      ),
    );
  }
}

/// A scale recognizer that never loses the gesture arena.
///
/// Inside a scrolling list the default behaviour is for the list's vertical drag recognizer to win,
/// which makes the image pannable sideways only. Accepting instead of rejecting keeps the gesture
/// here. Dragging anywhere else on the page still scrolls normally.
class _EagerScaleRecognizer extends ScaleGestureRecognizer {
  @override
  void rejectGesture(int pointer) => acceptGesture(pointer);
}

class _CropPainter extends CustomPainter {
  const _CropPainter({
    required this.content,
    required this.preview,
    required this.viewport,
    required this.frameRect,
  });

  final ImageContent content;
  final ui.Image? preview;
  final Size viewport;
  final Rect frameRect;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / viewport.width);

    final bounds = Rect.fromLTWH(0, 0, viewport.width, viewport.height);

    // Neutral ground, so empty areas read as "nothing here".
    canvas.drawRect(bounds, Paint()..color = const Color(0xFF9E9E99));

    // The source image, spilling into the margin.
    canvas.save();
    canvas.translate(_margin, _margin);
    paintImageOnly(canvas, content);
    canvas.restore();

    // Dim everything outside the frame — that's what gets thrown away.
    canvas.saveLayer(bounds, Paint());
    canvas.drawRect(bounds, Paint()..color = const Color(0xAA000000));
    canvas.drawRect(frameRect, Paint()..blendMode = BlendMode.clear);
    canvas.restore();

    final ready = preview;
    if (ready != null) {
      // Inside the frame, replace the source with the real inks.
      canvas.drawImageRect(
        ready,
        Rect.fromLTWH(0, 0, ready.width.toDouble(), ready.height.toDouble()),
        frameRect,
        Paint()..filterQuality = FilterQuality.none,
      );
    }

    // The frame itself: a light hairline over the dimmed surround, dark over the image.
    canvas.drawRect(
      frameRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0xFFFFFFFF),
    );
    canvas.drawRect(
      frameRect.deflate(1),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0x66000000),
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(_CropPainter oldDelegate) =>
      oldDelegate.content != content || oldDelegate.preview != preview;
}
