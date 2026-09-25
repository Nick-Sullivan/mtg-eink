import 'package:flutter/material.dart';

import '../models/panel_device.dart';
import '../render/canvas_painter.dart';
import 'widgets/palette_picker.dart';

/// Controls for composing text: what it says, how big, and in which inks.
class TextEditor extends StatelessWidget {
  const TextEditor({
    required this.device,
    required this.controller,
    required this.content,
    required this.onChanged,
    super.key,
  });

  final PanelDevice device;

  /// Owned by the caller, because the text is part of its state and outlives this widget.
  final TextEditingController controller;

  final PanelContent content;
  final ValueChanged<PanelContent> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: controller,
          maxLines: 3,
          minLines: 1,
          decoration: const InputDecoration(
            labelText: 'Text',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),

        Row(
          children: [
            const SizedBox(width: 72, child: Text('Size')),
            Expanded(
              child: Slider(
                value: content.fontSize,
                min: 10,
                max: 64,
                divisions: 54,
                label: content.fontSize.round().toString(),
                onChanged: (v) => onChanged(content.copyWith(fontSize: v)),
              ),
            ),
          ],
        ),

        PalettePicker(
          device: device,
          label: 'Text',
          selected: content.textColor,
          onPick: (c) => onChanged(content.copyWith(textColor: c)),
        ),
        PalettePicker(
          device: device,
          label: 'Background',
          selected: content.background,
          onPick: (c) => onChanged(content.copyWith(background: c)),
        ),
      ],
    );
  }
}
