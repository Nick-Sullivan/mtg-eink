import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/creature_art.dart';
import '../models/panel_device.dart';
import '../models/token_content.dart';
import 'canvas_painter.dart';

/// Where each part of the card sits, in panel coordinates.
///
/// Everything is a proportion of the panel's width, with the art box absorbing whatever height is
/// left, so the template follows [PanelDevice] rather than assuming 128×296.
///
/// With [hasAbility], a text box sits between the type line and the P/T row and the art gives up
/// the height. Without it there's no box at all — an empty one would just be a blank white slab.
@immutable
class TokenLayout {
  factory TokenLayout(PanelDevice device, {bool hasAbility = false}) {
    final w = device.size.width;
    final h = device.size.height;
    final u = w / 128;

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

  /// One pixel on the 128-wide reference layout.
  final double unit;

  final Rect title;
  final Rect art;
  final Rect type;

  /// Null when the token has no ability text.
  final Rect? ability;

  final Rect pt;
}

/// Draws [token] on the card template, in panel coordinates.
void paintToken(Canvas canvas, PanelDevice device, TokenContent token) {
  final layout = TokenLayout(
    device,
    hasAbility: token.ability.trim().isNotEmpty,
  );
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

  // The art box: the chosen creature, or with none chosen a sparse diagonal hatch, so it still
  // reads as a picture area rather than a blank.
  canvas.drawRect(layout.art, paperFill);
  final art = layout.art;
  if (CreatureArt.byId(token.art) case final creature?) {
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

/// Renders [token] to the device's frame and packs it.
Future<Uint8List> renderTokenFrame(PanelDevice device, TokenContent token) =>
    renderPainted(device, (canvas) => paintToken(canvas, device, token));
