import 'dart:typed_data';

import '../models/panel_device.dart';
import 'apdu.dart';
import 'gseries_protocol.dart';
import 'rev22_protocol.dart';

/// Writes a packed frame to whichever kind of panel [device] is, over an already-open [channel].
///
/// The two protocols share nothing past the transport, so this is only a switch — each owns its
/// own preamble, transfer and refresh.
Future<void> writeToPanel(
  ApduChannel channel,
  PanelDevice device,
  Uint8List frame, {
  void Function(int percent)? onProgress,
  void Function()? onSpotFound,
}) async {
  switch (device.protocol) {
    case PanelProtocol.gSeries:
      final protocol = GSeriesProtocol(channel);
      await protocol.readDeviceInfoChecked();
      await protocol.writeFrame(device, frame, onProgress: onProgress);
    case PanelProtocol.rev22:
      // Check the spot can power a refresh before spending ~5 s on the upload and refresh.
      final protocol = Rev22Protocol(channel);
      if (!await protocol.probe()) throw const RefreshNotStarted();
      onSpotFound?.call();
      await protocol.writeFrame(device, frame, onProgress: onProgress);
  }
}
