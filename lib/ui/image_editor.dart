import 'package:flutter/material.dart';

import '../render/image_content.dart';
import 'widgets/image_controls.dart';

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
          OrientationToggle(
            landscape: image.landscape,
            // Pan and zoom were measured on the other shape, so start the framing afresh — the same
            // rule as switching panel.
            onChanged: (landscape) =>
                onChanged(image.reframed(landscape: landscape).recentred()),
          ),
          const SizedBox(height: 8),
          ZoomRow(image: image, onChanged: onChanged),
          const SizedBox(height: 4),
          DitherStyleControl(image: image, onChanged: onChanged),
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
