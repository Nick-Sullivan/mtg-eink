import 'package:flutter/material.dart';

import '../../models/panel_device.dart';

/// A labelled row of swatches — every ink the panel can print, and no others.
///
/// Deliberately not a general colour picker: offering colours the panel can't produce would only
/// let you design something it will then silently approximate.
class PalettePicker extends StatelessWidget {
  const PalettePicker({
    required this.device,
    required this.label,
    required this.selected,
    required this.onPick,
    super.key,
  });

  final PanelDevice device;
  final String label;
  final Color selected;
  final ValueChanged<Color> onPick;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(width: 96, child: Text(label)),
          for (final colour in device.palette)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: GestureDetector(
                onTap: () => onPick(colour),
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: colour,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: colour == selected ? Colors.blue : Colors.black26,
                      width: colour == selected ? 3 : 1,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
