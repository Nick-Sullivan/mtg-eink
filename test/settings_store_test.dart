import 'dart:io';

import 'package:epaper_nfc/epaper_nfc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mtg_eink/services/settings_store.dart';

void main() {
  late Directory root;
  late SettingsStore store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('mtg_eink_settings');
    store = SettingsStore(root: root);
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('nothing remembered until a panel is set', () async {
    expect(await store.lastPanelId(), isNull);
  });

  test('the last panel survives a round trip', () async {
    await store.setLastPanelId(PanelDevice.waveshare42.id);
    expect(
      await SettingsStore(root: root).lastPanelId(),
      PanelDevice.waveshare42.id,
    );
  });

  test('a corrupt settings file loses the setting, not the app', () async {
    File('${root.path}/settings.json').writeAsStringSync('not json');
    expect(await store.lastPanelId(), isNull);
    expect(await store.cleanFinish(), isFalse);
  });

  test('clean finish is off until chosen, and survives a round trip', () async {
    expect(await store.cleanFinish(), isFalse);
    await store.setCleanFinish(true);
    expect(await SettingsStore(root: root).cleanFinish(), isTrue);
  });

  test('saving one setting keeps the others', () async {
    await store.setLastPanelId(PanelDevice.waveshare42.id);
    await store.setCleanFinish(true);
    await store.setLastPanelId(PanelDevice.waveshare29G.id);

    expect(await store.cleanFinish(), isTrue);
    expect(await store.lastPanelId(), PanelDevice.waveshare29G.id);
  });

  test('a file from before clean finish existed still loads', () async {
    // Exactly what the previous build wrote.
    File(
      '${root.path}/settings.json',
    ).writeAsStringSync('{"lastPanel":"${PanelDevice.waveshare42.id}"}');
    expect(await store.lastPanelId(), PanelDevice.waveshare42.id);
    expect(await store.cleanFinish(), isFalse);
  });
}
