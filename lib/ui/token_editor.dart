import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/token_content.dart';

/// Controls for an MTG token: name, type line, ability text, power and toughness.
///
/// Owns its text controllers, seeded from [content] and re-synced whenever [content] changes from
/// outside (opening a saved token). The token itself lives with the caller, so switching tab and
/// back picks up where you left off.
class TokenEditor extends StatefulWidget {
  const TokenEditor({
    required this.content,
    required this.onChanged,
    required this.busy,
    required this.onSave,
    super.key,
  });

  final TokenContent content;
  final ValueChanged<TokenContent> onChanged;
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
