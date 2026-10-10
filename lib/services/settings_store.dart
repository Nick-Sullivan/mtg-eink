import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// App settings that outlive a session, on disk as `settings.json` beside the design library.
///
/// A JSON file rather than a preferences plugin: there are only a couple of settings, the library
/// already does it this way, and it keeps the dependency list as it is.
///
/// Reads never throw — a corrupt or missing file costs the settings, not the app — and writes never
/// throw either, since callers don't wait for them and failing to save should only cost the
/// setting.
class SettingsStore {
  /// [root] overrides where the file lives, for tests; the app gets its documents directory.
  SettingsStore({Directory? root}) : _root = root;

  final Directory? _root;

  Future<File> _file() async {
    final base = _root ?? await getApplicationDocumentsDirectory();
    return File('${base.path}/settings.json');
  }

  Future<Map<String, Object?>> _read() async {
    try {
      final file = await _file();
      if (!file.existsSync()) return {};
      return (jsonDecode(await file.readAsString()) as Map)
          .cast<String, Object?>();
    } on Object {
      return {};
    }
  }

  /// Changes one setting and keeps the rest.
  Future<void> _write(String key, Object? value) async {
    try {
      final settings = await _read()
        ..[key] = value;
      await (await _file()).writeAsString(jsonEncode(settings), flush: true);
    } on Object {
      // See the class comment: the setting is the whole of the cost.
    }
  }

  /// The panel last in use, as a `PanelDevice.id` — what the app opens on. Null if there's never
  /// been one but the default.
  Future<String?> lastPanelId() async =>
      (await _read())['lastPanel'] as String?;

  /// Remembers [id] as the panel last in use.
  Future<void> setLastPanelId(String id) => _write('lastPanel', id);

  /// Whether to hold the panel in the field after a write so it can be lifted away cleanly — see
  /// `PanelDevice.cleanFinishSettle`. Off unless chosen: it more than doubles a 4.2" write.
  Future<bool> cleanFinish() async =>
      (await _read())['cleanFinish'] as bool? ?? false;

  Future<void> setCleanFinish(bool on) => _write('cleanFinish', on);
}
