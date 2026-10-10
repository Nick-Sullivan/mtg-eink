import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../render/image_content.dart';
import '../../render/quantiser.dart';

/// Zoom, as a slider rather than only a pinch.
///
/// Pinching is fiddly on a preview this small. The scale is logarithmic: a linear one spends most
/// of its travel on huge zooms nobody wants.
class ZoomRow extends StatelessWidget {
  const ZoomRow({required this.image, required this.onChanged, super.key});

  static const _minExponent = -2.0;
  static const _maxExponent = 3.0;

  final ImageContent image;
  final ValueChanged<ImageContent> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.zoom_out, size: 20),
        Expanded(
          child: Slider(
            value: (math.log(image.zoom) / math.ln2).clamp(
              _minExponent,
              _maxExponent,
            ),
            min: _minExponent,
            max: _maxExponent,
            onChanged: (v) =>
                onChanged(image.zoomedTo(math.pow(2, v).toDouble())),
          ),
        ),
        const Icon(Icons.zoom_in, size: 20),
        const SizedBox(width: 8),
        Tooltip(
          message: 'Fit to frame',
          child: IconButton.outlined(
            onPressed: () => onChanged(image.recentred()),
            icon: const Icon(Icons.fit_screen_outlined),
          ),
        ),
      ],
    );
  }
}

/// Photo or Graphic conversion, with a line saying what each is for.
class DitherStyleControl extends StatelessWidget {
  const DitherStyleControl({
    required this.image,
    required this.onChanged,
    super.key,
  });

  final ImageContent image;
  final ValueChanged<ImageContent> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<DitherStyle>(
          segments: const [
            ButtonSegment(value: DitherStyle.photo, label: Text('Photo')),
            ButtonSegment(value: DitherStyle.graphic, label: Text('Graphic')),
          ],
          selected: {image.style},
          onSelectionChanged: (s) => onChanged(image.copyWith(style: s.first)),
        ),
        const SizedBox(height: 8),
        Text(
          image.style == DitherStyle.photo
              ? 'Dithered across the panel’s inks. Best for photographs.'
              : 'Flat nearest colour. Best for logos and flat art.',
          style: const TextStyle(fontSize: 12, color: Colors.black54),
        ),
      ],
    );
  }
}

/// Portrait or landscape: across the panel, or along its long edge.
class OrientationToggle extends StatelessWidget {
  const OrientationToggle({
    required this.landscape,
    required this.onChanged,
    super.key,
  });

  final bool landscape;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<bool>(
      segments: const [
        ButtonSegment(
          value: false,
          icon: Icon(Icons.crop_portrait),
          label: Text('Portrait'),
        ),
        ButtonSegment(
          value: true,
          icon: Icon(Icons.crop_landscape),
          label: Text('Landscape'),
        ),
      ],
      selected: {landscape},
      onSelectionChanged: (s) => onChanged(s.first),
    );
  }
}
