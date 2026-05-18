import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../annotation/char_cfg.dart';
import '../export/gif_exporter.dart';
import '../rendering/animated_drawing_widget.dart';
import '../retarget/config_models.dart';
import 'bg_color_picker.dart';
import 'gif_export_sheet.dart';

class AnimationPage extends StatefulWidget {
  final CharConfig charCfg;
  final Uint8List textureBytes;
  final Uint8List maskBytes;
  final MotionConfig motionCfg;
  final RetargetConfig retargetCfg;
  final Color bgColor;

  const AnimationPage({
    super.key,
    required this.charCfg,
    required this.textureBytes,
    required this.maskBytes,
    required this.motionCfg,
    required this.retargetCfg,
    this.bgColor = Colors.white,
  });

  @override
  State<AnimationPage> createState() => _AnimationPageState();
}

class _AnimationPageState extends State<AnimationPage> {
  AnimatedDrawingState? _drawingState;
  String? _error;

  double _progress = 0.0;
  String _progressStep = 'Initializing…';

  AnimationController? _animCtrl;
  final _repaintKey = GlobalKey();

  late Color _bgColor;

  @override
  void initState() {
    super.initState();
    _bgColor = widget.bgColor;
    _load();
  }

  void _showBgColorPicker() {
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Background', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 16),
              StatefulBuilder(
                builder: (ctx, setLocal) => BgColorPicker(
                  selected: _bgColor,
                  sceneBgColor: widget.bgColor,
                  onChanged: (c) {
                    setLocal(() {});
                    setState(() => _bgColor = c ?? widget.bgColor);
                  },
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _load() async {
    try {
      final state = await buildAnimatedDrawingState(
        textureBytes: widget.textureBytes,
        maskBytes: widget.maskBytes,
        charCfg: widget.charCfg,
        motionCfg: widget.motionCfg,
        retargetCfg: widget.retargetCfg,
        onProgress: (p, s) {
          if (mounted) setState(() { _progress = p; _progressStep = s; });
        },
      );
      if (mounted) setState(() => _drawingState = state);
    } catch (e, st) {
      debugPrint('[AnimPage] ERROR: $e\n$st');
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _showExportSheet() {
    final s = _drawingState;
    final ctrl = _animCtrl;
    if (s == null || ctrl == null) return;

    final widgetSize = _repaintKey.currentContext?.size;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => GifExportSheet(
        widgetSize: widgetSize,
        initialBgColor: _bgColor,
        sceneBgColor: widget.bgColor,
        onExport: ({required speed, required pixelRatio, required outputPath, required backgroundColor, required onProgress}) async {
          final bvhFps = 1.0 / s.retargeter.frameTime;
          final effectiveFps = bvhFps * speed;

          const maxGifFps = 50.0;
          final step = (effectiveFps / maxGifFps).ceil().clamp(1, s.retargeter.frameCount);
          final captureCount = (s.retargeter.frameCount / step).ceil();

          final delayCs = (step * 100 / effectiveFps).round().clamp(1, 65535);

          final savedValue = ctrl.value;
          ctrl.stop();
          try {
            return await exportGif(
              repaintKey: _repaintKey,
              frameCount: captureCount,
              delayCs: delayCs,
              pixelRatio: pixelRatio,
              outputPath: outputPath,
              bgArgb: backgroundColor?.toARGB32(),
              onFrame: (i) async {
                if (!mounted) return;
                final frame = (i * step).clamp(0, s.retargeter.frameCount - 1);
                ctrl.value = frame / s.retargeter.frameCount;
                onProgress((i + 1) / captureCount);
                await WidgetsBinding.instance.endOfFrame;
              },
            );
          } finally {
            ctrl.value = savedValue;
            ctrl.repeat();
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Animation'),
        actions: [
          if (_drawingState != null) ...[
            IconButton(
              icon: const Icon(Icons.palette_outlined),
              tooltip: 'Background color',
              onPressed: _showBgColorPicker,
            ),
            IconButton(
              icon: const Icon(Icons.gif_box_outlined),
              tooltip: 'Export GIF',
              onPressed: _showExportSheet,
            ),
          ],
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 12),
              SelectableText('Error: $_error', textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }
    if (_drawingState == null) {
      return _buildLoadingUI();
    }
    return ColoredBox(
      color: _bgColor,
      child: Center(
        child: RepaintBoundary(
          key: _repaintKey,
          child: AnimatedDrawingWidget(
            state: _drawingState!,
            onReady: (ctrl) => _animCtrl = ctrl,
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingUI() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _TexturePreview(bytes: widget.textureBytes),
              const SizedBox(height: 20),
              Text(
                _progressStep,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 10),
              LinearProgressIndicator(
                value: _progress > 0 ? _progress : null,
                minHeight: 8,
                borderRadius: BorderRadius.circular(4),
              ),
              const SizedBox(height: 6),
              Text(
                '${(_progress * 100).toStringAsFixed(0)}%',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 20),
              _StepsList(progress: _progress),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Small preview of the input texture ───────────────────────────────────────

class _TexturePreview extends StatelessWidget {
  final Uint8List bytes;
  const _TexturePreview({required this.bytes});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 150,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.memory(
          bytes,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => const Center(
            child: Icon(Icons.image_not_supported, size: 48, color: Colors.grey),
          ),
        ),
      ),
    );
  }
}

// ─── Checklist of pipeline steps ─────────────────────────────────────────────

class _StepsList extends StatelessWidget {
  final double progress;
  const _StepsList({required this.progress});

  static const _steps = [
    (0.02, 'Load texture'),
    (0.10, 'Load mask'),
    (0.20, 'Build mesh (contour + BFS)'),
    (0.75, 'Build rig'),
    (0.86, 'Compute UV + rest vertices'),
    (0.90, 'Build LBS solver'),
    (0.93, 'Load motion (BVH)'),
    (1.00, 'Ready'),
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
              Text(
                s.$2,
                style: TextStyle(
                  color: done ? null : (active ? null : Colors.grey),
                  fontWeight: active ? FontWeight.bold : null,
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}
