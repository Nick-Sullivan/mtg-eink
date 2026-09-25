import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/panel_device.dart';
import '../models/saved_design.dart';
import '../nfc/apdu.dart';
import '../nfc/gseries_protocol.dart';
import '../nfc/tag_events.dart';
import '../render/canvas_painter.dart';
import '../render/image_content.dart';
import '../render/quantiser.dart';
import '../services/design_store.dart';
import 'crop_view.dart';
import 'library_view.dart';
import 'settings_view.dart';

/// The app's top-level tabs.
enum AppTab { text, image, saved, settings }

/// Compose something and push it to the panel.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(
    length: AppTab.values.length,
    vsync: this,
  )..addListener(_onTabChanged);

  /// Switches mode the moment the index changes, not when the animation finishes.
  ///
  /// Waiting for `indexIsChanging` to clear means the content only swaps once the ripple and slide
  /// have played out, which reads as lag.
  void _onTabChanged() {
    final mode = AppTab.values[_tabs.index];
    if (mode != _mode) setState(() => _mode = mode);
  }

  final _channel = ApduChannel();
  late final _protocol = GSeriesProtocol(_channel);
  final _textController = TextEditingController(text: 'HELLO');

  TagDetected? _tag;
  TagLost? _lost;
  AdapterState? _adapter;

  AppTab _mode = AppTab.text;
  PanelDevice _device = PanelDevice.waveshare29G;
  late PanelContent _content = PanelContent.forDevice(_device, text: 'HELLO');
  ImageContent? _image;
  bool _picking = false;

  final _store = DesignStore();
  List<SavedDesign> _designs = const [];

  /// Shown briefly on the write button after a successful write, then cleared.
  bool _succeeded = false;
  Timer? _successTimer;

  bool _writing = false;
  int _percent = 0;
  String? _status;
  bool _failed = false;

  /// The frame waiting for a panel to appear, captured when the write button was pressed.
  ///
  /// Arming rather than requiring the panel to be held first: lining up a panel against the back of
  /// a phone and *then* finding a button on the screen you can no longer see is an awkward order to
  /// do things in. Capturing the frame at arm time also means what you pressed is what gets written,
  /// even if the editor changes underneath.
  Uint8List? _armedFrame;

  bool get _armed => _armedFrame != null;

  @override
  void initState() {
    super.initState();
    tagEvents().listen(_onEvent);
    _textController.addListener(
      () => setState(
        () => _content = _content.copyWith(text: _textController.text),
      ),
    );
    _reloadLibrary();
  }

  Future<void> _reloadLibrary() async {
    final designs = await _store.load();
    if (!mounted) return;
    setState(() => _designs = designs);
  }

  /// Whether the active tab composes anything.
  bool get _composes => _mode == AppTab.text || _mode == AppTab.image;

  /// Whether there's something ready to send right now.
  bool get _hasSomethingToWrite => switch (_mode) {
    AppTab.text => true,
    AppTab.image => _image != null,
    // The library is a browser — tapping a design opens it in Image, and it's sent from there.
    AppTab.saved || AppTab.settings => false,
  };

  /// The frame the write button would send, for whichever tab is active.
  Future<Uint8List?> _currentFrame() async {
    switch (_mode) {
      case AppTab.text:
        return renderFrame(_device, _content);
      case AppTab.image:
        final image = _image;
        return image == null ? null : renderImageFrame(image);
      case AppTab.saved:
      case AppTab.settings:
        return null;
    }
  }

  /// Switching panel discards the composition: the frame size and the available inks both change,
  /// so reinterpreting what was there would be guesswork.
  void _changeDevice(PanelDevice device) {
    setState(() {
      _device = device;
      _content = PanelContent.forDevice(device, text: _content.text);
      _image?.source.dispose();
      _image = null;
    });
  }

  /// Opens a saved design in the Image tab, restoring the original picture and its framing.
  ///
  /// The stored frame is only a cache. Reopening goes back to the source, so the crop, zoom and
  /// dither style are all still adjustable and nothing is quantised twice.
  Future<void> _openDesign(SavedDesign design) async {
    final settings = design.settings;
    final source = await _store.readSource(design.id);

    if (source == null || settings == null) {
      // Saved before sources were kept: the flattened frame is all there is. It can still be
      // re-sent, but re-cropping it would be quantising an already-quantised picture.
      final decoded = await decodeFrame(_device, design.frame);
      if (!mounted) {
        decoded.dispose();
        return;
      }
      _setImage(
        ImageContent(
          device: _device,
          source: decoded,
          bytes: design.frame,
          style: DitherStyle.graphic,
        ),
      );
      _tabs.animateTo(AppTab.image.index);
      return;
    }

    final decoded = await _decodeBounded(source);
    if (!mounted) {
      decoded.dispose();
      return;
    }
    _setImage(
      ImageContent(
        device: _device,
        source: decoded,
        bytes: source,
        offset: settings.offset,
        scale: settings.scale,
        style: settings.style,
      ),
      recentre: false,
    );
    _tabs.animateTo(AppTab.image.index);
  }

  Future<void> _saveCurrent() async {
    final image = _image;
    if (image == null) return;

    final frame = await _currentFrame();
    if (frame == null || !mounted) return;

    final name = await _askForName(title: 'Save design', initial: 'Image');
    if (name == null || !mounted) return;

    // Grab the messenger before the awaits, so the confirmation doesn't depend on this widget's
    // context still being valid afterwards.
    final messenger = ScaffoldMessenger.of(context);
    await _store.save(
      name: name,
      frame: frame,
      source: image.bytes,
      settings: ImageSettings(
        offset: image.offset,
        scale: image.scale,
        style: image.style,
      ),
    );
    await _reloadLibrary();
    messenger.showSnackBar(SnackBar(content: Text('Saved "$name"')));
  }

  Future<String?> _askForName({
    required String title,
    required String initial,
  }) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _NameDialog(title: title, initial: initial),
    );
    return (name == null || name.isEmpty) ? null : name;
  }

  Future<void> _renameDesign(SavedDesign design) async {
    final name = await _askForName(title: 'Rename', initial: design.name);
    if (name == null) return;
    await _store.rename(design.id, name);
    await _reloadLibrary();
  }

  Future<void> _deleteDesign(SavedDesign design) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${design.name}"?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await _store.delete(design.id);
    await _reloadLibrary();
  }

  @override
  void dispose() {
    _successTimer?.cancel();
    _tabs.dispose();
    _textController.dispose();
    _image?.source.dispose();
    super.dispose();
  }

  void _onEvent(TagEvent event) {
    setState(() {
      switch (event) {
        case AdapterState():
          _adapter = event;
        case TagDetected():
          _tag = event;
          _lost = null;
          // The whole point of arming: the panel arriving is what starts the write.
          if (_armedFrame != null && !_writing) {
            WidgetsBinding.instance.addPostFrameCallback((_) => _write());
          }
        case TagLost():
          _lost = event;
        case TagHeld():
        case WriteProgress():
          break;
      }
    });
  }

  /// Decodes encoded image bytes at a bounded size.
  ///
  /// A 12 MP photo held at full resolution is pure waste when the target is 128x296 — 1024 across
  /// leaves plenty of headroom for zooming in.
  static Future<ui.Image> _decodeBounded(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: 1024);
    return (await codec.getNextFrame()).image;
  }

  /// Replaces the image being edited, disposing whatever it displaces.
  void _setImage(ImageContent content, {bool recentre = true}) {
    setState(() {
      _image?.source.dispose();
      _image = recentre ? content.recentred() : content;
      _mode = AppTab.image;
    });
  }

  Future<void> _pickImage() async {
    setState(() => _picking = true);
    try {
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (picked == null) return;

      final bytes = await picked.readAsBytes();
      final decoded = await _decodeBounded(bytes);

      if (!mounted) {
        decoded.dispose();
        return;
      }
      _setImage(ImageContent(device: _device, source: decoded, bytes: bytes));
      _tabs.animateTo(AppTab.image.index);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// Captures the current design and waits for a panel. Writes at once if one is already there.
  Future<void> _arm() async {
    // Rendering happens before the session opens: the panel is powered by the phone's field, so
    // there is no reason to hold it open while we lay out text.
    final frame = await _currentFrame();
    if (frame == null || !mounted) return;

    setState(() {
      _armedFrame = frame;
      _status = null;
      _failed = false;
    });

    if (_tag != null && _lost == null) _write();
  }

  void _disarm() => setState(() => _armedFrame = null);

  Future<void> _write() async {
    final frame = _armedFrame;
    if (frame == null || _writing) return;

    setState(() {
      _writing = true;
      _percent = 0;
      _status = null;
      _failed = false;
    });

    String? status;
    var failed = false;
    try {
      await _channel.open();
      await _protocol.readDeviceInfoChecked();
      await _protocol.writeFrame(
        _device,
        frame,
        onProgress: (p) {
          if (mounted) setState(() => _percent = p);
        },
      );
      status = null;
    } on NfcFailure catch (e) {
      status = e.message;
      failed = true;
    } finally {
      try {
        await _channel.close();
      } on NfcFailure {
        // The write's own outcome matters more than failing to hand the tag back.
      }
    }

    if (!mounted) return;
    setState(() {
      _writing = false;
      _status = status;
      _failed = failed;
      // Success is shown on the button itself and then fades; only failures persist, because only
      // failures need you to do something about them.
      _succeeded = !failed;
      // A finished write disarms either way; a retry re-arms deliberately.
      _armedFrame = null;
    });

    _successTimer?.cancel();
    if (!failed) {
      _successTimer = Timer(const Duration(seconds: 4), () {
        if (mounted) setState(() => _succeeded = false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final adapter = _adapter;

    // No app bar: the title said nothing the user didn't already know, and the panel preview wants
    // every vertical pixel it can get.
    return Scaffold(
      body: Stack(
        children: [
          SafeArea(child: _buildBody(adapter)),

          // Once armed, the write takes over the screen. It's the only thing that matters until it
          // finishes, you're looking at the panel rather than the phone, and the state needs to be
          // readable from the corner of your eye — so it comes to the front rather than staying a
          // button halfway down a scrolling list.
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            switchInCurve: Curves.easeOutBack,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: ScaleTransition(
                scale: Tween(begin: 0.9, end: 1.0).animate(animation),
                child: child,
              ),
            ),
            // Keyed on *whether* the overlay is up, never on which state it's in. Keying on the
            // state made the whole thing — scrim included — cross-fade when the panel arrived,
            // which flashed. The backdrop now stays put and only the card's contents change.
            child: (_armed || _writing)
                ? _WriteOverlay(
                    key: const ValueKey('write-overlay'),
                    writing: _writing,
                    percent: _percent,
                    onCancel: _disarm,
                  )
                : const SizedBox.shrink(key: ValueKey('no-overlay')),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(AdapterState? adapter) {
    return Column(
      children: [
        // The tabs sit outside the scroll view so they stay put — they're navigation, and
        // navigation that scrolls away leaves you unsure where you are.
        if (adapter != null && !adapter.enabled)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: _Banner('NFC is off. Turn it on in Settings.', Colors.red),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(12),
              ),
              border: const Border(bottom: BorderSide(color: Colors.black26)),
            ),
            child: TabBar(
              controller: _tabs,
              indicatorSize: TabBarIndicatorSize.tab,
              tabs: const [
                Tab(icon: Icon(Icons.title), text: 'Text'),
                Tab(icon: Icon(Icons.image_outlined), text: 'Image'),
                Tab(icon: Icon(Icons.bookmark_outline), text: 'Saved'),
                Tab(icon: Icon(Icons.tune), text: 'Settings'),
              ],
            ),
          ),
        ),

        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
            children: [
              if (_mode == AppTab.settings)
                SizedBox(
                  height: 460,
                  child: SettingsView(
                    device: _device,
                    onDeviceChanged: _changeDevice,
                  ),
                )
              else if (_mode == AppTab.saved)
                SizedBox(
                  height: 340,
                  child: LibraryView(
                    device: _device,
                    designs: _designs,
                    onOpen: _openDesign,
                    onRename: _renameDesign,
                    onDelete: _deleteDesign,
                  ),
                )
              else ...[
                // The panel is tall and narrow, so cap the preview's height rather than letting it eat
                // the screen.
                Center(
                  child: SizedBox(
                    height: 280,
                    child: DecoratedBox(
                      // A dark hairline plus a drop shadow, so the edge stays visible even when the
                      // frame itself is white right up to the border.
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.black54),
                        boxShadow: const [
                          BoxShadow(
                            color: Colors.black26,
                            blurRadius: 6,
                            offset: Offset(0, 2),
                          ),
                        ],
                      ),
                      child: switch ((_mode, _image)) {
                        (AppTab.image, final image?) => CropView(
                          content: image,
                          onChanged: (c) => setState(() => _image = c),
                        ),
                        (AppTab.image, null) => const Center(
                          child: Padding(
                            padding: EdgeInsets.all(16),
                            child: Text(
                              'No image picked',
                              style: TextStyle(color: Colors.black45),
                            ),
                          ),
                        ),
                        _ => PanelPreview(device: _device, content: _content),
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                if (_mode == AppTab.image)
                  ..._imageControls()
                else
                  ..._textControls(),
              ],

              // Nothing to write from the Saved or Settings tabs — tapping a saved design
              // opens it in Image, and that's where it gets sent from.
              if (_composes) ...[
                const Divider(height: 24),
                _WriteButton(
                  succeeded: _succeeded,
                  enabled: _hasSomethingToWrite,
                  onArm: _arm,
                ),

                if (_status case final status?) ...[
                  const SizedBox(height: 12),
                  _Banner(status, _failed ? Colors.red : Colors.green),
                  if (_failed) ...[
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _writing ? null : _arm,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Try again'),
                    ),
                  ],
                ],
              ],
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _imageControls() {
    final image = _image;
    return [
      OutlinedButton.icon(
        onPressed: _picking ? null : _pickImage,
        icon: const Icon(Icons.photo_library_outlined),
        label: Text(image == null ? 'Pick an image' : 'Pick a different image'),
      ),
      if (image != null) ...[
        const SizedBox(height: 8),
        // Pinching is fiddly on a preview this small, so the slider is the primary zoom control.
        // It's logarithmic: a linear one spends most of its travel on huge zooms nobody wants.
        Row(
          children: [
            const Icon(Icons.zoom_out, size: 20),
            Expanded(
              child: Slider(
                value: (math.log(image.zoom) / math.ln2).clamp(-2.0, 3.0),
                min: -2,
                max: 3,
                onChanged: (v) => setState(
                  () => _image = image.zoomedTo(math.pow(2, v).toDouble()),
                ),
              ),
            ),
            const Icon(Icons.zoom_in, size: 20),
            const SizedBox(width: 8),
            Tooltip(
              message: 'Fit to frame',
              child: IconButton.outlined(
                onPressed: () => setState(() => _image = image.recentred()),
                icon: const Icon(Icons.fit_screen_outlined),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        SegmentedButton<DitherStyle>(
          segments: const [
            ButtonSegment(value: DitherStyle.photo, label: Text('Photo')),
            ButtonSegment(value: DitherStyle.graphic, label: Text('Graphic')),
          ],
          selected: {image.style},
          onSelectionChanged: (s) =>
              setState(() => _image = image.copyWith(style: s.first)),
        ),
        const SizedBox(height: 8),
        Text(
          image.style == DitherStyle.photo
              ? 'Dithered across the four inks. Best for photographs.'
              : 'Flat nearest colour. Best for logos and flat art.',
          style: const TextStyle(fontSize: 12, color: Colors.black54),
        ),
        const SizedBox(height: 4),
        const Text(
          'Drag to move, pinch to zoom. The preview shows the real inks.',
          style: TextStyle(fontSize: 12, color: Colors.black54),
        ),
        const SizedBox(height: 12),
        // Saving is image-only: the library exists to keep pictures you've framed, and text is
        // quick enough to retype that storing it would be clutter.
        OutlinedButton.icon(
          onPressed: _writing ? null : _saveCurrent,
          icon: const Icon(Icons.bookmark_add_outlined),
          label: const Text('Save to library'),
        ),
      ],
    ];
  }

  List<Widget> _textControls() {
    return [
      TextField(
        controller: _textController,
        maxLines: 3,
        minLines: 1,
        decoration: const InputDecoration(
          labelText: 'Text',
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 16),

      Row(
        children: [
          const SizedBox(width: 72, child: Text('Size')),
          Expanded(
            child: Slider(
              value: _content.fontSize,
              min: 10,
              max: 64,
              divisions: 54,
              label: _content.fontSize.round().toString(),
              onChanged: (v) =>
                  setState(() => _content = _content.copyWith(fontSize: v)),
            ),
          ),
        ],
      ),

      _ColourRow(
        device: _device,
        label: 'Text',
        selected: _content.textColor,
        onPick: (c) =>
            setState(() => _content = _content.copyWith(textColor: c)),
      ),
      _ColourRow(
        device: _device,
        label: 'Background',
        selected: _content.background,
        onPick: (c) =>
            setState(() => _content = _content.copyWith(background: c)),
      ),
    ];
  }
}

/// The inline write button: idle, or briefly confirming a finished write.
///
/// Big because it's the one thing the app is for, and because you often press it with the phone
/// already half-positioned. Once pressed it hands over to [_WriteOverlay].
class _WriteButton extends StatelessWidget {
  const _WriteButton({
    required this.succeeded,
    required this.enabled,
    required this.onArm,
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
class _WriteOverlay extends StatelessWidget {
  const _WriteOverlay({
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

/// Asks for a name.
///
/// A widget rather than an inline `AlertDialog` so that it **owns its controller**. Creating the
/// controller outside and disposing it when `showDialog` returns looks equivalent and isn't: the
/// route is still animating out with the `TextField` alive, and pulling its controller away
/// mid-transition trips a framework assertion.
class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.title, required this.initial});

  final String title;
  final String initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(labelText: 'Name'),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}

/// The four colours the panel can actually show.
class _ColourRow extends StatelessWidget {
  const _ColourRow({
    required this.device,
    required this.label,
    required this.selected,
    required this.onPick,
  });

  final PanelDevice device;
  final String label;
  final Color selected;
  final ValueChanged<Color> onPick;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(width: 96, child: Text(label)),
          for (final colour in device.palette)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: GestureDetector(
                onTap: () => onPick(colour),
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: colour,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: colour == selected ? Colors.blue : Colors.black26,
                      width: colour == selected ? 3 : 1,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner(this.text, this.color);

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.all(12),
      color: color.withValues(alpha: 0.12),
      child: Text(text, style: TextStyle(color: color)),
    );
  }
}
