import 'dart:typed_data';

import 'panel_device.dart';
import 'transport.dart';

/// The command set for Waveshare's **Rev2.2** NFC-Powered e-Paper boards.
///
/// Recovered from `waveshare.feng.nfctag.activity.a.r(IsoDep, int, Bitmap)` in the vendor's
/// `NFCTag_EN.apk` (from the 4.2" wiki page), then confirmed command by command against a real
/// 4.2" panel. Full notes in `docs/protocol.md`.
///
/// This is neither the (G) protocol nor the old `0xCD`-over-NfcA one. The NFC chip here is little
/// more than a bridge: after authenticating, the phone toggles the display controller's reset line
/// and writes its registers one at a time, exactly as firmware on a wired board would. So most of
/// what follows is display-controller configuration, not NFC protocol.
class Rev22Protocol {
  /// [delay] and [clock] are for tests, which run the whole sequence without real waits.
  Rev22Protocol(
    this._channel, {
    Future<void> Function(Duration)? delay,
    DateTime Function()? clock,
  }) : _delay = delay ?? Future<void>.delayed,
       _clock = clock ?? DateTime.now;

  final PanelTransport _channel;
  final Future<void> Function(Duration) _delay;
  final DateTime Function() _clock;

  /// A fixed key; the vendor app sends the same eight bytes to every panel.
  static const authenticate = [
    0x74, 0xB1, 0x00, 0x00, 0x08, //
    0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
  ];

  /// The user password check, with an empty password. `6A00` means none is set, `6A01` accepted.
  static const emptyPassword = [0x74, 0xB3, 0x00, 0x00, 0x01, 0x00];
  static const swWrongPassword = '6A02';

  static const resetHigh = [0x74, 0x97, 0x01, 0x08, 0x00];
  static const resetLow = [0x74, 0x97, 0x00, 0x08, 0x00];

  /// First byte `01` while the controller is refreshing, `00` once it's idle.
  static const pollBusy = [0x74, 0x9B, 0x00, 0x0F, 0x01];

  /// Controller setup for a 400x300 frame, register then data, in the vendor's order.
  ///
  /// `21 48 00` inverts the black-and-white RAM on display, which is why a 1 bit is black. The
  /// `44`/`45` windows are 0..49 bytes across and 0..299 rows down; `4E`/`4F` park the address
  /// counter at the origin. A `null` is a pause the vendor app makes at that point.
  static const _setup400x300 = <(int, List<int>)?>[
    (0x21, [0x48, 0x00]),
    (0x3C, [0x05]),
    (0x1A, [0x6E]),
    (0x22, [0x91]),
    (0x20, []),
    null,
    (0x11, [0x03]),
    (0x44, [0x00, 0x31]),
    (0x45, [0x00, 0x00, 0x2B, 0x01]),
    (0x4E, [0x00]),
    (0x4F, [0x00, 0x00]),
    null,
  ];

  /// [onRefreshStarted] fires the moment a refresh is known to be running — the panel is in a
  /// good spot and should be held still.
  ///
  /// One refresh attempt only. If it doesn't run, [RefreshNotStarted]: on hardware, retrying within
  /// the same connection has never once worked — not the refresh alone, not after a controller
  /// reset, not after moving the panel to a spot that works — while lifting the panel away and
  /// putting it back has. So the retry belongs to the user, as a fresh connection.
  Future<void> writeFrame(
    PanelDevice device,
    Uint8List packed, {
    void Function(int percent)? onProgress,
    void Function()? onRefreshStarted,
  }) async {
    if (device.pixelsPerRow != 400 || device.frameRows != 300) {
      throw NfcFailure(
        'No controller setup is known for a ${device.pixelsPerRow}x${device.frameRows} '
        'Rev2.2 panel.',
      );
    }

    await _begin();
    await _resetAndSetup();
    onProgress?.call(_setupShare);
    await _sendImage(device, packed, onProgress);
    await _register(0x22, const [0xC7]);
    await _register(0x20, const []);
    if (!await _awaitRefresh(device, onProgress, onRefreshStarted)) {
      throw const RefreshNotStarted();
    }
  }

  /// Whether the panel is somewhere the field can power a refresh — asked before sending anything.
  ///
  /// A refresh with no image: it redraws whatever is already in the controller's memory, so on a
  /// panel that has kept its picture it looks like a flash of the same picture. Costs ~2.4 s,
  /// against ~5 s for the upload it saves sending to a spot that can't refresh.
  ///
  /// Nothing earlier can tell: in a weak spot the refresh runs exactly like a good one until it has
  /// drained the panel's stored energy — under a second in a very weak spot, but in one measured
  /// case past 1.1 s and gone by 1.6 s, against 1.6-1.9 s for a full refresh. So it is judged at
  /// [_probeVerdict]. Single polls don't disturb a refresh (measured); only rapid ones did.
  Future<bool> probe() async {
    await _begin();
    await _resetAndSetup();
    await _register(0x22, const [0xC7]);
    await _register(0x20, const []);
    await _delay(const Duration(milliseconds: 1000));
    if (!await _busy()) return false;
    await _delay(_probeVerdict - const Duration(milliseconds: 1000));
    final good = await _busy();
    // Let it finish either way, so the write that follows starts on an idle controller.
    for (var i = 0; i < 20 && await _busy(); i++) {
      await _delay(_pollInterval);
    }
    return good;
  }

  /// Still busy this long after the probe's refresh began means it's going to finish.
  static const _probeVerdict = Duration(milliseconds: 1450);

  Future<bool> _busy() async {
    final reply = await _channel.transceive(pollBusy);
    if (!reply.isOk || reply.body.isEmpty) {
      throw NfcFailure('Busy poll failed: ${toHex(reply)}');
    }
    return reply.body.first != 0;
  }

  /// Authenticates and checks the password, once per connection.
  Future<void> _begin() async {
    if (_begun) return;
    await _expectOk(authenticate, 'authentication');
    // Only a wrong password stops the vendor app; "none set" and "accepted" both carry on.
    final password = await _channel.transceive(emptyPassword);
    if (password.sw == swWrongPassword) {
      throw const NfcFailure(
        'The panel has a password set. Password entry is not implemented yet.',
      );
    }
    _begun = true;
  }

  var _begun = false;

  /// Pulses the controller's reset line and writes its setup registers.
  Future<void> _resetAndSetup() async {
    await _expectOk(resetHigh, 'reset');
    await _pause(50);
    await _expectOk(resetLow, 'reset');
    await _pause(50);
    await _expectOk(resetHigh, 'reset');
    await _pause(10);

    for (final step in _setup400x300) {
      if (step == null) {
        await _pause(100);
        continue;
      }
      await _register(step.$1, step.$2);
    }
  }

  Future<void> _sendImage(
    PanelDevice device,
    Uint8List packed,
    void Function(int)? onProgress,
  ) async {
    // The panel is written in fixed-size blocks; the last one is zero-padded.
    final padded = Uint8List(device.blockCount * device.blockSize)
      ..setRange(0, packed.length, packed);
    await _register(0x24, const []);
    for (var block = 0; block < device.blockCount; block++) {
      final start = block * device.blockSize;
      await _expectOk([
        0x74, 0x9A, 0x00, 0x0E, device.blockSize, //
        ...padded.sublist(start, start + device.blockSize),
      ], 'data block $block');
      onProgress?.call(
        _setupShare +
            (block + 1) * (_transferShare - _setupShare) ~/ device.blockCount,
      );
    }
  }

  /// Share of the progress bar given to setup, then to setup plus the block transfer.
  ///
  /// Measured on a 4.2": setup **0.8 s**, 60 blocks **3.2 s**, refresh **1.7 s**. Split by time,
  /// not by step count, so the bar moves steadily.
  static const int _setupShare = 14;
  static const int _transferShare = 70;

  /// Waits out the refresh. False if it never started; throws if it started and then went wrong.
  ///
  /// **Keep the radio quiet for the first second.** This is the vendor app's timing — sleep 1 s,
  /// then poll every 250 ms — and it is not a nicety. Polling every 100 ms from the moment the
  /// refresh began cut it short on hardware: busy cleared after 0.7 s instead of the usual
  /// 1.6-1.9 s, every command reported success, and the old picture stayed up. The panel runs on
  /// the phone's field, and traffic mid-refresh evidently takes something the refresh needs.
  ///
  /// But the vendor app also can't tell a finished refresh from one that never happened, and that
  /// case is real too: once, every command was accepted and busy simply never rose. So busy must be
  /// seen before idle is believed. It has always still been up at the one-second mark.
  Future<bool> _awaitRefresh(
    PanelDevice device,
    void Function(int)? onProgress,
    void Function()? onStarted,
  ) async {
    final startedAt = _clock();
    void report() {
      final elapsed = _clock().difference(startedAt).inMilliseconds;
      final fraction = elapsed / device.nominalRefresh.inMilliseconds;
      onProgress?.call(
        _transferShare +
            (fraction.clamp(0.0, 1.0) * (99 - _transferShare)).round(),
      );
    }

    // Sleeping in slices sends nothing to the panel; it only keeps the progress bar moving.
    for (
      var slice = 0;
      slice < _quietPeriod ~/ _pollInterval.inMilliseconds;
      slice++
    ) {
      await _delay(_pollInterval);
      report();
    }

    var sawBusy = false;
    while (true) {
      final elapsed = _clock().difference(startedAt);
      final reply = await _channel.transceive(pollBusy);
      if (!reply.isOk || reply.body.isEmpty) {
        throw NfcFailure('Refresh poll failed: ${toHex(reply)}');
      }

      final busy = reply.body.first != 0;
      if (busy) {
        if (!sawBusy) onStarted?.call();
        sawBusy = true;
      } else if (sawBusy) {
        onProgress?.call(100);
        return true;
      } else if (elapsed > _busyGrace) {
        return false;
      }
      if (elapsed > _refreshTimeout) {
        throw const NfcFailure('The panel never finished refreshing.');
      }

      report();
      await _delay(_pollInterval);
    }
  }

  static const _quietPeriod = 1000;
  static const _pollInterval = Duration(milliseconds: 250);

  /// How long to wait for busy to appear before concluding the refresh didn't start. Busy has
  /// always been up at the one-second mark, and lasted 1.6-1.9 s in all.
  static const _busyGrace = Duration(milliseconds: 1500);

  static const _refreshTimeout = Duration(seconds: 30);

  /// Writes one controller register: the register number, then its data if it has any.
  Future<void> _register(int register, List<int> data) async {
    final name = register.toRadixString(16).padLeft(2, '0').toUpperCase();
    await _expectOk([0x74, 0x99, 0x00, 0x0D, 0x01, register], 'register $name');
    if (data.isEmpty) return;
    await _expectOk([
      0x74, 0x9A, 0x00, 0x0E, data.length, //
      ...data,
    ], 'register $name data');
  }

  Future<void> _expectOk(List<int> apdu, String step) async {
    final reply = await _channel.transceive(apdu);
    if (!reply.isOk) throw NfcFailure('The panel refused $step: ${reply.sw}');
  }

  Future<void> _pause(int ms) => _delay(Duration(milliseconds: ms));
}
