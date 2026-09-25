import 'package:flutter/material.dart';

import '../models/epaper_display.dart';
import '../nfc/apdu.dart';
import '../nfc/gseries_protocol.dart';
import '../nfc/tag_events.dart';
import '../render/canvas_painter.dart';

/// Compose something and push it to the panel.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _channel = ApduChannel();
  late final _protocol = GSeriesProtocol(_channel);
  final _textController = TextEditingController(text: 'HELLO');

  TagDetected? _tag;
  TagLost? _lost;
  AdapterState? _adapter;

  PanelContent _content = const PanelContent(text: 'HELLO');

  bool _writing = false;
  int _percent = 0;
  String? _status;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    tagEvents().listen(_onEvent);
    _textController.addListener(
      () => setState(() => _content = _content.copyWith(text: _textController.text)),
    );
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  void _onEvent(TagEvent event) {
    setState(() {
      switch (event) {
        case AdapterState():
          _adapter = event;
        case TagDetected():
          _tag = event;
          _lost = null;
        case TagLost():
          _lost = event;
        case TagHeld():
        case WriteProgress():
          break;
      }
    });
  }

  Future<void> _write() async {
    setState(() {
      _writing = true;
      _percent = 0;
      _status = null;
      _failed = false;
    });

    // Rendering happens before the session opens: the panel is powered by the phone's field, so
    // there is no reason to hold it open while we lay out text.
    final frame = await renderFrame(_content);

    String status;
    var failed = false;
    try {
      await _channel.open();
      await _protocol.readDeviceInfoChecked();
      await _protocol.writeFrame(
        frame,
        onProgress: (p) {
          if (mounted) setState(() => _percent = p);
        },
      );
      status = 'Done. The image stays on the panel now, even off the phone.';
    } on NfcFailure catch (e) {
      status = e.message;
      failed = true;
    } finally {
      try {
        await _channel.close();
      } on NfcFailure {
        // The write's own outcome matters more than failing to hand the tag back.
      }
    }

    if (!mounted) return;
    setState(() {
      _writing = false;
      _status = status;
      _failed = failed;
    });
  }

  @override
  Widget build(BuildContext context) {
    final present = _tag != null && _lost == null;
    final adapter = _adapter;

    return Scaffold(
      appBar: AppBar(title: const Text('nfc-eink')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (adapter != null && !adapter.enabled)
            const _Banner('NFC is off. Turn it on in Settings.', Colors.red),

          // The panel is tall and narrow, so cap the preview's height rather than letting it eat
          // the screen.
          Center(
            child: SizedBox(
              height: 280,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.black26),
                ),
                child: PanelPreview(content: _content),
              ),
            ),
          ),
          const SizedBox(height: 20),

          TextField(
            controller: _textController,
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
                  value: _content.fontSize,
                  min: 10,
                  max: 64,
                  divisions: 54,
                  label: _content.fontSize.round().toString(),
                  onChanged: (v) =>
                      setState(() => _content = _content.copyWith(fontSize: v)),
                ),
              ),
            ],
          ),

          _ColourRow(
            label: 'Text',
            selected: _content.textColor,
            onPick: (c) => setState(() => _content = _content.copyWith(textColor: c)),
          ),
          _ColourRow(
            label: 'Background',
            selected: _content.background,
            onPick: (c) => setState(() => _content = _content.copyWith(background: c)),
          ),
          _ColourRow(
            label: 'Border',
            selected: _content.borderColor,
            onPick: (c) => setState(() => _content = _content.copyWith(borderColor: c)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Draw border'),
            value: _content.border,
            onChanged: (v) => setState(() => _content = _content.copyWith(border: v)),
          ),

          const Divider(height: 24),

          FilledButton.icon(
            onPressed: present && !_writing ? _write : null,
            icon: const Icon(Icons.nfc),
            label: Text(
              _writing
                  ? 'Writing…'
                  : present
                  ? 'Write to panel'
                  : 'Hold the panel to the phone',
            ),
          ),

          if (_writing) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(value: _percent / 100),
            const SizedBox(height: 8),
            Text('$_percent%', textAlign: TextAlign.center),
            const SizedBox(height: 8),
            const Text(
              'Hold still — about 25 seconds.\n'
              'A small gap works better than pressing flat.',
              textAlign: TextAlign.center,
              style: TextStyle(fontStyle: FontStyle.italic),
            ),
          ],

          if (_status case final status?) ...[
            const SizedBox(height: 12),
            _Banner(status, _failed ? Colors.red : Colors.green),
            if (_failed && present) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _writing ? null : _write,
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// The four colours the panel can actually show.
class _ColourRow extends StatelessWidget {
  const _ColourRow({
    required this.label,
    required this.selected,
    required this.onPick,
  });

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
          for (final colour in EPaperDisplay.palette)
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

class _Banner extends StatelessWidget {
  const _Banner(this.text, this.color);

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.all(12),
      color: color.withValues(alpha: 0.12),
      child: Text(text, style: TextStyle(color: color)),
    );
  }
}
