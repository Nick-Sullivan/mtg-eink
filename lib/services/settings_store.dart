import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// App settings that outlive a session, on disk as `settings.json` beside the design library.
///
/// A JSON file rather than a preferences plugin: there's one setting, the library already does it
/// this way, and it keeps the dependency list as it is.
class SettingsStore {
  /// [root] overrides where the file lives, for tests; the app gets its documents directory.
  SettingsStore({Directory? root}) : _root = root;

  final Directory? _root;

  Future<File> _file() async {
    final base = _root ?? await getApplicationDocumentsDirectory();
    return File('${base.path}/settings.json');
  }

  /// The panel last in use, as a `PanelDevice.id` — what the app opens on. Null if there's never
  /// been one but the default.
  ///
  /// Null too if the file is unreadable: a corrupt settings file should cost you the setting, not
  /// the app.
  Future<String?> lastPanelId() async {
    try {
      final file = await _file();
      if (!file.existsSync()) return null;
      final json = jsonDecode(await file.readAsString()) as Map<String, Object?>;
      return json['lastPanel'] as String?;
    } on Object {
      return null;
    }
  }

  /// Remembers [id] as the panel last in use. Never throws: callers don't wait for it, and failing
  /// to save should only cost the setting.
  Future<void> setLastPanelId(String id) async {
    try {
      final file = await _file();
      await file.writeAsString(jsonEncode({'lastPanel': id}), flush: true);
    } on Object {
      // Opening on the default panel next time is the whole of the cost.
    }
  }
}
