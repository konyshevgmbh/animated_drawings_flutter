import 'dart:io';
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../annotation/char_cfg.dart';
import '../annotation/pose_onnx.dart';
import '../annotation/segmentation.dart';
import '../retarget/config_models.dart';
import 'animation_page.dart';

const _motions = [
  ('dab', 'assets/config/motion/dab.yaml', 'assets/config/retarget/fair1_ppf.yaml'),
  ('wave_hello', 'assets/config/motion/wave_hello.yaml', 'assets/config/retarget/fair1_ppf.yaml'),
  ('jumping', 'assets/config/motion/jumping.yaml', 'assets/config/retarget/fair1_ppf.yaml'),
  ('zombie', 'assets/config/motion/zombie.yaml', 'assets/config/retarget/fair1_ppf.yaml'),
  ('jesse_dance', 'assets/config/motion/jesse_dance.yaml', 'assets/config/retarget/fair1_ppf.yaml'),
  ('jumping_jacks', 'assets/config/motion/jumping_jacks.yaml', 'assets/config/retarget/cmu1_pfp.yaml'),
];

class AnnotationPage extends StatefulWidget {
  final String imagePath;
  const AnnotationPage({super.key, required this.imagePath});

  @override
  State<AnnotationPage> createState() => _AnnotationPageState();
}

class _AnnotationPageState extends State<AnnotationPage> {
  bool _loading = true;
  String _status = 'Loading image…';
  double _progress = 0.0;
  Uint8List? _overlayBytes;
  String? _texturePath;
  String? _maskPath;
  CharConfig? _charCfg;
  int _selectedMotion = 0;

  PoseEstimator? _estimator;

  @override
  void initState() {
    super.initState();
    _runAnnotation();
  }

  @override
  void dispose() {
    _estimator?.dispose();
    super.dispose();
  }

  Future<void> _runAnnotation() async {
    final tmpDir = await getTemporaryDirectory();
    final outDir = '${tmpDir.path}/annotation_out';
    await Directory(outDir).create(recursive: true);
    final imagePath = widget.imagePath;

    try {
      // ── Step 1: segmentation in isolate (pure Dart, no plugin) ──────────
      _setStatus('Segmenting…', progress: 0.05);
      final port = ReceivePort();
      await Isolate.spawn(_segmentIsolate, [imagePath, outDir, port.sendPort]);

      late final _SegResult segResult;
      await for (final msg in port) {
        if (msg is String && msg.startsWith('status:')) {
          final label = msg.substring(7);
          final p = label.contains('Segment') ? 0.20 : 0.05;
          _setStatus(label, progress: p);
        } else if (msg is _SegResult) {
          segResult = msg;
          port.close();
          break;
        } else if (msg is Exception) {
          throw msg;
        }
      }

      debugPrint('[Ann] segmentation done  ${segResult.w}×${segResult.h}  mask=${segResult.maskPath}');

      // ── Step 2: pose estimation on main isolate (ONNX needs plugin ctx) ──
      _setStatus('Loading ONNX model…', progress: 0.50);
      _estimator = PoseEstimator();
      await _estimator!.init();
      debugPrint('[Ann] ONNX session ready');

      _setStatus('Estimating pose…', progress: 0.60);
      final imageBytes = await File(segResult.texturePath).readAsBytes();
      final image = img.decodeImage(imageBytes)!;
      final maskBytes = await File(segResult.maskPath).readAsBytes();
      final maskImage = img.decodeImage(maskBytes);
      final kpts = await _estimator!.estimate(image, mask: maskImage, straightenLegs: true);
      debugPrint('[Ann] ONNX result: ${kpts == null ? "no pose found" : "${kpts.length} keypoints"}');

      // ── Step 3: build skeleton ──────────────────────────────────────────
      _setStatus('Building skeleton…', progress: 0.80);
      final skeleton = kpts != null
          ? buildSkeleton(kpts)
          : defaultSkeleton(segResult.h, segResult.w);
      debugPrint('[Ann] skeleton source: ${kpts != null ? "ONNX" : "default fallback"}');

      final charCfg = CharConfig(
          height: segResult.h, width: segResult.w, skeleton: skeleton);
      final charCfgYaml = charCfg.toYamlString();
      await File('$outDir/char_cfg.yaml').writeAsString(charCfgYaml);

      // ── Step 4: draw joint overlay ──────────────────────────────────────
      _setStatus('Drawing overlay…', progress: 0.90);
      final overlay = img.Image.from(image);
      for (final j in skeleton) {
        final x = j.x.round().clamp(0, segResult.w - 1);
        final y = j.y.round().clamp(0, segResult.h - 1);
        img.fillCircle(overlay,
            x: x, y: y, radius: 5, color: img.ColorRgba8(255, 0, 0, 255));
        if (j.parent != null) {
          final par = skeleton.firstWhere((s) => s.name == j.parent);
          img.drawLine(overlay,
              x1: par.x.round().clamp(0, segResult.w - 1),
              y1: par.y.round().clamp(0, segResult.h - 1),
              x2: x, y2: y,
              color: img.ColorRgba8(0, 255, 0, 180));
        }
      }
      final overlayBytes = Uint8List.fromList(img.encodePng(overlay));

      if (mounted) {
        setState(() {
          _charCfg = charCfg;
          _overlayBytes = overlayBytes;
          _texturePath = segResult.texturePath;
          _maskPath = segResult.maskPath;
          _loading = false;
        });
      }
    } catch (e, st) {
      debugPrint('[Ann] ERROR: $e\n$st');
      if (mounted) setState(() { _status = 'Error: $e'; _loading = false; });
    }
  }

  void _setStatus(String s, {double progress = -1}) {
    debugPrint('[Ann] status: $s');
    if (mounted) {
      setState(() {
        _status = s;
        if (progress >= 0) _progress = progress;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Annotation')),
      body: _loading ? _buildLoading() : _buildReady(),
    );
  }

  Widget _buildLoading() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _status,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: _progress > 0 ? _progress : null,
                minHeight: 8,
                borderRadius: BorderRadius.circular(4),
              ),
              const SizedBox(height: 6),
              if (_progress > 0)
                Text(
                  '${(_progress * 100).toStringAsFixed(0)}%',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              const SizedBox(height: 20),
              _AnnotationStepsList(progress: _progress),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildReady() {
    return Column(
      children: [
        if (_overlayBytes != null)
          Expanded(
              child: Image.memory(_overlayBytes!, fit: BoxFit.contain)),
        const Divider(),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              const Text('Select motion:'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: List.generate(_motions.length, (i) {
                  return ChoiceChip(
                    label: Text(_motions[i].$1),
                    selected: _selectedMotion == i,
                    onSelected: (_) =>
                        setState(() => _selectedMotion = i),
                  );
                }),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                icon: const Icon(Icons.play_arrow),
                label: const Text('Animate'),
                onPressed: _onAnimate,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _onAnimate() async {
    if (_charCfg == null || _texturePath == null || _maskPath == null) return;
    final (_, motionAsset, retargetAsset) = _motions[_selectedMotion];

    final motionYaml = await rootBundle.loadString(motionAsset);
    final retargetYaml = await rootBundle.loadString(retargetAsset);

    final motionCfg = MotionConfig.fromYamlString(motionYaml, 'assets');
    final retargetCfg = RetargetConfig.fromYamlString(retargetYaml);

    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AnimationPage(
          charCfg: _charCfg!,
          texturePath: _texturePath!,
          maskPath: _maskPath!,
          motionCfg: motionCfg,
          retargetCfg: retargetCfg,
        ),
      ),
    );
  }
}

// ─── Annotation pipeline step checklist ───────────────────────────────────────

class _AnnotationStepsList extends StatelessWidget {
  final double progress;
  const _AnnotationStepsList({required this.progress});

  static const _steps = [
    (0.05, 'Load image'),
    (0.20, 'Segment (adaptive threshold + flood fill)'),
    (0.50, 'Load ONNX model'),
    (0.60, 'Estimate pose (YOLOv8n)'),
    (0.80, 'Build skeleton'),
    (0.90, 'Draw joint overlay'),
    (1.00, 'Done'),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: _steps.map((s) {
        final done = progress >= s.$1;
        final active = !done && progress >= (s.$1 - 0.15).clamp(0.0, 1.0);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              Icon(
                done
                    ? Icons.check_circle
                    : (active ? Icons.radio_button_checked : Icons.radio_button_unchecked),
                size: 18,
                color: done
                    ? Colors.green
                    : (active ? Theme.of(context).colorScheme.primary : Colors.grey),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  s.$2,
                  style: TextStyle(
                    color: done ? null : (active ? null : Colors.grey),
                    fontWeight: active ? FontWeight.bold : null,
                  ),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}

// ─── Isolate: segmentation only (no plugins) ───────────────────────────────

class _SegResult {
  final String maskPath;
  final String texturePath;
  final int w, h;
  _SegResult(this.maskPath, this.texturePath, this.w, this.h);
}

Future<void> _segmentIsolate(List<dynamic> args) async {
  final imagePath = args[0] as String;
  final outDir = args[1] as String;
  final sendPort = args[2] as SendPort;

  try {
    sendPort.send('status:Loading image…');
    final bytes = await File(imagePath).readAsBytes();
    var image = img.decodeImage(bytes);
    if (image == null) throw Exception('Cannot decode image');

    if (image.width > 1000 || image.height > 1000) {
      final scale =
          1000 / (image.width > image.height ? image.width : image.height);
      image = img.copyResize(image,
          width: (image.width * scale).round(),
          height: (image.height * scale).round());
    }

    final h = image.height;
    final w = image.width;

    sendPort.send('status:Segmenting…');
    final maskData = segmentImage(image);
    final maskImg = img.Image(width: w, height: h);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final v = maskData[y * w + x];
        maskImg.setPixelRgba(x, y, v, v, v, 255);
      }
    }
    final maskPath = '$outDir/mask.png';
    await File(maskPath).writeAsBytes(img.encodePng(maskImg));

    final rgba = img.Image(width: w, height: h, numChannels: 4);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final px = image.getPixel(x, y);
        rgba.setPixelRgba(x, y, px.r.toInt(), px.g.toInt(), px.b.toInt(), 255);
      }
    }
    final texturePath = '$outDir/texture.png';
    await File(texturePath).writeAsBytes(img.encodePng(rgba));

    sendPort.send(_SegResult(maskPath, texturePath, w, h));
  } catch (e) {
    sendPort.send(Exception(e.toString()));
  }
}
