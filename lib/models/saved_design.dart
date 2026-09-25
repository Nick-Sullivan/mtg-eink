import 'dart:typed_data';
import 'dart:ui';

import '../render/quantiser.dart';

/// How an image was framed and converted, kept so a saved design can be reopened and adjusted.
class ImageSettings {
  const ImageSettings({
    required this.offset,
    required this.scale,
    required this.style,
  });

  final Offset offset;
  final double scale;
  final DitherStyle style;

  Map<String, Object?> toJson() => {
    'dx': offset.dx,
    'dy': offset.dy,
    'scale': scale,
    'style': style.name,
  };

  factory ImageSettings.fromJson(Map<String, Object?> json) => ImageSettings(
    offset: Offset(
      (json['dx'] as num?)?.toDouble() ?? 0,
      (json['dy'] as num?)?.toDouble() ?? 0,
    ),
    scale: (json['scale'] as num?)?.toDouble() ?? 1,
    style: DitherStyle.values.firstWhere(
      (s) => s.name == json['style'],
      orElse: () => DitherStyle.photo,
    ),
  );
}

/// A saved image design.
///
/// What's stored is the **original picture plus how it was framed** — not the rendered frame. An
/// earlier version saved only the 9,472-byte panel frame, which made reopening a design quantise an
/// already-quantised image: crops locked in, detail lost a second time, and no way to adjust
/// anything. The source is the thing worth keeping; the frame is derived from it.
///
/// [frame] is still held, but only as a cache: it makes list thumbnails instant and lets a re-send
/// skip re-rendering. It is always reproducible from the source and settings.
class SavedDesign {
  const SavedDesign({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.frame,
    this.settings,
    this.hasSource = false,
  });

  final String id;
  final String name;
  final DateTime createdAt;

  /// The device's packed ink codes, ready for `GSeriesProtocol.writeFrame`.
  final Uint8List frame;

  /// How the source was framed. Null for designs saved before sources were kept.
  final ImageSettings? settings;

  /// Whether the original picture is on disk alongside. Read it with `DesignStore.readSource`.
  final bool hasSource;

  /// Whether reopening this design can restore the original picture, or only the flattened frame.
  bool get isEditable => hasSource && settings != null;

  SavedDesign copyWith({String? name}) => SavedDesign(
    id: id,
    name: name ?? this.name,
    createdAt: createdAt,
    frame: frame,
    settings: settings,
    hasSource: hasSource,
  );

  /// Metadata only — the frame and the source live in their own files alongside.
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'createdAt': createdAt.toIso8601String(),
    'hasSource': hasSource,
    if (settings != null) 'settings': settings!.toJson(),
  };
}
