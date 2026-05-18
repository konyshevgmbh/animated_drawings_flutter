import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../annotation/char_cfg.dart';
import '../retarget/config_models.dart';
import 'animation_page.dart';
import 'annotation_page.dart';

const _motions = [
  ('dab',           'assets/config/motion/dab.yaml',          'assets/config/retarget/fair1_ppf.yaml'),
  ('wave_hello',    'assets/config/motion/wave_hello.yaml',    'assets/config/retarget/fair1_ppf.yaml'),
  ('jumping',       'assets/config/motion/jumping.yaml',       'assets/config/retarget/fair1_ppf.yaml'),
  ('zombie',        'assets/config/motion/zombie.yaml',        'assets/config/retarget/fair1_ppf.yaml'),
  ('jesse_dance',   'assets/config/motion/jesse_dance.yaml',   'assets/config/retarget/mixamo_fff.yaml'),
  ('jumping_jacks', 'assets/config/motion/jumping_jacks.yaml', 'assets/config/retarget/cmu1_pfp.yaml'),
];

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
            if (!kIsWeb) ...[
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
          ],
        ),
      ),
    );
  }

  Future<void> _pickImage(BuildContext context) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      withData: true, // always load bytes (required on web)
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    if (!context.mounted) return;

    if (kIsWeb) {
      final bytes = file.bytes;
      if (bytes == null) return;
      Navigator.push(context,
          MaterialPageRoute(builder: (_) => AnnotationPage(imageBytes: bytes)));
    } else {
      final path = file.path;
      if (path == null) return;
      Navigator.push(context,
          MaterialPageRoute(builder: (_) => AnnotationPage(imagePath: path)));
    }
  }

  /// Loads a pre-annotated folder (native only).
  Future<void> _loadAnnotationFolder(BuildContext context) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['yaml', 'yml'],
      dialogTitle: 'Select char_cfg.yaml from annotation folder',
      withData: false,
    );
    if (result == null || result.files.isEmpty) return;
    final cfgPath = result.files.first.path;
    if (cfgPath == null) return;

    final folder = File(cfgPath).parent.path;
    final sep = Platform.pathSeparator;
    final texturePath = '$folder${sep}texture.png';
    final maskPath = '$folder${sep}mask.png';

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

    if (!context.mounted) return;
    final motionIdx = await _pickMotionDialog(context);
    if (motionIdx == null) return;

    final (_, motionAsset, retargetAsset) = _motions[motionIdx];
    final motionYaml = await rootBundle.loadString(motionAsset);
    final retargetYaml = await rootBundle.loadString(retargetAsset);
    final motionCfg = MotionConfig.fromYamlString(motionYaml, 'assets');
    final retargetCfg = RetargetConfig.fromYamlString(retargetYaml);

    // Read texture and mask as bytes for AnimationPage
    final textureBytes = await File(texturePath).readAsBytes();
    final maskBytes = await File(maskPath).readAsBytes();

    if (!context.mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AnimationPage(
          charCfg: charCfg,
          textureBytes: textureBytes,
          maskBytes: maskBytes,
          motionCfg: motionCfg,
          retargetCfg: retargetCfg,
        ),
      ),
    );
  }
}

Future<int?> _pickMotionDialog(BuildContext context) {
  int selected = 0;
  return showDialog<int>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('Select motion'),
        content: RadioGroup<int>(
          groupValue: selected,
          onChanged: (v) => setState(() => selected = v!),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(_motions.length, (i) => RadioListTile<int>(
              title: Text(_motions[i].$1),
              value: i,
            )),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, selected), child: const Text('OK')),
        ],
      ),
    ),
  );
}
