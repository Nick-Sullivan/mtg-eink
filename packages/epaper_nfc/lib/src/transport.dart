import 'dart:typed_data';

/// Whatever carries APDUs to a panel and brings the replies back.
///
/// The protocols need nothing more than this, which keeps them pure Dart: `NfcSession` is the
/// real radio, and tests answer with a fake panel.
abstract interface class PanelTransport {
  /// Connects to the panel now in the field.
  Future<void> open();

  /// Lets the panel go. The (G) protocol closes and reopens to clear a confused panel.
  Future<void> close();

  /// Sends one APDU and returns the full response, status word included.
  Future<Uint8List> transceive(List<int> apdu);
}

/// A failure talking to the panel. Expected, not exceptional — the panel is powered by the phone's
/// field, so losing it mid-sequence is ordinary and the caller should offer a retry.
class NfcFailure implements Exception {
  const NfcFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The panel left the field mid-session. Bringing it back is the retry.
class PanelLost extends NfcFailure {
  const PanelLost(super.message);
}

/// Every command was accepted, but the refresh didn't run, so the old picture is still up. It
/// depends on where the panel sits on the phone; a fresh connection somewhere else is the cure, so
/// the app treats this as "try again", not as an error.
class RefreshNotStarted extends NfcFailure {
  const RefreshNotStarted()
    : super(
        "Couldn't find a spot where the panel would refresh. Lift it away and put it back to try "
        'again.',
      );
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
