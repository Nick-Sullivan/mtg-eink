import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../render/image_content.dart';
import '../render/quantiser.dart';

/// Controls for an imported image: picking one, framing it, and choosing how it's converted.
class ImageEditor extends StatelessWidget {
  const ImageEditor({
    required this.content,
    required this.picking,
    required this.busy,
    required this.onPick,
    required this.onChanged,
    required this.onSave,
    super.key,
  });

  /// Null until something has been picked.
  final ImageContent? content;

  final bool picking;
  final bool busy;
  final VoidCallback onPick;
  final ValueChanged<ImageContent> onChanged;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final image = content;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          onPressed: picking ? null : onPick,
          icon: const Icon(Icons.photo_library_outlined),
          label: Text(
            image == null ? 'Pick an image' : 'Pick a different image',
          ),
        ),
        if (image != null) ...[
          const SizedBox(height: 8),
          _ZoomRow(image: image, onChanged: onChanged),
          const SizedBox(height: 4),
          SegmentedButton<DitherStyle>(
            segments: const [
              ButtonSegment(value: DitherStyle.photo, label: Text('Photo')),
              ButtonSegment(value: DitherStyle.graphic, label: Text('Graphic')),
            ],
            selected: {image.style},
            onSelectionChanged: (s) =>
                onChanged(image.copyWith(style: s.first)),
          ),
          const SizedBox(height: 8),
          Text(
            image.style == DitherStyle.photo
                ? 'Dithered across the panel’s inks. Best for photographs.'
                : 'Flat nearest colour. Best for logos and flat art.',
            style: const TextStyle(fontSize: 12, color: Colors.black54),
          ),
          const SizedBox(height: 4),
          const Text(
            'Drag to move, pinch to zoom. The preview shows the real inks.',
            style: TextStyle(fontSize: 12, color: Colors.black54),
          ),
          const SizedBox(height: 12),
          // Images and tokens save; text doesn't — it's quick enough to retype that storing it
          // would be clutter.
          OutlinedButton.icon(
            onPressed: busy ? null : onSave,
            icon: const Icon(Icons.bookmark_add_outlined),
            label: const Text('Save to library'),
          ),
        ],
      ],
    );
  }
}

/// Zoom, as a slider rather than only a pinch.
///
/// Pinching is fiddly on a preview this small. The scale is logarithmic: a linear one spends most
/// of its travel on huge zooms nobody wants.
class _ZoomRow extends StatelessWidget {
  const _ZoomRow({required this.image, required this.onChanged});

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
