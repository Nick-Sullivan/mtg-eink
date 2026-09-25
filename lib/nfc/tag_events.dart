import 'package:flutter/services.dart';

/// Mirrors the payloads emitted by `MainActivity.kt` over `nfc_eink/tag_events`.
sealed class TagEvent {
  const TagEvent();

  factory TagEvent.fromMap(Map<Object?, Object?> map) {
    return switch (map['type']) {
      'adapter' => AdapterState(
        present: map['present'] as bool? ?? false,
        enabled: map['enabled'] as bool? ?? false,
      ),
      'detected' => TagDetected(
        uid: map['uid'] as String? ?? '',
        techs: (map['techs'] as List<Object?>? ?? const [])
            .map((t) => t.toString())
            .toList(growable: false),
        discoveryCount: map['discoveryCount'] as int? ?? 0,
        atqa: map['atqa'] as String?,
        sak: map['sak'] as int?,
        maxTransceiveLength: map['maxTransceiveLength'] as int?,
      ),
      'held' => TagHeld(heldMs: map['heldMs'] as int? ?? 0),
      _ => TagLost(
        reason: map['reason'] as String? ?? 'unknown',
        heldMs: map['heldMs'] as int? ?? 0,
      ),
    };
  }
}

class AdapterState extends TagEvent {
  const AdapterState({required this.present, required this.enabled});

  final bool present;
  final bool enabled;
}

class TagDetected extends TagEvent {
  const TagDetected({
    required this.uid,
    required this.techs,
    required this.discoveryCount,
    this.atqa,
    this.sak,
    this.maxTransceiveLength,
  });

  final String uid;
  final List<String> techs;

  /// Rises every time the tag is re-acquired. While the user holds still, any rise is a dropout.
  final int discoveryCount;
  final String? atqa;
  final int? sak;
  final int? maxTransceiveLength;
}

class TagHeld extends TagEvent {
  const TagHeld({required this.heldMs});

  final int heldMs;
}

class TagLost extends TagEvent {
  const TagLost({required this.reason, required this.heldMs});

  final String reason;
  final int heldMs;
}

const _channel = EventChannel('nfc_eink/tag_events');

Stream<TagEvent> tagEvents() => _channel.receiveBroadcastStream().map(
  (event) => TagEvent.fromMap(event as Map<Object?, Object?>),
);
