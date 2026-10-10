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
  });
}
