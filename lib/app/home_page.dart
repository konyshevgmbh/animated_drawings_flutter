import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../annotation/char_cfg.dart';
import '../retarget/config_models.dart';
import 'animation_page.dart';
import 'annotation_page.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Animated Drawings')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Pick a drawing to animate', style: TextStyle(fontSize: 18)),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              icon: const Icon(Icons.image),
              label: const Text('Choose Image'),
              onPressed: () => _pickImage(context),
            ),
            const SizedBox(height: 16),
            const Divider(indent: 40, endIndent: 40),
            const SizedBox(height: 8),
            const Text('— or load pre-annotated folder —',
                style: TextStyle(color: Colors.grey)),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.folder_open),
              label: const Text('Load annotation folder'),
              onPressed: () => _loadAnnotationFolder(context),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickImage(BuildContext context) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.first.path;
    if (path == null) return;
    if (!context.mounted) return;
    Navigator.push(context,
        MaterialPageRoute(builder: (_) => AnnotationPage(imagePath: path)));
  }

  /// Loads an annotation folder that already contains:
  ///   texture.png, mask.png, char_cfg.yaml
  /// Skips Flutter segmentation / pose — uses Python outputs directly.
  Future<void> _loadAnnotationFolder(BuildContext context) async {
    // Let user pick the char_cfg.yaml to locate the folder
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['yaml', 'yml'],
      dialogTitle: 'Select char_cfg.yaml from annotation folder',
    );
    if (result == null || result.files.isEmpty) return;
    final cfgPath = result.files.first.path;
    if (cfgPath == null) return;

    final folder = File(cfgPath).parent.path;
    final texturePath = '$folder${Platform.pathSeparator}texture.png';
    final maskPath = '$folder${Platform.pathSeparator}mask.png';

    if (!File(texturePath).existsSync() || !File(maskPath).existsSync()) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('texture.png or mask.png not found in folder')),
      );
      return;
    }

    final charCfgYaml = await File(cfgPath).readAsString();
    CharConfig charCfg;
    try {
      charCfg = CharConfig.fromYamlString(charCfgYaml);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to parse char_cfg.yaml: $e')),
      );
      return;
    }

    // Default motion: dab + fair1_ppf
    final motionYaml = await rootBundle.loadString('assets/config/motion/dab.yaml');
    final retargetYaml = await rootBundle.loadString('assets/config/retarget/fair1_ppf.yaml');
    final motionCfg = MotionConfig.fromYamlString(motionYaml, 'assets');
    final retargetCfg = RetargetConfig.fromYamlString(retargetYaml);

    if (!context.mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AnimationPage(
          charCfg: charCfg,
          texturePath: texturePath,
          maskPath: maskPath,
          motionCfg: motionCfg,
          retargetCfg: retargetCfg,
        ),
      ),
    );
  }
}
