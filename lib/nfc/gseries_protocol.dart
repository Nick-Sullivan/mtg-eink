import 'dart:typed_data';

import '../models/epaper_display.dart';
import 'apdu.dart';

/// The command set for the Waveshare NFC-Powered e-Paper **(G)** series.
///
/// Recovered from `IsoDepUtils.java` in the vendor APK (`com.waveshera.epaper`, 2025-11-06), which
/// ships unobfuscated. Full notes in `docs/protocol.md`.
///
/// Note this is *not* the protocol in Waveshare's published `NFC.jar` — that one drives the older
/// mono and three-colour panels with raw `0xCD` frames over NfcA, and this hardware answers `6700`
/// to all of it.
class GSeriesProtocol {
  const GSeriesProtocol(this._channel);

  final ApduChannel _channel;

  /// Select the NDEF application. Sent with no `Le` byte, exactly as the vendor app does.
  static const selectNdefApp = [
    0x00, 0xA4, 0x04, 0x00, 0x07, //
    0xD2, 0x76, 0x00, 0x00, 0x85, 0x01, 0x01,
  ];

  static const unlock = [0xF0, 0xD8, 0x01, 0xFE, 0x05, 0, 0, 0, 0, 0];

  /// `F0 D4 05 <plane|0x80> 00` — begin the refresh once all blocks are in.
  static const startRefresh = [0xF0, 0xD4, 0x05, 0x80, 0x00];

  /// The same command with P1 `0x85`. Sent when [startRefresh] answers busy — see [_refresh].
  static const startRefreshBusy = [0xF0, 0xD4, 0x85, 0x80, 0x00];

  /// Busy, in the panel's two dialects. Not an error: retry with [startRefreshBusy].
  static const swBusy = {'6986', '68C6'};

  /// `F0 DE 00 00 01` — poll until the panel says it has finished.
  static const pollRefresh = [0xF0, 0xDE, 0x00, 0x00, 0x01];

  static const deviceInfo1 = [0x00, 0xD1, 0x00, 0x00, 0x00];
  static const deviceInfo2 = [0xF0, 0xD8, 0x00, 0x00, 0x05, 0, 0, 0, 0, 0x0E];

  /// Returned by [deviceInfo2] when the panel has a PIN set.
  static const swPinRequired = '6985';

  /// Opens a session and reads the panel's identity.
  ///
  /// The select and unlock replies are **deliberately not checked**. The vendor app logs both and
  /// ignores them, and on our panel the unlock answers `6A86` ("incorrect P1-P2") yet the sequence
  /// works anyway. Treating either as a failure invents a requirement the protocol doesn't have.
  /// Their status words are reported for information instead.
  Future<DeviceInfoRaw> readDeviceInfo() async {
    final select = await _channel.transceive(selectNdefApp);
    final unlocked = await _channel.transceive(unlock);

    final first = await _channel.transceive(deviceInfo1);
    final second = await _channel.transceive(deviceInfo2);

    if (second.sw == swPinRequired) {
      throw const NfcFailure(
        'The panel has a PIN set (6985). PIN handling is not implemented yet.',
      );
    }
    return DeviceInfoRaw(
      first: first,
      second: second,
      selectSw: select.sw,
      unlockSw: unlocked.sw,
    );
  }

  /// Reads device info, rejecting the garbage the panel sometimes returns, and retrying.
  ///
  /// Observed on hardware: the panel occasionally answers the preamble with a well-formed but
  /// nonsense block — dimensions of 52032, zeroed capacities, a missing appID — and then refuses
  /// the first data block with `6A86`. Writing 38 blocks into that state just wastes 20 seconds,
  /// so check the panel is talking sense before trusting it.
  Future<DeviceInfoRaw> readDeviceInfoChecked({int attempts = 4}) async {
    DeviceInfoRaw? last;
    for (var attempt = 0; attempt < attempts; attempt++) {
      if (attempt > 0) {
        // Drop the session entirely and start again — the bad state survives a re-read.
        await _channel.close();
        await Future<void>.delayed(const Duration(milliseconds: 400));
        await _channel.open();
      }
      last = await readDeviceInfo();
      if (last.looksSane) return last;
    }
    throw NfcFailure(
      'The panel is not answering sensibly (got ${last?.dimensionsDebug}). '
      'Lift the phone away for a few seconds and try again.',
    );
  }
}

/// Sends a packed frame and refreshes the panel.
///
/// [onProgress] is called with 0-100. A refresh takes ~16 s on top of the transfer, so the UI
/// needs this; a silent 20-second pause reads as a hang.
extension GSeriesWrite on GSeriesProtocol {
  Future<void> writeFrame(
    Uint8List packed, {
    void Function(int percent)? onProgress,
  }) async {
    // The panel is written in fixed 250-byte blocks; the last one is zero-padded.
    final padded = Uint8List(EPaperDisplay.blockCount * EPaperDisplay.blockSize)
      ..setRange(0, packed.length, packed);

    for (var block = 0; block < EPaperDisplay.blockCount; block++) {
      final start = block * EPaperDisplay.blockSize;
      final apdu = <int>[
        0xF0, 0xD2,
        0x00, // plane — only one on this panel
        block,
        0xFA, // Lc = 250
        ...padded.sublist(start, start + EPaperDisplay.blockSize),
      ];

      final response = await _channel.transceive(apdu);
      if (!response.isOk) {
        throw NfcFailure('Block $block refused: ${response.sw}');
      }
      onProgress?.call((block + 1) * _transferShare ~/ EPaperDisplay.blockCount);
    }

    await _refresh(onProgress);
  }

  /// Share of the progress bar given to the block transfer.
  ///
  /// Measured on hardware: 38 blocks take **1.6 s**, the refresh takes **21.4 s**. Splitting the
  /// bar by steps rather than by time makes it race to 80% and then appear to hang, so it is split
  /// by how long each phase actually takes.
  static const int _transferShare = 8;

  /// How long a full refresh takes, measured end to end on the 2.9" (G).
  static const _nominalRefresh = Duration(milliseconds: 21400);

  Future<void> _refresh(void Function(int)? onProgress) async {
    onProgress?.call(_transferShare);
    final started = await _channel.transceive(GSeriesProtocol.startRefresh);
    final startedHex = toHex(started);

    if (startedHex == '019000') {
      // Some panels report the whole refresh done in one step and never need polling.
      onProgress?.call(100);
      return;
    }
    if (started.sw == '698A') {
      throw const NfcFailure('The panel refused the refresh (698A).');
    }

    if (GSeriesProtocol.swBusy.contains(started.sw)) {
      // Busy is not a failure: the panel wants the same command with P1 0x85 instead of 0x05.
      // The vendor app retries five times, 100 ms apart, then polls as usual.
      var accepted = false;
      for (var attempt = 0; attempt < 5 && !accepted; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final retry = await _channel.transceive(GSeriesProtocol.startRefreshBusy);
        final hex = toHex(retry);
        accepted = hex == '009000' || hex == '9000';
      }
      if (!accepted) {
        throw const NfcFailure(
          'The panel stayed busy after five retries. Lift the phone and try again.',
        );
      }
    } else if (started.sw != '9000') {
      throw NfcFailure('Refresh not accepted: ${started.sw}');
    }

    // `019000` means still working, `009000` means done. The vendor app polls up to 1000 times at
    // 100 ms, which is ~100 s of headroom for a ~21 s refresh.
    //
    // Progress during the refresh is driven by elapsed time against [_nominalRefresh], not by the
    // poll count — polls come back at whatever rate the panel answers, so counting them makes the
    // bar lurch. It creeps towards 99 and only reaches 100 when the panel actually says so, so a
    // slower-than-usual refresh looks slow rather than looking finished.
    final startedAt = DateTime.now();
    for (var attempt = 0; attempt < 1000; attempt++) {
      final response = await _channel.transceive(GSeriesProtocol.pollRefresh);
      final hex = toHex(response);
      if (hex == '009000') {
        onProgress?.call(100);
        return;
      }
      if (hex != '019000') {
        throw NfcFailure('Refresh failed: $hex');
      }

      final elapsed = DateTime.now().difference(startedAt).inMilliseconds;
      final fraction = elapsed / _nominalRefresh.inMilliseconds;
      final span = 99 - _transferShare;
      onProgress?.call(
        _transferShare + (fraction.clamp(0.0, 1.0) * span).round(),
      );

      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw const NfcFailure('The panel never finished refreshing.');
  }
}

/// The two device-info responses, unparsed.
///
/// The vendor app concatenates these as hex and looks the result up against a table of known
/// panels to get width, height, colour count and the 2-bit code for each colour. We keep the raw
/// bytes until we've confirmed our reading of that format against real hardware — guessing at a
/// layout and then packing 9,472 bytes against it would fail in ways that are hard to attribute.
class DeviceInfoRaw {
  const DeviceInfoRaw({
    required this.first,
    required this.second,
    required this.selectSw,
    required this.unlockSw,
  });

  final List<int> first;
  final List<int> second;

  /// Reported, not enforced. See [GSeriesProtocol.readDeviceInfo].
  final String selectSw;
  final String unlockSw;

  String get combinedHex => '${toHex(first)}${toHex(second)}';

  /// The two dimension fields from the `A0` block, at bytes 5-6 and 7-8.
  int? get reportedLong => _word(5);
  int? get reportedShort => _word(7);

  int? _word(int offset) {
    if (first.length < offset + 2) return null;
    return (first[offset] << 8) | first[offset + 1];
  }

  String get dimensionsDebug => '${reportedLong ?? '?'} x ${reportedShort ?? '?'}';

  /// Whether the panel is answering sensibly at all.
  ///
  /// The failure mode this catches is not a malformed reply — the TLV framing stays intact — but a
  /// plausible-looking block full of nonsense. Bounding the dimensions is what separates them:
  /// a good read gives 592 x 128, a bad one gave 52032 x 217.
  bool get looksSane {
    if (first.isEmpty || first[0] != 0xA0) return false;
    final long = reportedLong;
    final short = reportedShort;
    if (long == null || short == null) return false;
    return long >= 8 && long <= 4096 && short >= 8 && short <= 4096;
  }

  @override
  String toString() =>
      'select: $selectSw   unlock: $unlockSw\n'
      'info1: ${toSpacedHex(first)}\n'
      'info2: ${toSpacedHex(second)}';
}
