import 'package:flutter/services.dart';

/// Firm buzzes from the phone's vibrator: one for a bad spot, two for a finished write.
///
/// Through the vibrator directly rather than Flutter's `HapticFeedback`, which fires the system's
/// 50 ms touch tick — on a Pixel 10a, too faint to notice mid-write. Handled in `MainActivity.kt`.
class Haptics {
  static const _channel = MethodChannel('mtg_eink/haptics');

  /// [pulses] short buzzes. Never throws: a missed buzz isn't worth interrupting anything for.
  Future<void> buzz({int pulses = 1}) async {
    try {
      await _channel.invokeMethod<void>('buzz', pulses);
    } on Object {
      // No vibrator, or no handler; the write's own outcome is shown on screen regardless.
    }
  }
}
