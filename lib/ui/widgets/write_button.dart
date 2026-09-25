import 'package:flutter/material.dart';

/// The inline write button: idle, or briefly confirming a finished write.
///
/// Big because it's the one thing the app is for, and because you often press it with the phone
/// already half-positioned. Once pressed it hands over to [WriteOverlay].
class WriteButton extends StatelessWidget {
  const WriteButton({
    required this.succeeded,
    required this.enabled,
    required this.onArm,
    super.key,
  });

  final bool succeeded;
  final bool enabled;
  final VoidCallback onArm;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 72,
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: enabled ? onArm : null,
        style: FilledButton.styleFrom(
          backgroundColor: succeeded ? Colors.green.shade600 : null,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        icon: Icon(
          succeeded ? Icons.check_circle_outline : Icons.nfc,
          size: 30,
        ),
        label: Text(
          succeeded ? 'Uploaded' : 'Write to panel',
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

/// The write, brought to the front of the screen.
///
/// While waiting for a panel or writing to one you're looking at the panel against the back of the
/// phone, not at the screen. A card in the middle behind a dimmed backdrop is recognisable from the
/// corner of your eye in a way that a button halfway down a scrolling list is not — and it also
/// stops you fiddling with controls whose result has already been captured.
class WriteOverlay extends StatelessWidget {
  const WriteOverlay({
    required this.writing,
    required this.percent,
    required this.onCancel,
    super.key,
  });

  final bool writing;
  final int percent;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Material(
      // Only cancellable while waiting — a write in flight can't be called back, and tapping
      // through to the editor underneath mid-transfer would only cause confusion.
      color: Colors.black.withValues(alpha: 0.55),
      child: InkWell(
        onTap: writing ? null : onCancel,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Card(
              elevation: 12,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 28,
                  vertical: 32,
                ),
                // The card changes size between states, so animate the box as well as the
                // contents — otherwise it snaps the instant the panel makes contact.
                child: AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOut,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    child: writing
                        ? _writingBody(context)
                        : _waitingBody(context),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _waitingBody(BuildContext context) {
    return Column(
      key: const ValueKey('waiting'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.nfc, size: 64, color: Colors.amber.shade800),
        const SizedBox(height: 16),
        Text(
          'Hold the panel to the phone',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        const Text(
          'A small gap works better than pressing flat.',
          textAlign: TextAlign.center,
          style: TextStyle(fontStyle: FontStyle.italic),
        ),
        const SizedBox(height: 20),
        OutlinedButton(onPressed: onCancel, child: const Text('Cancel')),
      ],
    );
  }

  Widget _writingBody(BuildContext context) {
    return Column(
      key: const ValueKey('writing'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$percent%',
          style: Theme.of(
            context,
          ).textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 16),
        LinearProgressIndicator(
          value: percent / 100,
          minHeight: 8,
          borderRadius: const BorderRadius.all(Radius.circular(4)),
        ),
        const SizedBox(height: 20),
        Text('Writing…', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        const Text(
          'Hold still — about 25 seconds.',
          textAlign: TextAlign.center,
          style: TextStyle(fontStyle: FontStyle.italic),
        ),
      ],
    );
  }
}
