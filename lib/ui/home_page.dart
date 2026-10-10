import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:epaper_nfc/epaper_nfc.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/saved_design.dart';
import '../models/token_content.dart';
import '../render/canvas_painter.dart';
import '../render/image_content.dart';
import '../render/quantiser.dart';
import '../render/token_painter.dart';
import '../services/design_store.dart';
import '../services/haptics.dart';
import '../services/settings_store.dart';
import 'crop_view.dart';
import 'image_editor.dart';
import 'library_view.dart';
import 'settings_view.dart';
import 'text_editor.dart';
import 'token_editor.dart';
import 'token_preview.dart';
import 'widgets/info_banner.dart';
import 'widgets/name_dialog.dart';
import 'widgets/write_button.dart';

/// The app's top-level tabs.
enum AppTab { text, image, token, saved, settings }

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

  final _channel = NfcSession();
  final _haptics = Haptics();
  final _textController = TextEditingController(text: 'HELLO');
  final _store = DesignStore();
  final _settings = SettingsStore();

  AppTab _tab = AppTab.text;
  /// The panel being composed for. Remembered, so the app opens on whichever was last in use —
  /// picked in Settings or detected.
  PanelDevice _device = PanelDevice.waveshare29G;
  late PanelContent _content = PanelContent.forDevice(_device, text: 'HELLO');
  ImageContent? _image;
  TokenContent _token = const TokenContent();

  /// A picture in the token's art box, framed to it. Overrides the token's preset art.
  ImageContent? _tokenPicture;
  List<SavedDesign> _designs = const [];

  TagDetected? _tag;
  TagLost? _lost;
  AdapterState? _adapter;

  bool _picking = false;
  bool _writing = false;

  /// Mid-write on the 4.2", still finding out whether this spot can power a refresh.
  bool _checkingSpot = false;

  int _percent = 0;
  String? _error;

  /// Coaching shown on the write overlay: mid-write when the refresh hasn't started and the panel
  /// needs moving, or while waiting when a write is to be retried on the next placement.
  String? _retryNotice;

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
  bool get _composes =>
      _tab == AppTab.text || _tab == AppTab.image || _tab == AppTab.token;

  /// Whether there's something ready to send right now.
  bool get _hasSomethingToWrite => switch (_tab) {
    AppTab.text || AppTab.token => true,
    AppTab.image => _image != null,
    // The library is a browser — tapping a design opens it in its own tab, and it's sent from there.
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
    _loadLastDevice();
  }

  Future<void> _loadLastDevice() async {
    final id = await _settings.lastPanelId();
    final saved = PanelDevice.supported.where((d) => d.id == id).firstOrNull;
    if (saved == null || !mounted) return;
    // Unless a panel was already detected, or a write begun, in the moment that took.
    if (_device == PanelDevice.waveshare29G && _tag == null && !_armed) {
      _changeDevice(saved);
    }
  }

  @override
  void dispose() {
    _successTimer?.cancel();
    _tabs.dispose();
    _textController.dispose();
    _image?.source.dispose();
    _tokenPicture?.source.dispose();
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
    if (event is TagDetected) {
      final detected = PanelDevice.forAts(event.ats);
      if (detected != null && detected != _device && !_writing) {
        _switchToDetected(detected, event);
        return;
      }
    }

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
          } else if (_writing) {
            // Back already, while the last attempt is still closing. Pick it up when that's done.
            _arrivedWhileWriting = true;
          }
        case TagLost():
          _lost = event;
        case TagHeld():
        case WriteProgress():
          break;
      }
    });
  }

  /// A different kind of panel arrived: follow it rather than writing a frame of the wrong shape.
  ///
  /// An armed frame was rendered for the old panel, so it's rendered again for this one — the
  /// composition itself (text, token, picture) carries over, and the write goes ahead as intended.
  void _switchToDetected(PanelDevice detected, TagDetected event) {
    final wasArmed = _armed;
    _changeDevice(detected);
    setState(() {
      _tag = event;
      _lost = null;
      _armedFrame = null;
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('${detected.name} detected')));
    if (wasArmed) _arm();
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
      case AppTab.token:
        return renderTokenFrame(_device, _token, picture: _tokenPicture);
      case AppTab.saved:
      case AppTab.settings:
        return null;
    }
  }

  /// Switching panel keeps what you were composing but resets what's tied to the old panel: text
  /// colours go back to the new panel's own paper and pen, and a picture is re-framed to fill the
  /// new canvas — its pan and zoom were measured in the old one's pixels.
  void _changeDevice(PanelDevice device) {
    if (device != _device) _settings.setLastPanelId(device.id);
    setState(() {
      _device = device;
      _content = PanelContent.forDevice(
        device,
        text: _content.text,
        landscape: _content.landscape,
      );
      _image = _image?.reframed(device: device).recentred();
      _tokenPicture = _fittedToArtBox(_tokenPicture);
    });
  }

  /// [picture] reframed to the token's art box on the current panel, if it isn't already.
  ///
  /// The box changes height as ability text comes and goes, and shape with the panel. Reframing
  /// keeps the zoom and whatever was centred, so the picture doesn't jump about as you type.
  ImageContent? _fittedToArtBox(ImageContent? picture) {
    if (picture == null) return null;
    final box = tokenArtBox(_device, _token);
    if (picture.device == _device && picture.box == box) return picture;
    return picture.reframed(device: _device, box: () => box);
  }

  void _setToken(TokenContent token) => setState(() {
    _token = token;
    _tokenPicture = _fittedToArtBox(_tokenPicture);
  });

  /// Replaces the token's picture, disposing whatever it displaces. Null removes it.
  void _setTokenPicture(ImageContent? picture) {
    if (identical(picture, _tokenPicture)) return;
    setState(() {
      if (picture?.source != _tokenPicture?.source) {
        _tokenPicture?.source.dispose();
      }
      _tokenPicture = picture;
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

  /// Picks a picture from the gallery and decodes it. Null if nothing was picked, or this page went
  /// away meanwhile.
  Future<({Uint8List bytes, ui.Image decoded})?> _pickPicture() async {
    setState(() => _picking = true);
    try {
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (picked == null) return null;

      final bytes = await picked.readAsBytes();
      final decoded = await _decodeBounded(bytes);

      if (!mounted) {
        decoded.dispose();
        return null;
      }
      return (bytes: bytes, decoded: decoded);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _pickImage() async {
    final picked = await _pickPicture();
    if (picked == null) return;
    _setImage(
      ImageContent(device: _device, source: picked.decoded, bytes: picked.bytes),
    );
  }

  Future<void> _pickTokenPicture() async {
    final picked = await _pickPicture();
    if (picked == null) return;
    _setTokenPicture(
      ImageContent(
        device: _device,
        source: picked.decoded,
        bytes: picked.bytes,
        box: tokenArtBox(_device, _token),
      ).recentred(),
    );
  }

  // --------------------------------------------------------------- library

  Future<void> _reloadLibrary() async {
    final designs = await _store.load();
    if (!mounted) return;
    setState(() => _designs = designs);
  }

  /// Opens a saved design in the tab it was made in.
  ///
  /// The stored frame is only a cache. An image reopens from its source, so the crop, zoom and
  /// dither style are all still adjustable and nothing is quantised twice; a token reopens from its
  /// fields, so it's editable rather than a flat picture.
  Future<void> _openDesign(SavedDesign design) async {
    if (design.token case final token?) {
      await _openToken(design, token);
      return;
    }

    final settings = design.settings;
    final source = await _store.readSource(design.id);
    if (!mounted) return;

    if (source == null || settings == null) {
      // Saved before sources were kept: the flattened frame is all there is. It can still be
      // re-sent, but re-cropping it would be quantising an already-quantised picture — and it can
      // only go back to the panel it was packed for.
      if (design.deviceId != _device.id) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'This design was saved for the '
              '${PanelDevice.byId(design.deviceId).name} and can only be sent to that panel.',
            ),
          ),
        );
        return;
      }
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
    // The saved framing is in the original panel's canvas pixels; on another panel, start centred.
    final sameDevice = design.deviceId == _device.id;
    _setImage(
      ImageContent(
        device: _device,
        source: decoded,
        bytes: source,
        offset: settings.offset,
        scale: settings.scale,
        style: settings.style,
        landscape: settings.landscape,
      ),
      recentre: !sameDevice,
    );
  }

  /// Opens a saved token in the MTG tab, with its picture if it had one.
  Future<void> _openToken(SavedDesign design, TokenContent token) async {
    ImageContent? picture;
    final settings = design.settings;
    if (design.hasSource && settings != null) {
      final source = await _store.readSource(design.id);
      if (!mounted) return;
      if (source != null) {
        final decoded = await _decodeBounded(source);
        if (!mounted) {
          decoded.dispose();
          return;
        }
        picture = ImageContent(
          device: _device,
          source: decoded,
          bytes: source,
          offset: settings.offset,
          scale: settings.scale,
          style: settings.style,
          box: tokenArtBox(_device, token),
        );
        // The saved framing is in the original panel's art box; on another panel, start centred.
        if (design.deviceId != _device.id) picture = picture.recentred();
      }
    }

    setState(() {
      _token = token;
      _tab = AppTab.token;
    });
    _setTokenPicture(picture);
    _tabs.animateTo(AppTab.token.index);
  }

  /// Saves whatever the active tab is composing — an image or a token.
  Future<void> _saveCurrent() async {
    final image = _image;
    final token = _token;
    final picture = _tokenPicture;
    if (_tab == AppTab.image && image == null) return;

    final frame = await _currentFrame();
    if (frame == null || !mounted) return;

    final name = await askForName(
      context,
      title: 'Save design',
      initial: _tab == AppTab.token
          ? (token.name.trim().isEmpty ? 'Token' : token.name)
          : 'Image',
    );
    if (name == null || !mounted) return;

    // Grab the messenger before the awaits, so the confirmation doesn't depend on this widget's
    // context still being valid afterwards.
    final messenger = ScaffoldMessenger.of(context);
    if (_tab == AppTab.token) {
      await _store.saveToken(
        name: name,
        deviceId: _device.id,
        frame: frame,
        token: token,
        source: picture?.bytes,
        settings: picture == null
            ? null
            : ImageSettings(
                offset: picture.offset,
                scale: picture.scale,
                style: picture.style,
              ),
      );
    } else {
      await _store.save(
        name: name,
        deviceId: _device.id,
        frame: frame,
        source: image!.bytes,
        settings: ImageSettings(
          offset: image.offset,
          scale: image.scale,
          style: image.style,
          landscape: image.landscape,
        ),
      );
    }
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
      _retryNotice = null;
    });

    if (_panelPresent) _write();
  }

  /// Moving the panel around near the phone has never rescued a write; lifting it away and bringing
  /// it back — a fresh power-up — always has. So that's the only thing ever asked for.
  static const _liftNotice =
      'Not a good spot. Lift the panel away and bring it back, about a centimetre from the phone.';

  /// Set when the panel is detected again before the previous attempt has finished closing.
  bool _arrivedWhileWriting = false;

  void _disarm() => setState(() {
    _armedFrame = null;
    _retryNotice = null;
  });

  Future<void> _write() async {
    final frame = _armedFrame;
    if (frame == null || _writing) return;

    setState(() {
      _writing = true;
      _arrivedWhileWriting = false;
      _percent = 0;
      _error = null;
      // The 4.2" first proves the spot can power a refresh; until then there's no write to time.
      _checkingSpot = _device.protocol == PanelProtocol.rev22;
      if (_checkingSpot) _retryNotice = null;
    });

    String? error;
    var refreshFailed = false;
    var lost = false;
    try {
      await _channel.open();
      await writeToPanel(
        _channel,
        _device,
        frame,
        onProgress: (p) {
          if (mounted) setState(() => _percent = p);
        },
        // The spot can power a refresh: say so now, before the upload, so it's held still.
        onSpotFound: () {
          if (mounted) {
            // "Hold still" with the time follows on its own; nothing else needs saying.
            setState(() {
              _checkingSpot = false;
              _retryNotice = null;
            });
          }
        },
      );
    } on RefreshNotStarted catch (e) {
      error = e.message;
      refreshFailed = true;
    } on PanelLost {
      error = 'Lost the panel.';
      lost = true;
    } on NfcFailure catch (e) {
      error = e.message;
    } finally {
      try {
        await _channel.close();
      } on NfcFailure {
        // The write's own outcome matters more than failing to hand the tag back.
      }
    }

    // Both are "try again": stay armed, so bringing the panel back starts the write from the top.
    // A bad spot buzzes once, a finished write twice.
    final retry = refreshFailed || lost;
    if (refreshFailed) _haptics.buzz();
    if (error == null) _haptics.buzz(pulses: 2);

    if (!mounted) return;
    setState(() {
      _writing = false;
      _checkingSpot = false;
      _error = retry ? null : error;
      _retryNotice = lost
          ? 'Lost the panel. Lift it away and bring it back.'
          : refreshFailed
          ? _liftNotice
          : null;
      // Success is shown on the button itself and then fades; only failures persist, because only
      // failures need you to do something about them.
      _succeeded = error == null;
      // A finished write disarms either way, unless the panel just needs placing again.
      if (!retry) _armedFrame = null;
    });
    // The panel came back while that attempt was still closing; its arrival was the cue to go again.
    if (retry && _arrivedWhileWriting && _panelPresent) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _write());
    }

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
                    checking: _checkingSpot,
                    percent: _percent,
                    holdFor: _device.typicalWrite,
                    notice: _retryNotice,
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
              // Five tabs across a phone leave ~79dp each; the default 16dp side padding clipped
              // "Settings".
              labelPadding: const EdgeInsets.symmetric(horizontal: 4),
              tabs: const [
                Tab(icon: Icon(Icons.title), text: 'Text'),
                Tab(icon: Icon(Icons.image_outlined), text: 'Image'),
                Tab(icon: Icon(Icons.style_outlined), text: 'MTG'),
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
                  // Tall enough for the credits, which the art's licence requires be shown.
                  height: 560,
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
                AppTab.text || AppTab.image || AppTab.token => _composer(),
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
        // the screen. A cap rather than a fixed height: on its side, the panel is limited by the
        // screen's width instead, and a fixed height would stretch it past that.
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 280),
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
                (AppTab.image, null) => AspectRatio(
                  aspectRatio: _device.size.width / _device.size.height,
                  child: const Center(
                    child: Text(
                      'No image picked',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.black45),
                    ),
                  ),
                ),
                (AppTab.token, _) => TokenPreview(
                  device: _device,
                  token: _token,
                  picture: _tokenPicture,
                ),
                _ => PanelPreview(device: _device, content: _content),
              },
            ),
          ),
        ),
        const SizedBox(height: 20),

        switch (_tab) {
          AppTab.image => ImageEditor(
            content: image,
            picking: _picking,
            busy: _writing,
            onPick: _pickImage,
            onChanged: (c) => setState(() => _image = c),
            onSave: _saveCurrent,
          ),
          AppTab.token => TokenEditor(
            content: _token,
            onChanged: _setToken,
            picture: _tokenPicture,
            picking: _picking,
            onPickPicture: _pickTokenPicture,
            onPictureChanged: _setTokenPicture,
            busy: _writing,
            onSave: _saveCurrent,
          ),
          _ => TextEditor(
            device: _device,
            controller: _textController,
            content: _content,
            onChanged: (c) => setState(() => _content = c),
          ),
        },
      ],
    );
  }
}
