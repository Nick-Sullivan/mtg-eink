import 'dart:async';
import 'dart:ui' as ui;

import 'package:epaper_nfc/epaper_nfc.dart';
import 'package:flutter/material.dart';

import '../models/token_content.dart';
import '../render/canvas_painter.dart';
import '../render/image_content.dart';
import '../render/token_painter.dart';

/// The token card, with a picture in the art box shown in the inks the panel will really use.
///
/// The card itself is drawn live, so typing stays instant. Only the picture is quantised, and that
/// takes a few milliseconds, so — as in the crop view — the source is shown while it's changing and
/// the quantised version settles in shortly after it stops.
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
  ui.Image? _inks;
  Timer? _debounce;

  /// True while [_inks] no longer matches the picture.
  bool _stale = true;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(TokenPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.picture != widget.picture) {
      setState(() => _stale = true);
      _schedule();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _inks?.dispose();
    super.dispose();
  }

  void _schedule() {
    _debounce?.cancel();
    final picture = widget.picture;
    if (picture == null) return;
    _debounce = Timer(const Duration(milliseconds: 120), () async {
      final image = await renderImagePreview(picture);
      // Superseded while it was rendering, or gone.
      if (!mounted || widget.picture != picture) {
        image.dispose();
        return;
      }
      setState(() {
        _inks?.dispose();
        _inks = image;
        _stale = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final device = widget.device;
    final token = widget.token;
    final picture = widget.picture;
    // The quantised picture is only good for the box it was rendered for.
    final inks = _stale || picture?.box != tokenArtBox(device, token)
        ? null
        : _inks;

    return PaintedPreview(
      device: device,
      paint: (canvas) => paintToken(
        canvas,
        device,
        token,
        picture: picture,
        pictureInks: inks,
      ),
    );
  }
}
