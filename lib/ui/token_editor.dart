import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/creature_art.dart';
import '../models/token_content.dart';
import '../render/image_content.dart';
import '../render/token_painter.dart';
import 'crop_view.dart';
import 'widgets/image_controls.dart';

/// Controls for an MTG token: name, art, type line, ability text, power and toughness.
///
/// Owns its text controllers, seeded from [content] and re-synced whenever [content] changes from
/// outside (opening a saved token). The token itself lives with the caller, so switching tab and
/// back picks up where you left off.
class TokenEditor extends StatefulWidget {
  const TokenEditor({
    required this.content,
    required this.onChanged,
    required this.picture,
    required this.picking,
    required this.onPickPicture,
    required this.onPictureChanged,
    required this.busy,
    required this.onSave,
    super.key,
  });

  final TokenContent content;
  final ValueChanged<TokenContent> onChanged;

  /// A picture for the art box, overriding the preset creature. Null for none.
  final ImageContent? picture;

  final bool picking;
  final VoidCallback onPickPicture;

  /// Null removes the picture, putting the preset back.
  final ValueChanged<ImageContent?> onPictureChanged;

  final bool busy;
  final VoidCallback onSave;

  @override
  State<TokenEditor> createState() => _TokenEditorState();
}

class _TokenEditorState extends State<TokenEditor> {
  late final _name = TextEditingController(text: widget.content.name);
  late final _type = TextEditingController(text: widget.content.type);
  late final _power = TextEditingController(text: widget.content.power);
  late final _toughness = TextEditingController(text: widget.content.toughness);
  late final _ability = TextEditingController(text: widget.content.ability);

  @override
  void didUpdateWidget(TokenEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Typing round-trips through the caller and comes back equal, so this only fires on a real
    // outside change — and only then does it move the cursor.
    final content = widget.content;
    for (final (controller, value) in [
      (_name, content.name),
      (_type, content.type),
      (_power, content.power),
      (_toughness, content.toughness),
      (_ability, content.ability),
    ]) {
      if (controller.text != value) controller.text = value;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _type.dispose();
    _power.dispose();
    _toughness.dispose();
    _ability.dispose();
    super.dispose();
  }

  Widget _field(
    TextEditingController controller,
    String label,
    TokenContent Function(String value) update, {
    bool multiline = false,
    bool numeric = false,
  }) {
    return TextField(
      controller: controller,
      // Two digits covers every real P/T; the cap keeps the P/T box from having to shrink.
      maxLength: numeric ? 2 : null,
      textAlign: numeric ? TextAlign.center : TextAlign.start,
      minLines: 1,
      maxLines: multiline ? 4 : 1,
      keyboardType: numeric
          ? TextInputType.number
          : multiline
          ? TextInputType.multiline
          : null,
      inputFormatters: numeric
          ? [FilteringTextInputFormatter.digitsOnly]
          : null,
      // Names and types are Title Case; rules text is sentences.
      textCapitalization: multiline
          ? TextCapitalization.sentences
          : TextCapitalization.words,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        // P/T are capped at a few characters; a counter under each would be noise.
        counterText: '',
      ),
      onChanged: (v) => widget.onChanged(update(v)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final content = widget.content;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _field(_name, 'Name', (v) => content.copyWith(name: v)),
        const SizedBox(height: 16),
        _ArtPicker(
          selected: content.art,
          hasPicture: widget.picture != null,
          onPickPicture: widget.picking ? null : widget.onPickPicture,
          onChanged: (id) {
            widget.onPictureChanged(null);
            widget.onChanged(content.copyWith(art: () => id));
          },
        ),
        if (widget.picture case final picture?) ...[
          const SizedBox(height: 12),
          // Capped like the main preview: an art box on the 4.2" is taller than the 2.9"'s whole card.
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.black54),
                ),
                child: CropView(
                  content: picture,
                  onChanged: widget.onPictureChanged,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          ZoomRow(image: picture, onChanged: widget.onPictureChanged),
          const SizedBox(height: 4),
          DitherStyleControl(
            image: picture,
            onChanged: widget.onPictureChanged,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: widget.picking ? null : widget.onPickPicture,
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('Different image'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => widget.onPictureChanged(null),
                  icon: const Icon(Icons.hide_image_outlined),
                  label: const Text('Remove'),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 16),
        _field(_type, 'Type', (v) => content.copyWith(type: v)),
        const SizedBox(height: 16),
        _field(
          _ability,
          'Ability text (optional)',
          (v) => content.copyWith(ability: v),
          multiline: true,
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: _field(
                _power,
                'Power',
                (v) => content.copyWith(power: v),
                numeric: true,
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Text('/', style: TextStyle(fontSize: 24)),
            ),
            Expanded(
              child: _field(
                _toughness,
                'Toughness',
                (v) => content.copyWith(toughness: v),
                numeric: true,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: widget.busy ? null : widget.onSave,
          icon: const Icon(Icons.bookmark_add_outlined),
          label: const Text('Save to library'),
        ),
      ],
    );
  }
}

/// The art dropdown: a picture from the gallery, a preset creature, or none for the plain hatch.
///
/// Changes only the art — the name, type and P/T are left as typed.
class _ArtPicker extends StatelessWidget {
  const _ArtPicker({
    required this.selected,
    required this.hasPicture,
    required this.onPickPicture,
    required this.onChanged,
  });

  /// Stands in for "a picture" among the creature ids; no art id can start with a NUL.
  static const _picture = '\u0000picture';

  final String? selected;
  final bool hasPicture;

  /// Null while a picker is already open.
  final VoidCallback? onPickPicture;

  /// A preset was chosen, or null for the hatch.
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    // An id this build doesn't know shows as "None" rather than failing the dropdown's assert.
    final value = hasPicture ? _picture : CreatureArt.byId(selected)?.id;

    Widget row(Widget thumb, String label) => Row(
      children: [
        SizedBox.square(dimension: 28, child: thumb),
        const SizedBox(width: 12),
        Text(label),
      ],
    );

    return InputDecorator(
      decoration: const InputDecoration(
        labelText: 'Art',
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String?>(
          value: value,
          isExpanded: true,
          menuMaxHeight: 420,
          onChanged: (id) {
            if (id == _picture) {
              // Choosing it again while a picture is set picks a new one.
              onPickPicture?.call();
            } else {
              onChanged(id);
            }
          },
          items: [
            DropdownMenuItem(
              value: _picture,
              enabled: onPickPicture != null,
              child: row(
                const Icon(Icons.photo_library_outlined),
                hasPicture ? 'Picture' : 'From image…',
              ),
            ),
            DropdownMenuItem(
              value: null,
              child: row(const Icon(Icons.texture), 'None'),
            ),
            for (final art in CreatureArt.all)
              DropdownMenuItem(
                value: art.id,
                child: row(
                  CustomPaint(
                    painter: _ArtThumbPainter(
                      art,
                      Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  art.label,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ArtThumbPainter extends CustomPainter {
  const _ArtThumbPainter(this.art, this.colour);

  final CreatureArt art;
  final Color colour;

  @override
  void paint(Canvas canvas, Size size) =>
      paintCreatureArt(canvas, art, Offset.zero & size, colour);

  @override
  bool shouldRepaint(_ArtThumbPainter oldDelegate) =>
      oldDelegate.art != art || oldDelegate.colour != colour;
}
