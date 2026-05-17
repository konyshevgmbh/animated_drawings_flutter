import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

/// Captures [frameCount] frames from a [RepaintBoundary] key, encodes as GIF.
/// Calls [onFrame] between captures to advance the animation externally.
Future<File> exportGif({
  required GlobalKey repaintKey,
  required int frameCount,
  required Future<void> Function(int frameIndex) onFrame,
  String? outputPath,
  int fps = 24,
}) async {
  final encoder = img.GifEncoder(repeat: 0); // loop forever

  for (int i = 0; i < frameCount; i++) {
    await onFrame(i);
    // wait a frame for Flutter to render
    await Future.delayed(Duration.zero);

    final boundary = repaintKey.currentContext?.findRenderObject()
        as RenderRepaintBoundary?;
    if (boundary == null) continue;

    final uiImage = await boundary.toImage(pixelRatio: 1.0);
    final byteData = await uiImage.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (byteData == null) continue;

    final frame = img.Image.fromBytes(
      width: uiImage.width,
      height: uiImage.height,
      bytes: byteData.buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );

    encoder.addFrame(frame, duration: (1000 ~/ fps));
    uiImage.dispose();
  }

  final gifBytes = encoder.finish();
  if (gifBytes == null) throw StateError('GIF encoding failed');

  final dir = outputPath != null
      ? File(outputPath).parent
      : await getApplicationDocumentsDirectory();
  final outFile = outputPath != null
      ? File(outputPath)
      : File('${dir.path}/animated_drawing.gif');

  await outFile.writeAsBytes(gifBytes);
  return outFile;
}
