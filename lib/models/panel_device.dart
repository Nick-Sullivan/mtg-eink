import 'dart:ui';

/// Which command set a panel speaks. The two are unrelated, despite both being ISO-DEP.
enum PanelProtocol {
  /// The (G) series: `F0 D2` data blocks, `F0 D4` refresh. See `GSeriesProtocol`.
  gSeries,

  /// Waveshare's "Rev2.2" boards: CLA `0x74` commands that drive the display controller's registers
  /// directly. See `Rev22Protocol`.
  rev22,
}

/// A panel model: its geometry, its inks, and how a frame is chopped up to reach it.
///
/// Everything that used to be a hard-coded constant lives here, so adding a second panel is a
/// matter of adding an entry to [supported] rather than hunting through the renderer. The values
/// are all derived from one another where possible — give it the pixel dimensions and the bit
/// depth and the rest follows — because the frame maths is exactly where a typo goes unnoticed.
///
/// ## Two coordinate systems
///
/// The **frame** is what goes over the air: [frameRows] rows of [pixelsPerRow] pixels, in the
/// controller's own order. The **canvas** is what everything draws on: always portrait, origin
/// top-left, [size] in logical pixels. They differ only by [frameQuarterTurns] — the frame is the
/// canvas turned that many quarter turns clockwise — and only the packer ever crosses between them.
class PanelDevice {
  const PanelDevice({
    required this.id,
    required this.name,
    required this.protocol,
    required this.pixelsPerRow,
    required this.frameRows,
    this.frameQuarterTurns = 0,
    required this.bitsPerPixel,
    required this.palette,
    required this.backgroundCode,
    required this.foregroundCode,
    required this.blockSize,
    required this.nominalRefresh,
    required this.typicalWrite,
  }) : assert(frameQuarterTurns == 0 || frameQuarterTurns == 1);

  /// Stable identifier, safe to persist.
  final String id;

  /// What to call it in the UI.
  final String name;

  final PanelProtocol protocol;

  /// Across a frame row, in the controller's own orientation.
  final int pixelsPerRow;

  /// Down the frame. Row 0 is sent first.
  final int frameRows;

  /// 0 when the frame is already portrait; 1 when it's the canvas turned a quarter turn clockwise.
  final int frameQuarterTurns;

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

  /// How long to hold the panel for a whole write, transfer and refresh, as told to the user.
  final Duration typicalWrite;

  int get pixelsPerByte => 8 ~/ bitsPerPixel;
  int get frameBytesPerRow => pixelsPerRow ~/ pixelsPerByte;
  int get packedBytes => frameRows * frameBytesPerRow;
  int get blockCount => (packedBytes + blockSize - 1) ~/ blockSize;

  int get canvasWidth => frameQuarterTurns == 0 ? pixelsPerRow : frameRows;
  int get canvasHeight => frameQuarterTurns == 0 ? frameRows : pixelsPerRow;

  /// The canvas in logical pixels, for drawing.
  Size get size => Size(canvasWidth.toDouble(), canvasHeight.toDouble());

  /// The drawing surface for a design: [size], or turned on its side when [landscape].
  ///
  /// Orientation belongs to the design, not the panel, so it's a parameter rather than a field. A
  /// landscape drawing is turned upright by the packer — see `packCodes`.
  Size canvasSizeFor({required bool landscape}) =>
      landscape ? Size(size.height, size.width) : size;

  /// Where canvas pixel ([u], [v]) lives in the frame.
  ({int x, int y}) framePoint(int u, int v) =>
      frameQuarterTurns == 0 ? (x: u, y: v) : (x: pixelsPerRow - 1 - v, y: u);

  Color get background => palette[backgroundCode];
  Color get foreground => palette[foregroundCode];

  /// Waveshare 2.9" NFC-Powered e-Paper **(G)**.
  ///
  /// Held with the long edge vertical, row 0 is at the top and bit 7 of byte 0 is the top-left
  /// pixel. Established by writing test frames and photographing the result; see
  /// `docs/protocol.md`, and note that the panel's own device info describes itself wrongly.
  static const waveshare29G = PanelDevice(
    id: 'waveshare-2.9-g',
    name: 'Waveshare 2.9" (G)',
    protocol: PanelProtocol.gSeries,
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
    typicalWrite: Duration(seconds: 25),
  );

  /// Waveshare 4.2" NFC-Powered e-Paper, **Rev2.2** — black and white, 400x300.
  ///
  /// The frame is 300 rows of 400 pixels, 1 bit each, most significant bit leftmost, and **1 is
  /// black**. Held portrait, row 0 runs down the left edge and pixel 0 of each row is at the
  /// bottom — so the frame is the portrait canvas turned a quarter turn clockwise. All of that was
  /// established by writing test frames and photographing them; see `docs/protocol.md`.
  static const waveshare42 = PanelDevice(
    id: 'waveshare-4.2-rev2.2',
    name: 'Waveshare 4.2" (Rev2.2)',
    protocol: PanelProtocol.rev22,
    pixelsPerRow: 400,
    frameRows: 300,
    frameQuarterTurns: 1,
    bitsPerPixel: 1,
    palette: [
      Color(0xFFFFFFFF), // 0 white
      Color(0xFF000000), // 1 black
    ],
    backgroundCode: 0,
    foregroundCode: 1,
    blockSize: 250,
    nominalRefresh: Duration(milliseconds: 1700),
    typicalWrite: Duration(seconds: 6),
  );

  /// Every panel the app can drive.
  static const supported = <PanelDevice>[waveshare29G, waveshare42];

  static PanelDevice byId(String id) =>
      supported.firstWhere((d) => d.id == id, orElse: () => waveshare29G);

  /// `YZRCOS` in ASCII — the card OS on Waveshare's Rev2.2 boards. The (G) panel's ATS is instead
  /// `90` followed by its UID.
  static const _rev22Ats = '59 5A 52 43 4F 53';

  /// Which panel a tag is, from its ISO-DEP historical bytes, or null if it has none.
  ///
  /// Every other radio-level property — tech list, ATQA, SAK, transceive limits — is identical
  /// between the two panels; the ATS is the only thing that tells them apart before a command is
  /// sent. Rev2.2 boards don't report their size, so `YZRCOS` means the 4.2" only because that is
  /// the only Rev2.2 panel supported.
  static PanelDevice? forAts(String? ats) {
    if (ats == null || ats.isEmpty) return null;
    return ats.toUpperCase().startsWith(_rev22Ats) ? waveshare42 : waveshare29G;
  }
}
