import 'dart:math' as math;
import 'dart:typed_data';

import '../models/panel_device.dart';

/// How to map full-colour pixels onto a panel's inks.
enum DitherStyle {
  /// Flat nearest-colour. Correct for text, logos and flat art — no dithering noise, every pixel
  /// lands on one ink.
  graphic,

  /// Error-diffused. Correct for photographs.
  photo,
}

/// One ink, in Oklab.
class _Ink {
  const _Ink(this.code, this.l, this.a, this.b);

  final int code;
  final double l;
  final double a;
  final double b;

  double get chroma => math.sqrt(a * a + b * b);
  double get hue => math.atan2(b, a);
}

/// Maps images onto a panel's palette.
///
/// ## The trap this is built around
///
/// For the four-colour panel the obvious approach — nearest palette colour per pixel — fails badly,
/// and not in the way you'd expect. The problem isn't the missing green and blue; it's **red**. Red
/// sits at Oklab lightness 0.53, almost exactly the neutral midpoint, so a plain distance metric
/// makes a mid-grey *closer to red than to either black or white*. An overcast sky comes out pink.
/// Switching from RGB to a perceptual space does not help: in Oklab a neutral mid-grey is about
/// eight times closer to red than to the neutrals.
///
/// Two things fix it, and both are load-bearing:
///
/// 1. **Chroma error is weighted [_chromaWeight] times lightness error** when choosing an ink, so
///    a colourless pixel can only pick a colourless ink.
/// 2. **A hue gate** pulls colours outside the palette's reachable hues toward neutral before
///    matching. This palette spans roughly 31°-90°; *no* mixture of its inks makes a cool hue, at
///    any resolution. So a blue sky has to become grey. Left ungated, its error can never be
///    discharged and error diffusion smears it into red.
///
/// What's left after gating is a warm duotone — and the palette is genuinely good at warm subjects,
/// since skin, wood, brick and sunsets all fall inside the reachable range.
///
/// Nothing here is specific to that panel: the inks come from [PanelDevice.palette] and the gate
/// from whatever hues they happen to span, so a different palette re-derives itself.
class Quantiser {
  const Quantiser._();

  /// How much more a chroma error costs than a lightness error of the same size.
  ///
  /// **Not a taste knob.** Red's lightness is so close to neutral mid-grey that red wins against
  /// black and white for any weight below about 8.1. Below that, every grey sky goes pink.
  ///
  /// 9.0 is the bare break-even and it is *not* enough: at that weight a pure neutral only beats
  /// red by 0.25 to 0.279, so a pixel carrying even 2% residual chroma — a desaturated green, say —
  /// tips back to red. Shadowed foliage came out 5% red speckle. 12.0 restores a real margin.
  ///
  /// If a panel's ink colours are ever recalibrated against a photograph, this needs re-deriving.
  /// `quantiser_test.dart` pins the behaviour it protects.
  static const double _chromaWeight = 12.0;

  static final _inkCache = <String, List<_Ink>>{};

  /// The device's inks in Oklab, derived from its palette rather than hardcoded so the two cannot
  /// drift apart. Cached because the conversion involves cube roots and the palette never changes.
  static List<_Ink> _inksFor(PanelDevice device) {
    return _inkCache.putIfAbsent(device.id, () {
      return [
        for (var code = 0; code < device.palette.length; code++)
          () {
            final colour = device.palette[code];
            final lab = _rgbToOklab(
              (colour.r * 255).round(),
              (colour.g * 255).round(),
              (colour.b * 255).round(),
            );
            return _Ink(code, lab[0], lab[1], lab[2]);
          }(),
      ];
    });
  }

  /// Converts an RGBA buffer of the device's frame size into a packed frame.
  static Uint8List quantiseToFrame(
    PanelDevice device,
    Uint8List rgba,
    DitherStyle style,
  ) {
    final width = device.pixelsPerRow;
    final height = device.frameRows;
    final count = width * height;

    final l = Float32List(count);
    final a = Float32List(count);
    final b = Float32List(count);

    for (var p = 0; p < count; p++) {
      final i = p * 4;
      final lab = _rgbToOklab(rgba[i], rgba[i + 1], rgba[i + 2]);
      l[p] = lab[0];
      a[p] = lab[1];
      b[p] = lab[2];
    }

    final inks = _inksFor(device);
    if (style == DitherStyle.photo) _autoLevels(l);
    _gateChroma(inks, a, b);

    return style == DitherStyle.photo
        ? _diffuse(device, inks, l, a, b)
        : _flat(device, inks, l, a, b);
  }

  static Uint8List _flat(
    PanelDevice device,
    List<_Ink> inks,
    Float32List l,
    Float32List a,
    Float32List b,
  ) {
    final frame = Uint8List(device.packedBytes);
    for (var y = 0; y < device.frameRows; y++) {
      for (var x = 0; x < device.pixelsPerRow; x++) {
        final p = y * device.pixelsPerRow + x;
        setPixel(device, frame, x, y, _nearestInk(inks, l[p], a[p], b[p]).code);
      }
    }
    return frame;
  }

  /// Atkinson error diffusion, serpentine.
  ///
  /// Atkinson propagates only six eighths of each pixel's error and discards the rest. On a normal
  /// palette that's a stylistic choice; here it's a necessity. With four widely spaced levels, a
  /// single pixel's error can be enormous, and a kernel that propagates all of it drags visible
  /// trails of wrong-coloured speckle across flat regions. Discarding a quarter damps that, and
  /// leaves genuinely flat areas flat.
  ///
  /// ```
  ///        *   1   1
  ///    1   1   1
  ///        1            (each 1/8 of the error)
  /// ```
  ///
  /// Scanning alternates direction per row. At 128 pixels wide a single-direction scan never lets
  /// the error trail decorrelate, and the result is pronounced diagonal "worming".
  static Uint8List _diffuse(
    PanelDevice device,
    List<_Ink> inks,
    Float32List l,
    Float32List a,
    Float32List b,
  ) {
    final width = device.pixelsPerRow;
    final height = device.frameRows;
    final frame = Uint8List(device.packedBytes);

    const taps = [
      [1, 0],
      [2, 0],
      [-1, 1],
      [0, 1],
      [1, 1],
      [0, 2],
    ];

    for (var y = 0; y < height; y++) {
      final leftToRight = y.isEven;
      for (var step = 0; step < width; step++) {
        final x = leftToRight ? step : width - 1 - step;
        final p = y * width + x;

        final ink = _nearestInk(inks, l[p], a[p], b[p]);
        setPixel(device, frame, x, y, ink.code);

        // Clamping keeps a pathological pixel from poisoning its neighbourhood. With four levels
        // the raw error is already large; an unclamped runaway shows up as a bright smear.
        final errL = (l[p] - ink.l).clamp(-0.3, 0.3) / 8.0;
        final errA = (a[p] - ink.a).clamp(-0.3, 0.3) / 8.0;
        final errB = (b[p] - ink.b).clamp(-0.3, 0.3) / 8.0;

        for (final tap in taps) {
          final nx = x + (leftToRight ? tap[0] : -tap[0]);
          final ny = y + tap[1];
          if (nx < 0 || nx >= width || ny < 0 || ny >= height) continue;
          final q = ny * width + nx;
          l[q] += errL;
          a[q] += errA;
          b[q] += errB;
        }
      }
    }
    return frame;
  }

  /// The ink closest to a colour, with chroma error weighted. See [_chromaWeight].
  static _Ink _nearestInk(List<_Ink> inks, double l, double a, double b) {
    var best = inks.first;
    var bestDistance = double.infinity;
    for (final ink in inks) {
      final dl = l - ink.l;
      final da = a - ink.a;
      final db = b - ink.b;
      final distance = dl * dl + _chromaWeight * (da * da + db * db);
      if (distance < bestDistance) {
        bestDistance = distance;
        best = ink;
      }
    }
    return best;
  }

  /// Pulls hues the palette cannot reach toward neutral, smoothly.
  ///
  /// A hard saturation threshold would leave a visible contour wherever a gradient crosses it, so
  /// the gate falls off with the cosine of the angular distance from the reachable range.
  ///
  /// Fourth power, not squared: a squared falloff still leaves a quarter of the chroma on a hue 60°
  /// outside the range — green — and that residue is enough to pull mid-tones into red. The steeper
  /// curve keeps near-range hues (sunlit foliage, warm skin) almost untouched while sending
  /// genuinely unreachable hues properly neutral.
  static void _gateChroma(List<_Ink> inks, Float32List a, Float32List b) {
    final coloured = inks.where((i) => i.chroma > 0.01).map((i) => i.hue);
    if (coloured.isEmpty) {
      // A purely monochrome palette can't represent any hue at all.
      a.fillRange(0, a.length, 0);
      b.fillRange(0, b.length, 0);
      return;
    }
    final low = coloured.reduce(math.min);
    final high = coloured.reduce(math.max);

    for (var p = 0; p < a.length; p++) {
      final chroma = math.sqrt(a[p] * a[p] + b[p] * b[p]);
      if (chroma < 1e-4) continue;

      final hue = math.atan2(b[p], a[p]);
      final distance = hue < low
          ? low - hue
          : hue > high
          ? hue - high
          : 0.0;

      final clamped = hue.clamp(low, high);
      final falloff = distance >= math.pi / 2 ? 0.0 : math.cos(distance);
      final gated = chroma * math.pow(falloff, 4).toDouble();

      a[p] = gated * math.cos(clamped);
      b[p] = gated * math.sin(clamped);
    }
  }

  /// Stretches lightness to fill the range, ignoring the extreme 2% at each end.
  ///
  /// With only a handful of levels available, spending any of them on unused headroom is expensive
  /// — this is the single largest quality win for ordinary phone photos.
  static void _autoLevels(Float32List l) {
    final histogram = Int32List(256);
    for (final value in l) {
      histogram[(value.clamp(0.0, 1.0) * 255).round()]++;
    }

    final cutoff = (l.length * 0.02).round();
    var low = 0;
    var high = 255;
    for (var seen = 0, i = 0; i < 256; i++) {
      seen += histogram[i];
      if (seen > cutoff) {
        low = i;
        break;
      }
    }
    for (var seen = 0, i = 255; i >= 0; i--) {
      seen += histogram[i];
      if (seen > cutoff) {
        high = i;
        break;
      }
    }
    // Already flat; stretching would only amplify noise.
    if (high - low < 8) return;

    final lo = low / 255.0;
    final scale = 1.0 / ((high - low) / 255.0);
    for (var p = 0; p < l.length; p++) {
      l[p] = ((l[p] - lo) * scale).clamp(0.0, 1.0);
    }
  }

  /// sRGB (0-255) to Oklab. Björn Ottosson's transform.
  static List<double> _rgbToOklab(int r, int g, int bl) {
    final lr = _toLinear(r / 255.0);
    final lg = _toLinear(g / 255.0);
    final lb = _toLinear(bl / 255.0);

    final ll = 0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb;
    final mm = 0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb;
    final ss = 0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb;

    final l = _cbrt(ll);
    final m = _cbrt(mm);
    final s = _cbrt(ss);

    return [
      0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
      1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
      0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
    ];
  }

  static double _toLinear(double c) =>
      c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

  static double _cbrt(double x) => x <= 0 ? 0 : math.pow(x, 1 / 3).toDouble();
}

/// The palette entry closest to a colour, by squared distance in RGB.
///
/// Used where a colour is already known to be one of the inks — text, borders, decoded frames — so
/// the subtleties [Quantiser] deals with don't arise.
int nearestCode(PanelDevice device, int r, int g, int b) {
  var bestCode = device.backgroundCode;
  var bestDistance = double.infinity;

  for (var code = 0; code < device.palette.length; code++) {
    final candidate = device.palette[code];
    final dr = r - (candidate.r * 255).round();
    final dg = g - (candidate.g * 255).round();
    final db = b - (candidate.b * 255).round();
    final distance = (dr * dr + dg * dg + db * db).toDouble();
    if (distance < bestDistance) {
      bestDistance = distance;
      bestCode = code;
    }
  }
  return bestCode;
}

/// Reads the ink code at ([x], [y]) in a packed frame. The inverse of [setPixel].
int codeAt(PanelDevice device, Uint8List frame, int x, int y) {
  final index = y * device.frameBytesPerRow + (x ~/ device.pixelsPerByte);
  final shift = 8 - device.bitsPerPixel * (x % device.pixelsPerByte + 1);
  return (frame[index] >> shift) & ((1 << device.bitsPerPixel) - 1);
}

/// Writes an ink [code] at ([x], [y]) in a packed frame.
///
/// Pixels run several to a byte, most significant first — the same layout the vendor app packs with
/// (`byte = p0<<6 | p1<<4 | p2<<2 | p3` at two bits per pixel).
void setPixel(PanelDevice device, Uint8List frame, int x, int y, int code) {
  if (x < 0 || x >= device.pixelsPerRow) return;
  if (y < 0 || y >= device.frameRows) return;

  final index = y * device.frameBytesPerRow + (x ~/ device.pixelsPerByte);
  final shift = 8 - device.bitsPerPixel * (x % device.pixelsPerByte + 1);
  final mask = (1 << device.bitsPerPixel) - 1;
  frame[index] =
      (frame[index] & ~(mask << shift) & 0xFF) | ((code & mask) << shift);
}
