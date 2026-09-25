import 'dart:ui';

/// A panel model: its geometry, its inks, and how a frame is chopped up to reach it.
///
/// Everything that used to be a hard-coded constant lives here, so adding a second panel is a
/// matter of adding an entry to [supported] rather than hunting through the renderer. The values
/// are all derived from one another where possible — give it the pixel dimensions and the bit
/// depth and the rest follows — because the frame maths is exactly where a typo goes unnoticed.
class PanelDevice {
  const PanelDevice({
    required this.id,
    required this.name,
    required this.pixelsPerRow,
    required this.frameRows,
    required this.bitsPerPixel,
    required this.palette,
    required this.backgroundCode,
    required this.foregroundCode,
    required this.blockSize,
    required this.nominalRefresh,
  });

  /// Stable identifier, safe to persist.
  final String id;

  /// What to call it in the UI.
  final String name;

  /// Across a row, in the panel's own orientation.
  final int pixelsPerRow;

  /// Down the frame. Row 0 is the top.
  final int frameRows;

  final int bitsPerPixel;

  /// The inks, indexed by the code written for them.
  final List<Color> palette;

  /// Sensible defaults for composing — which ink is "paper" and which is "pen".
  final int backgroundCode;
  final int foregroundCode;

  /// Bytes per data block on the wire.
  final int blockSize;

  /// Roughly how long a refresh takes, for progress reporting.
  ///
  /// Deliberately a little under the measured time: overestimate and the bar finishes early, which
  /// looks broken; underestimate and it waits at 99%, which looks like it's finishing.
  final Duration nominalRefresh;

  int get pixelsPerByte => 8 ~/ bitsPerPixel;
  int get frameBytesPerRow => pixelsPerRow ~/ pixelsPerByte;
  int get packedBytes => frameRows * frameBytesPerRow;
  int get blockCount => (packedBytes + blockSize - 1) ~/ blockSize;

  /// The frame's shape in logical pixels, for canvas work.
  Size get size => Size(pixelsPerRow.toDouble(), frameRows.toDouble());

  Color get background => palette[backgroundCode];
  Color get foreground => palette[foregroundCode];

  /// Waveshare 2.9" NFC-Powered e-Paper **(G)** — the only panel this app has been built against.
  ///
  /// Held with the long edge vertical, row 0 is at the top and bit 7 of byte 0 is the top-left
  /// pixel. Established by writing test frames and photographing the result; see
  /// `docs/protocol.md`, and note that the panel's own device info describes itself wrongly.
  static const waveshare29G = PanelDevice(
    id: 'waveshare-2.9-g',
    name: 'Waveshare 2.9" (G)',
    pixelsPerRow: 128,
    frameRows: 296,
    bitsPerPixel: 2,
    palette: [
      Color(0xFF000000), // 00 black
      Color(0xFFFFFFFF), // 01 white
      Color(0xFFFFCC00), // 10 yellow
      Color(0xFFBB3322), // 11 red
    ],
    backgroundCode: 1,
    foregroundCode: 0,
    blockSize: 250,
    nominalRefresh: Duration(milliseconds: 19000),
  );

  /// Every panel the app can drive. One, for now.
  static const supported = <PanelDevice>[waveshare29G];

  static PanelDevice byId(String id) =>
      supported.firstWhere((d) => d.id == id, orElse: () => waveshare29G);
}
