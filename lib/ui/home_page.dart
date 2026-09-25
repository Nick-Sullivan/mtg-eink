import 'package:flutter/material.dart';

import '../nfc/tag_events.dart';

/// M1 diagnostic screen. The number that matters is "held for" — 10+ seconds without the
/// re-acquire count climbing means the panel is stable enough to write to.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  AdapterState? _adapter;
  TagDetected? _tag;
  int _heldMs = 0;
  TagLost? _lost;
  int _bestHoldMs = 0;

  @override
  void initState() {
    super.initState();
    tagEvents().listen(_onEvent);
  }

  void _onEvent(TagEvent event) {
    setState(() {
      switch (event) {
        case AdapterState():
          _adapter = event;
        case TagDetected():
          _tag = event;
          _lost = null;
          _heldMs = 0;
        case TagHeld():
          _heldMs = event.heldMs;
          if (event.heldMs > _bestHoldMs) _bestHoldMs = event.heldMs;
        case TagLost():
          _lost = event;
          if (event.heldMs > _bestHoldMs) _bestHoldMs = event.heldMs;
          _heldMs = 0;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final adapter = _adapter;
    final tag = _tag;
    final present = tag != null && _lost == null;

    return Scaffold(
      appBar: AppBar(title: const Text('nfc-eink · M1 tag probe')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (adapter != null && !adapter.enabled)
            const _Banner(
              text: 'NFC is off. Turn it on in Settings.',
              color: Colors.red,
            ),
          _StatusCard(present: present, heldMs: _heldMs, tag: tag),
          const SizedBox(height: 16),
          if (tag != null) ...[
            _Row('UID', tag.uid),
            _Row('Technologies', tag.techs.join(', ')),
            _Row('ATQA / SAK', '${tag.atqa ?? '?'} / ${tag.sak ?? '?'}'),
            _Row('Max transceive', '${tag.maxTransceiveLength ?? '?'} bytes'),
            const Divider(height: 32),
            _Row(
              'Re-acquires',
              '${tag.discoveryCount}',
              warn: tag.discoveryCount > 1,
            ),
            _Row('Best hold', '${(_bestHoldMs / 1000).toStringAsFixed(1)} s'),
            if (_lost case final lost?) _Row('Last loss', lost.reason),
          ] else
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'Hold the panel to the back of the phone.\n\n'
                'Leave a 0.25–0.5 inch gap rather than pressing flat — at very close '
                'range the coil over-couples and power transfer gets worse.',
                style: TextStyle(height: 1.5),
              ),
            ),
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.present,
    required this.heldMs,
    required this.tag,
  });

  final bool present;
  final int heldMs;
  final TagDetected? tag;

  @override
  Widget build(BuildContext context) {
    final seconds = (heldMs / 1000).toStringAsFixed(1);
    return Card(
      color: present ? Colors.green.shade50 : Colors.grey.shade200,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              present ? 'Tag present' : (tag == null ? 'No tag' : 'Tag lost'),
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            if (present) ...[
              const SizedBox(height: 8),
              Text(
                'held for $seconds s',
                style: Theme.of(context).textTheme.displaySmall,
              ),
              const SizedBox(height: 4),
              Text(
                heldMs >= 10000
                    ? 'Stable — this is the M1 pass condition.'
                    : 'Keep holding; we want 10 s unbroken.',
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value, {this.warn = false});

  final String label;
  final String value;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(label, style: const TextStyle(color: Colors.black54)),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontFamily: 'monospace',
                color: warn ? Colors.orange.shade900 : null,
                fontWeight: warn ? FontWeight.bold : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      color: color.withValues(alpha: 0.12),
      child: Text(text, style: TextStyle(color: color)),
    );
  }
}
