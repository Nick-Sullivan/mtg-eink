import 'dart:typed_data';

import 'gseries_protocol.dart';
import 'panel_device.dart';
import 'rev22_protocol.dart';
import 'transport.dart';

/// Writes a packed frame to whichever kind of panel [device] is, over an already-open [channel].
///
/// The two protocols share nothing past the transport, so this is only a switch — each owns its
/// own preamble, transfer and refresh.
///
/// [cleanFinish] holds the panel in the field for [PanelDevice.cleanFinishSettle] after the refresh,
/// so it can be lifted away without its white areas fading. Ignored by panels that don't need it.
///
/// [inFieldSince] is when the panel arrived on the phone. A panel needs [PanelDevice.chargeTime]
/// in the field before its first refresh; whatever of that hasn't passed yet is waited out first.
/// Null means it has only just arrived.
Future<void> writeToPanel(
  PanelTransport channel,
  PanelDevice device,
  Uint8List frame, {
  void Function(int percent)? onProgress,
  void Function()? onSpotFound,
  bool cleanFinish = false,
  DateTime? inFieldSince,
}) async {
  switch (device.protocol) {
    case PanelProtocol.gSeries:
      final protocol = GSeriesProtocol(channel);
      await protocol.readDeviceInfoChecked();
      await protocol.writeFrame(device, frame, onProgress: onProgress);
    case PanelProtocol.rev22:
      final protocol = Rev22Protocol(channel);
      // Check the spot can power a refresh before spending ~5 s on the upload and refresh.
      final inField = inFieldSince == null
          ? Duration.zero
          : DateTime.now().difference(inFieldSince);
      final charge = device.chargeTime - inField;
      if (_rev22SpotCheck &&
          !await protocol.probe(
            charge: charge.isNegative ? Duration.zero : charge,
          )) {
        throw const RefreshNotStarted();
      }
      onSpotFound?.call();
      await protocol.writeFrame(
        device,
        frame,
        onProgress: onProgress,
        settle: cleanFinish ? device.cleanFinishSettle : Duration.zero,
      );
  }
}

/// The spot check is a whole extra refresh before every write. Turned off on 2026-10-10 to see
/// whether that double refresh caused the speckle white areas get when the panel is pulled away
/// soon after a write: it didn't, and without it a bad spot only shows after the whole upload. On.
const _rev22SpotCheck = true;
