import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
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
  ('jesse_dance', 'assets/config/motion/jesse_dance.yaml', 'assets/config/retarget/mixamo_fff.yaml'),
  ('jumping_jacks', 'assets/config/motion/jumping_jacks.yaml', 'assets/config/retarget/cmu1_pfp.yaml'),
];

enum _EditMode { joints, mask }

class AnnotationPage extends StatefulWidget {
  final String? imagePath;       // set on native platforms
  final Uint8List? imageBytes;   // set on web (or when bytes are pre-loaded)

  const AnnotationPage({
    super.key,
    this.imagePath,
    this.imageBytes,
  }) : assert(imagePath != null || imageBytes != null,
              'Either imagePath or imageBytes must be provided');

  @override
  State<AnnotationPage> createState() => _AnnotationPageState();
}

class _AnnotationPageState extends State<AnnotationPage> {
  // Loading
  bool _loading = true;
  String _status = 'Loading image…';
  double _progress = 0.0;

  // Annotation results (always available after load)
  Uint8List? _textureBytes;
  String? _texturePath; // native only
  String? _maskPath;    // native only
  int _imgW = 0;
  int _imgH = 0;
  List<CharJoint> _skeleton = [];
  Uint8List _maskData = Uint8List(0);

  // Edit mode
  _EditMode _editMode = _EditMode.joints;

  // Joint editor
  int _selectedJointIdx = -1;
  int _jointVersion = 0;

  // Mask editor
  bool _maskEraseMode = false;
  double _brushSize = 20.0;
  int _maskVersion = 0;
  Offset? _brushCenter;

  // Layout
  Size _viewSize = Size.zero;
  int _selectedMotion = 0; // _motions.length → custom BVH

  // Custom BVH
  String? _customBvhContent;
  String _customBvhFileName = '';
  String _customBvhFormat = 'fair1'; // auto-detected: fair1 | cmu1 | cmu_una | rokoko

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

  // ── Transform ──────────────────────────────────────────────────────────────

  ({double scale, double ox, double oy}) _getTransform() {
    if (_imgW == 0 || _imgH == 0 || _viewSize.isEmpty) {
      return (scale: 1.0, ox: 0.0, oy: 0.0);
    }
    final s = math.min(_viewSize.width / _imgW, _viewSize.height / _imgH);
    return (
      scale: s,
      ox: (_viewSize.width - _imgW * s) / 2,
      oy: (_viewSize.height - _imgH * s) / 2,
    );
  }

  Offset _toImageCoords(Offset w) {
    final t = _getTransform();
    return Offset((w.dx - t.ox) / t.scale, (w.dy - t.oy) / t.scale);
  }

  // ── Annotation pipeline ────────────────────────────────────────────────────

  Future<void> _runAnnotation() async {
    try {
      if (kIsWeb) {
        await _runAnnotationWeb();
      } else {
        await _runAnnotationNative();
      }
    } catch (e, st) {
      debugPrint('[Ann] ERROR: $e\n$st');
      if (mounted) setState(() { _status = 'Error: $e'; _loading = false; });
    }
  }

  // Web: everything on main thread, no dart:io file I/O
  Future<void> _runAnnotationWeb() async {
    _setStatus('Decoding image…', progress: 0.05);

    final rawBytes = widget.imageBytes!;
    var image = img.decodeImage(rawBytes);
    if (image == null) throw Exception('Cannot decode image');

    if (image.width > 1000 || image.height > 1000) {
      final scale = 1000 / math.max(image.width, image.height);
      image = img.copyResize(image,
          width: (image.width * scale).round(),
          height: (image.height * scale).round());
    }

    final h = image.height;
    final w = image.width;

    _setStatus('Segmenting…', progress: 0.20);
    final maskDataRaw = segmentImage(image);

    // Build RGBA texture image
    final rgba = img.Image(width: w, height: h, numChannels: 4);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final px = image.getPixel(x, y);
        rgba.setPixelRgba(x, y, px.r.toInt(), px.g.toInt(), px.b.toInt(), 255);
      }
    }

    // Build mask image for pose estimation
    final maskImgRaw = img.Image(width: w, height: h);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final v = maskDataRaw[y * w + x];
        maskImgRaw.setPixelRgba(x, y, v, v, v, 255);
      }
    }

    _setStatus('Loading ONNX model…', progress: 0.50);
    _estimator = PoseEstimator();
    await _estimator!.init();

    _setStatus('Estimating pose…', progress: 0.60);
    final kpts = await _estimator!.estimate(rgba, mask: maskImgRaw, straightenLegs: true);

    _setStatus('Building skeleton…', progress: 0.80);
    final skeleton = kpts != null ? buildSkeleton(kpts) : defaultSkeleton(h, w);

    _setStatus('Done', progress: 1.0);
    if (mounted) {
      setState(() {
        _textureBytes = Uint8List.fromList(img.encodePng(rgba));
        _imgW = w;
        _imgH = h;
        _skeleton = List<CharJoint>.from(skeleton);
        _maskData = maskDataRaw;
        _loading = false;
      });
    }
  }

  // Native: use isolate for segmentation, file I/O for temp storage
  Future<void> _runAnnotationNative() async {
    final tmpDir = await getTemporaryDirectory();
    final outDir = '${tmpDir.path}/annotation_out';
    await Directory(outDir).create(recursive: true);

    _setStatus('Segmenting…', progress: 0.05);
    final port = ReceivePort();
    await Isolate.spawn(_segmentIsolate, [widget.imagePath!, outDir, port.sendPort]);

    late final _SegResult segResult;
    await for (final msg in port) {
      if (msg is String && msg.startsWith('status:')) {
        _setStatus(msg.substring(7), progress: msg.contains('Segment') ? 0.20 : 0.05);
      } else if (msg is _SegResult) {
        segResult = msg;
        port.close();
        break;
      } else if (msg is Exception) {
        throw msg;
      }
    }

    _setStatus('Loading ONNX model…', progress: 0.50);
    _estimator = PoseEstimator();
    await _estimator!.init();

    _setStatus('Estimating pose…', progress: 0.60);
    final imageBytes = await File(segResult.texturePath).readAsBytes();
    final image = img.decodeImage(imageBytes)!;
    final maskBytes = await File(segResult.maskPath).readAsBytes();
    final maskImage = img.decodeImage(maskBytes);
    final kpts = await _estimator!.estimate(image, mask: maskImage, straightenLegs: true);

    _setStatus('Building skeleton…', progress: 0.80);
    final skeleton = kpts != null
        ? buildSkeleton(kpts)
        : defaultSkeleton(segResult.h, segResult.w);

    final maskRaw = Uint8List(segResult.w * segResult.h);
    if (maskImage != null) {
      for (int y = 0; y < segResult.h; y++) {
        for (int x = 0; x < segResult.w; x++) {
          maskRaw[y * segResult.w + x] = maskImage.getPixel(x, y).r.toInt();
        }
      }
    }

    _setStatus('Done', progress: 1.0);
    if (mounted) {
      setState(() {
        _textureBytes = imageBytes;
        _texturePath = segResult.texturePath;
        _maskPath = segResult.maskPath;
        _imgW = segResult.w;
        _imgH = segResult.h;
        _skeleton = List<CharJoint>.from(skeleton);
        _maskData = maskRaw;
        _loading = false;
      });
    }
  }

  void _setStatus(String s, {double progress = -1}) {
    if (mounted) setState(() { _status = s; if (progress >= 0) _progress = progress; });
  }

  // ── Gesture handlers ───────────────────────────────────────────────────────

  void _onPanStart(DragStartDetails d) {
    final imgPt = _toImageCoords(d.localPosition);
    if (_editMode == _EditMode.joints) {
      final hitR = 30.0 / _getTransform().scale;
      setState(() => _selectedJointIdx = _nearestJoint(imgPt, hitR));
    } else {
      setState(() => _brushCenter = imgPt);
      _applyBrush(imgPt);
    }
  }

  void _onPanUpdate(DragUpdateDetails d) {
    final imgPt = _toImageCoords(d.localPosition);
    if (_editMode == _EditMode.joints) {
      if (_selectedJointIdx >= 0) _moveJoint(_selectedJointIdx, imgPt);
    } else {
      setState(() => _brushCenter = imgPt);
      _applyBrush(imgPt);
    }
  }

  void _onPanEnd(DragEndDetails d) {
    if (_editMode == _EditMode.joints) {
      setState(() => _selectedJointIdx = -1);
    } else {
      setState(() => _brushCenter = null);
    }
  }

  int _nearestJoint(Offset imgPt, double maxDist) {
    int best = -1;
    double bestDist = maxDist;
    for (int i = 0; i < _skeleton.length; i++) {
      final j = _skeleton[i];
      final d = (Offset(j.x, j.y) - imgPt).distance;
      if (d < bestDist) { bestDist = d; best = i; }
    }
    return best;
  }

  void _moveJoint(int idx, Offset imgPt) {
    final j = _skeleton[idx];
    final updated = List<CharJoint>.from(_skeleton);
    updated[idx] = CharJoint(
      name: j.name,
      parent: j.parent,
      x: imgPt.dx.clamp(0.0, _imgW.toDouble()),
      y: imgPt.dy.clamp(0.0, _imgH.toDouble()),
    );
    setState(() { _skeleton = updated; _jointVersion++; });
  }

  void _applyBrush(Offset imgPt) {
    final r = _brushSize.round();
    final cx = imgPt.dx.round();
    final cy = imgPt.dy.round();
    final fill = _maskEraseMode ? 0 : 255;
    bool changed = false;
    for (int dy = -r; dy <= r; dy++) {
      for (int dx = -r; dx <= r; dx++) {
        if (dx * dx + dy * dy > r * r) continue;
        final nx = cx + dx; final ny = cy + dy;
        if (nx < 0 || nx >= _imgW || ny < 0 || ny >= _imgH) continue;
        final idx = ny * _imgW + nx;
        if (_maskData[idx] != fill) { _maskData[idx] = fill; changed = true; }
      }
    }
    if (changed) setState(() => _maskVersion++);
  }

  // ── Navigate to animation ──────────────────────────────────────────────────

  Future<void> _onAnimate() async {
    if (_skeleton.isEmpty || _textureBytes == null) return;

    final charCfg = CharConfig(height: _imgH, width: _imgW, skeleton: _skeleton);

    // Encode edited mask from _maskData to PNG bytes
    final maskImg = img.Image(width: _imgW, height: _imgH);
    for (int y = 0; y < _imgH; y++) {
      for (int x = 0; x < _imgW; x++) {
        final v = _maskData[y * _imgW + x];
        maskImg.setPixelRgba(x, y, v, v, v, 255);
      }
    }
    final maskBytes = Uint8List.fromList(img.encodePng(maskImg));

    // On native, also persist the edited mask back to the temp file
    if (!kIsWeb && _maskPath != null) {
      await File(_maskPath!).writeAsBytes(maskBytes);
    }

    MotionConfig motionCfg;
    RetargetConfig retargetCfg;

    if (_selectedMotion == _motions.length) {
      // Custom BVH
      if (_customBvhContent == null) return;
      motionCfg = MotionConfig.fromCustomBvh(
        bvhContent: _customBvhContent!,
        fileName: _customBvhFileName,
        format: _customBvhFormat,
      );
      const retargetMap = {
        'fair1':   'assets/config/retarget/fair1_ppf.yaml',
        'cmu1':    'assets/config/retarget/cmu1_pfp.yaml',
        'cmu_una': 'assets/config/retarget/cmu_una_pfp.yaml',
        'rokoko':  'assets/config/retarget/mixamo_fff.yaml',
      };
      final retargetYaml = await rootBundle.loadString(retargetMap[_customBvhFormat]!);
      retargetCfg = RetargetConfig.fromYamlString(retargetYaml);
    } else {
      final (_, motionAsset, retargetAsset) = _motions[_selectedMotion];
      final motionYaml = await rootBundle.loadString(motionAsset);
      final retargetYaml = await rootBundle.loadString(retargetAsset);
      motionCfg = MotionConfig.fromYamlString(motionYaml, 'assets');
      retargetCfg = RetargetConfig.fromYamlString(retargetYaml);
    }

    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AnimationPage(
          charCfg: charCfg,
          textureBytes: _textureBytes!,
          maskBytes: maskBytes,
          motionCfg: motionCfg,
          retargetCfg: retargetCfg,
        ),
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

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
              Text(_status,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge),
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: _progress > 0 ? _progress : null,
                minHeight: 8,
                borderRadius: BorderRadius.circular(4),
              ),
              const SizedBox(height: 6),
              if (_progress > 0)
                Text('${(_progress * 100).toStringAsFixed(0)}%',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 20),
              _AnnotationStepsList(progress: _progress, isWeb: kIsWeb),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildReady() {
    return Column(
      children: [
        _buildModeBar(),
        Expanded(
          child: LayoutBuilder(builder: (ctx, constraints) {
            _viewSize = constraints.biggest;
            return Stack(children: [
              Positioned.fill(
                child: Image.memory(_textureBytes!, fit: BoxFit.contain,
                    gaplessPlayback: true),
              ),
              Positioned.fill(
                child: GestureDetector(
                  onPanStart: _onPanStart,
                  onPanUpdate: _onPanUpdate,
                  onPanEnd: _onPanEnd,
                  child: _editMode == _EditMode.joints
                      ? CustomPaint(
                          painter: _JointPainter(
                            skeleton: _skeleton,
                            imgW: _imgW,
                            imgH: _imgH,
                            selectedIdx: _selectedJointIdx,
                            version: _jointVersion,
                          ),
                        )
                      : CustomPaint(
                          painter: _MaskPainter(
                            maskData: _maskData,
                            imgW: _imgW,
                            imgH: _imgH,
                            version: _maskVersion,
                            eraseMode: _maskEraseMode,
                            brushCenter: _brushCenter,
                            brushSize: _brushSize,
                          ),
                        ),
                ),
              ),
            ]);
          }),
        ),
        if (_editMode == _EditMode.mask) _buildMaskControls(),
        const Divider(height: 1),
        _buildMotionPanel(),
      ],
    );
  }

  Widget _buildModeBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: SegmentedButton<_EditMode>(
        segments: const [
          ButtonSegment(
            value: _EditMode.joints,
            label: Text('Joints'),
            icon: Icon(Icons.scatter_plot),
          ),
          ButtonSegment(
            value: _EditMode.mask,
            label: Text('Mask'),
            icon: Icon(Icons.brush),
          ),
        ],
        selected: {_editMode},
        onSelectionChanged: (s) => setState(() => _editMode = s.first),
      ),
    );
  }

  Widget _buildMaskControls() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Row(
        children: [
          ToggleButtons(
            isSelected: [!_maskEraseMode, _maskEraseMode],
            onPressed: (i) => setState(() => _maskEraseMode = i == 1),
            borderRadius: BorderRadius.circular(8),
            children: const [
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.brush, size: 16),
                  SizedBox(width: 4),
                  Text('Paint'),
                ]),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.auto_fix_normal, size: 16),
                  SizedBox(width: 4),
                  Text('Erase'),
                ]),
              ),
            ],
          ),
          const SizedBox(width: 8),
          const Icon(Icons.circle_outlined, size: 14),
          Expanded(
            child: Slider(
              value: _brushSize,
              min: 5,
              max: 60,
              divisions: 11,
              label: '${_brushSize.round()}px',
              onChanged: (v) => setState(() => _brushSize = v),
            ),
          ),
          SizedBox(
            width: 40,
            child: Text('${_brushSize.round()}px',
                style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }

  Widget _buildMotionPanel() {
    final isCustom = _selectedMotion == _motions.length;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Select motion:'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              ...List.generate(_motions.length, (i) => ChoiceChip(
                label: Text(_motions[i].$1),
                selected: _selectedMotion == i,
                onSelected: (_) => setState(() => _selectedMotion = i),
              )),
              ChoiceChip(
                label: Text(
                  isCustom && _customBvhContent != null
                      ? _customBvhFileName
                      : 'Custom BVH…',
                ),
                selected: isCustom,
                onSelected: (_) {
                  setState(() => _selectedMotion = _motions.length);
                  _pickCustomBvh();
                },
              ),
            ],
          ),
          if (isCustom && _customBvhContent != null) ...[
            const SizedBox(height: 6),
            Text(
              'Detected: ${_formatLabel(_customBvhFormat)}',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ],
          const SizedBox(height: 16),
          ElevatedButton.icon(
            icon: const Icon(Icons.play_arrow),
            label: const Text('Animate'),
            onPressed: (!isCustom || _customBvhContent != null) ? _onAnimate : null,
          ),
        ],
      ),
    );
  }


  Future<void> _pickCustomBvh() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['bvh'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null) return;
    final content = String.fromCharCodes(bytes);
    final format = _detectBvhFormat(content);
    setState(() {
      _customBvhContent = content;
      _customBvhFileName = file.name;
      _customBvhFormat = format;
    });
  }

  static String _formatLabel(String format) => switch (format) {
    'cmu1'    => 'CMU MoCap',
    'cmu_una' => 'CMU MoCap (una-dinosauria)',
    'rokoko'  => 'Rokoko / Mixamo',
    _         => 'Fair1 / FAIR',
  };

  static String _detectBvhFormat(String bvhContent) {
    final joints = <String>{};
    for (final line in bvhContent.split('\n')) {
      final t = line.trim();
      if (t.startsWith('ROOT ') || t.startsWith('JOINT ')) {
        joints.add(t.split(' ').last);
      }
    }
    // una-dinosauria CMU: hip proxy joint leads to LeftUpLeg-style legs
    if (joints.contains('LHipJoint') && joints.contains('LeftUpLeg')) return 'cmu_una';
    // Standard CMU: hip proxy joint with LeftHip/LeftAnkle naming
    if (joints.contains('LeftHip') && joints.contains('LeftAnkle')) return 'cmu1';
    // Rokoko / Mixamo: Spine2 present, no Spine3
    if (joints.contains('Spine2') && !joints.contains('Spine3')) return 'rokoko';
    // Fair1 / FAIR: fallback (up=+z, Spine3, or other FAIR-lab BVH)
    return 'fair1';
  }
}

// ─── Joint overlay painter ─────────────────────────────────────────────────────

class _JointPainter extends CustomPainter {
  final List<CharJoint> skeleton;
  final int imgW, imgH, selectedIdx, version;

  const _JointPainter({
    required this.skeleton,
    required this.imgW,
    required this.imgH,
    required this.selectedIdx,
    required this.version,
  });

  ({double scale, double ox, double oy}) _transform(Size size) {
    final s = math.min(size.width / imgW, size.height / imgH);
    return (scale: s, ox: (size.width - imgW * s) / 2, oy: (size.height - imgH * s) / 2);
  }

  Offset _pt(CharJoint j, ({double scale, double ox, double oy}) t) =>
      Offset(j.x * t.scale + t.ox, j.y * t.scale + t.oy);

  @override
  void paint(Canvas canvas, Size size) {
    if (skeleton.isEmpty) return;
    final t = _transform(size);

    final nameToIdx = <String, int>{for (int i = 0; i < skeleton.length; i++) skeleton[i].name: i};
    final bonePaint = Paint()..strokeWidth = 2.5..style = PaintingStyle.stroke;
    final shadowPaint = Paint()..color = Colors.black.withAlpha(140)..style = PaintingStyle.fill;
    final fillPaint = Paint()..style = PaintingStyle.fill;
    final selectRingPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    for (final j in skeleton) {
      if (j.parent == null) continue;
      final pi = nameToIdx[j.parent];
      if (pi == null) continue;
      bonePaint.color = _boneColor(j.name).withAlpha(200);
      canvas.drawLine(_pt(skeleton[pi], t), _pt(j, t), bonePaint);
    }

    for (int i = 0; i < skeleton.length; i++) {
      final j = skeleton[i];
      final pt = _pt(j, t);
      final sel = i == selectedIdx;
      final r = sel ? 9.0 : 6.5;
      canvas.drawCircle(pt, r + 1.5, shadowPaint);
      fillPaint.color = sel ? Colors.yellow : _jointColor(j.name);
      canvas.drawCircle(pt, r, fillPaint);
      if (sel) canvas.drawCircle(pt, r, selectRingPaint);
    }
  }

  Color _boneColor(String name) {
    if (name.startsWith('left_')) return Colors.cyanAccent;
    if (name.startsWith('right_')) return Colors.orangeAccent;
    return Colors.lightGreenAccent;
  }

  Color _jointColor(String name) {
    if (name.startsWith('left_')) return Colors.blue;
    if (name.startsWith('right_')) return Colors.deepOrange;
    return Colors.green;
  }

  @override
  bool shouldRepaint(_JointPainter old) =>
      old.version != version || old.selectedIdx != selectedIdx;
}

// ─── Mask overlay painter ──────────────────────────────────────────────────────

class _MaskPainter extends CustomPainter {
  final Uint8List maskData;
  final int imgW, imgH, version;
  final bool eraseMode;
  final Offset? brushCenter;
  final double brushSize;

  const _MaskPainter({
    required this.maskData,
    required this.imgW,
    required this.imgH,
    required this.version,
    required this.eraseMode,
    required this.brushCenter,
    required this.brushSize,
  });

  ({double scale, double ox, double oy}) _transform(Size size) {
    final s = math.min(size.width / imgW, size.height / imgH);
    return (scale: s, ox: (size.width - imgW * s) / 2, oy: (size.height - imgH * s) / 2);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final t = _transform(size);
    final imgRect = Rect.fromLTWH(t.ox, t.oy, imgW * t.scale, imgH * t.scale);

    canvas.save();
    canvas.clipRect(imgRect);

    canvas.drawRect(imgRect, Paint()..color = Colors.black.withValues(alpha: 0.35));

    final fgPaint = Paint()
      ..color = Colors.red.withValues(alpha: 0.45)
      ..style = PaintingStyle.fill;

    for (int y = 0; y < imgH; y++) {
      int? start;
      final rowBase = y * imgW;
      final wy = y * t.scale + t.oy;
      final rowH = t.scale;
      for (int x = 0; x <= imgW; x++) {
        final fg = x < imgW && maskData[rowBase + x] > 0;
        if (fg && start == null) {
          start = x;
        } else if (!fg && start != null) {
          canvas.drawRect(
            Rect.fromLTWH(start * t.scale + t.ox, wy, (x - start) * t.scale, rowH),
            fgPaint,
          );
          start = null;
        }
      }
    }

    canvas.restore();

    if (brushCenter != null) {
      final bx = brushCenter!.dx * t.scale + t.ox;
      final by = brushCenter!.dy * t.scale + t.oy;
      final br = brushSize * t.scale;
      canvas.drawCircle(
        Offset(bx, by),
        br,
        Paint()
          ..color = (eraseMode ? Colors.lightBlue : Colors.white).withValues(alpha: 0.75)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(_MaskPainter old) =>
      old.version != version ||
      old.brushCenter != brushCenter ||
      old.eraseMode != eraseMode ||
      old.brushSize != brushSize;
}

// ─── Step checklist (loading screen) ──────────────────────────────────────────

class _AnnotationStepsList extends StatelessWidget {
  final double progress;
  final bool isWeb;
  const _AnnotationStepsList({required this.progress, required this.isWeb});

  @override
  Widget build(BuildContext context) {
    final steps = isWeb
        ? const [
            (0.05, 'Decode image'),
            (0.20, 'Segment'),
            (0.50, 'Load ONNX model'),
            (0.60, 'Estimate pose (YOLOv8n)'),
            (0.80, 'Build skeleton'),
            (1.00, 'Done'),
          ]
        : const [
            (0.05, 'Load image'),
            (0.20, 'Segment (adaptive threshold + flood fill)'),
            (0.50, 'Load ONNX model'),
            (0.60, 'Estimate pose (YOLOv8n)'),
            (0.80, 'Build skeleton'),
            (0.90, 'Extract mask data'),
            (1.00, 'Done'),
          ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: steps.map((s) {
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

// ─── Isolate: segmentation only (native, no plugins) ──────────────────────────

class _SegResult {
  final String maskPath, texturePath;
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
      final scale = 1000 / math.max(image.width, image.height);
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
