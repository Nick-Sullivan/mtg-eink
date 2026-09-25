import 'package:flutter/material.dart';

import 'ui/home_page.dart';

void main() => runApp(const NfcEinkApp());

class NfcEinkApp extends StatelessWidget {
  const NfcEinkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'nfc-eink',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
        // A grey ground, so the panel preview reads as an object sitting on the page. Against a
        // white app background a mostly-white frame has no visible edge at all.
        scaffoldBackgroundColor: const Color(0xFFDDDCD8),
      ),
      home: const HomePage(),
    );
  }
}
