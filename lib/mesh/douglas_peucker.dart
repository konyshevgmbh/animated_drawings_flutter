import 'dart:math' as math;
import 'dart:ui' show Offset;

/// Ramer-Douglas-Peucker polygon simplification.
/// Handles both open polylines and closed rings (first≈last or first==last).
List<Offset> simplifyPolygon(List<Offset> points, double tolerance) {
  if (points.length <= 2) return List.from(points);

  // Detect closed ring: first and last points are the same or very close.
  final first = points.first;
  final last = points.last;
  final isClosed = (first - last).distance < tolerance * 4;

  if (isClosed) {
    return _rdpRing(points, tolerance);
  }
  return _rdpOpen(points, 0, points.length - 1, tolerance);
}

/// Ring-aware simplification: find the two most-distant points as split,
/// then run RDP on each half independently.
List<Offset> _rdpRing(List<Offset> pts, double eps) {
  final n = pts.length;
  // Find the two indices furthest apart
  int i0 = 0, i1 = n ~/ 2; // good default split
  double maxDist = 0;
  // Sample to keep O(N) not O(N²)
  final step = math.max(1, n ~/ 200);
  for (int a = 0; a < n; a += step) {
    for (int b = a + n ~/ 4; b < a + 3 * n ~/ 4; b += step) {
      final bi = b % n;
      final d = (pts[a] - pts[bi]).distance;
      if (d > maxDist) {
        maxDist = d;
        i0 = a;
        i1 = bi;
      }
    }
  }
  if (i0 > i1) {
    final tmp = i0; i0 = i1; i1 = tmp;
  }

  // Run open RDP on each half
  final half1 = pts.sublist(i0, i1 + 1);
  final half2 = [...pts.sublist(i1), ...pts.sublist(0, i0 + 1)];

  final s1 = _rdpOpen(half1, 0, half1.length - 1, eps);
  final s2 = _rdpOpen(half2, 0, half2.length - 1, eps);

  // Combine: s1 ends at i1, s2 starts at i1 — avoid duplicate
  return [...s1, ...s2.skip(1)];
}

List<Offset> _rdpOpen(List<Offset> pts, int start, int end, double eps) {
  if (end <= start + 1) return [pts[start], pts[end]];
  double maxDist = 0;
  int maxIdx = start;
  for (int i = start + 1; i < end; i++) {
    final d = _perpendicularDist(pts[i], pts[start], pts[end]);
    if (d > maxDist) {
      maxDist = d;
      maxIdx = i;
    }
  }
  if (maxDist > eps) {
    final left = _rdpOpen(pts, start, maxIdx, eps);
    final right = _rdpOpen(pts, maxIdx, end, eps);
    return [...left, ...right.skip(1)];
  }
  return [pts[start], pts[end]];
}

double _perpendicularDist(Offset pt, Offset lineStart, Offset lineEnd) {
  final dx = lineEnd.dx - lineStart.dx;
  final dy = lineEnd.dy - lineStart.dy;
  final len = math.sqrt(dx * dx + dy * dy);
  if (len < 1e-12) return (pt - lineStart).distance;
  return ((dy * pt.dx - dx * pt.dy +
              lineEnd.dx * lineStart.dy -
              lineEnd.dy * lineStart.dx) /
          len)
      .abs();
}
