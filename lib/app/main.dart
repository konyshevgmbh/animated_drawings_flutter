import 'package:flutter/material.dart';
import 'annotation_page.dart';

void main() {
  runApp(const AnimatedDrawingsApp());
}

class AnimatedDrawingsApp extends StatelessWidget {
  const AnimatedDrawingsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Animated Drawings',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const AnnotationPage(),
    );
  }
}
