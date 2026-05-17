import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show debugPrint;

import 'lbs_weights.dart';

/// LBS deformation solver replacing Python ARAP.
/// All coords are normalized [0,1].
class LbsSolver {
  final int numVertices;
  final int numJoints;

  /// Initial vertex positions [numVerts × 2]
  final Float32List _origVerts;

  /// Initial joint positions [numJoints × 2]
  final Float32List _origJoints;

  /// Parent index per joint (-1 for root), length = numJoints
  final Int32List _parentIndices;

  /// Skinning weights [numVerts × numJoints]
  late final Float32List _weights;

  LbsSolver({
    required Float32List origVerts,
    required Float32List origJoints,
    required Int32List parentIndices,
  })  : numVertices = origVerts.length ~/ 2,
        numJoints = origJoints.length ~/ 2,
        _origVerts = Float32List.fromList(origVerts),
        _origJoints = Float32List.fromList(origJoints),
        _parentIndices = Int32List.fromList(parentIndices) {
    debugPrint('[LBS] init  verts=${origVerts.length ~/ 2}  joints=${origJoints.length ~/ 2}');
    _weights = computeLbsWeights(origVerts, origJoints, parentIndices: parentIndices);
    debugPrint('[LBS] weights computed  shape=[$numVertices×$numJoints]');
  }

  /// Given new joint positions [numJoints × 2], return new vertex positions [numVerts × 2].
  /// Replaces ARAP.solve() with bone-rotation-based LBS.
  Float32List solve(Float32List newJoints) {
    assert(newJoints.length == numJoints * 2);

    // Compute per-joint rotation angle from bone direction change
    // For joint j with parent p: angle = atan2(new_dir) - atan2(orig_dir)
    final angles = Float32List(numJoints);
    // Build a simple parent index map (joint 0 = root, assume each joint > 0 has parent)
    // Since we don't have explicit hierarchy here, approximate: use nearest joint as anchor
    // Better: use bone-to-parent rotation for each joint
    // For now: compute rotation as change in position direction from origin
    for (int ji = 0; ji < numJoints; ji++) {
      angles[ji] = 0.0; // overridden by _computeBoneAngles below
    }
    _computeBoneAngles(angles, newJoints);

    // LBS: v' = Σ_j w_j * (R_j * (v - j_orig) + j_new)
    final result = Float32List(numVertices * 2);
    for (int vi = 0; vi < numVertices; vi++) {
      final vx = _origVerts[vi * 2];
      final vy = _origVerts[vi * 2 + 1];
      double rx = 0, ry = 0;
      for (int ji = 0; ji < numJoints; ji++) {
        final w = _weights[vi * numJoints + ji];
        if (w < 1e-8) continue;
        final jox = _origJoints[ji * 2];
        final joy = _origJoints[ji * 2 + 1];
        final jnx = newJoints[ji * 2];
        final jny = newJoints[ji * 2 + 1];
        final angle = angles[ji];
        // Rotate vertex relative to original joint
        final dvx = vx - jox;
        final dvy = vy - joy;
        final cos = math.cos(angle);
        final sin = math.sin(angle);
        rx += w * (jnx + cos * dvx - sin * dvy);
        ry += w * (jny + sin * dvx + cos * dvy);
      }
      result[vi * 2] = rx;
      result[vi * 2 + 1] = ry;
    }
    return result;
  }

  void _computeBoneAngles(Float32List angles, Float32List newJoints) {
    for (int ji = 0; ji < numJoints; ji++) {
      final parentIdx = _parentIndices[ji];
      if (parentIdx < 0) continue;

      final opx = _origJoints[parentIdx * 2];
      final opy = _origJoints[parentIdx * 2 + 1];
      final origDx = _origJoints[ji * 2] - opx;
      final origDy = _origJoints[ji * 2 + 1] - opy;

      final npx = newJoints[parentIdx * 2];
      final npy = newJoints[parentIdx * 2 + 1];
      final newDx = newJoints[ji * 2] - npx;
      final newDy = newJoints[ji * 2 + 1] - npy;

      if (origDx * origDx + origDy * origDy < 1e-12 ||
          newDx * newDx + newDy * newDy < 1e-12) { continue; }

      angles[ji] = math.atan2(newDy, newDx) - math.atan2(origDy, origDx);
    }
  }
}
