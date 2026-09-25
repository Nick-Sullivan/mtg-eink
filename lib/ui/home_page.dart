import 'dart:async';
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
import 'image_editor.dart';
import 'library_view.dart';
import 'settings_view.dart';
import 'text_editor.dart';
import 'widgets/info_banner.dart';
import 'widgets/name_dialog.dart';
import 'widgets/write_button.dart';

/// The app's top-level tabs.
enum AppTab { text, image, saved, settings }

/// Compose something and push it to the panel.
///
/// This holds the state and the NFC plumbing; each tab's controls live in their own widget.
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

  final _channel = ApduChannel();
  late final _protocol = GSeriesProtocol(_channel);
  final _textController = TextEditingController(text: 'HELLO');
  final _store = DesignStore();

  AppTab _tab = AppTab.text;
  PanelDevice _device = PanelDevice.waveshare29G;
  late PanelContent _content = PanelContent.forDevice(_device, text: 'HELLO');
  ImageContent? _image;
  List<SavedDesign> _designs = const [];

  TagDetected? _tag;
  TagLost? _lost;
  AdapterState? _adapter;

  bool _picking = false;
  bool _writing = false;
  int _percent = 0;
  String? _error;

  /// Shown briefly on the write button after a successful write, then cleared.
  bool _succeeded = false;
  Timer? _successTimer;

  /// The frame waiting for a panel to appear, captured when the write button was pressed.
  ///
  /// Arming rather than requiring the panel to be held first: lining up a panel against the back of
  /// a phone and *then* finding a button on the screen you can no longer see is an awkward order to
  /// do things in. Capturing the frame at arm time also means what you pressed is what gets written,
  /// even if the editor changes underneath.
  Uint8List? _armedFrame;

  bool get _armed => _armedFrame != null;
  bool get _panelPresent => _tag != null && _lost == null;

  /// Whether the active tab composes anything to send.
  bool get _composes => _tab == AppTab.text || _tab == AppTab.image;

  /// Whether there's something ready to send right now.
  bool get _hasSomethingToWrite => switch (_tab) {
    AppTab.text => true,
    AppTab.image => _image != null,
    // The library is a browser — tapping a design opens it in Image, and it's sent from there.
    AppTab.saved || AppTab.settings => false,
  };

  @override
  void initState() {
    super.initState();
    tagEvents().listen(_onTagEvent);
    _textController.addListener(
      () => setState(
        () => _content = _content.copyWith(text: _textController.text),
      ),
    );
    _reloadLibrary();
  }

  @override
  void dispose() {
    _successTimer?.cancel();
    _tabs.dispose();
    _textController.dispose();
    _image?.source.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- events

  /// Switches tab the moment the index changes, not when the animation finishes.
  ///
  /// Waiting for `indexIsChanging` to clear means the content only swaps once the ripple and slide
  /// have played out, which reads as lag.
  void _onTabChanged() {
    final tab = AppTab.values[_tabs.index];
    if (tab != _tab) setState(() => _tab = tab);
  }

  void _onTagEvent(TagEvent event) {
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

  // --------------------------------------------------------------- content

  /// The frame the write button would send, for whichever tab is active.
  Future<Uint8List?> _currentFrame() async {
    switch (_tab) {
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

  /// Decodes encoded image bytes at a bounded size.
  ///
  /// A 12 MP photo held at full resolution is pure waste when the target is a few hundred pixels —
  /// 1024 across leaves plenty of headroom for zooming in.
  static Future<ui.Image> _decodeBounded(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: 1024);
    return (await codec.getNextFrame()).image;
  }

  /// Replaces the image being edited, disposing whatever it displaces.
  void _setImage(ImageContent content, {bool recentre = true}) {
    setState(() {
      _image?.source.dispose();
      _image = recentre ? content.recentred() : content;
      _tab = AppTab.image;
    });
    _tabs.animateTo(AppTab.image.index);
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
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  // --------------------------------------------------------------- library

  Future<void> _reloadLibrary() async {
    final designs = await _store.load();
    if (!mounted) return;
    setState(() => _designs = designs);
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
  }

  Future<void> _saveCurrent() async {
    final image = _image;
    if (image == null) return;

    final frame = await _currentFrame();
    if (frame == null || !mounted) return;

    final name = await askForName(
      context,
      title: 'Save design',
      initial: 'Image',
    );
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

  Future<void> _renameDesign(SavedDesign design) async {
    final name = await askForName(
      context,
      title: 'Rename',
      initial: design.name,
    );
    if (name == null) return;
    await _store.rename(design.id, name);
    await _reloadLibrary();
  }

  Future<void> _deleteDesign(SavedDesign design) async {
    if (!await confirmDelete(context, design.name)) return;
    await _store.delete(design.id);
    await _reloadLibrary();
  }

  // ----------------------------------------------------------------- write

  /// Captures the current design and waits for a panel. Writes at once if one is already there.
  Future<void> _arm() async {
    // Rendering happens before the session opens: the panel is powered by the phone's field, so
    // there is no reason to hold it open while we lay out text.
    final frame = await _currentFrame();
    if (frame == null || !mounted) return;

    setState(() {
      _armedFrame = frame;
      _error = null;
    });

    if (_panelPresent) _write();
  }

  void _disarm() => setState(() => _armedFrame = null);

  Future<void> _write() async {
    final frame = _armedFrame;
    if (frame == null || _writing) return;

    setState(() {
      _writing = true;
      _percent = 0;
      _error = null;
    });

    String? error;
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
    } on NfcFailure catch (e) {
      error = e.message;
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
      _error = error;
      // Success is shown on the button itself and then fades; only failures persist, because only
      // failures need you to do something about them.
      _succeeded = error == null;
      // A finished write disarms either way; a retry re-arms deliberately.
      _armedFrame = null;
    });

    _successTimer?.cancel();
    if (error == null) {
      _successTimer = Timer(const Duration(seconds: 4), () {
        if (mounted) setState(() => _succeeded = false);
      });
    }
  }

  // ------------------------------------------------------------------- ui

  @override
  Widget build(BuildContext context) {
    // No app bar: the title said nothing the user didn't already know, and the panel preview wants
    // every vertical pixel it can get.
    return Scaffold(
      body: Stack(
        children: [
          SafeArea(child: _body(context)),

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
                ? WriteOverlay(
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

  Widget _body(BuildContext context) {
    final adapter = _adapter;

    return Column(
      children: [
        // The tabs sit outside the scroll view so they stay put — they're navigation, and
        // navigation that scrolls away leaves you unsure where you are.
        if (adapter != null && !adapter.enabled)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: InfoBanner(
              'NFC is off. Turn it on in Settings.',
              Colors.red,
            ),
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
            padding: const EdgeInsets.all(16),
            children: [
              switch (_tab) {
                AppTab.settings => SizedBox(
                  height: 460,
                  child: SettingsView(
                    device: _device,
                    onDeviceChanged: _changeDevice,
                  ),
                ),
                AppTab.saved => SizedBox(
                  height: 340,
                  child: LibraryView(
                    device: _device,
                    designs: _designs,
                    onOpen: _openDesign,
                    onRename: _renameDesign,
                    onDelete: _deleteDesign,
                  ),
                ),
                AppTab.text || AppTab.image => _composer(),
              },

              // Nothing to write from the Saved or Settings tabs — tapping a saved design opens it
              // in Image, and that's where it gets sent from.
              if (_composes) ...[
                const Divider(height: 24),
                WriteButton(
                  succeeded: _succeeded,
                  enabled: _hasSomethingToWrite,
                  onArm: _arm,
                ),
                if (_error case final error?) ...[
                  const SizedBox(height: 12),
                  InfoBanner(error, Colors.red),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _writing ? null : _arm,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Try again'),
                  ),
                ],
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// The preview and the controls for whichever composing tab is active.
  Widget _composer() {
    final image = _image;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The panel is tall and narrow, so cap the preview's height rather than letting it eat
        // the screen.
        Center(
          child: SizedBox(
            height: 280,
            child: DecoratedBox(
              // A dark hairline plus a drop shadow, so the edge stays visible even when the frame
              // itself is white right up to the border.
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
              child: switch ((_tab, image)) {
                (AppTab.image, final picked?) => CropView(
                  content: picked,
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

        if (_tab == AppTab.image)
          ImageEditor(
            content: image,
            picking: _picking,
            busy: _writing,
            onPick: _pickImage,
            onChanged: (c) => setState(() => _image = c),
            onSave: _saveCurrent,
          )
        else
          TextEditor(
            device: _device,
            controller: _textController,
            content: _content,
            onChanged: (c) => setState(() => _content = c),
          ),
      ],
    );
  }
}
