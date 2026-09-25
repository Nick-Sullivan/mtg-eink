import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_eink/models/panel_device.dart';
import 'package:nfc_eink/models/saved_design.dart';
import 'package:nfc_eink/render/quantiser.dart';

import 'package:nfc_eink/services/design_store.dart';

const device = PanelDevice.waveshare29G;

Uint8List frameOf(int fill) =>
    Uint8List(device.packedBytes)..fillRange(0, device.packedBytes, fill);

Uint8List sourceOf(String marker) =>
    Uint8List.fromList(List.generate(64, (i) => marker.codeUnitAt(0) + i));

const _settings = ImageSettings(
  offset: Offset(-12.5, 40),
  scale: 2.25,
  style: DitherStyle.graphic,
);

void main() {
  late Directory root;
  late DesignStore store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('nfc_eink_test');
    store = DesignStore(root: root);
  });

  tearDown(() => root.deleteSync(recursive: true));

  Future<SavedDesign> save(String name, {int fill = 0xAB, String src = 'a'}) =>
      store.save(
        name: name,
        frame: frameOf(fill),
        source: sourceOf(src),
        settings: _settings,
      );

  test('an empty library loads as empty rather than throwing', () async {
    expect(await store.load(), isEmpty);
  });

  test('a saved design comes back with its frame intact', () async {
    await save('Hello');

    final designs = await store.load();
    expect(designs, hasLength(1));
    expect(designs.single.name, 'Hello');
    expect(designs.single.frame.length, device.packedBytes);
    expect(designs.single.frame.every((b) => b == 0xAB), isTrue);
  });

  group('the original source is what gets kept', () {
    // The library used to store only the rendered frame, so reopening a design quantised an
    // already-quantised picture — crops locked in, detail lost twice. These pin the fix.
    test('the source bytes survive a round trip', () async {
      final saved = await save('Photo', src: 'z');
      expect(await store.readSource(saved.id), sourceOf('z'));
    });

    test('the framing settings survive a round trip', () async {
      await save('Photo');
      final design = (await store.load()).single;

      expect(design.settings, isNotNull);
      expect(design.settings!.offset, const Offset(-12.5, 40));
      expect(design.settings!.scale, 2.25);
      expect(design.settings!.style, DitherStyle.graphic);
    });

    test(
      'a design with both source and settings reports itself editable',
      () async {
        await save('Photo');
        expect((await store.load()).single.isEditable, isTrue);
      },
    );

    test(
      'a design whose source is missing is not editable, but still loads',
      () async {
        final saved = await save('Legacy');
        File('${root.path}/designs/${saved.id}.src').deleteSync();

        final design = (await store.load()).single;
        expect(design.isEditable, isFalse);
        expect(design.frame.every((b) => b == 0xAB), isTrue);
        expect(await store.readSource(saved.id), isNull);
      },
    );
  });

  test('designs list newest first', () async {
    await save('First');
    await save('Second');

    final names = (await store.load()).map((d) => d.name).toList();
    expect(names, ['Second', 'First']);
  });

  test('saving twice keeps both, with distinct ids', () async {
    final a = await save('A');
    final b = await save('B');

    expect((await store.load()), hasLength(2));
    expect(a.id, isNot(b.id));
  });

  test('rename changes the name and leaves everything else alone', () async {
    final saved = await save('Before', fill: 7, src: 'q');
    await store.rename(saved.id, 'After');

    final design = (await store.load()).single;
    expect(design.name, 'After');
    expect(design.frame.every((b) => b == 7), isTrue);
    expect(design.settings!.scale, 2.25);
    expect(await store.readSource(saved.id), sourceOf('q'));
  });

  test('delete removes the design, its frame and its source', () async {
    final doomed = await save('Doomed', fill: 3);
    final survivor = await save('Keeper', fill: 4);

    await store.delete(doomed.id);

    expect((await store.load()).map((d) => d.id), [survivor.id]);
    // Both the 9.5 KB frame and the original picture should be gone, not just the index entry.
    final leftovers = root
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.contains(doomed.id));
    expect(leftovers, isEmpty);
  });

  test(
    'a design whose frame file has vanished is skipped, not fatal',
    () async {
      final ghost = await save('Ghost', fill: 5);
      await save('Real', fill: 6);

      File('${root.path}/designs/${ghost.id}.frame').deleteSync();

      expect((await store.load()).map((d) => d.name), ['Real']);
    },
  );

  test('a corrupt index loses the list, not the app', () async {
    await save('Something', fill: 9);
    File(
      '${root.path}/designs/index.json',
    ).writeAsStringSync('this is not json');

    expect(await store.load(), isEmpty);
  });
}
