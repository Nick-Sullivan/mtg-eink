import 'package:flutter/material.dart';

import '../models/creature_art.dart';
import '../models/panel_device.dart';

/// Things you set once and then forget about.
///
/// Kept off the composing tabs deliberately: which panel you own changes roughly never, and a
/// control that permanent has no business taking up room above the preview you look at every time.
class SettingsView extends StatelessWidget {
  const SettingsView({
    required this.device,
    required this.onDeviceChanged,
    super.key,
  });

  final PanelDevice device;
  final ValueChanged<PanelDevice> onDeviceChanged;

  @override
  Widget build(BuildContext context) {
    final titles = Theme.of(context).textTheme;

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        Text('Panel', style: titles.titleMedium),
        const SizedBox(height: 8),
        DropdownButtonFormField<PanelDevice>(
          value: device,
          isExpanded: true,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          ),
          items: [
            for (final option in PanelDevice.supported)
              DropdownMenuItem(value: option, child: Text(option.name)),
          ],
          onChanged: (picked) {
            if (picked != null && picked != device) onDeviceChanged(picked);
          },
        ),
        const Divider(height: 32),

        Text('This panel', style: titles.titleMedium),
        const SizedBox(height: 12),
        _Fact('Resolution', '${device.pixelsPerRow} x ${device.frameRows}'),
        _Fact('Colours', '${device.palette.length}'),
        _Fact(
          'Refresh',
          '~${(device.nominalRefresh.inMilliseconds / 1000).round()} seconds',
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            const SizedBox(width: 120, child: Text('Inks')),
            for (final colour in device.palette)
              Container(
                width: 28,
                height: 28,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  color: colour,
                  border: Border.all(color: Colors.black54),
                ),
              ),
          ],
        ),
        const Divider(height: 32),

        // The creature art's licence (CC BY 3.0) requires this credit to be shown.
        Text('Credits', style: titles.titleMedium),
        const SizedBox(height: 8),
        Text(
          creatureArtCredit,
          style: TextStyle(color: Colors.black.withValues(alpha: 0.6)),
        ),
      ],
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: TextStyle(color: Colors.black.withValues(alpha: 0.6)),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
