import 'dart:math' as math;
import 'dart:typed_data';

/// Compute IDW skinning weights based on distance to bone segments.
/// For each vertex and joint j, the distance is measured to the bone segment
/// from parent(j) to j (or to the joint point if j has no parent).
/// Returns [numVertices × numJoints] Float32List, row-major, each row sums to 1.
Float32List computeLbsWeights(
    Float32List vertices2d,  // [numVerts × 2]
    Float32List joints2d,    // [numJoints × 2]
    {Int32List? parentIndices}
) {
  final nv = vertices2d.length ~/ 2;
  final nj = joints2d.length ~/ 2;
  final weights = Float32List(nv * nj);

  for (int vi = 0; vi < nv; vi++) {
    final vx = vertices2d[vi * 2];
    final vy = vertices2d[vi * 2 + 1];
    double sumW = 0;
    for (int ji = 0; ji < nj; ji++) {
      final jx = joints2d[ji * 2];
      final jy = joints2d[ji * 2 + 1];

      double d2;
      final pi = parentIndices != null ? parentIndices[ji] : -1;
      if (pi >= 0) {
        final px = joints2d[pi * 2];
        final py = joints2d[pi * 2 + 1];
        d2 = _distSqToSegment(vx, vy, px, py, jx, jy);
      } else {
        final dx = vx - jx;
        final dy = vy - jy;
        d2 = dx * dx + dy * dy;
      }

      final w = d2 < 1e-12 ? 1e12 : 1.0 / d2;
      weights[vi * nj + ji] = w;
      sumW += w;
    }
    if (sumW > 0) {
      for (int ji = 0; ji < nj; ji++) {
        weights[vi * nj + ji] /= sumW;
      }
    }
  }

  return weights;
}

double _distSqToSegment(
    double px, double py, double ax, double ay, double bx, double by) {
  final dx = bx - ax;
  final dy = by - ay;
  final lenSq = dx * dx + dy * dy;
  if (lenSq < 1e-12) {
    final ex = px - ax;
    final ey = py - ay;
    return ex * ex + ey * ey;
  }
  final t = ((px - ax) * dx + (py - ay) * dy) / lenSq;
  final tc = math.max(0.0, math.min(1.0, t));
  final cx = ax + tc * dx;
  final cy = ay + tc * dy;
  final ex = px - cx;
  final ey = py - cy;
  return ex * ex + ey * ey;
}
