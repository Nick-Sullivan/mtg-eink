import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../models/saved_design.dart';
import '../models/token_content.dart';

/// The saved design library, on disk.
///
/// Layout under the app's documents directory:
///
/// ```
/// designs/
///   index.json        metadata: kind, framing settings or token fields, newest first
///   <id>.frame        9,472 rendered bytes — a cache, for thumbnails and re-sends
///   <id>.src          the original picture, as picked (images only)
/// ```
///
/// Binaries are kept as raw files rather than base64 inside the index so the index stays small and
/// quick to parse: it's read on every launch, the frames only when a thumbnail is drawn, and the
/// sources only when a design is reopened.
class DesignStore {
  /// [root] overrides where the library lives. Tests pass a temporary directory; the app doesn't
  /// pass anything and gets the platform's documents directory.
  DesignStore({Directory? root}) : _root = root;

  final Directory? _root;
  Directory? _directory;

  Future<Directory> _ensureDirectory() async {
    final existing = _directory;
    if (existing != null) return existing;

    final base = _root ?? await getApplicationDocumentsDirectory();
    final directory = Directory('${base.path}/designs');
    if (!directory.existsSync()) await directory.create(recursive: true);
    return _directory = directory;
  }

  File _indexFile(Directory directory) => File('${directory.path}/index.json');

  File _frameFile(Directory directory, String id) =>
      File('${directory.path}/$id.frame');

  File _sourceFile(Directory directory, String id) =>
      File('${directory.path}/$id.src');

  /// The original picture for a design, or null if this one predates sources being kept.
  Future<Uint8List?> readSource(String id) async {
    final file = _sourceFile(await _ensureDirectory(), id);
    return file.existsSync() ? file.readAsBytes() : null;
  }

  /// Reads the library, newest first. Returns empty rather than throwing if anything is unreadable —
  /// a corrupt index should cost you the list, not the ability to open the app.
  Future<List<SavedDesign>> load() async {
    final directory = await _ensureDirectory();
    final index = _indexFile(directory);
    if (!index.existsSync()) return const [];

    try {
      final entries = (jsonDecode(await index.readAsString()) as List)
          .cast<Map<String, Object?>>();

      final designs = <SavedDesign>[];
      for (final entry in entries) {
        final id = entry['id'] as String;
        final file = _frameFile(directory, id);
        // Index and frames drifted; skip quietly.
        if (!file.existsSync()) {
          continue;
        }

        final settings = entry['settings'] as Map<String, Object?>?;
        // Entries from before tokens existed have no kind, and are all images.
        final token = entry['kind'] == DesignKind.token.name
            ? TokenContent.fromJson(
                entry['token'] as Map<String, Object?>? ?? const {},
              )
            : null;
        designs.add(
          SavedDesign(
            id: id,
            name: entry['name'] as String? ?? 'Untitled',
            createdAt:
                DateTime.tryParse(entry['createdAt'] as String? ?? '') ??
                DateTime.now(),
            frame: await file.readAsBytes(),
            settings: settings == null
                ? null
                : ImageSettings.fromJson(settings),
            hasSource: _sourceFile(directory, id).existsSync(),
            token: token,
          ),
        );
      }
      return designs;
    } on Object {
      return const [];
    }
  }

  Future<SavedDesign> save({
    required String name,
    required Uint8List frame,
    required Uint8List source,
    required ImageSettings settings,
  }) async {
    final directory = await _ensureDirectory();
    final design = SavedDesign(
      id: _newId(),
      name: name,
      createdAt: DateTime.now(),
      frame: frame,
      settings: settings,
      hasSource: true,
    );
    await _sourceFile(directory, design.id).writeAsBytes(source, flush: true);
    return _add(directory, design);
  }

  /// Saves an MTG token. Its fields go in the index; there's no source picture.
  Future<SavedDesign> saveToken({
    required String name,
    required Uint8List frame,
    required TokenContent token,
  }) async {
    final directory = await _ensureDirectory();
    return _add(
      directory,
      SavedDesign(
        id: _newId(),
        name: name,
        createdAt: DateTime.now(),
        frame: frame,
        token: token,
      ),
    );
  }

  static String _newId() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  /// Writes [design]'s frame and puts it at the head of the index.
  Future<SavedDesign> _add(Directory directory, SavedDesign design) async {
    await _frameFile(
      directory,
      design.id,
    ).writeAsBytes(design.frame, flush: true);
    final all = await load();
    await _writeIndex(directory, [design, ...all]);
    return design;
  }

  Future<void> rename(String id, String name) async {
    final directory = await _ensureDirectory();
    final all = await load();
    await _writeIndex(directory, [
      for (final design in all)
        design.id == id ? design.copyWith(name: name) : design,
    ]);
  }

  Future<void> delete(String id) async {
    final directory = await _ensureDirectory();
    final all = await load();

    for (final file in [
      _frameFile(directory, id),
      _sourceFile(directory, id),
    ]) {
      if (file.existsSync()) await file.delete();
    }
    await _writeIndex(directory, all.where((d) => d.id != id).toList());
  }

  Future<void> _writeIndex(Directory directory, List<SavedDesign> designs) {
    return _indexFile(directory).writeAsString(
      jsonEncode([for (final design in designs) design.toJson()]),
      flush: true,
    );
  }
}
