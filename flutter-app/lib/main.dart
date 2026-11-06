import 'package:flutter/material.dart';

void main() {
  runApp(const LightMusicApp());
}

class LightMusicApp extends StatelessWidget {
  const LightMusicApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '流光音乐',
      debugShowCheckedModeBanner: false,
      home: const Scaffold(
        body: Center(child: Text('流光音乐 · M1 骨架')),
      ),
    );
  }
}
