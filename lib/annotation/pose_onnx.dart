import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset;
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;

import '../annotation/char_cfg.dart';
import '../annotation/straighten_legs.dart' as legs;

const String _modelAsset = 'assets/models/drawn_humanoid_pose.onnx';
const int _inputSize = 640;

// COCO-17 keypoint indices
const int _kNose = 0, _kLShoulder = 5, _kRShoulder = 6;
const int _kLElbow = 7, _kRElbow = 8, _kLWrist = 9, _kRWrist = 10;
const int _kLHip = 11, _kRHip = 12, _kLKnee = 13, _kRKnee = 14;
const int _kLAnkle = 15, _kRAnkle = 16;

class PoseEstimator {
  OrtSession? _session;

  Future<void> init() async {
    // On web, Flutter stores assets at assets/assets/..., but createSessionFromAsset
    // passes the key verbatim to ONNX Runtime JS which fetches assets/... (single prefix) → 404.
    // Pass the web-correct path directly; on other platforms use the standard method.
    if (kIsWeb) {
      _session = await OnnxRuntime().createSession(
        'assets/$_modelAsset',
      );
    } else {
      _session = await OnnxRuntime().createSessionFromAsset(_modelAsset);
    }
  }

  void dispose() {
    _session?.close();
  }

  /// Returns COCO-17 keypoints in original image coords, or null if no pose found.
  Future<List<Offset>?> estimate(img.Image image,
      {img.Image? mask, bool straightenLegs = false}) async {
    assert(_session != null, 'Call init() first');

    var result = await _inferOnImage(image, 'original');

    if (result == null && mask != null) {
      debugPrint('[Pose] no pose on original — retrying on mask silhouette...');
      final maskRgb = img.Image(width: mask.width, height: mask.height);
      for (int y = 0; y < mask.height; y++) {
        for (int x = 0; x < mask.width; x++) {
          final v = mask.getPixel(x, y).r.toInt();
          maskRgb.setPixelRgba(x, y, v, v, v, 255);
        }
      }
      result = await _inferOnImage(maskRgb, 'mask');
    }

    if (result != null && straightenLegs) {
      result = legs.straightenLegs(result);
    }
    return result;
  }

  Future<List<Offset>?> _inferOnImage(img.Image image, String label) async {
    final origW = image.width;
    final origH = image.height;

    // Letterbox resize to 640×640
    final scale = _inputSize / math.max(origW, origH);
    final rW = (origW * scale).round();
    final rH = (origH * scale).round();
    final resized = img.copyResize(image, width: rW, height: rH);

    // Build float tensor [1,3,640,640] RGB normalized [0,1]
    const gray = 114.0 / 255.0;
    final tensor = Float32List(_inputSize * _inputSize * 3)
      ..fillRange(0, _inputSize * _inputSize * 3, gray);
    final padX = (_inputSize - rW) ~/ 2;
    final padY = (_inputSize - rH) ~/ 2;
    for (int y = 0; y < rH; y++) {
      for (int x = 0; x < rW; x++) {
        final px = resized.getPixel(x, y);
        final destX = x + padX;
        final destY = y + padY;
        final offset = destY * _inputSize + destX;
        tensor[offset] = px.r / 255.0;
        tensor[_inputSize * _inputSize + offset] = px.g / 255.0;
        tensor[2 * _inputSize * _inputSize + offset] = px.b / 255.0;
      }
    }

    debugPrint('[Pose] $label: ${origW}x$origH → scale=$scale rW=$rW rH=$rH padX=$padX padY=$padY');

    final inputValue = await OrtValue.fromList(
      tensor,
      [1, 3, _inputSize, _inputSize],
    );

    Map<String, OrtValue?> outputs;
    try {
      outputs = await _session!.run({'images': inputValue});
    } finally {
      await inputValue.dispose();
    }

    // Output shape: [1, 56, 8400] — flattened to 1*56*8400
    final outputKey = outputs.keys.firstOrNull;
    Float32List? flat;
    if (outputKey != null) {
      final flatList = await outputs[outputKey]?.asFlattenedList();
      if (flatList is Float32List) flat = flatList;
      else if (flatList != null) flat = Float32List.fromList(flatList.cast<double>());
    }
    for (final v in outputs.values) { await v?.dispose(); }

    if (flat == null) return null;

    List<Offset>? result;
    for (final conf in [0.25, 0.10, 0.05, 0.01]) {
      result = _decodeOutput(flat, conf, origW, origH, scale, padX, padY, label);
      if (result != null) break;
    }
    return result;
  }

  List<Offset>? _decodeOutput(
      Float32List flat, double confThresh, int origW, int origH,
      double scale, int padX, int padY, String label) {
    const numDetections = 8400;
    double bestConf = confThresh;
    int bestIdx = -1;

    final contentW = (origW * scale).round();
    final contentH = (origH * scale).round();
    for (int i = 0; i < numDetections; i++) {
      final cx = flat[0 * numDetections + i];
      final cy = flat[1 * numDetections + i];
      if (cx < padX || cx > padX + contentW || cy < padY || cy > padY + contentH) continue;
      final c = flat[4 * numDetections + i];
      if (c > bestConf) {
        bestConf = c;
        bestIdx = i;
      }
    }
    if (bestIdx < 0) {
      debugPrint('[Pose] $label: no detection inside content area → skip');
      return null;
    }

    final bh = flat[3 * numDetections + bestIdx];
    debugPrint('[Pose] $label: best detection conf=$bestConf idx=$bestIdx bh=${bh.toStringAsFixed(1)}');

    const names = ['nose','leye','reye','lear','rear','lsho','rsho',
                    'lelb','relb','lwri','rwri','lhip','rhip',
                    'lkne','rkne','lank','rank'];
    final kpts = <Offset>[];
    int outOfBounds = 0;
    for (int k = 0; k < 17; k++) {
      final kx = flat[(5 + k * 3) * numDetections + bestIdx];
      final ky = flat[(5 + k * 3 + 1) * numDetections + bestIdx];
      final ox = (kx - padX) / scale;
      final oy = (ky - padY) / scale;
      if (ox < 0 || oy < 0 || ox > origW || oy > origH) outOfBounds++;
      kpts.add(Offset(ox.clamp(0, origW.toDouble()), oy.clamp(0, origH.toDouble())));
    }

    final kpLog = List.generate(17, (k) =>
      '${names[k]}=(${kpts[k].dx.toStringAsFixed(0)},${kpts[k].dy.toStringAsFixed(0)})').join(' ');
    debugPrint('[Pose] $label: $kpLog');

    if (outOfBounds > 8) {
      debugPrint('[Pose] $label: $outOfBounds/17 keypoints out of bounds → rejecting');
      return null;
    }

    final posOx = kpts.where((p) => p.dx > 0).map((p) => p.dx).toList();
    if (posOx.isNotEmpty) {
      final meanOx = posOx.reduce((a, b) => a + b) / posOx.length;
      if (meanOx < 0.08 * origW || meanOx > 0.92 * origW) {
        debugPrint('[Pose] $label: centroid x=${meanOx.toStringAsFixed(0)} near edge → rejecting');
        return null;
      }
    }

    if (kpts.every((p) => p.dx == 0 && p.dy == 0)) return null;

    return _fillMissingKpts(kpts, origW, origH);
  }

  List<Offset> _fillMissingKpts(List<Offset> kpts, int w, int h) {
    bool missing(int i) => kpts[i].dx == 0 && kpts[i].dy == 0;

    const chains = <(int, int, int, double, double)>[
      (5,  7,  9,  0.90, 0.50),
      (6,  8,  10, 0.90, 0.50),
      (11, 13, 15, 1.05, 0.50),
      (12, 14, 16, 1.05, 0.50),
    ];

    final filled = List<Offset>.from(kpts);
    for (final (gp, mid, end, ratio, t) in chains) {
      if (missing(end) && !missing(mid) && !missing(gp)) {
        final delta = filled[mid] - filled[gp];
        final estimated = filled[mid] + delta * ratio;
        filled[end] = Offset(
          estimated.dx.clamp(0, w.toDouble()),
          estimated.dy.clamp(0, h.toDouble()),
        );
      } else if (missing(mid) && !missing(end) && !missing(gp)) {
        final interpolated = filled[gp] + (filled[end] - filled[gp]) * t;
        filled[mid] = Offset(
          interpolated.dx.clamp(0, w.toDouble()),
          interpolated.dy.clamp(0, h.toDouble()),
        );
      }
    }
    return filled;
  }
}

/// Build AnimatedDrawings skeleton from COCO-17 keypoints.
List<CharJoint> buildSkeleton(List<Offset> kpts) {
  Offset pt(int idx) => kpts[idx];
  Offset midpt(int a, int b) => Offset(
        (kpts[a].dx + kpts[b].dx) / 2,
        (kpts[a].dy + kpts[b].dy) / 2,
      );

  final locs = [
    ('root', null as String?, midpt(_kLHip, _kRHip)),
    ('hip', 'root', midpt(_kLHip, _kRHip)),
    ('torso', 'hip', midpt(_kLShoulder, _kRShoulder)),
    ('neck', 'torso', pt(_kNose)),
    ('right_shoulder', 'torso', pt(_kRShoulder)),
    ('right_elbow', 'right_shoulder', pt(_kRElbow)),
    ('right_hand', 'right_elbow', pt(_kRWrist)),
    ('left_shoulder', 'torso', pt(_kLShoulder)),
    ('left_elbow', 'left_shoulder', pt(_kLElbow)),
    ('left_hand', 'left_elbow', pt(_kLWrist)),
    ('right_hip', 'root', pt(_kRHip)),
    ('right_knee', 'right_hip', pt(_kRKnee)),
    ('right_foot', 'right_knee', pt(_kRAnkle)),
    ('left_hip', 'root', pt(_kLHip)),
    ('left_knee', 'left_hip', pt(_kLKnee)),
    ('left_foot', 'left_knee', pt(_kLAnkle)),
  ];

  return locs
      .map((t) => CharJoint(
            name: t.$1,
            parent: t.$2,
            x: t.$3.dx.roundToDouble(),
            y: t.$3.dy.roundToDouble(),
          ))
      .toList();
}

/// Proportional fallback skeleton used when YOLO finds no pose.
List<CharJoint> defaultSkeleton(int h, int w) {
  CharJoint pt(String name, String? parent, double fh, double fw) =>
      CharJoint(name: name, parent: parent, x: (fw * w).roundToDouble(), y: (fh * h).roundToDouble());
  return [
    pt('root', null, 0.60, 0.50),
    pt('hip', 'root', 0.60, 0.50),
    pt('torso', 'hip', 0.42, 0.50),
    pt('neck', 'torso', 0.22, 0.50),
    pt('right_shoulder', 'torso', 0.40, 0.33),
    pt('right_elbow', 'right_shoulder', 0.52, 0.25),
    pt('right_hand', 'right_elbow', 0.63, 0.18),
    pt('left_shoulder', 'torso', 0.40, 0.67),
    pt('left_elbow', 'left_shoulder', 0.52, 0.75),
    pt('left_hand', 'left_elbow', 0.63, 0.82),
    pt('right_hip', 'root', 0.62, 0.42),
    pt('right_knee', 'right_hip', 0.75, 0.40),
    pt('right_foot', 'right_knee', 0.90, 0.38),
    pt('left_hip', 'root', 0.62, 0.58),
    pt('left_knee', 'left_hip', 0.75, 0.60),
    pt('left_foot', 'left_knee', 0.90, 0.62),
  ];
}
