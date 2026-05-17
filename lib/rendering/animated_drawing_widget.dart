import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../annotation/char_cfg.dart';
import '../lbs/arap_solver.dart';
import '../mesh/triangulation.dart';
import '../rendering/depth_sorter.dart';
import '../rendering/mesh_painter.dart';
import '../retarget/config_models.dart';
import '../retarget/retargeter.dart';
import '../rig/rig.dart';

/// State bag produced by [AnimatedDrawingController.init].
class AnimatedDrawingState {
  final ui.Image texture;
  final int imgDim;
  final int charWidth;
  final int charHeight;
  final CharMesh mesh;
  final ArapSolver lbs;
  final Rig rig;
  final Retargeter retargeter;
  final RetargetConfig retargetCfg;
  /// Initial (rest-pose) vertex positions [numVerts × 2]
  final Float32List origVertexPositions;
  /// UV tex coords [numVerts × 2] — normalized, never change
  final Float32List uvCoords;

  const AnimatedDrawingState({
    required this.texture,
    required this.imgDim,
    required this.charWidth,
    required this.charHeight,
    required this.mesh,
    required this.lbs,
    required this.rig,
    required this.retargeter,
    required this.retargetCfg,
    required this.origVertexPositions,
    required this.uvCoords,
  });
}

/// Loads and initializes all data needed for animation.
Future<AnimatedDrawingState> buildAnimatedDrawingState({
  required String texturePath,
  required String maskPath,
  required CharConfig charCfg,
  required MotionConfig motionCfg,
  required RetargetConfig retargetCfg,
  void Function(double progress, String step)? onProgress,
}) async {
  debugPrint('[AD] buildAnimatedDrawingState start');
  debugPrint('[AD]   texturePath=$texturePath  maskPath=$maskPath');
  debugPrint('[AD]   imgDim=${charCfg.imgDim}  joints=${charCfg.skeleton.length}');

  // Load texture image and pad to square (portrait orientation, matching Python)
  onProgress?.call(0.02, 'Loading texture…');
  debugPrint('[AD] step 1/8 — load texture');
  final texBytes = await File(texturePath).readAsBytes();
  final texImg = img.decodeImage(texBytes)!;
  debugPrint('[AD]   raw texture: ${texImg.width}×${texImg.height}');

  final imgDim = charCfg.imgDim;
  final padded = img.Image(width: imgDim, height: imgDim);
  img.compositeImage(padded, texImg, dstX: 0, dstY: 0);

  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    padded.getBytes(order: img.ChannelOrder.rgba),
    imgDim, imgDim, ui.PixelFormat.rgba8888, completer.complete,
  );
  final texture = await completer.future;
  debugPrint('[AD]   ui.Image: ${texture.width}×${texture.height}');

  // Load mask and pad to square (no rotation, matching Python)
  onProgress?.call(0.10, 'Loading mask…');
  debugPrint('[AD] step 2/8 — load mask');
  final maskBytes = await File(maskPath).readAsBytes();
  final maskImg = img.decodeImage(maskBytes)!;
  debugPrint('[AD]   raw mask: ${maskImg.width}×${maskImg.height}');
  final paddedMask = img.Image(width: imgDim, height: imgDim);
  img.compositeImage(paddedMask, maskImg, dstX: 0, dstY: 0);

  final maskData = Uint8List(imgDim * imgDim);
  for (int y = 0; y < imgDim; y++) {
    for (int x = 0; x < imgDim; x++) {
      maskData[y * imgDim + x] = paddedMask.getPixel(x, y).r.toInt();
    }
  }
  // Some masks encode the region as the alpha channel (RGB all-zero, alpha=255).
  // If the r-channel is empty, retry with alpha.
  if (!maskData.any((v) => v > 0)) {
    debugPrint('[AD]   mask r-channel empty — retrying with alpha channel');
    for (int y = 0; y < imgDim; y++) {
      for (int x = 0; x < imgDim; x++) {
        maskData[y * imgDim + x] = paddedMask.getPixel(x, y).a.toInt();
      }
    }
  }
  final maskNonZero = maskData.where((v) => v > 0).length;
  debugPrint('[AD]   mask non-zero pixels: $maskNonZero / ${imgDim * imgDim}');

  // Build mesh
  onProgress?.call(0.20, 'Building mesh (contour + triangulation)…');
  debugPrint('[AD] step 3/8 — buildMesh');
  final mesh = buildMesh(maskData, imgDim, charCfg);
  debugPrint('[AD]   vertices=${mesh.vertices.length}  triangles=${mesh.triangles.length ~/ 3}  joints=${mesh.jointToTriIndices.length}');

  // Build rig
  onProgress?.call(0.75, 'Building rig…');
  debugPrint('[AD] step 4/8 — build Rig');
  final rig = Rig(charCfg);
  debugPrint('[AD]   rig joints=${rig.jointCount}');

  // UV coordinates
  onProgress?.call(0.82, 'Computing UV coordinates…');
  debugPrint('[AD] step 5/8 — compute UV coords');
  final uvCoords = Float32List(mesh.vertices.length * 2);
  for (int i = 0; i < mesh.vertices.length; i++) {
    uvCoords[i * 2]     = mesh.vertices[i].x; // u = col/imgDim
    uvCoords[i * 2 + 1] = mesh.vertices[i].y; // v = row/imgDim
  }

  // Initial vertex positions
  onProgress?.call(0.86, 'Extracting rest-pose vertices…');
  debugPrint('[AD] step 6/8 — extract rest-pose vertex positions');
  final origVertexPositions = Float32List(mesh.vertices.length * 2);
  for (int i = 0; i < mesh.vertices.length; i++) {
    origVertexPositions[i * 2]     = mesh.vertices[i].x;
    origVertexPositions[i * 2 + 1] = mesh.vertices[i].y;
  }

  // Build ARAP solver
  onProgress?.call(0.90, 'Building ARAP solver…');
  debugPrint('[AD] step 7/8 — build ArapSolver');
  final initJoints = rig.getJoints2DPositions();
  final parentIndices = rig.getParentIndices();
  final lbs = ArapSolver(
    origVerts: origVertexPositions,
    origJoints: initJoints,
    parentIndices: parentIndices,
    triangles: mesh.triangles,
  );
  debugPrint('[AD]   ARAP: ${lbs.numVertices} verts × ${lbs.numJoints} joints');

  // Load retargeter
  onProgress?.call(0.93, 'Loading motion (BVH + retargeter)…');
  debugPrint('[AD] step 8/8 — load Retargeter  bvh=${motionCfg.bvhPath}');
  final retargeter = await Retargeter.load(motionCfg, retargetCfg);
  debugPrint('[AD]   retargeter: frames=${retargeter.frameCount}  frameTime=${retargeter.frameTime.toStringAsFixed(4)}s');

  // Compute char-to-BVH scale factor now that both rig and retargeter are ready.
  final charJointPositions = <String, List<double>>{
    for (final j in rig.root.allJoints) j.name: [j.initX, j.initY],
  };
  retargeter.recomputeCharRootPositions(
    charJointPositions: charJointPositions,
    motionScale: motionCfg.scale,
    cfg: retargetCfg,
  );

  onProgress?.call(1.0, 'Ready');
  debugPrint('[AD] buildAnimatedDrawingState DONE');
  return AnimatedDrawingState(
    texture: texture,
    imgDim: imgDim,
    charWidth: charCfg.width,
    charHeight: charCfg.height,
    mesh: mesh,
    lbs: lbs,
    rig: rig,
    retargeter: retargeter,
    retargetCfg: retargetCfg,
    origVertexPositions: origVertexPositions,
    uvCoords: uvCoords,
  );
}

/// Widget that plays the animation.
class AnimatedDrawingWidget extends StatefulWidget {
  final AnimatedDrawingState state;

  /// Called once the [AnimationController] is created.
  /// Callers can use it to pause/seek the animation (e.g. for GIF export).
  final void Function(AnimationController)? onReady;

  const AnimatedDrawingWidget({super.key, required this.state, this.onReady});

  @override
  State<AnimatedDrawingWidget> createState() => _AnimatedDrawingWidgetState();
}

class _AnimatedDrawingWidgetState extends State<AnimatedDrawingWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  Float32List _currentVertexPositions = Float32List(0);
  Uint16List _currentIndices = Uint16List(0);
  int _tickCount = 0;

  @override
  void initState() {
    super.initState();
    final s = widget.state;
    final durationMs = (s.retargeter.frameCount * s.retargeter.frameTime * 1000).round();
    debugPrint('[Widget] initState  frames=${s.retargeter.frameCount}  durationMs=$durationMs');
    debugPrint('[Widget]   mesh: ${s.mesh.vertices.length} verts  ${s.mesh.triangles.length ~/ 3} tris');
    debugPrint('[Widget]   lbs: ${s.lbs.numVertices} verts × ${s.lbs.numJoints} joints');
    final duration = Duration(milliseconds: durationMs);
    _ctrl = AnimationController(vsync: this, duration: duration)
      ..addListener(_onTick)
      ..repeat();
    widget.onReady?.call(_ctrl);
    _currentVertexPositions = Float32List.fromList(s.origVertexPositions);
    _currentIndices = s.mesh.triangles;
    debugPrint('[Widget] AnimationController started  duration=$duration');
  }

  void _onTick() {
    _tickCount++;
    final s = widget.state;
    final time = _ctrl.value * _ctrl.duration!.inMilliseconds / 1000.0;

    // log every 60 ticks
    final log = _tickCount % 60 == 1;
    if (log) debugPrint('[Tick #$_tickCount] t=${time.toStringAsFixed(3)}s  ctrl=${_ctrl.value.toStringAsFixed(3)}');

    // retarget
    final frame = s.retargeter.getFrame(time);
    if (log) {
      debugPrint('[Tick]   orientations=${frame.orientations.length}  depths=${frame.jointDepths.length}');
      debugPrint('[Tick]   rootPos=(${frame.rootPosition[0].toStringAsFixed(3)}, ${frame.rootPosition[1].toStringAsFixed(3)})');
    }

    // Update rig: retargeter rootPosition is a delta from (0,0); add character's
    // initial portrait position so the character stays at its natural location.
    s.rig.setRootPosition(
      frame.rootPosition[0] + s.rig.root.initX,
      frame.rootPosition[1] + s.rig.root.initY,
    );
    s.rig.setGlobalOrientations(frame.orientations);
    if (log) {
      final joints = s.rig.getJoints2DPositions();
      final jc = joints.length ~/ 2;
      final sb = StringBuffer('[Tick]   ALL joints ($jc):');
      final allJ = s.rig.root.allJoints;
      for (int i = 0; i < jc; i++) {
        sb.write('\n  [${allJ[i].name}] (${joints[i*2].toStringAsFixed(3)},${joints[i*2+1].toStringAsFixed(3)})');
      }
      debugPrint(sb.toString());
    }

    // LBS deformation
    final newJoints = s.rig.getJoints2DPositions();
    final newVerts = s.lbs.solve(newJoints);
    if (log) {
      debugPrint('[Tick]   LBS → ${newVerts.length ~/ 2} verts  [0]=(${newVerts[0].toStringAsFixed(3)},${newVerts[1].toStringAsFixed(3)})');
    }

    // Depth sort
    final sortedIndices = sortTrianglesByDepth(
      s.mesh.jointToTriIndices,
      s.retargetCfg.charBodypartGroups,
      frame.jointDepths,
    );
    if (log) {
      debugPrint('[Tick]   sortedIndices=${sortedIndices.length ~/ 3} tris (0=fallback: ${sortedIndices.isEmpty})');
    }

    setState(() {
      _currentVertexPositions = newVerts;
      _currentIndices = sortedIndices.isEmpty ? s.mesh.triangles : sortedIndices;
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    // Display in the character's natural portrait aspect ratio.
    // MeshPainter scales x by imgDim/charWidth so the character fills the canvas.
    final aspectRatio = s.charWidth / s.charHeight;
    return AspectRatio(
      aspectRatio: aspectRatio,
      child: CustomPaint(
        painter: MeshPainter(
          texture: s.texture,
          imgDim: s.imgDim,
          charWidth: s.charWidth,
          vertexPositions: _currentVertexPositions,
          texCoords: s.uvCoords,
          indices: _currentIndices,
        ),
      ),
    );
  }
}
