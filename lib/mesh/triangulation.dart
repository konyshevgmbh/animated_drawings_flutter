import 'dart:typed_data';
import 'package:flutter/foundation.dart' show debugPrint;

import '../annotation/char_cfg.dart';

/// Mesh vertex: normalized [0,1] coords used for both position and UV.
class MeshVertex {
  final double x;
  final double y;
  const MeshVertex(this.x, this.y);
}

class CharMesh {
  final List<MeshVertex> vertices;
  /// Triangle indices into vertices, 3 per triangle.
  final Uint16List triangles;
  /// maps joint name → flat array of vertex indices for all triangles owned by that joint
  final Map<String, Uint16List> jointToTriIndices;

  const CharMesh({
    required this.vertices,
    required this.triangles,
    required this.jointToTriIndices,
  });
}

/// Bowyer-Watson Delaunay triangulation — web-safe float64 predicates.
///
/// The original `delaunay` pub package uses int32×int32 products in the
/// in-circle test.  On JS (53-bit float) those products overflow when
/// coordinates exceed ~46,340, flipping the predicate sign non-determin-
/// istically → infinite legalization loop.
///
/// Fix: our in-circle determinant uses float64 on normalized [0,1] coords.
/// The 3×3 determinant is bounded by ≈12 — well within float64 precision —
/// so no overflow is possible on any platform.
///
/// Pipeline:
///   1. Staggered N×N grid; include vertex if any mask pixel within ½-cell
///      radius is non-zero (area sampling → thin appendages captured).
///   2. Bowyer-Watson incremental Delaunay on sampled points.
///   3. Discard triangles whose centroid is outside the mask.
///   4. Compact (remove unreferenced vertices).
///   5. Laplacian smoothing (boundary fixed, 3 iterations).
///   6. BFS joint-to-triangle mapping.
CharMesh buildMesh(Uint8List maskData, int imgDim, CharConfig charCfg) {
  debugPrint('[Mesh] buildMesh  imgDim=$imgDim  skeletonJoints=${charCfg.skeleton.length}');

  const int N = 80;  

  // ── 1. Staggered grid + area sampling ──────────────────────────────────────
  // Odd rows shifted +0.5 cell (≈60° triangles).
  // Vertex included if single-pixel OR any pixel within hc (circumradius margin).
  debugPrint('[Mesh] step 1 — staggered grid + area sampling  N=$N');
  final cellPx = (imgDim - 1.0) / (N - 1);
  // Circumradius of our staggered triangle = 0.625×cellPx; use 0.7 as margin.
  final hc = (cellPx * 0.7).ceil().clamp(1, 30);
  debugPrint('[Mesh]   cellPx=${cellPx.toStringAsFixed(1)}  hc=$hc');

  bool checkArea(int cpx, int cpy) {
    for (int dy = -hc; dy <= hc; dy++) {
      for (int dx = -hc; dx <= hc; dx++) {
        final npx = (cpx + dx).clamp(0, imgDim - 1);
        final npy = (cpy + dy).clamp(0, imgDim - 1);
        if (maskData[npy * imgDim + npx] > 0) return true;
      }
    }
    return false;
  }

  final ptX = <double>[];
  final ptY = <double>[];

  for (int j = 0; j < N; j++) {
    final offsetX = j.isOdd ? 0.5 : 0.0;
    for (int i = 0; i < N; i++) {
      final nx = ((i + offsetX) / (N - 1.0)).clamp(0.0, 1.0);
      final ny = j / (N - 1.0);
      final cpx = (nx * (imgDim - 1)).round().clamp(0, imgDim - 1);
      final cpy = (ny * (imgDim - 1)).round().clamp(0, imgDim - 1);
      if (maskData[cpy * imgDim + cpx] > 0 || checkArea(cpx, cpy)) {
        ptX.add(nx);
        ptY.add(ny);
      }
    }
  }
  debugPrint('[Mesh]   sample points=${ptX.length}');
  if (ptX.isEmpty) throw StateError('No mask pixels found — check mask data');

  // ── 2. Bowyer-Watson Delaunay (float64, web-safe) ──────────────────────────
  debugPrint('[Mesh] step 2 — Bowyer-Watson Delaunay');
  final rawTris = _delaunay(ptX, ptY);
  debugPrint('[Mesh]   raw triangles=${rawTris.length}');

  // ── 3. Centroid filter: keep triangles inside mask ─────────────────────────
  debugPrint('[Mesh] step 3 — centroid filter');
  final triList = <int>[];
  for (final t in rawTris) {
    final cx = ((ptX[t.$1] + ptX[t.$2] + ptX[t.$3]) / 3 * imgDim).round().clamp(0, imgDim - 1);
    final cy = ((ptY[t.$1] + ptY[t.$2] + ptY[t.$3]) / 3 * imgDim).round().clamp(0, imgDim - 1);
    if (maskData[cy * imgDim + cx] > 0) {
      triList.addAll([t.$1, t.$2, t.$3]);
    }
  }
  debugPrint('[Mesh]   filtered triangles=${triList.length ~/ 3}');
  if (triList.isEmpty) throw StateError('No triangles inside mask — check mask data');

  // ── 4. Compact: remove unreferenced vertices ───────────────────────────────
  debugPrint('[Mesh] step 4 — compact vertices');
  final usedSet = <int>{};
  for (final idx in triList) { usedSet.add(idx); }

  final sortedUsed = usedSet.toList()..sort();
  final remap = Int32List(ptX.length)..fillRange(0, ptX.length, -1);
  final compactVerts = <MeshVertex>[];
  for (final v in sortedUsed) {
    remap[v] = compactVerts.length;
    compactVerts.add(MeshVertex(ptX[v], ptY[v]));
  }
  final compactTri = List<int>.generate(triList.length, (i) => remap[triList[i]]);
  debugPrint('[Mesh]   compact verts=${compactVerts.length}  tris=${compactTri.length ~/ 3}');

  // ── 5. Laplacian smoothing (boundary fixed, 3 passes) ─────────────────────
  debugPrint('[Mesh] step 5 — Laplacian smoothing');
  final numVerts = compactVerts.length;
  final adj = List<Set<int>>.generate(numVerts, (_) => <int>{});
  final edgeCount = <int, int>{};

  for (int t = 0; t < compactTri.length; t += 3) {
    final va = compactTri[t], vb = compactTri[t + 1], vc = compactTri[t + 2];
    adj[va]..add(vb)..add(vc);
    adj[vb]..add(va)..add(vc);
    adj[vc]..add(va)..add(vb);
    for (final pair in [(va, vb), (vb, vc), (vc, va)]) {
      final lo = pair.$1 < pair.$2 ? pair.$1 : pair.$2;
      final hi = pair.$1 < pair.$2 ? pair.$2 : pair.$1;
      final ek = lo * numVerts + hi;
      edgeCount[ek] = (edgeCount[ek] ?? 0) + 1;
    }
  }

  final isBoundary = List<bool>.filled(numVerts, false);
  for (final entry in edgeCount.entries) {
    if (entry.value == 1) {
      isBoundary[entry.key ~/ numVerts] = true;
      isBoundary[entry.key % numVerts]  = true;
    }
  }
  debugPrint('[Mesh]   boundary=${isBoundary.where((b) => b).length}');

  var sxArr = Float64List(numVerts);
  var syArr = Float64List(numVerts);
  for (int v = 0; v < numVerts; v++) { sxArr[v] = compactVerts[v].x; syArr[v] = compactVerts[v].y; }

  for (int iter = 0; iter < 3; iter++) {
    final nxArr = Float64List.fromList(sxArr);
    final nyArr = Float64List.fromList(syArr);
    for (int v = 0; v < numVerts; v++) {
      if (isBoundary[v] || adj[v].isEmpty) continue;
      var sx = 0.0, sy = 0.0;
      for (final n in adj[v]) { sx += sxArr[n]; sy += syArr[n]; }
      nxArr[v] = sx / adj[v].length;
      nyArr[v] = sy / adj[v].length;
    }
    sxArr = nxArr; syArr = nyArr;
  }

  final smoothedVerts = List<MeshVertex>.generate(numVerts, (v) => MeshVertex(sxArr[v], syArr[v]));

  // ── 6. BFS joint-to-triangle mapping ───────────────────────────────────────
  debugPrint('[Mesh] step 6 — BFS joint-to-triangle mapping');
  final triangles = Uint16List.fromList(compactTri);
  final jointToTri = _buildJointToTriMap(maskData, imgDim, charCfg, smoothedVerts, triangles);
  debugPrint('[Mesh]   jointToTri entries=${jointToTri.length}  keys: ${jointToTri.keys.take(5).join(", ")}');

  debugPrint('[Mesh] buildMesh DONE  verts=${smoothedVerts.length}  tris=${triangles.length ~/ 3}');
  return CharMesh(vertices: smoothedVerts, triangles: triangles, jointToTriIndices: jointToTri);
}

// ─── Bowyer-Watson Delaunay ────────────────────────────────────────────────

/// Incremental Delaunay via Bowyer-Watson.  O(n²) time, fine for n ≤ 2000.
///
/// Predicates use float64; on normalized [0,1] coords the in-circle determinant
/// is bounded by ≈12 — well within 53-bit mantissa — so the sign is always correct.
List<(int, int, int)> _delaunay(List<double> xs, List<double> ys) {
  final n = xs.length;
  // Append super-triangle vertices well outside [0,1]×[0,1].
  final ax = List<double>.from(xs)..addAll([-3.0, 4.0, 0.5]);
  final ay = List<double>.from(ys)..addAll([-3.0, -3.0, 5.0]);
  final m  = n + 3; // total vertex count for key packing

  var tris = <(int, int, int)>[(n, n + 1, n + 2)];

  for (int p = 0; p < n; p++) {
    // Partition: bad = circumcircle contains p, good = does not.
    final bad  = <(int, int, int)>[];
    final next = <(int, int, int)>[];
    for (final t in tris) {
      if (_inCircle(ax, ay, t.$1, t.$2, t.$3, p)) {
        bad.add(t);
      } else {
        next.add(t);
      }
    }

    // Boundary edges of the cavity: appear exactly once across bad triangles.
    // Key = canonical lo*m+hi; dirA/dirB store the directed version.
    final occ  = <int, int>{};
    final dirA = <int, int>{};
    final dirB = <int, int>{};
    for (final t in bad) {
      for (final e in [(t.$1, t.$2), (t.$2, t.$3), (t.$3, t.$1)]) {
        final lo = e.$1 < e.$2 ? e.$1 : e.$2;
        final hi = e.$1 < e.$2 ? e.$2 : e.$1;
        final key = lo * m + hi;
        if (!occ.containsKey(key)) { dirA[key] = e.$1; dirB[key] = e.$2; }
        occ[key] = (occ[key] ?? 0) + 1;
      }
    }

    // Re-triangulate from p to each boundary edge (CCW orientation).
    tris = next;
    for (final entry in occ.entries) {
      if (entry.value != 1) continue;
      final ea = dirA[entry.key]!;
      final eb = dirB[entry.key]!;
      // cross > 0 → (ea,eb,p) is CCW; cross < 0 → flip.
      final cross = (ax[eb] - ax[ea]) * (ay[p] - ay[ea])
                  - (ay[eb] - ay[ea]) * (ax[p] - ax[ea]);
      if (cross > 1e-14) {
        tris.add((ea, eb, p));
      } else if (cross < -1e-14) {
        tris.add((eb, ea, p));
      }
      // |cross| ≤ 1e-14 → degenerate (collinear), skip
    }
  }

  // Discard triangles touching super-triangle vertices (indices n, n+1, n+2).
  return tris.where((t) => t.$1 < n && t.$2 < n && t.$3 < n).toList();
}

/// In-circle test using float64 (3×3 determinant expansion).
///
/// Returns true iff point [d] lies strictly inside the circumcircle of the
/// CCW triangle (a, b, c).  For [0,1] coords the determinant is ≤ 12 →
/// float64 sign is always exact (no int32 overflow on JS).
bool _inCircle(List<double> xs, List<double> ys, int a, int b, int c, int d) {
  final adx = xs[a] - xs[d], ady = ys[a] - ys[d];
  final bdx = xs[b] - xs[d], bdy = ys[b] - ys[d];
  final cdx = xs[c] - xs[d], cdy = ys[c] - ys[d];
  // 3×3 determinant: always bounded for [0,1] inputs.
  return adx * (bdy * (cdx * cdx + cdy * cdy) - cdy * (bdx * bdx + bdy * bdy))
       - ady * (bdx * (cdx * cdx + cdy * cdy) - cdx * (bdx * bdx + bdy * bdy))
       + (adx * adx + ady * ady) * (bdx * cdy - bdy * cdx) > 0;
}

// ─── BFS Joint Assignment ──────────────────────────────────────────────────

Map<String, Uint16List> _buildJointToTriMap(
    Uint8List mask, int imgDim,
    CharConfig charCfg, List<MeshVertex> verts, Uint16List triangles) {
  final sw = Stopwatch()..start();
  final int cells = imgDim * imgDim;

  const int kCard = 10, kDiag = 14;
  final shortestDist = Int32List(cells)..fillRange(0, cells, 0x7fffffff);
  final closestJoint  = Int32List(cells)..fillRange(0, cells, -1);

  final joints = charCfg.skeleton;
  final jointNameToIdx = {for (int i = 0; i < joints.length; i++) joints[i].name: i};

  debugPrint('[BFS] start  cells=$cells  joints=${joints.length}');

  final seeds = <(int, int, int)>[];
  for (final joint in joints) {
    if (joint.parent == null) continue;
    final parent = joints.firstWhere((j) => j.name == joint.parent);
    final ji = jointNameToIdx[joint.name]!;
    for (int s = 0; s < 20; s++) {
      final t  = s / 20.0;
      final ix = (joint.x + t * (parent.x - joint.x)).round().clamp(0, imgDim - 1);
      final iy = (joint.y + t * (parent.y - joint.y)).round().clamp(0, imgDim - 1);
      seeds.add((ji, ix, iy));
    }
  }
  debugPrint('[BFS] seeds=${seeds.length}');

  final maxDist = imgDim * 15;
  final buckets = List<List<(int, int, int)>>.generate(maxDist, (_) => []);

  for (final (ji, x, y) in seeds) {
    if (mask[y * imgDim + x] == 0) continue;
    if (shortestDist[y * imgDim + x] > 0) {
      shortestDist[y * imgDim + x] = 0;
      closestJoint[y * imgDim + x]  = ji;
      buckets[0].add((ji, x, y));
    }
  }

  const dx = [-1, 0, 1, -1, 1, -1, 0, 1];
  const dy = [-1, -1, -1,  0, 0,  1, 1, 1];
  const dd = [kDiag, kCard, kDiag, kCard, kCard, kDiag, kCard, kDiag];

  int processed = 0;
  for (int dist = 0; dist < maxDist; dist++) {
    final bucket = buckets[dist];
    if (bucket.isEmpty) continue;
    for (int bi = 0; bi < bucket.length; bi++) {
      final (ji, x, y) = bucket[bi];
      if (shortestDist[y * imgDim + x] != dist) continue;
      processed++;
      for (int d = 0; d < 8; d++) {
        final nx = x + dx[d], ny = y + dy[d];
        if (nx < 0 || nx >= imgDim || ny < 0 || ny >= imgDim) continue;
        if (mask[ny * imgDim + nx] == 0) continue;
        final nd = dist + dd[d];
        if (nd >= maxDist || shortestDist[ny * imgDim + nx] <= nd) continue;
        shortestDist[ny * imgDim + nx] = nd;
        closestJoint[ny * imgDim + nx]  = ji;
        buckets[nd].add((ji, nx, ny));
      }
    }
  }
  debugPrint('[BFS] done  processed=$processed  elapsed=${sw.elapsedMilliseconds}ms');

  final jointToTriVerts = <int, List<int>>{};
  for (int i = 0; i < triangles.length; i += 3) {
    final a = verts[triangles[i]];
    final b = verts[triangles[i + 1]];
    final c = verts[triangles[i + 2]];
    final cx = ((a.x + b.x + c.x) / 3 * imgDim).round().clamp(0, imgDim - 1);
    final cy = ((a.y + b.y + c.y) / 3 * imgDim).round().clamp(0, imgDim - 1);
    final ji = closestJoint[cy * imgDim + cx];
    if (ji < 0) continue;
    jointToTriVerts.putIfAbsent(ji, () => <int>[])
        .addAll([triangles[i], triangles[i + 1], triangles[i + 2]]);
  }

  return {
    for (final entry in jointToTriVerts.entries)
      joints[entry.key].name: Uint16List.fromList(entry.value),
  };
}
