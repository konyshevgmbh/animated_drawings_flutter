import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

/// Captures [frameCount] frames from a [RepaintBoundary] key, encodes as GIF.
/// On native: writes to [outputPath] and returns the path.
/// On web: triggers a browser download and returns null.
Future<String?> exportGif({
  required GlobalKey repaintKey,
  required int frameCount,
  required Future<void> Function(int frameIndex) onFrame,
  String? outputPath,
  int delayCs = 4,
  double pixelRatio = 1.0,
  int? bgArgb,
}) async {
  final rawFrames = <_RawFrame>[];

  for (int i = 0; i < frameCount; i++) {
    await onFrame(i);

    final boundary = repaintKey.currentContext?.findRenderObject()
        as RenderRepaintBoundary?;
    if (boundary == null) continue;

    final uiImage = await boundary.toImage(pixelRatio: pixelRatio);
    final width = uiImage.width;
    final height = uiImage.height;
    final byteData = await uiImage.toByteData(format: ui.ImageByteFormat.rawRgba);
    uiImage.dispose();
    if (byteData == null) continue;

    rawFrames.add(_RawFrame(
      bytes: byteData.buffer.asUint8List(),
      width: width,
      height: height,
    ));
  }

  final gifBytes = await compute(_encodeGif, _EncodeParams(frames: rawFrames, delayCs: delayCs, bgArgb: bgArgb));
  if (gifBytes == null) throw StateError('GIF encoding failed');

  if (kIsWeb) {
    await FilePicker.platform.saveFile(
      fileName: 'animated_drawing.gif',
      bytes: gifBytes,
    );
    return null;
  }

  final outFile = outputPath != null
      ? File(outputPath)
      : File('${(await getApplicationDocumentsDirectory()).path}/animated_drawing.gif');
  await outFile.writeAsBytes(gifBytes);
  return outFile.path;
}

// ─── Isolate-safe data classes ────────────────────────────────────────────────

class _RawFrame {
  final Uint8List bytes;
  final int width;
  final int height;
  _RawFrame({required this.bytes, required this.width, required this.height});
}

class _EncodeParams {
  final List<_RawFrame> frames;
  final int delayCs;
  final int? bgArgb;
  _EncodeParams({required this.frames, required this.delayCs, this.bgArgb});
}

Uint8List? _encodeGif(_EncodeParams p) {
  final encoder = img.GifEncoder(repeat: 0);
  final delay = p.delayCs.clamp(1, 65535);
  for (final f in p.frames) {
    var frame = img.Image.fromBytes(
      width: f.width,
      height: f.height,
      bytes: f.bytes.buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
    if (p.bgArgb != null) {
      final a = (p.bgArgb! >> 24) & 0xFF;
      final r = (p.bgArgb! >> 16) & 0xFF;
      final g = (p.bgArgb! >> 8) & 0xFF;
      final b = p.bgArgb! & 0xFF;
      final bg = img.fill(
        img.Image(width: f.width, height: f.height),
        color: img.ColorRgba8(r, g, b, a),
      );
      frame = img.compositeImage(bg, frame);
    }
    encoder.addFrame(frame, duration: delay);
  }
  return encoder.finish();
}
