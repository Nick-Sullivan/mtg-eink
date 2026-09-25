import 'package:flutter/services.dart';

/// A raw ISO-DEP channel to the panel, over the platform's reader mode.
///
/// Kotlin owns the radio because reader mode and the presence-check delay can't be set from Dart,
/// and on this hardware they are not optional — at the platform default the session dies within
/// seconds. This class is the whole of that dependency: everything above it is pure Dart.
class ApduChannel {
  static const _channel = MethodChannel('nfc_eink/epaper');

  Future<void> open() => _invoke<bool>('openSession');

  Future<void> close() => _invoke<bool>('closeSession');

  /// Sends one APDU and returns the full response, status word included.
  Future<Uint8List> transceive(List<int> apdu) async {
    final value = await _invoke<Object?>(
      'transceive',
      Uint8List.fromList(apdu),
    );
    return Uint8List.fromList((value as List).cast<int>());
  }

  Future<T> _invoke<T>(String method, [Object? args]) async {
    final reply = await _channel.invokeMapMethod<String, Object?>(method, args);
    if (reply == null) throw const NfcFailure('No reply from the platform.');
    if (reply['ok'] != true) {
      throw NfcFailure(reply['error'] as String? ?? 'Unknown NFC failure.');
    }
    return reply['value'] as T;
  }
}

/// A failure talking to the panel. Expected, not exceptional — the panel is powered by the phone's
/// field, so losing it mid-sequence is ordinary and the caller should offer a retry.
class NfcFailure implements Exception {
  const NfcFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Helpers for reading ISO 7816-4 responses.
extension ApduResponse on Uint8List {
  /// The trailing status word, e.g. `9000`.
  String get sw {
    if (length < 2) return '????';
    return toHex(sublist(length - 2));
  }

  bool get isOk => sw == '9000';

  /// The response without its status word.
  Uint8List get body => length < 2 ? Uint8List(0) : sublist(0, length - 2);
}

String toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join();

String toSpacedHex(List<int> bytes) => bytes
    .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
    .join(' ');
