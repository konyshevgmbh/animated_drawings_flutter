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

/// Grid-based mesh with boundary clipping — no Delaunay, works on all platforms.
///
/// The delaunay package uses 32×32-bit integer products in the in-circle test.
/// On web (JS 53-bit float) those products overflow → sign flips non-deterministically
/// → legalize loops forever even with jitter.
///
/// Algorithm:
///   1. N×N grid; keep vertices whose mask pixel is > 0.
///   2. For each cell split into 2 right-angle triangles.
///      • All-inside cell  → add both triangles as-is (interior quality).
///      • Boundary cell    → clip each triangle: outside vertices are replaced
///        by midpoints of the crossing grid edge, giving a smooth boundary
///        approximation at ½-cell resolution without any floating-point predicates.
///   3. BFS joint-to-triangle mapping (unchanged).
CharMesh buildMesh(Uint8List maskData, int imgDim, CharConfig charCfg) {
  debugPrint('[Mesh] buildMesh  imgDim=$imgDim  skeletonJoints=${charCfg.skeleton.length}');

  const int N = 40; // 40×40 grid → typically ~1000-1300 verts, ~1500-2000 tris

  // ── 1. Grid vertices ────────────────────────────────────────────────────────
  debugPrint('[Mesh] step 1 — $N×$N grid vertices');
  final verts = <MeshVertex>[];
  final gridIdx = List<int>.filled(N * N, -1); // -1 = outside mask

  for (int j = 0; j < N; j++) {
    for (int i = 0; i < N; i++) {
      final nx = i / (N - 1.0);
      final ny = j / (N - 1.0);
      final px = (nx * (imgDim - 1)).round();
      final py = (ny * (imgDim - 1)).round();
      if (maskData[py * imgDim + px] > 0) {
        gridIdx[j * N + i] = verts.length;
        verts.add(MeshVertex(nx, ny));
      }
    }
  }
  debugPrint('[Mesh]   grid verts inside mask=${verts.length}');
  if (verts.isEmpty) throw StateError('No mask pixels found — check mask data');

  // ── 2. Triangulate with boundary clipping ──────────────────────────────────
  //
  // For edges that cross the inside/outside boundary, we add a midpoint vertex
  // (cached so shared edges reuse the same vertex).  Each grid cell then clips
  // its two candidate triangles against the mask: outside corners are replaced
  // by the midpoint of the edge where the boundary crosses, producing a smooth
  // ½-cell-resolution approximation of the character outline.

  // midCache key: canonical (lo, hi) of grid linear indices, packed as lo*N²+hi.
  final midCache = <int, int>{};

  int getMid(int i1, int j1, int i2, int j2) {
    final k1 = i1 * N + j1;
    final k2 = i2 * N + j2;
    final lo = k1 < k2 ? k1 : k2;
    final hi = k1 < k2 ? k2 : k1;
    return midCache.putIfAbsent(lo * (N * N) + hi, () {
      final nx = (i1 + i2) / (2.0 * (N - 1));
      final ny = (j1 + j2) / (2.0 * (N - 1));
      final idx = verts.length;
      verts.add(MeshVertex(nx, ny));
      return idx;
    });
  }

  debugPrint('[Mesh] step 2 — triangulation with boundary clipping');
  final triList = <int>[];

  // Clip triangle (a,b,c).  Indices ≥ 0 = inside mask; -1 = outside.
  // Grid coords (ai,aj) etc. are needed only to create midpoint vertices.
  void clipTri(int a, int b, int c,
               int ai, int aj, int bi, int bj, int ci, int cj) {
    final aIn = a >= 0;
    final bIn = b >= 0;
    final cIn = c >= 0;
    final cnt = (aIn ? 1 : 0) + (bIn ? 1 : 0) + (cIn ? 1 : 0);

    if (cnt == 3) {
      // Fully inside — add as-is.
      triList.addAll([a, b, c]);
    } else if (cnt == 2) {
      // One corner outside — clipped quad → 2 triangles.
      if (!aIn) {
        final mab = getMid(ai, aj, bi, bj);
        final mac = getMid(ai, aj, ci, cj);
        triList.addAll([mab, b, c]);
        triList.addAll([mab, c, mac]);
      } else if (!bIn) {
        final mab = getMid(ai, aj, bi, bj);
        final mbc = getMid(bi, bj, ci, cj);
        triList.addAll([a, mab, mbc]);
        triList.addAll([a, mbc, c]);
      } else {
        // !cIn
        final mac = getMid(ai, aj, ci, cj);
        final mbc = getMid(bi, bj, ci, cj);
        triList.addAll([a, b, mbc]);
        triList.addAll([a, mbc, mac]);
      }
    } else if (cnt == 1) {
      // Two corners outside — small triangle at the surviving corner.
      if (aIn) {
        final mab = getMid(ai, aj, bi, bj);
        final mac = getMid(ai, aj, ci, cj);
        triList.addAll([a, mab, mac]);
      } else if (bIn) {
        final mab = getMid(ai, aj, bi, bj);
        final mbc = getMid(bi, bj, ci, cj);
        triList.addAll([mab, b, mbc]);
      } else {
        final mac = getMid(ai, aj, ci, cj);
        final mbc = getMid(bi, bj, ci, cj);
        triList.addAll([mac, mbc, c]);
      }
    }
    // cnt == 0: fully outside — skip.
  }

  for (int j = 0; j < N - 1; j++) {
    for (int i = 0; i < N - 1; i++) {
      final tl = gridIdx[j * N + i];
      final tr = gridIdx[j * N + (i + 1)];
      final bl = gridIdx[(j + 1) * N + i];
      final br = gridIdx[(j + 1) * N + (i + 1)];

      // Upper-left triangle: TL(i,j) – TR(i+1,j) – BL(i,j+1)
      clipTri(tl, tr, bl, i, j, i + 1, j, i, j + 1);
      // Lower-right triangle: TR(i+1,j) – BR(i+1,j+1) – BL(i,j+1)
      clipTri(tr, br, bl, i + 1, j, i + 1, j + 1, i, j + 1);
    }
  }

  debugPrint('[Mesh]   verts (grid + boundary midpoints)=${verts.length}');
  debugPrint('[Mesh]   triangles=${triList.length ~/ 3}');

  if (triList.isEmpty) {
    debugPrint('[Mesh] WARNING: no triangles — mesh is empty!');
  }

  final triangles = Uint16List.fromList(triList);

  // ── 3. BFS joint-to-triangle mapping ───────────────────────────────────────
  debugPrint('[Mesh] step 3 — BFS joint-to-triangle mapping');
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

  const int kCard = 10, kDiag = 14;
  final shortestDist = Int32List(cells)..fillRange(0, cells, 0x7fffffff);
  final closestJoint = Int32List(cells)..fillRange(0, cells, -1);

  final joints = charCfg.skeleton;
  final jointNameToIdx = {for (int i = 0; i < joints.length; i++) joints[i].name: i};

  debugPrint('[BFS] start  cells=$cells  joints=${joints.length}');

  // Seed: 20 sample points per bone segment
  final seeds = <(int, int, int)>[];
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
      if (shortestDist[y * imgDim + x] != dist) continue;
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
