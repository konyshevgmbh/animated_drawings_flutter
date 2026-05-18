import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'bg_color_picker.dart';

typedef ExportFn = Future<String?> Function({
  required double speed,
  required double pixelRatio,
  required String outputPath,
  required Color? backgroundColor, // null = transparent
  required void Function(double) onProgress,
});

enum _S { settings, exporting, done, error }

// ─── Size preset ──────────────────────────────────────────────────────────────

class _Preset {
  final String label;
  final double pixelRatio;
  final String dimensions;
  const _Preset(this.label, this.pixelRatio, this.dimensions);
}

List<_Preset> _buildPresets(Size? sz) {
  if (sz == null || sz.width < 1) {
    return [
      const _Preset('Small', 0.4, '—'),
      const _Preset('Medium', 0.8, '—'),
      const _Preset('Original', 1.0, '—'),
    ];
  }

  final w = sz.width;
  final h = sz.height;

  final targets = <int?>[150, 350, null, (w * 2).round()];
  final out = <_Preset>[];
  final seen = <int>{};

  for (final t in targets) {
    final ratio = t != null ? t / w : 1.0;
    final ow = (w * ratio).round().clamp(16, 4096);
    final oh = (h * ratio).round().clamp(16, 4096);
    if (!seen.add(ow)) continue;

    final label = t == null
        ? 'Original'
        : t <= 200
            ? 'Small'
            : t <= 400
                ? 'Medium'
                : 'Large';

    out.add(_Preset(label, ratio.clamp(0.05, 4.0), '$ow × $oh px'));
  }
  return out;
}

// ─── Sheet widget ─────────────────────────────────────────────────────────────

class GifExportSheet extends StatefulWidget {
  final ExportFn onExport;
  final Size? widgetSize;
  final Color? initialBgColor;
  final Color? sceneBgColor;

  const GifExportSheet({
    super.key,
    required this.onExport,
    this.widgetSize,
    this.initialBgColor,
    this.sceneBgColor,
  });

  @override
  State<GifExportSheet> createState() => _GifExportSheetState();
}

class _GifExportSheetState extends State<GifExportSheet> {
  _S _state = _S.settings;
  late List<_Preset> _presets;
  int _presetIdx = 0;
  double _speed = 1.0;
  String? _outputPath;
  double _progress = 0.0;
  String? _resultPath;
  String? _errorMsg;
  Color? _bgColor;

  static const _speedOptions = [0.1, 1.0, 2.0, 10.0];

  bool get _canPop => _state != _S.exporting;
  bool get _encoding => _progress >= 1.0;

  @override
  void initState() {
    super.initState();
    _presets = _buildPresets(widget.widgetSize);
    _bgColor = widget.initialBgColor;
  }

  // ── output path picker (native only) ──────────────────────────────────────

  Future<void> _pickPath() async {
    try {
      String? path;
      if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
        path = await FilePicker.platform.saveFile(
          dialogTitle: 'Save GIF as',
          fileName: 'animated_drawing.gif',
          type: FileType.custom,
          allowedExtensions: ['gif'],
        );
      } else {
        final dir = await FilePicker.platform.getDirectoryPath(
          dialogTitle: 'Choose save location',
        );
        if (dir != null) path = '$dir/animated_drawing.gif';
      }
      if (path != null && mounted) setState(() => _outputPath = path);
    } catch (_) {}
  }

  Future<String> _resolvedPath() async {
    if (_outputPath != null) return _outputPath!;
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/animated_drawing.gif';
  }

  // ── export ────────────────────────────────────────────────────────────────

  Future<void> _run() async {
    setState(() { _state = _S.exporting; _progress = 0; });
    try {
      final outPath = kIsWeb ? '' : await _resolvedPath();
      final resultPath = await widget.onExport(
        speed: _speed,
        pixelRatio: _presets[_presetIdx].pixelRatio,
        outputPath: outPath,
        backgroundColor: _bgColor,
        onProgress: (p) { if (mounted) setState(() => _progress = p); },
      );
      if (mounted) setState(() { _state = _S.done; _resultPath = resultPath; });
    } catch (e) {
      if (mounted) setState(() { _state = _S.error; _errorMsg = e.toString(); });
    }
  }

  // ── build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _canPop,
      child: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            24, 12, 24,
            MediaQuery.of(context).viewInsets.bottom + 24,
          ),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: switch (_state) {
              _S.settings  => _buildSettings(),
              _S.exporting => _buildExporting(),
              _S.done      => _buildDone(),
              _S.error     => _buildError(),
            },
          ),
        ),
      ),
    );
  }

  // ── settings ──────────────────────────────────────────────────────────────

  Widget _buildSettings() {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Column(
      key: const ValueKey('settings'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Handle(),
        const SizedBox(height: 12),
        Row(children: [
          const Icon(Icons.gif_box_outlined),
          const SizedBox(width: 8),
          Text('Export GIF', style: tt.titleLarge),
        ]),
        const SizedBox(height: 24),

        // ── Size ──
        Text('Size', style: tt.labelLarge),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: List.generate(_presets.length, (i) {
            final p = _presets[i];
            return ChoiceChip(
              label: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(p.label),
                  Text(p.dimensions, style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
                ],
              ),
              selected: _presetIdx == i,
              onSelected: (_) => setState(() => _presetIdx = i),
            );
          }),
        ),
        const SizedBox(height: 20),

        // ── Speed ──
        Text('Speed', style: tt.labelLarge),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: _speedOptions.map((s) {
            final label = s == s.truncateToDouble() ? '${s.toInt()}×' : '$s×';
            return ChoiceChip(
              label: Text(label),
              selected: _speed == s,
              onSelected: (_) => setState(() => _speed = s),
            );
          }).toList(),
        ),
        const SizedBox(height: 6),
        Text(
          'Lower fps = fewer frames captured = faster export',
          style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 20),

        // ── Background ──
        Text('Background', style: tt.labelLarge),
        const SizedBox(height: 8),
        BgColorPicker(
          selected: _bgColor,
          sceneBgColor: widget.sceneBgColor,
          onChanged: (c) => setState(() => _bgColor = c),
        ),
        const SizedBox(height: 20),

        // ── Output path (native only) ──
        if (!kIsWeb) ...[
          Text('Output', style: tt.labelLarge),
          const SizedBox(height: 8),
          InkWell(
            onTap: _pickPath,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                border: Border.all(color: cs.outline.withValues(alpha: 0.5)),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(Icons.folder_outlined, size: 18, color: cs.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _outputPath ?? 'Documents / animated_drawing.gif',
                      style: tt.bodySmall?.copyWith(
                        color: _outputPath != null ? null : cs.onSurfaceVariant,
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 2,
                    ),
                  ),
                  Icon(Icons.chevron_right, size: 16, color: cs.onSurfaceVariant),
                ],
              ),
            ),
          ),
          const SizedBox(height: 28),
        ] else ...[
          Text(
            'GIF will be downloaded to your Downloads folder',
            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 28),
        ],

        FilledButton.icon(
          icon: const Icon(Icons.gif),
          label: const Text('Export'),
          style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
          onPressed: _run,
        ),
      ],
    );
  }

  // ── exporting ─────────────────────────────────────────────────────────────

  Widget _buildExporting() {
    final tt = Theme.of(context).textTheme;
    return Column(
      key: const ValueKey('exporting'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Handle(),
        const SizedBox(height: 32),
        Center(
          child: SizedBox(
            width: 72, height: 72,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CircularProgressIndicator(
                  value: _encoding ? null : _progress,
                  strokeWidth: 6,
                ),
                if (!_encoding)
                  Text('${(_progress * 100).toStringAsFixed(0)}%', style: tt.labelLarge),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        Center(
          child: Text(
            _encoding ? 'Encoding GIF…' : 'Capturing frames…',
            style: tt.titleMedium,
          ),
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(
          value: _encoding ? null : _progress,
          minHeight: 4,
          borderRadius: BorderRadius.circular(2),
        ),
        const SizedBox(height: 32),
      ],
    );
  }

  // ── done ──────────────────────────────────────────────────────────────────

  Widget _buildDone() {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return _DoneBody(key: const ValueKey('done'), path: _resultPath, tt: tt, cs: cs);
  }

  // ── error ─────────────────────────────────────────────────────────────────

  Widget _buildError() {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Column(
      key: const ValueKey('error'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Handle(),
        const SizedBox(height: 20),
        Center(child: Icon(Icons.error_outline_rounded, size: 64, color: cs.error)),
        const SizedBox(height: 12),
        Center(child: Text('Export failed', style: tt.titleMedium)),
        const SizedBox(height: 8),
        Text(
          _errorMsg ?? 'Unknown error',
          textAlign: TextAlign.center,
          style: tt.bodySmall?.copyWith(color: cs.error),
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 24),
        Row(children: [
          Expanded(child: OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))),
          const SizedBox(width: 12),
          Expanded(child: FilledButton(
            onPressed: () => setState(() => _state = _S.settings),
            child: const Text('Retry'),
          )),
        ]),
      ],
    );
  }
}

// ─── Done body ────────────────────────────────────────────────────────────────

class _DoneBody extends StatefulWidget {
  final String? path; // null on web (download triggered)
  final TextTheme tt;
  final ColorScheme cs;
  const _DoneBody({super.key, required this.path, required this.tt, required this.cs});

  @override
  State<_DoneBody> createState() => _DoneBodyState();
}

class _DoneBodyState extends State<_DoneBody> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.path!));
    setState(() => _copied = true);
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final path = widget.path;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Handle(),
        const SizedBox(height: 20),
        Center(child: Icon(Icons.check_circle_rounded, size: 64, color: widget.cs.primary)),
        const SizedBox(height: 12),
        Center(child: Text(path == null ? 'GIF downloaded!' : 'GIF saved!', style: widget.tt.titleMedium)),
        const SizedBox(height: 20),
        if (path != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: widget.cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                const Icon(Icons.folder_outlined, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(path, style: widget.tt.bodySmall, maxLines: 3, overflow: TextOverflow.ellipsis),
                ),
                const SizedBox(width: 4),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: IconButton(
                    key: ValueKey(_copied),
                    icon: Icon(_copied ? Icons.check : Icons.copy, size: 18),
                    color: _copied ? widget.cs.primary : null,
                    onPressed: _copy,
                    tooltip: _copied ? 'Copied!' : 'Copy path',
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 20),
        OutlinedButton(
          onPressed: () => Navigator.pop(context),
          style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

// ─── Handle ───────────────────────────────────────────────────────────────────

class _Handle extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 36, height: 4,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.outlineVariant,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}
