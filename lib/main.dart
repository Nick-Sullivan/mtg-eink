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
      ),
      home: const HomePage(),
    );
  }
}
