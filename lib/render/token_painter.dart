import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:epaper_nfc/epaper_nfc.dart';
import 'package:flutter/material.dart';

import '../models/creature_art.dart';
import '../models/token_content.dart';
import 'canvas_painter.dart';
import 'frame_packer.dart';
import 'image_content.dart';

/// Where each part of the card sits, in panel coordinates.
///
/// Everything is measured in a unit scaled from the 128×296 reference — by whichever of width or
/// height is tighter, so a wider canvas like the 4.2"'s 300×400 gets a proportionally sized frame
/// rather than one so tall it crushes the art box. Boxes still span the full width, and the art box
/// absorbs whatever height is left.
///
/// With [hasAbility], a text box sits between the type line and the P/T row and the art gives up
/// the height. Without it there's no box at all — an empty one would just be a blank white slab.
@immutable
class TokenLayout {
  factory TokenLayout(PanelDevice device, {bool hasAbility = false}) {
    final w = device.size.width;
    final h = device.size.height;
    final u = math.min(w / 128, h / 296);

    final border = 5 * u;
    final gap = 4 * u;

    final title = Rect.fromLTWH(border, border, w - 2 * border, 22 * u);
    final pt = Rect.fromLTRB(
      w - border - 40 * u,
      h - border - 26 * u,
      w - border,
      h - border,
    );
    final ability = hasAbility
        ? Rect.fromLTRB(border, pt.top - gap - 64 * u, w - border, pt.top - gap)
        : null;
    final typeBottom = (ability?.top ?? pt.top) - gap;
    final type = Rect.fromLTRB(
      border,
      typeBottom - 18 * u,
      w - border,
      typeBottom,
    );
    final art = Rect.fromLTRB(
      border + 3 * u,
      title.bottom + gap,
      w - border - 3 * u,
      type.top - gap,
    );

    return TokenLayout._(u, title, art, type, ability, pt);
  }

  const TokenLayout._(
    this.unit,
    this.title,
    this.art,
    this.type,
    this.ability,
    this.pt,
  );

  /// One pixel on the 128×296 reference layout.
  final double unit;

  final Rect title;
  final Rect art;

  /// [art] shrunk to whole pixels, for a picture.
  ///
  /// The layout is fractional on any panel but the reference one, and a quantised picture has to
  /// land pixel for pixel — half a pixel off and every edge pixel is resampled between inks.
  Rect get artPixels => Rect.fromLTRB(
    art.left.ceilToDouble(),
    art.top.ceilToDouble(),
    art.right.floorToDouble(),
    art.bottom.floorToDouble(),
  );

  final Rect type;

  /// Null when the token has no ability text.
  final Rect? ability;

  final Rect pt;
}

/// The layout [token] gets on [device].
TokenLayout tokenLayoutFor(PanelDevice device, TokenContent token) =>
    TokenLayout(device, hasAbility: token.ability.trim().isNotEmpty);

/// The frame a picture in [token]'s art box is framed in. It changes with the ability text.
Size tokenArtBox(PanelDevice device, TokenContent token) =>
    tokenLayoutFor(device, token).artPixels.size;

/// Draws [token] on the card template, in panel coordinates.
///
/// With [picture], the art box shows that instead of the preset creature: [pictureInks] if given —
/// the picture already quantised, from [renderImagePreview] — otherwise the source itself, for
/// while that's still being worked out.
void paintToken(
  Canvas canvas,
  PanelDevice device,
  TokenContent token, {
  ImageContent? picture,
  ui.Image? pictureInks,
}) {
  final layout = tokenLayoutFor(device, token);
  final u = layout.unit;
  final ink = device.foreground;
  final paper = device.background;

  // Shapes are drawn without anti-aliasing: every pixel has to land on an ink.
  final paperFill = Paint()
    ..color = paper
    ..isAntiAlias = false;
  final radius = Radius.circular(5 * u);

  // The frame.
  canvas.drawRect(
    Offset.zero & device.size,
    Paint()
      ..color = ink
      ..isAntiAlias = false,
  );

  canvas.drawRRect(RRect.fromRectAndRadius(layout.title, radius), paperFill);
  canvas.drawRRect(RRect.fromRectAndRadius(layout.type, radius), paperFill);
  canvas.drawRRect(RRect.fromRectAndRadius(layout.pt, radius), paperFill);
  if (layout.ability case final box?) {
    canvas.drawRRect(RRect.fromRectAndRadius(box, radius), paperFill);
  }

  // The art box: a picture, the chosen creature, or with neither a sparse diagonal hatch, so it
  // still reads as a picture area rather than a blank.
  canvas.drawRect(layout.art, paperFill);
  final art = layout.art;
  if (picture != null) {
    final box = layout.artPixels;
    if (pictureInks != null) {
      canvas.drawImageRect(
        pictureInks,
        Offset.zero &
            Size(pictureInks.width.toDouble(), pictureInks.height.toDouble()),
        box,
        Paint()..filterQuality = FilterQuality.none,
      );
    } else {
      canvas.save();
      canvas.translate(box.left, box.top);
      paintImageContent(canvas, picture);
      canvas.restore();
    }
  } else if (CreatureArt.byId(token.art) case final creature?) {
    paintCreatureArt(canvas, creature, art.deflate(6 * u), ink);
  } else {
    canvas.save();
    canvas.clipRect(art);
    final hatch = Paint()
      ..color = ink
      ..strokeWidth = math.max(1, u)
      ..isAntiAlias = false;
    for (var d = -art.height; d < art.width; d += 8 * u) {
      canvas.drawLine(
        Offset(art.left + d, art.bottom),
        Offset(art.left + d + art.height, art.top),
        hatch,
      );
    }
    canvas.restore();
  }

  final padding = 6 * u;
  _paintFitted(
    canvas,
    token.name,
    layout.title.deflate(padding),
    colour: ink,
    maxSize: 14 * u,
    minSize: 8 * u,
    weight: FontWeight.w700,
  );
  _paintFitted(
    canvas,
    token.type,
    layout.type.deflate(padding),
    colour: ink,
    maxSize: 10 * u,
    minSize: 7 * u,
    weight: FontWeight.w600,
  );
  if (layout.ability case final box?) {
    _paintWrapped(
      canvas,
      token.ability.trim(),
      box.deflate(padding),
      colour: ink,
      maxSize: 11 * u,
      minSize: 7 * u,
    );
  }
  _paintFitted(
    canvas,
    '${token.power}/${token.toughness}',
    layout.pt.deflate(3 * u),
    colour: ink,
    maxSize: 18 * u,
    minSize: 8 * u,
    weight: FontWeight.w800,
    centred: true,
  );
}

/// Draws [creature]'s silhouette as large as fits inside [box], centred, in [colour].
///
/// Fitted to the silhouette's own bounds rather than its 512 viewBox: the icons don't all fill
/// their square, and on a 110-pixel-wide art box every pixel of a narrow one like the skeleton
/// counts. The bounds include curve control points, so they can overshoot slightly — hence the
/// clip.
///
/// Shared with the editor's dropdown, so the thumbnails there are the same drawing as the card.
void paintCreatureArt(
  Canvas canvas,
  CreatureArt creature,
  Rect box,
  Color colour,
) {
  final path = creature.path;
  final bounds = path.getBounds();
  final scale = math.min(box.width / bounds.width, box.height / bounds.height);

  canvas.save();
  canvas.clipRect(box);
  canvas.translate(box.center.dx, box.center.dy);
  canvas.scale(scale);
  canvas.translate(-bounds.center.dx, -bounds.center.dy);
  canvas.drawPath(
    path,
    Paint()
      ..color = colour
      ..isAntiAlias = false,
  );
  canvas.restore();
}

/// Draws [text] on one line inside [box], vertically centred, shrinking the font until it fits.
///
/// If it still doesn't fit at [minSize] it's cut off with an ellipsis rather than overflowing.
void _paintFitted(
  Canvas canvas,
  String text,
  Rect box, {
  required Color colour,
  required double maxSize,
  required double minSize,
  required FontWeight weight,
  bool centred = false,
}) {
  if (text.trim().isEmpty) return;

  TextPainter layout(double size) => TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        color: colour,
        fontSize: size,
        fontWeight: weight,
        height: 1,
      ),
    ),
    maxLines: 1,
    ellipsis: '…',
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: box.width);

  var size = maxSize;
  var painter = layout(size);
  while (painter.didExceedMaxLines && size > minSize) {
    painter.dispose();
    size = math.max(minSize, size - 0.5);
    painter = layout(size);
  }

  final dx = centred ? box.left + (box.width - painter.width) / 2 : box.left;
  painter.paint(
    canvas,
    Offset(dx, box.top + (box.height - painter.height) / 2),
  );
  painter.dispose();
}

/// Draws [text] wrapped inside [box], top-left, shrinking the font until the whole thing fits.
///
/// If it still doesn't fit at [minSize], it's cut at the last line that does, with an ellipsis.
void _paintWrapped(
  Canvas canvas,
  String text,
  Rect box, {
  required Color colour,
  required double maxSize,
  required double minSize,
}) {
  const lineHeight = 1.15;

  TextPainter layout(double size, {int? maxLines}) => TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        color: colour,
        fontSize: size,
        fontWeight: FontWeight.w500,
        height: lineHeight,
      ),
    ),
    maxLines: maxLines,
    ellipsis: maxLines == null ? null : '…',
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: box.width);

  var size = maxSize;
  var painter = layout(size);
  while (painter.height > box.height && size > minSize) {
    painter.dispose();
    size = math.max(minSize, size - 0.5);
    painter = layout(size);
  }
  if (painter.height > box.height) {
    painter.dispose();
    final lines = math.max(1, (box.height / (size * lineHeight)).floor());
    painter = layout(size, maxLines: lines);
  }

  painter.paint(canvas, box.topLeft);
  painter.dispose();
}

/// Renders [token] to the device's frame and packs it, with [picture] in the art box if given.
///
/// The card is flat art and is packed flat; a picture is quantised separately, in its own style and
/// on its own pixels, and laid over the art box afterwards. Dithering the whole card instead would
/// speckle every edge of the text, and the card's paper would throw off the picture's levels.
Future<Uint8List> renderTokenFrame(
  PanelDevice device,
  TokenContent token, {
  ImageContent? picture,
}) async {
  if (picture == null) {
    return renderPainted(device, (canvas) => paintToken(canvas, device, token));
  }

  final box = tokenLayoutFor(device, token).artPixels;
  // The caller keeps the picture framed to the box, but a stale one is still drawn in the right
  // place rather than smeared across the card.
  final fitted = picture.box == box.size && picture.device == device
      ? picture
      : picture.reframed(device: device, box: () => box.size);
  // The card pass draws the picture too, though it's about to be replaced: that keeps the art box's
  // fractional edges paper, rather than slivers of the hatch.
  final frame = await renderPainted(
    device,
    (canvas) => paintToken(canvas, device, token, picture: fitted),
  );
  overlayCodes(
    device,
    frame,
    await renderImageCodes(fitted),
    box.width.round(),
    left: box.left.round(),
    top: box.top.round(),
  );
  return frame;
}
