import 'dart:typed_data';

import 'package:epaper_nfc/epaper_nfc.dart';
import 'package:flutter_test/flutter_test.dart';

const device = PanelDevice.waveshare42;

/// Answers like the real 4.2" did on hardware: `9000` to everything, `6A00` to the password check,
/// and a busy flag that is up for [busyPolls] polls after each refresh starts — except that the
/// first [deadRefreshes] refreshes never raise it at all, as happened on hardware.
class FakePanel implements PanelTransport {
  FakePanel({
    this.busyPolls = 3,
    this.deadRefreshes = 0,
    this.refuse,
    this.clock,
  });

  final int busyPolls;
  final int deadRefreshes;

  /// The first APDU starting with these bytes gets `6A86` instead of `9000`.
  final List<int>? refuse;

  /// When given, each APDU's send time is recorded in [sentAt].
  final DateTime Function()? clock;

  final sent = <List<int>>[];
  final sentAt = <DateTime>[];
  var _polls = 0;
  var _refreshes = 0;

  /// The data last written to register 22: `C7`/`F7` make the next `20` a refresh, `91` a waveform load.
  var _mode = '';

  @override
  Future<Uint8List> transceive(List<int> apdu) async {
    sent.add(apdu);
    if (clock case final clock?) sentAt.add(clock());
    final refuse = this.refuse;
    if (refuse != null && _startsWith(apdu, refuse)) {
      return Uint8List.fromList([0x6A, 0x86]);
    }
    if (_startsWith(apdu, Rev22Protocol.emptyPassword)) {
      return Uint8List.fromList([0x6A, 0x00]);
    }
    if (hex(apdu).startsWith('74 9A 00 0E 01 ')) {
      _mode = hex(apdu).substring(15);
    }
    if ((_mode == 'C7' || _mode == 'F7') && hex(apdu) == '74 99 00 0D 01 20') {
      _refreshes++;
      _polls = 0;
    }
    if (_startsWith(apdu, Rev22Protocol.pollBusy)) {
      final dead = _refreshes <= deadRefreshes;
      final busy = !dead && _polls++ < busyPolls;
      return Uint8List.fromList([busy ? 1 : 0, 0x90, 0x00]);
    }
    return Uint8List.fromList([0x90, 0x00]);
  }

  @override
  Future<void> open() async {}

  @override
  Future<void> close() async {}

  static bool _startsWith(List<int> apdu, List<int> prefix) =>
      apdu.length >= prefix.length &&
      Iterable<int>.generate(prefix.length).every((i) => apdu[i] == prefix[i]);
}

/// A clock that only moves when the protocol sleeps, so the timing logic runs instantly.
class FakeTime {
  var now = DateTime(2026);
  Future<void> sleep(Duration d) async => now = now.add(d);
}

Rev22Protocol protocolFor(FakePanel panel, FakeTime time) =>
    Rev22Protocol(panel, delay: time.sleep, clock: () => time.now);

String hex(List<int> bytes) => bytes
    .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
    .join(' ');

/// The command sequence that drew a frame on the real panel, 2026-10-10. Pinned exactly: none of
/// it fails loudly if wrong, the panel just doesn't change.
final _expectedPreamble = [
  '74 B1 00 00 08 00 11 22 33 44 55 66 77',
  '74 B3 00 00 01 00',
  '74 97 01 08 00',
  '74 97 00 08 00',
  '74 97 01 08 00',
  '74 99 00 0D 01 21',
  '74 9A 00 0E 02 48 00',
  '74 99 00 0D 01 3C',
  '74 9A 00 0E 01 05',
  ..._waveformSetup,
  '74 99 00 0D 01 11',
  '74 9A 00 0E 01 03',
  '74 99 00 0D 01 44',
  '74 9A 00 0E 02 00 31',
  '74 99 00 0D 01 45',
  '74 9A 00 0E 04 00 00 2B 01',
  '74 99 00 0D 01 4E',
  '74 9A 00 0E 01 00',
  '74 99 00 0D 01 4F',
  '74 9A 00 0E 02 00 00',
  '74 99 00 0D 01 24',
];

/// The waveform part of the setup. The fast one is the vendor's, proven on hardware 2026-10-10.
final _waveformSetup = Rev22Protocol.fastWaveform
    ? [
        '74 99 00 0D 01 1A',
        '74 9A 00 0E 01 6E',
        '74 99 00 0D 01 22',
        '74 9A 00 0E 01 91',
        '74 99 00 0D 01 20',
      ]
    : ['74 99 00 0D 01 18', '74 9A 00 0E 01 80'];

/// What's written to register 22 to start the refresh.
final _refreshData = Rev22Protocol.fastWaveform
    ? '74 9A 00 0E 01 C7'
    : '74 9A 00 0E 01 F7';

/// Deep sleep, mode 1 — sent once the refresh has finished.
const _deepSleep = ['74 99 00 0D 01 10', '74 9A 00 0E 01 01'];

void main() {
  final frame = Uint8List.fromList(
    List.generate(device.packedBytes, (i) => i % 251),
  );

  test('sends the sequence proven on hardware, in order', () async {
    final panel = FakePanel();
    await protocolFor(panel, FakeTime()).writeFrame(device, frame);

    final commands = panel.sent.map(hex).toList();
    expect(commands.take(_expectedPreamble.length), _expectedPreamble);

    final afterData = commands.skip(_expectedPreamble.length + 60).toList();
    expect(afterData.take(3), [
      '74 99 00 0D 01 22',
      _refreshData,
      '74 99 00 0D 01 20',
    ]);
    final polls = afterData.sublist(3, afterData.length - 2);
    expect(polls, everyElement('74 9B 00 0F 01'));
    expect(afterData.skip(afterData.length - 2), _deepSleep);
  });

  test('puts the controller to sleep once the picture is up', () async {
    // Pulled away awake, white areas came up speckled; Waveshare's wired drivers end with this.
    final panel = FakePanel();
    await protocolFor(panel, FakeTime()).writeFrame(device, frame);
    final commands = panel.sent.map(hex).toList();
    expect(commands.skip(commands.length - 2), _deepSleep);
    // After the refresh has finished, never during it.
    expect(hex(panel.sent[panel.sent.length - 3]), '74 9B 00 0F 01');
  });

  group('a clean finish', () {
    // Pulled away ~3 s after busy cleared, the white turned to speckle; after ~10 s it stayed clean.
    Future<(FakePanel, FakeTime, List<(DateTime, int)>)> write(
      Duration settle,
    ) async {
      final time = FakeTime();
      final panel = FakePanel(clock: () => time.now);
      final progress = <(DateTime, int)>[];
      await protocolFor(panel, time).writeFrame(
        device,
        frame,
        onProgress: (p) => progress.add((time.now, p)),
        settle: settle,
      );
      return (panel, time, progress);
    }

    test(
      'holds the panel, quietly, for the settle before reporting done',
      () async {
        final (panel, time, progress) = await write(device.cleanFinishSettle);

        // Nothing sent after the sleep command, for the whole settle.
        expect(hex(panel.sent.last), '74 9A 00 0E 01 01');
        expect(
          time.now.difference(panel.sentAt.last),
          greaterThanOrEqualTo(device.cleanFinishSettle),
        );
        // 100 only at the very end — "done" means safe to lift.
        expect(progress.firstWhere((e) => e.$2 == 100).$1, time.now);
      },
    );

    test('keeps the progress bar moving through the settle', () async {
      final (_, _, progress) = await write(device.cleanFinishSettle);
      final values = progress.map((e) => e.$2).toList();
      expect(values, orderedEquals([...values]..sort()));
      // The settle is most of the write, so it's most of the bar — no long stall at the end.
      expect(values.where((p) => p > 50 && p < 100), isNotEmpty);
    });

    test('without one, done comes straight after the refresh', () async {
      final (panel, time, _) = await write(Duration.zero);
      expect(time.now.difference(panel.sentAt.last), Duration.zero);
    });
  });

  test('a refused sleep still counts as a finished write', () async {
    // The picture is already up; a panel pulled away that instant just misses the sleep.
    final panel = FakePanel(refuse: [0x74, 0x99, 0x00, 0x0D, 0x01, 0x10]);
    await protocolFor(panel, FakeTime()).writeFrame(device, frame);
  });

  test('no sleep when the refresh did not run', () async {
    final panel = FakePanel(deadRefreshes: 99);
    await expectLater(
      protocolFor(panel, FakeTime()).writeFrame(device, frame),
      throwsA(isA<RefreshNotStarted>()),
    );
    expect(panel.sent.map(hex), isNot(contains('74 99 00 0D 01 10')));
  });

  test(
    'sends the frame as 60 blocks of 250 bytes, in order, unaltered',
    () async {
      final panel = FakePanel();
      await protocolFor(panel, FakeTime()).writeFrame(device, frame);

      final blocks = panel.sent
          .skip(_expectedPreamble.length)
          .take(60)
          .toList();
      final rebuilt = <int>[];
      for (final block in blocks) {
        expect(block.sublist(0, 5), [0x74, 0x9A, 0x00, 0x0E, 0xFA]);
        expect(block, hasLength(255));
        rebuilt.addAll(block.sublist(5));
      }
      expect(rebuilt, frame);
    },
  );

  test('waits for busy to clear and reports 100 at the end', () async {
    final panel = FakePanel(busyPolls: 5);
    final progress = <int>[];
    await protocolFor(
      panel,
      FakeTime(),
    ).writeFrame(device, frame, onProgress: progress.add);

    final polls = panel.sent.where((a) => a[1] == 0x9B).length;
    expect(polls, 6, reason: 'five busy, then one idle');
    expect(progress.last, 100);
    expect(progress, orderedEquals([...progress]..sort()));
  });

  test('stays silent for the first second of the refresh', () async {
    // Measured on hardware: polling every 100 ms from the start cut the refresh to 0.7 s and left
    // the old picture up, with every command reporting success. The vendor's 1 s of quiet works.
    final time = FakeTime();
    final panel = FakePanel(clock: () => time.now);
    await protocolFor(panel, time).writeFrame(device, frame);

    final refreshAt =
        panel.sentAt[panel.sent.lastIndexWhere(
          (a) => hex(a) == '74 99 00 0D 01 20',
        )];
    final firstPollAt =
        panel.sentAt[panel.sent.indexWhere((a) => a[1] == 0x9B)];
    expect(
      firstPollAt.difference(refreshAt),
      greaterThanOrEqualTo(const Duration(seconds: 1)),
    );
  });

  int refreshCount(FakePanel panel) =>
      panel.sent.where((a) => hex(a) == _refreshData).length;

  test('a refresh that never goes busy is a failure, not a success', () async {
    // Seen on hardware: every command accepted, busy never raised, old picture left up.
    final panel = FakePanel(deadRefreshes: 99);
    await expectLater(
      protocolFor(panel, FakeTime()).writeFrame(device, frame),
      throwsA(isA<RefreshNotStarted>()),
    );
    // One attempt per connection: retries are the app's, as a fresh connection after a field reset.
    expect(refreshCount(panel), 1);
  });

  test('reports the moment a refresh is running, once', () async {
    // The cue to buzz and say "hold still".
    final panel = FakePanel(busyPolls: 4);
    var started = 0;
    await protocolFor(
      panel,
      FakeTime(),
    ).writeFrame(device, frame, onRefreshStarted: () => started++);
    expect(started, 1);
  });

  test('a refresh that does not run reports no start', () async {
    var started = 0;
    await expectLater(
      protocolFor(
        FakePanel(deadRefreshes: 1),
        FakeTime(),
      ).writeFrame(device, frame, onRefreshStarted: () => started++),
      throwsA(isA<RefreshNotStarted>()),
    );
    expect(started, 0);
  });

  test('a refused command stops the write and names the step', () async {
    final panel = FakePanel(refuse: [0x74, 0x9A, 0x00, 0x0E, 0xFA]);
    await expectLater(
      protocolFor(panel, FakeTime()).writeFrame(device, frame),
      throwsA(
        isA<NfcFailure>().having(
          (f) => f.message,
          'message',
          allOf(contains('data block 0'), contains('6A86')),
        ),
      ),
    );
    // Nothing after the refusal: in particular, no refresh of a half-written frame.
    expect(panel.sent.last.sublist(0, 5), [0x74, 0x9A, 0x00, 0x0E, 0xFA]);
  });

  test('refuses a panel size it has no controller setup for', () async {
    await expectLater(
      protocolFor(FakePanel(), FakeTime()).writeFrame(
        PanelDevice.waveshare29G,
        Uint8List(PanelDevice.waveshare29G.packedBytes),
      ),
      throwsA(isA<NfcFailure>()),
    );
  });

  group('the position probe', () {
    // A refresh with no image, judged 1.45 s in: measured on hardware, a weak spot's refresh runs
    // like a good one for over a second before it dies, so nothing earlier can tell them apart.
    test('a refresh that outlasts the verdict means a good spot', () async {
      final panel = FakePanel(busyPolls: 3);
      expect(await protocolFor(panel, FakeTime()).probe(), isTrue);
      expect(refreshCount(panel), 1);
      // The whole point: nothing uploaded yet.
      expect(panel.sent.where((a) => a[1] == 0x9A && a[4] == 0xFA), isEmpty);
    });

    test('lets the panel charge, quietly, before anything is sent', () async {
      // Logged 2026-10-10: a placement within 8 s of the last succeeded 14% of the time with the
      // probe ~1 s in; the write's refresh, ~4 s into the field, never failed.
      final time = FakeTime();
      final start = time.now;
      final panel = FakePanel(clock: () => time.now);
      await protocolFor(
        panel,
        time,
      ).probe(charge: PanelDevice.waveshare42.chargeTime);
      expect(
        panel.sentAt.first.difference(start),
        greaterThanOrEqualTo(PanelDevice.waveshare42.chargeTime),
      );
    });

    test('a refresh that dies partway means a bad spot', () async {
      // Busy at 1.0 s, gone by 1.45 s — the pattern seen in a spot that never drew the image.
      final panel = FakePanel(busyPolls: 1);
      expect(await protocolFor(panel, FakeTime()).probe(), isFalse);
    });

    test('a refresh that never starts means a bad spot', () async {
      final panel = FakePanel(deadRefreshes: 99);
      expect(await protocolFor(panel, FakeTime()).probe(), isFalse);
    });

    test('the write after a good probe authenticates only once', () async {
      final panel = FakePanel(busyPolls: 3);
      final protocol = protocolFor(panel, FakeTime());
      expect(await protocol.probe(), isTrue);
      await protocol.writeFrame(device, frame);

      expect(panel.sent.where((a) => a[1] == 0xB1), hasLength(1));
      expect(refreshCount(panel), 2);
      expect(
        panel.sent.where((a) => a[1] == 0x9A && a[4] == 0xFA),
        hasLength(60),
      );
    });
  });
}
