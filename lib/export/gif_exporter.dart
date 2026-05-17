import 'dart:io';

import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

/// Captures [frameCount] frames from a [RepaintBoundary] key, encodes as GIF.
/// Frame capture runs on the main thread; GIF encoding runs in a background isolate.
Future<File> exportGif({
  required GlobalKey repaintKey,
  required int frameCount,
  required Future<void> Function(int frameIndex) onFrame,
  String? outputPath,
  int delayCs = 4, // centiseconds per frame (GIF spec unit)
  double pixelRatio = 1.0,
  int? bgArgb, // null = transparent
}) async {
  final rawFrames = <_RawFrame>[];

  for (int i = 0; i < frameCount; i++) {
    // onFrame already waits for endOfFrame — no extra delay needed.
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

  // Encode in a background isolate so the main thread stays free.
  final gifBytes = await compute(_encodeGif, _EncodeParams(frames: rawFrames, delayCs: delayCs, bgArgb: bgArgb));
  if (gifBytes == null) throw StateError('GIF encoding failed');

  final outFile = outputPath != null
      ? File(outputPath)
      : File('${(await getApplicationDocumentsDirectory()).path}/animated_drawing.gif');

  await outFile.writeAsBytes(gifBytes);
  return outFile;
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

// Top-level function required by compute().
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
