import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;

import '../bvh/bvh_parser.dart';
import 'config_models.dart';
import 'pca.dart';

const List<double> _xAxis = [1.0, 0.0, 0.0];
const List<double> _zAxis = [0.0, 0.0, 1.0];

class RetargetedFrame {
  /// char joint name → orientation (degrees CCW from +Y)
  final Map<String, double> orientations;
  /// bvh joint name → depth from projection plane
  final Map<String, double> jointDepths;
  /// root offset [x, y, z] in char normalized space
  final List<double> rootPosition;

  const RetargetedFrame({
    required this.orientations,
    required this.jointDepths,
    required this.rootPosition,
  });
}

class Retargeter {
  late final BvhData _bvh;
  late final List<String> _bvhJointNames;

  // [frameCount × jointCount × 3] — world positions, root-normalized, facing +X
  late final Float32List _jointPositions; // flat: [frame * jointCount * 3 + joint * 3 + axis]
  late final Float32List _fwdVectors; // [frame × 3]
  late final Float32List _bvhRootPositions; // [frame × 3]

  // bvh joint name → projection plane normal ([1,0,0] or [0,0,1])
  final _jointToPlane = <String, List<double>>{};
  final _groupToPlane = <String, List<double>>{};

  // char joint name → array of orientation per frame
  final _charJointOrientations = <String, Float32List>{};

  // bvh joint name → depth per frame
  final _bvhJointDepths = <String, Float32List>{};

  // char root positions: [frame × 2]
  late Float32List _charRootPositions;
  late List<double> _charStartLoc;

  int get frameCount => _bvh.frameCount;
  double get frameTime => _bvh.frameTime;

  static Future<Retargeter> load(
      MotionConfig motionCfg, RetargetConfig retargetCfg) async {
    final r = Retargeter();
    await r._init(motionCfg, retargetCfg);
    return r;
  }

  Future<void> _init(MotionConfig motionCfg, RetargetConfig retargetCfg) async {
    debugPrint('[Retargeter] _init  bvh=${motionCfg.bvhPath}');

    // Load BVH
    debugPrint('[Retargeter] step 1 — load BVH asset');
    final bvhContent = await rootBundle.loadString(motionCfg.bvhPath);
    _bvh = BvhData.fromString(
      bvhContent,
      motionCfg.bvhPath.split('/').last,
      startFrame: motionCfg.startFrame,
      endFrame: motionCfg.endFrame,
    );
    if (motionCfg.frameTime != null) _bvh.frameTime = motionCfg.frameTime!;
    _bvhJointNames = _bvh.jointNames;
    _charStartLoc = retargetCfg.charStartLoc;
    debugPrint('[Retargeter]   bvh joints=${_bvhJointNames.length}  frames=${_bvh.frameCount}  frameTime=${_bvh.frameTime}');
    debugPrint('[Retargeter]   charStartLoc=$_charStartLoc');

    // Compute joint world positions for all frames (with up/fwd normalization)
    debugPrint('[Retargeter] step 2 — computeNormalizedPositions (up=${motionCfg.up})');
    _computeNormalizedPositions(motionCfg);
    debugPrint('[Retargeter]   _jointPositions.length=${_jointPositions.length}');

    // Projection planes
    debugPrint('[Retargeter] step 3 — determine projection planes (${retargetCfg.bvhProjectionGroups.length} groups)');
    for (final group in retargetCfg.bvhProjectionGroups) {
      final plane = _determinePlane(group.name, group.bvhJointNames, group.method);
      _groupToPlane[group.name] = plane;
      for (final jn in group.bvhJointNames) {
        _jointToPlane[jn] = plane;
      }
      debugPrint('[Retargeter]   group="${group.name}" method=${group.method} → plane=$plane');
    }

    // Depth per joint
    debugPrint('[Retargeter] step 4 — computeDepths');
    _computeDepths();
    debugPrint('[Retargeter]   depth joints tracked: ${_bvhJointDepths.length}');

    // Orientations for each char joint
    debugPrint('[Retargeter] step 5 — computeOrientations (${retargetCfg.charJointBvhMapping.length} char joints)');
    for (final entry in retargetCfg.charJointBvhMapping.entries) {
      final charJoint = entry.key;
      final bvhProx = entry.value[0];
      final bvhDist = entry.value[1];
      _computeOrientations(bvhProx, bvhDist, charJoint);
      debugPrint('[Retargeter]   $charJoint ← ($bvhProx → $bvhDist)');
    }

    // Root offset scaling deferred — call recomputeCharRootPositions() after rig is built.
    _charRootPositions = Float32List(frameCount * 2);
    debugPrint('[Retargeter] step 6 — root positions zeroed (call recomputeCharRootPositions after rig)');

    debugPrint('[Retargeter] _init DONE  frames=$frameCount');
  }

  void _computeNormalizedPositions(MotionConfig motionCfg) {
    final jc = _bvh.jointCount;
    _jointPositions = Float32List(frameCount * jc * 3);
    _fwdVectors = Float32List(frameCount * 3);
    _bvhRootPositions = Float32List(frameCount * 3);

    for (int fi = 0; fi < frameCount; fi++) {
      _bvh.applyFrame(fi);

      // Apply up-axis rotation: for +z up, rotate so +z becomes +y
      final rawPos = _bvh.root.getChainWorldPos();

      // Rotate skeleton if up == '+z': swap y and z (rotate -90° around x → +z up becomes +y up)
      final pos = List<double>.from(rawPos);
      if (motionCfg.up == '+z') {
        for (int j = 0; j < jc; j++) {
          final y = pos[j * 3 + 1];
          final z = pos[j * 3 + 2];
          pos[j * 3 + 1] = z;   // new y = old z
          pos[j * 3 + 2] = -y;  // new z = -old y
        }
      }

      // Root position
      _bvhRootPositions[fi * 3] = pos[0];
      _bvhRootPositions[fi * 3 + 1] = pos[1];
      _bvhRootPositions[fi * 3 + 2] = pos[2];

      // Subtract root to normalize
      for (int j = 0; j < jc; j++) {
        pos[j * 3] -= pos[0];
        pos[j * 3 + 1] -= pos[1];
        pos[j * 3 + 2] -= pos[2];
      }

      // Compute forward vector from perpendicular joints
      final fwd = _getSkeletonFwd(pos, motionCfg.forwardPerpJointVectors);
      _fwdVectors[fi * 3] = fwd[0];
      _fwdVectors[fi * 3 + 1] = fwd[1];
      _fwdVectors[fi * 3 + 2] = fwd[2];

      // Rotate so skeleton faces +X
      final angle = _fwdAngle(fwd);
      final cosA = math.cos(angle), sinA = math.sin(angle);
      for (int j = 0; j < jc; j++) {
        final x = pos[j * 3], z = pos[j * 3 + 2];
        _jointPositions[fi * jc * 3 + j * 3] = cosA * x + sinA * z;
        _jointPositions[fi * jc * 3 + j * 3 + 1] = pos[j * 3 + 1];
        _jointPositions[fi * jc * 3 + j * 3 + 2] = -sinA * x + cosA * z;
      }
    }
  }

  List<double> _getSkeletonFwd(List<double> pos, List<List<String>> pairNames) {
    // Average of perpendicular vectors to given joint pairs
    double avgX = 0, avgZ = 0;
    for (final pair in pairNames) {
      final si = _bvhJointNames.indexOf(pair[0]);
      final ei = _bvhJointNames.indexOf(pair[1]);
      if (si < 0 || ei < 0) continue;
      final dx = pos[ei * 3] - pos[si * 3];
      final dz = pos[ei * 3 + 2] - pos[si * 3 + 2];
      final len = math.sqrt(dx * dx + dz * dz);
      if (len > 1e-8) {
        avgX += dx / len;
        avgZ += dz / len;
      }
    }
    // Perpendicular to average (rotate 90° CW in XZ plane)
    return [avgZ, 0.0, -avgX];
  }

  double _fwdAngle(List<double> fwd) {
    final v1x = 1.0, v1z = 0.0;
    final v2x = fwd[0], v2z = fwd[2];
    final dot = v1x * v2x + v1z * v2z;
    final det = v1x * v2z - v2x * v1z;
    var angle = math.atan2(det, dot);
    angle %= 2 * math.pi;
    if (angle < 0) angle += 2 * math.pi;
    return angle;
  }

  List<double> _determinePlane(
      String groupName, List<String> jointNames, String method) {
    if (method == 'frontal') return List.from(_xAxis);
    if (method == 'sagittal') return List.from(_zAxis);
    // PCA
    final jc = _bvh.jointCount;
    final pts = <List<double>>[];
    for (final jn in jointNames) {
      final ji = _bvhJointNames.indexOf(jn);
      if (ji < 0) continue;
      for (int fi = 0; fi < frameCount; fi++) {
        pts.add([
          _jointPositions[fi * jc * 3 + ji * 3],
          _jointPositions[fi * jc * 3 + ji * 3 + 1],
          _jointPositions[fi * jc * 3 + ji * 3 + 2],
        ]);
      }
    }
    final normal = planaNormalPca(pts);
    final xSim = (normal[0] * _xAxis[0]).abs();
    final zSim = (normal[2] * _zAxis[2]).abs();
    return xSim > zSim ? List.from(_xAxis) : List.from(_zAxis);
  }

  void _computeDepths() {
    final jc = _bvh.jointCount;
    for (final jn in _bvhJointNames) {
      final ji = _bvhJointNames.indexOf(jn);
      if (!_jointToPlane.containsKey(jn)) continue;
      final plane = _jointToPlane[jn]!;
      final depths = Float32List(frameCount);
      for (int fi = 0; fi < frameCount; fi++) {
        final x = _jointPositions[fi * jc * 3 + ji * 3];
        final z = _jointPositions[fi * jc * 3 + ji * 3 + 2];
        depths[fi] = plane[0] != 0 ? x : z;
      }
      _bvhJointDepths[jn] = depths;
    }
  }

  void _computeOrientations(
      String proxJointName, String distJointName, String charJointName) {
    final jc = _bvh.jointCount;
    final proxIdx = _bvhJointNames.indexOf(proxJointName);
    final distIdx = _bvhJointNames.indexOf(distJointName);

    if (proxIdx < 0 || distIdx < 0) {
      _charJointOrientations[charJointName] = Float32List(frameCount);
      return;
    }

    final plane = _jointToPlane[distJointName] ?? _xAxis;
    final thetas = Float32List(frameCount);

    for (int fi = 0; fi < frameCount; fi++) {
      final base = fi * jc * 3;
      final dx = _jointPositions[base + distIdx * 3] - _jointPositions[base + proxIdx * 3];
      final dy = _jointPositions[base + distIdx * 3 + 1] - _jointPositions[base + proxIdx * 3 + 1];
      final dz = _jointPositions[base + distIdx * 3 + 2] - _jointPositions[base + proxIdx * 3 + 2];

      // Project onto 2D plane
      double bx, by;
      if (plane[0] != 0) {
        // frontal: project onto yz plane → use (-z, y) as (x, y)
        bx = -dz; by = dy;
      } else {
        // sagittal: project onto xy plane
        bx = dx; by = dy;
      }

      final len = math.sqrt(bx * bx + by * by);
      if (len > 1e-8) {
        bx /= len; by /= len;
      }

      var theta = (math.atan2(by, bx) - math.atan2(1.0, 0.0)) * 180 / math.pi;
      theta = theta % 360;
      if (theta < 0) theta += 360;
      thetas[fi] = theta;
    }

    _charJointOrientations[charJointName] = thetas;
  }

  /// Compute char-to-BVH scale factor and rebuild root position track.
  /// Must be called after [Retargeter.load] once the character rig is available.
  ///
  /// [charJointPositions] maps joint name → [x, y] in normalized char space.
  /// [motionScale] is MotionConfig.scale (e.g. 0.025 for dab.bvh).
  void recomputeCharRootPositions({
    required Map<String, List<double>> charJointPositions,
    required double motionScale,
    required RetargetConfig cfg,
  }) {
    final rootOffsetGroup = cfg.rootOffsetBvhGroup;
    if (rootOffsetGroup == null) return;
    final charGroups = cfg.charRootOffsetCharJoints;
    final bvhGroups = cfg.charRootOffsetBvhJoints;
    if (charGroups == null || bvhGroups == null) return;

    // Char limb length (normalized coords)
    double charLimb = 0.0;
    for (final group in charGroups) {
      for (int i = 0; i + 1 < group.length; i++) {
        final prox = charJointPositions[group[i]];
        final dist = charJointPositions[group[i + 1]];
        if (prox == null || dist == null) continue;
        final dx = dist[0] - prox[0];
        final dy = dist[1] - prox[1];
        charLimb += math.sqrt(dx * dx + dy * dy);
      }
    }

    // BVH limb length at rest pose (frame 0), scaled by motionScale
    _bvh.applyFrame(0);
    final bvhPos = _bvh.root.getChainWorldPos();
    double bvhLimb = 0.0;
    for (final group in bvhGroups) {
      for (int i = 0; i + 1 < group.length; i++) {
        final pi = _bvhJointNames.indexOf(group[i]);
        final di = _bvhJointNames.indexOf(group[i + 1]);
        if (pi < 0 || di < 0) continue;
        final dx = (bvhPos[di * 3] - bvhPos[pi * 3]) * motionScale;
        final dy = (bvhPos[di * 3 + 1] - bvhPos[pi * 3 + 1]) * motionScale;
        final dz = (bvhPos[di * 3 + 2] - bvhPos[pi * 3 + 2]) * motionScale;
        bvhLimb += math.sqrt(dx * dx + dy * dy + dz * dz);
      }
    }

    final scale = bvhLimb > 1e-8 ? charLimb / bvhLimb : 1.0;
    debugPrint('[Retargeter] recomputeCharRootPositions: charLimb=${charLimb.toStringAsFixed(5)} '
        'bvhLimb=${bvhLimb.toStringAsFixed(5)} scale=${scale.toStringAsFixed(6)}');
    _scaleRootPositions(cfg, rootOffsetGroup, scale);
  }

  void _scaleRootPositions(RetargetConfig cfg, String rootOffsetGroup, double scale) {
    final plane = _groupToPlane[rootOffsetGroup] ?? _xAxis;
    _charRootPositions = Float32List(frameCount * 2);

    for (int fi = 1; fi < frameCount; fi++) {
      final prevRootX = _bvhRootPositions[(fi - 1) * 3];
      final prevRootY = _bvhRootPositions[(fi - 1) * 3 + 1];
      final prevRootZ = _bvhRootPositions[(fi - 1) * 3 + 2];
      final curRootX = _bvhRootPositions[fi * 3];
      final curRootY = _bvhRootPositions[fi * 3 + 1];
      final curRootZ = _bvhRootPositions[fi * 3 + 2];

      final delta = [
        curRootX - prevRootX,
        curRootY - prevRootY,
        curRootZ - prevRootZ,
      ];

      final fwd = [
        _fwdVectors[fi * 3],
        _fwdVectors[fi * 3 + 1],
        _fwdVectors[fi * 3 + 2],
      ];

      if (plane[0] != 0) {
        // frontal: lateral motion — Python: fwd[::-1] * [-1,1,-1] = [-fwd[2], fwd[1], -fwd[0]]
        final v1 = [-fwd[2], fwd[1], -fwd[0]];
        _charRootPositions[fi * 2] =
            _charRootPositions[(fi - 1) * 2] + scale * _dot3(v1, delta);
      } else {
        // sagittal: forward motion
        _charRootPositions[fi * 2] =
            _charRootPositions[(fi - 1) * 2] + scale * _dot3(fwd, delta);
      }
      _charRootPositions[fi * 2 + 1] =
          _charRootPositions[(fi - 1) * 2 + 1] + scale * delta[1];
    }
  }

  double _dot3(List<double> a, List<double> b) =>
      a[0] * b[0] + a[1] * b[1] + a[2] * b[2];

  /// Get retargeted data for the given time (seconds).
  RetargetedFrame getFrame(double time) {
    var fi = (time / _bvh.frameTime).round();
    fi = fi.clamp(0, frameCount - 1);

    final orientations = <String, double>{};
    for (final entry in _charJointOrientations.entries) {
      orientations[entry.key] = entry.value[fi];
    }

    final depths = <String, double>{};
    for (final entry in _bvhJointDepths.entries) {
      depths[entry.key] = entry.value[fi];
    }

    final rootX = fi < _charRootPositions.length ~/ 2
        ? _charRootPositions[fi * 2]
        : 0.0;
    final rootY = fi < _charRootPositions.length ~/ 2
        ? _charRootPositions[fi * 2 + 1]
        : 0.0;

    final rootPos = [
      rootX + _charStartLoc[0],
      rootY + _charStartLoc[1],
      _charStartLoc.length > 2 ? _charStartLoc[2] : 0.0,
    ];

    return RetargetedFrame(
      orientations: orientations,
      jointDepths: depths,
      rootPosition: rootPos,
    );
  }
}
