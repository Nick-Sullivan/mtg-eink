import 'package:flutter/material.dart';

/// A tinted strip of text — a warning, an error, or a confirmation.
class InfoBanner extends StatelessWidget {
  const InfoBanner(this.text, this.color, {super.key});

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
