import 'dart:math' show Point;
import 'dart:typed_data';
import 'dart:ui' show Offset;
import 'package:flutter/foundation.dart' show debugPrint;

import 'package:delaunay/delaunay.dart';

import '../annotation/char_cfg.dart';
import 'douglas_peucker.dart';
import 'marching_squares.dart';

/// Mesh vertex: normalized [0,1] coords + original pixel row,col for UV.
class MeshVertex {
  final double x; // normalized (mesh_col / img_dim)
  final double y; // normalized (mesh_row / img_dim)
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

/// Port of animated_drawing.py:_generate_mesh() + _initialize_joint_to_triangles_dict().
/// [maskData] – row-major Uint8List of size [imgDim × imgDim] (values 0 or 255).
/// [imgDim]   – padded square size = max(height, width) of char image.
/// [charCfg]  – skeleton joints in pixel coords.
CharMesh buildMesh(Uint8List maskData, int imgDim, CharConfig charCfg) {
  debugPrint('[Mesh] buildMesh  imgDim=$imgDim  skeletonJoints=${charCfg.skeleton.length}');

  // 1. Extract contour from mask
  debugPrint('[Mesh] step 1 — marchingSquares');
  final contour = marchingSquares(maskData, imgDim, imgDim);
  if (contour.isEmpty) throw StateError('No contour found in mask');
  debugPrint('[Mesh]   contour points=${contour.length}');

  // 2. Simplify contour (tolerance=0.25 pixels)
  debugPrint('[Mesh] step 2 — simplifyPolygon (tol=0.25)');
  final simplified = simplifyPolygon(contour, 0.25);
  debugPrint('[Mesh]   simplified points=${simplified.length}');

  // 3. Interior grid: 40×40 points, keep those inside contour
  debugPrint('[Mesh] step 3 — interior grid 40×40');
  final inside = <Offset>[];
  for (int i = 0; i < 40; i++) {
    for (int j = 0; j < 40; j++) {
      final p = Offset(imgDim * i / 39.0, imgDim * j / 39.0);
      if (_pointInPolygon(p, simplified)) inside.add(p);
    }
  }
  debugPrint('[Mesh]   interior points inside mask=${inside.length}');

  // 4. Combine, deduplicating points within 0.5 px of each other.
  //    Near-duplicate points produce machine-epsilon-area triangles that make
  //    the ARAP step-2 system under-determined (zero-vector edge constraints
  //    leave those vertices unconstrained → pulled to zero by the solver).
  debugPrint('[Mesh] step 4 — deduplicate and combine points (merge radius 0.5 px)');
  const double mergeDistSq = 0.5 * 0.5;
  final allPts = <Offset>[...simplified];
  int droppedNearDups = 0;
  for (final p in inside) {
    bool tooClose = false;
    for (final existing in allPts) {
      final dx = p.dx - existing.dx, dy = p.dy - existing.dy;
      if (dx * dx + dy * dy < mergeDistSq) { tooClose = true; break; }
    }
    if (tooClose) { droppedNearDups++; } else { allPts.add(p); }
  }
  if (droppedNearDups > 0) {
    debugPrint('[Mesh]   dropped $droppedNearDups near-duplicate interior points');
  }
  debugPrint('[Mesh] step 4 — total input points=${allPts.length} '
      '(outline=${simplified.length} + interior=${allPts.length - simplified.length})');
  final points = allPts.map((o) => Point<double>(o.dx, o.dy)).toList();

  // 5. Delaunay triangulation
  debugPrint('[Mesh] step 5 — Delaunay triangulation');
  final tri = Delaunay.from(points);
  tri.initialize();
  tri.processAllPoints();
  debugPrint('[Mesh]   raw triangles=${tri.triangles.length ~/ 3}');

  // 6. Filter: keep triangles whose centroid is inside contour and are non-degenerate.
  //    Degenerate triangles (area < 0.1 px²) produce zero-vector edges that
  //    leave adjacent vertices unconstrained in the ARAP step-2 solve.
  debugPrint('[Mesh] step 6 — filter triangles by centroid-in-contour and area');
  final goodTris = <int>[];
  int skippedDegenerate = 0;
  for (int i = 0; i < tri.triangles.length; i += 3) {
    final a = tri.getPoint(tri.triangles[i]);
    final b = tri.getPoint(tri.triangles[i + 1]);
    final c = tri.getPoint(tri.triangles[i + 2]);
    // Area in pixel space — skip near-zero triangles
    final area = ((b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)).abs() * 0.5;
    if (area < 0.1) { skippedDegenerate++; continue; }
    final centroid = Offset(
      (a.x + b.x + c.x) / 3,
      (a.y + b.y + c.y) / 3,
    );
    if (_pointInPolygon(centroid, simplified)) {
      goodTris.add(tri.triangles[i]);
      goodTris.add(tri.triangles[i + 1]);
      goodTris.add(tri.triangles[i + 2]);
    }
  }
  if (skippedDegenerate > 0) {
    debugPrint('[Mesh]   skipped $skippedDegenerate degenerate triangles (area<0.1 px²)');
  }
  debugPrint('[Mesh]   triangles after filter=${goodTris.length ~/ 3}');

  // 7. Normalize vertices to [0,1]
  final verts = allPts
      .map((o) => MeshVertex(o.dx / imgDim, o.dy / imgDim))
      .toList();

  final triangles = Uint16List.fromList(goodTris);

  // Diagnostic: empty mesh guard
  if (goodTris.isEmpty) {
    debugPrint('[Mesh] WARNING: no triangles survived centroid filter — mesh is empty!');
  } else {
    // Paranoia: verify Delaunay uses the original input ordering
    final si = tri.triangles[0];
    if (si >= 0 && si < allPts.length) {
      final ep = allPts[si];
      final gp = tri.getPoint(si);
      if ((gp.x - ep.dx).abs() > 1.0 || (gp.y - ep.dy).abs() > 1.0) {
        debugPrint('[Mesh] WARNING: Delaunay index-ordering mismatch at idx=$si — '
            'allPts=(${ep.dx.toStringAsFixed(0)},${ep.dy.toStringAsFixed(0)}) '
            'getPoint=(${gp.x.toStringAsFixed(0)},${gp.y.toStringAsFixed(0)})');
      }
    }
    // Count degenerate triangles (near-zero area in normalized [0,1] space)
    int degCount = 0;
    double minArea = double.infinity;
    for (int i = 0; i < goodTris.length; i += 3) {
      final a = verts[goodTris[i]], b = verts[goodTris[i + 1]], c = verts[goodTris[i + 2]];
      final area = ((b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)).abs() * 0.5;
      if (area < 1e-8) degCount++;
      if (area < minArea) minArea = area;
    }
    if (degCount > 0) {
      debugPrint('[Mesh] WARNING: $degCount/${goodTris.length ~/ 3} degenerate triangles '
          '(area<1e-8)  minArea=${minArea.toStringAsExponential(2)}');
    } else {
      debugPrint('[Mesh] triangles OK  count=${goodTris.length ~/ 3}  minArea=${minArea.toStringAsExponential(2)}');
    }
  }

  // 8. BFS joint-to-triangle mapping
  debugPrint('[Mesh] step 7 — BFS joint-to-triangle mapping');
  final jointToTri = _buildJointToTriMap(maskData, imgDim, charCfg, verts, triangles);
  debugPrint('[Mesh]   jointToTri entries=${jointToTri.length}  keys: ${jointToTri.keys.take(5).join(", ")}');

  debugPrint('[Mesh] buildMesh DONE  verts=${verts.length}  tris=${triangles.length ~/ 3}');
  return CharMesh(vertices: verts, triangles: triangles, jointToTriIndices: jointToTri);
}

// ─── BFS Joint Assignment ──────────────────────────────────────────────────

Map<String, Uint16List> _buildJointToTriMap(
    Uint8List mask, int imgDim,
    CharConfig charCfg, List<MeshVertex> verts, Uint16List triangles) {
  final sw = Stopwatch()..start();
  final int cells = imgDim * imgDim;

  // Use integer distances ×10: cardinal=10, diagonal=14 (≈√2×10).
  // Bucket queue: array of lists indexed by distance, O(1) push/pop.
  const int kCard = 10, kDiag = 14;
  final shortestDist = Int32List(cells)..fillRange(0, cells, 0x7fffffff);
  final closestJoint = Int32List(cells)..fillRange(0, cells, -1);

  final joints = charCfg.skeleton;
  final jointNameToIdx = {for (int i = 0; i < joints.length; i++) joints[i].name: i};

  debugPrint('[BFS] start  cells=$cells  joints=${joints.length}');

  // Seed: 20 points per bone segment at dist=0
  final seeds = <(int, int, int)>[]; // (ji, x, y)
  for (final joint in joints) {
    if (joint.parent == null) continue;
    final parent = joints.firstWhere((j) => j.name == joint.parent);
    final ji = jointNameToIdx[joint.name]!;
    for (int s = 0; s < 20; s++) {
      final t = s / 20.0;
      final ix = (joint.x + t * (parent.x - joint.x)).round().clamp(0, imgDim - 1);
      final iy = (joint.y + t * (parent.y - joint.y)).round().clamp(0, imgDim - 1);
      seeds.add((ji, ix, iy));
    }
  }
  debugPrint('[BFS] seeds=${seeds.length}');

  // Bucket queue: max distance ≈ imgDim × 14 (diagonal across the image)
  final maxDist = imgDim * 15;
  final buckets = List<List<(int, int, int)>>.generate(maxDist, (_) => []);

  for (final (ji, x, y) in seeds) {
    if (mask[y * imgDim + x] == 0) continue;
    if (shortestDist[y * imgDim + x] > 0) {
      shortestDist[y * imgDim + x] = 0;
      closestJoint[y * imgDim + x] = ji;
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
      if (shortestDist[y * imgDim + x] != dist) continue; // stale entry
      processed++;
      for (int d = 0; d < 8; d++) {
        final nx = x + dx[d], ny = y + dy[d];
        if (nx < 0 || nx >= imgDim || ny < 0 || ny >= imgDim) continue;
        if (mask[ny * imgDim + nx] == 0) continue;
        final nd = dist + dd[d];
        if (nd >= maxDist || shortestDist[ny * imgDim + nx] <= nd) continue;
        shortestDist[ny * imgDim + nx] = nd;
        closestJoint[ny * imgDim + nx] = ji;
        buckets[nd].add((ji, nx, ny));
      }
    }
  }
  debugPrint('[BFS] done  processed=$processed  elapsed=${sw.elapsedMilliseconds}ms');

  // Map triangle centroids to closest joint
  final jointToTriVerts = <int, List<int>>{};
  for (int i = 0; i < triangles.length; i += 3) {
    final a = verts[triangles[i]];
    final b = verts[triangles[i + 1]];
    final c = verts[triangles[i + 2]];
    final cx = ((a.x + b.x + c.x) / 3 * imgDim).round().clamp(0, imgDim - 1);
    final cy = ((a.y + b.y + c.y) / 3 * imgDim).round().clamp(0, imgDim - 1);
    final ji = closestJoint[cy * imgDim + cx];
    if (ji < 0) continue;
    jointToTriVerts.putIfAbsent(ji, () => <int>[]).addAll([triangles[i], triangles[i + 1], triangles[i + 2]]);
  }

  return {
    for (final entry in jointToTriVerts.entries)
      joints[entry.key].name: Uint16List.fromList(entry.value),
  };
}

// ─── Point-in-polygon (ray casting) ───────────────────────────────────────

bool _pointInPolygon(Offset pt, List<Offset> polygon) {
  int crossings = 0;
  final n = polygon.length;
  for (int i = 0; i < n; i++) {
    final a = polygon[i];
    final b = polygon[(i + 1) % n];
    if ((a.dy <= pt.dy && b.dy > pt.dy) || (b.dy <= pt.dy && a.dy > pt.dy)) {
      final xIntersect = a.dx + (pt.dy - a.dy) / (b.dy - a.dy) * (b.dx - a.dx);
      if (pt.dx < xIntersect) crossings++;
    }
  }
  return crossings % 2 == 1;
}
