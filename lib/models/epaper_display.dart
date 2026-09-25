import 'dart:ui';

/// The panel this app targets: Waveshare 2.9" NFC-Powered e-Paper **(G)**, 296x128, four colours.
///
/// Not the monochrome 2.9". That is a different product with a different chip and a different
/// protocol, and nothing here applies to it.
class EPaperDisplay {
  const EPaperDisplay._();

  static const int width = 296;
  static const int height = 128;

  /// The same dimensions as doubles, for canvas geometry in `const` expressions.
  static const double widthPx = 296;
  static const double heightPx = 128;

  /// The frame's true shape, established from hardware on 2026-09-25 (see `PROGRESS.md`).
  ///
  /// The panel's device info reports "592 x 128, 1 bit per pixel" and the vendor app believes it.
  /// That framing is misleading: 592 x 16 bytes is the same 9,472 bytes as **296 rows of 32 bytes**,
  /// and the ruler probe showed that what looks like two 16-byte rows is really the left and right
  /// half of one 32-byte row. So the frame is:
  ///
  /// ```
  /// 296 rows x 32 bytes   =   128 pixels per row, 2 bits per pixel, 4 pixels per byte, MSB first
  /// ```
  ///
  /// Held with the long edge vertical, row 0 is at the top and bit 7 of byte 0 is top-left.
  static const int frameRows = 296;
  static const int frameBytesPerRow = 32;
  static const int pixelsPerRow = 128;
  static const int pixelsPerByte = 4;

  /// 296 * 32.
  static const int packedBytes = 9472;

  /// `ceil((592 * 128 / 250) / 8)` — mind the integer division, see `docs/protocol.md`.
  static const int blockCount = 38;

  /// The panel is written in 250-byte blocks. See `docs/protocol.md` for the odd block-count maths.
  static const int blockSize = 250;

  static const Size size = Size(296, 128);

  /// The four colours, and the 2-bit code each one is written as.
  ///
  /// Established by writing all four codes to the panel and photographing the result, 2026-09-25.
  /// The panel's own device info claims `colourCount = 2` and only describes black and white, which
  /// is why the vendor app drives this panel as if it were monochrome.
  static const int codeBlack = 0;
  static const int codeWhite = 1;
  static const int codeYellow = 2;
  static const int codeRed = 3;

  static const Color black = Color(0xFF000000);
  static const Color white = Color(0xFFFFFFFF);
  static const Color yellow = Color(0xFFFFCC00);
  static const Color red = Color(0xFFBB3322);

  /// Indexed by 2-bit code, so `palette[codeYellow]` is the yellow the panel actually produces.
  /// These are approximations of the physical ink for on-screen preview; the panel decides the rest.
  static const List<Color> palette = [black, white, yellow, red];
}
