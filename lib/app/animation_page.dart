import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../annotation/char_cfg.dart';
import '../export/gif_exporter.dart';
import '../rendering/animated_drawing_widget.dart';
import '../retarget/config_models.dart';

class AnimationPage extends StatefulWidget {
  final CharConfig charCfg;
  final String texturePath;
  final String maskPath;
  final MotionConfig motionCfg;
  final RetargetConfig retargetCfg;

  const AnimationPage({
    super.key,
    required this.charCfg,
    required this.texturePath,
    required this.maskPath,
    required this.motionCfg,
    required this.retargetCfg,
  });

  @override
  State<AnimationPage> createState() => _AnimationPageState();
}

class _AnimationPageState extends State<AnimationPage> {
  AnimatedDrawingState? _drawingState;
  String? _error;

  double _progress = 0.0;
  String _progressStep = 'Initializing…';

  // GIF export state
  AnimationController? _animCtrl;
  bool _exporting = false;
  double _exportProgress = 0.0;

  final _repaintKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final state = await buildAnimatedDrawingState(
        texturePath: widget.texturePath,
        maskPath: widget.maskPath,
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

  Future<void> _exportGif() async {
    final s = _drawingState;
    final ctrl = _animCtrl;
    if (s == null || ctrl == null || _exporting) return;

    setState(() { _exporting = true; _exportProgress = 0; });

    final savedValue = ctrl.value;
    ctrl.stop();

    try {
      final dir = await getApplicationDocumentsDirectory();
      final outPath = '${dir.path}/animated_drawing.gif';
      final fps = (1.0 / s.retargeter.frameTime).clamp(1.0, 60.0).round();

      final file = await exportGif(
        repaintKey: _repaintKey,
        frameCount: s.retargeter.frameCount,
        fps: fps,
        outputPath: outPath,
        onFrame: (i) async {
          if (!mounted) return;
          ctrl.value = i / s.retargeter.frameCount;
          setState(() => _exportProgress = (i + 1) / s.retargeter.frameCount);
          // Let the widget rebuild and render the new frame before capture.
          await WidgetsBinding.instance.endOfFrame;
        },
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('GIF saved: ${file.path}'),
            duration: const Duration(seconds: 4),
            action: SnackBarAction(label: 'OK', onPressed: () {}),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Export failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      ctrl.value = savedValue;
      ctrl.repeat();
      if (mounted) setState(() { _exporting = false; _exportProgress = 0; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Animation'),
        bottom: _exporting
            ? PreferredSize(
                preferredSize: const Size.fromHeight(6),
                child: LinearProgressIndicator(
                  value: _exportProgress,
                  minHeight: 6,
                ),
              )
            : null,
        actions: [
          if (_drawingState != null)
            _exporting
                ? Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Center(
                      child: Text(
                        'Exporting… ${(_exportProgress * 100).toStringAsFixed(0)}%',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  )
                : IconButton(
                    icon: const Icon(Icons.gif),
                    tooltip: 'Export GIF',
                    onPressed: _exportGif,
                  ),
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
    return Center(
      child: RepaintBoundary(
        key: _repaintKey,
        child: AnimatedDrawingWidget(
          state: _drawingState!,
          onReady: (ctrl) => _animCtrl = ctrl,
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
              _TexturePreview(path: widget.texturePath),
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
  final String path;
  const _TexturePreview({required this.path});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 150,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(
          File(path),
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
