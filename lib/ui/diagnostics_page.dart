import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../nfc/apdu.dart';
import '../nfc/probe_script.dart';
import '../nfc/tag_events.dart';

/// Runs a hand-written command script against whatever panel is on the phone.
///
/// The instrument for working out an unknown panel by trial and error. The script is a text file,
/// `probe.txt`, pushed to the app's files directory with `adb`, so each experiment is an edit and a
/// push rather than a rebuild. Every exchange is also logged to `adb logcat -s mtgeink` by the
/// Kotlin side, so results can be read off the device without anyone transcribing hex.
class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({super.key});

  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  final _channel = ApduChannel();
  final _log = <String>[];
  StreamSubscription<TagEvent>? _events;

  String? _source;
  String? _path;
  bool _armed = false;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _events = tagEvents().listen(_onTagEvent);
    _load();
  }

  @override
  void dispose() {
    _events?.cancel();
    super.dispose();
  }

  /// Looks in external app storage first (plain `adb push`), then internal (`adb shell run-as`).
  Future<void> _load() async {
    final dirs = [
      await getExternalStorageDirectory(),
      await getApplicationDocumentsDirectory(),
    ];
    for (final dir in dirs.whereType<Directory>()) {
      final file = File('${dir.path}/probe.txt');
      if (await file.exists()) {
        final text = await file.readAsString();
        setState(() {
          _source = text;
          _path = file.path;
        });
        return;
      }
    }
    setState(() {
      _source = null;
      _path = dirs
          .whereType<Directory>()
          .map((d) => '${d.path}/probe.txt')
          .join('\nor ');
    });
  }

  void _onTagEvent(TagEvent event) {
    if (event is TagDetected) {
      _add('panel ${event.uid}  ats ${event.ats}');
      if (_armed && !_running) _run();
    }
  }

  void _add(String line) {
    if (!mounted) return;
    setState(() => _log.add(line));
  }

  Future<void> _run() async {
    final source = _source;
    if (source == null || _running) return;

    final ProbeScript script;
    try {
      script = ProbeScript.parse(source);
    } on FormatException catch (e) {
      _add('script error: ${e.message}');
      return;
    }

    setState(() {
      _running = true;
      _armed = false;
    });
    _add('--- run (${script.tech}, ${script.steps.length} steps)');
    final started = DateTime.now();

    try {
      await _channel.open(tech: script.tech);
    } on NfcFailure catch (e) {
      // Most likely no panel yet: wait for one rather than making you tap again.
      _add('open failed: ${e.message} — waiting for a panel');
      setState(() {
        _running = false;
        _armed = true;
      });
      return;
    }

    var last = '';
    try {
      for (final step in script.steps) {
        switch (step) {
          case DelayStep(:final duration):
            await Future<void>.delayed(duration);
          case StopUnlessStep(:final suffix):
            if (!last.endsWith(suffix)) {
              _add('stopped: last reply did not end $suffix');
              return;
            }
          case SendStep(:final bytes):
            final shown = bytes.length > 24
                ? '${toSpacedHex(bytes.sublist(0, 8))} … (${bytes.length} bytes)'
                : toSpacedHex(bytes);
            _add('>> $shown');
            final reply = await _channel.transceive(bytes);
            last = toHex(reply);
            _add('<< ${toSpacedHex(reply)}');
        }
      }
    } on NfcFailure catch (e) {
      _add('!! ${e.message}');
    } finally {
      try {
        await _channel.close();
      } on NfcFailure {
        // The run's own outcome is what matters.
      }
      final ms = DateTime.now().difference(started).inMilliseconds;
      _add('--- done in $ms ms');
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnostics'),
        actions: [
          IconButton(
            tooltip: 'Reload probe.txt',
            onPressed: _running ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Clear log',
            onPressed: () => setState(_log.clear),
            icon: const Icon(Icons.clear_all),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _source == null ? 'No script. Expected at:\n$_path' : _path ?? '',
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _source == null || _running
                  ? null
                  : () => _armed ? setState(() => _armed = false) : _run(),
              icon: Icon(_armed ? Icons.close : Icons.play_arrow),
              label: Text(
                _running
                    ? 'Running…'
                    : _armed
                    ? 'Waiting for panel — tap to cancel'
                    : 'Run',
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.black26),
                ),
                child: ListView.builder(
                  padding: const EdgeInsets.all(8),
                  itemCount: _log.length,
                  itemBuilder: (_, i) => Text(
                    _log[i],
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
