import 'package:flutter/services.dart';

import 'transport.dart';

/// A raw ISO-DEP channel to the panel, over the platform's reader mode.
///
/// Kotlin owns the radio because reader mode and the presence-check delay can't be set from Dart,
/// and on this hardware they are not optional — at the platform default the session dies within
/// seconds. This class is the whole of that dependency: everything above it is pure Dart.
class NfcSession implements PanelTransport {
  static const _channel = MethodChannel('epaper_nfc/session');

  /// [tech] is `isoDep` for every panel so far, or `nfcA` for raw frames from the diagnostics
  /// console.
  @override
  Future<void> open({String tech = 'isoDep'}) =>
      _invoke<bool>('openSession', tech);

  @override
  Future<void> close() => _invoke<bool>('closeSession');

  @override
  Future<Uint8List> transceive(List<int> apdu) async {
    final value = await _invoke<Object?>(
      'transceive',
      Uint8List.fromList(apdu),
    );
    return Uint8List.fromList((value as List).cast<int>());
  }

  /// How the platform reports the panel leaving mid-session: out of range, or a handle invalidated
  /// by a re-discovery. See `onNfcThread` on the Kotlin side, which sends `ClassName: message`.
  static const _lostPrefixes = [
    'IOException',
    'TagLostException',
    'SecurityException',
  ];

  Future<T> _invoke<T>(String method, [Object? args]) async {
    final reply = await _channel.invokeMapMethod<String, Object?>(method, args);
    if (reply == null) throw const NfcFailure('No reply from the platform.');
    if (reply['ok'] != true) {
      final error = reply['error'] as String? ?? 'Unknown NFC failure.';
      throw _lostPrefixes.any(error.startsWith)
          ? PanelLost(error)
          : NfcFailure(error);
    }
    return reply['value'] as T;
  }
}
