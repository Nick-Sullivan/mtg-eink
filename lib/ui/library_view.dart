import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/saved_design.dart';
import '../models/panel_device.dart';
import '../render/image_content.dart';

/// The shelf of saved designs. Tap one to open it in the Image tab, ready to re-frame or re-send.
class LibraryView extends StatelessWidget {
  const LibraryView({
    required this.device,
    required this.designs,
    required this.onOpen,
    required this.onRename,
    required this.onDelete,
    super.key,
  });

  final PanelDevice device;
  final List<SavedDesign> designs;
  final ValueChanged<SavedDesign> onOpen;
  final ValueChanged<SavedDesign> onRename;
  final ValueChanged<SavedDesign> onDelete;

  @override
  Widget build(BuildContext context) {
    if (designs.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Nothing saved yet.\n\nCompose something in Text or Image and tap Save.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.black45),
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: designs.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final design = designs[index];

        return ListTile(
          leading: SizedBox(
            width: 34,
            height: 78,
            child: FrameThumbnail(device: device, frame: design.frame),
          ),
          title: Text(design.name),
          subtitle: Text(
            design.kind == DesignKind.token
                ? 'MTG token · ${_describe(design.createdAt)}'
                : _describe(design.createdAt),
          ),
          trailing: PopupMenuButton<String>(
            onSelected: (action) => switch (action) {
              'rename' => onRename(design),
              _ => onDelete(design),
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'rename', child: Text('Rename')),
              PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
          onTap: () => onOpen(design),
        );
      },
    );
  }

  static String _describe(DateTime when) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(when.year, when.month, when.day);
    final time =
        '${when.hour.toString().padLeft(2, '0')}:'
        '${when.minute.toString().padLeft(2, '0')}';

    if (day == today) return 'Today, $time';
    if (day == today.subtract(const Duration(days: 1))) {
      return 'Yesterday, $time';
    }
    return '${when.day}/${when.month}/${when.year}, $time';
  }
}

/// Draws a packed frame at whatever size it's given, in the panel's own inks.
///
/// Decoding is async, so the image is built once and held. [FilterQuality.none] matters: smoothing
/// a dithered frame turns it to mush and makes the thumbnail misrepresent the panel.
class FrameThumbnail extends StatefulWidget {
  const FrameThumbnail({required this.device, required this.frame, super.key});

  final PanelDevice device;
  final Uint8List frame;

  @override
  State<FrameThumbnail> createState() => _FrameThumbnailState();
}

class _FrameThumbnailState extends State<FrameThumbnail> {
  ui.Image? _image;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void didUpdateWidget(FrameThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.frame != widget.frame) _decode();
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  Future<void> _decode() async {
    final image = await decodeFrame(widget.device, widget.frame);
    if (!mounted) {
      image.dispose();
      return;
    }
    setState(() {
      _image?.dispose();
      _image = image;
    });
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    return DecoratedBox(
      // Same reasoning as the main preview: a mostly-white thumbnail needs a hard edge to read as
      // a panel rather than as a gap in the list.
      decoration: BoxDecoration(border: Border.all(color: Colors.black54)),
      child: image == null
          ? const SizedBox.expand()
          : CustomPaint(
              painter: _ThumbnailPainter(widget.device, image),
              size: Size.infinite,
            ),
    );
  }
}

class _ThumbnailPainter extends CustomPainter {
  const _ThumbnailPainter(this.device, this.image);

  final PanelDevice device;
  final ui.Image image;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, device.size.width, device.size.height),
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..filterQuality = FilterQuality.none,
    );
  }

  @override
  bool shouldRepaint(_ThumbnailPainter oldDelegate) =>
      oldDelegate.image != image;
}
