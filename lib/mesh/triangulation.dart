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

/// Staggered-row grid + area sampling + boundary clipping + Laplacian smoothing.
///
/// Two-level mask test per grid vertex:
///   gridIn  = single-pixel check  → used for boundary clipping decisions.
///   areaIn  = any pixel within ½ cell radius → used for vertex inclusion.
/// This ensures thin appendages (< 1 grid cell wide) are captured: the
/// surrounding vertices are included via area sampling and boundary-clipped
/// correctly using the single-pixel test.  Vertices that are area-included
/// but never referenced by any triangle are removed by the compaction step.
CharMesh buildMesh(Uint8List maskData, int imgDim, CharConfig charCfg) {
  debugPrint('[Mesh] buildMesh  imgDim=$imgDim  skeletonJoints=${charCfg.skeleton.length}');

  const int N = 80;

  // ── 1. Staggered grid vertices with area sampling ──────────────────────────
  debugPrint('[Mesh] step 1 — staggered grid + area sampling  N=$N');

  final cellPx = (imgDim - 1.0) / (N - 1); // pixels per grid cell
  // Circumradius of the staggered-grid triangle = 0.625 × cellPx.
  // hc must exceed this to guarantee no feature is missed; 0.7 gives a margin.
  final hc = (cellPx * 0.7).ceil().clamp(1, 30); // area-sampling radius (px)
  debugPrint('[Mesh]   cellPx=${cellPx.toStringAsFixed(1)}  hc=$hc');

  // Local helper: any mask pixel within hc radius?
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

  final gridXY  = Float64List(N * N * 2); // interleaved (x,y) per cell
  final gridIdx = List<int>.filled(N * N, -1);   // vertex index or -1
  final gridIn  = List<bool>.filled(N * N, false); // single-pixel inside
  final verts   = <MeshVertex>[];

  for (int j = 0; j < N; j++) {
    final offsetX = j.isOdd ? 0.5 : 0.0;
    for (int i = 0; i < N; i++) {
      final nx = ((i + offsetX) / (N - 1.0)).clamp(0.0, 1.0);
      final ny = j / (N - 1.0);
      final k  = j * N + i;
      gridXY[k * 2]     = nx;
      gridXY[k * 2 + 1] = ny;

      final cpx = (nx * (imgDim - 1)).round().clamp(0, imgDim - 1);
      final cpy = (ny * (imgDim - 1)).round().clamp(0, imgDim - 1);

      final pointIn = maskData[cpy * imgDim + cpx] > 0;
      gridIn[k] = pointIn;

      if (pointIn || checkArea(cpx, cpy)) {
        gridIdx[k] = verts.length;
        verts.add(MeshVertex(nx, ny));
      }
    }
  }
  debugPrint('[Mesh]   area-included verts=${verts.length}');
  if (!gridIn.any((b) => b)) throw StateError('No mask pixels found — check mask data');

  // ── 2. Triangulate with boundary clipping ──────────────────────────────────
  // getMid: midpoint vertex between two grid-linear-index positions.
  // midCache key = canonical lo*(N²)+hi.
  final midCache = <int, int>{};

  int getMid(int k1, int k2) {
    final lo = k1 < k2 ? k1 : k2;
    final hi = k1 < k2 ? k2 : k1;
    return midCache.putIfAbsent(lo * (N * N) + hi, () {
      final nx = (gridXY[lo * 2]     + gridXY[hi * 2])     / 2.0;
      final ny = (gridXY[lo * 2 + 1] + gridXY[hi * 2 + 1]) / 2.0;
      final idx = verts.length;
      verts.add(MeshVertex(nx, ny));
      return idx;
    });
  }

  debugPrint('[Mesh] step 2 — staggered triangulation + boundary clipping');
  final triList = <int>[];

  // a,b,c     : vertex indices from gridIdx (may be -1 if truly area-excluded)
  // aIn,bIn,cIn : single-pixel inside flags from gridIn
  // ka,kb,kc  : grid linear indices → position source for getMid
  void clipTri(int a, int b, int c,
               bool aIn, bool bIn, bool cIn,
               int ka, int kb, int kc) {
    final cnt = (aIn ? 1 : 0) + (bIn ? 1 : 0) + (cIn ? 1 : 0);
    if (cnt == 3) {
      // All point-inside → all area-included → a,b,c ≥ 0 guaranteed.
      triList.addAll([a, b, c]);
    } else if (cnt == 2) {
      if (!aIn) {
        final mab = getMid(ka, kb), mac = getMid(ka, kc);
        triList.addAll([mab, b, c]);
        triList.addAll([mab, c, mac]);
      } else if (!bIn) {
        final mab = getMid(ka, kb), mbc = getMid(kb, kc);
        triList.addAll([a, mab, mbc]);
        triList.addAll([a, mbc, c]);
      } else {
        final mac = getMid(ka, kc), mbc = getMid(kb, kc);
        triList.addAll([a, b, mbc]);
        triList.addAll([a, mbc, mac]);
      }
    } else if (cnt == 1) {
      if (aIn) {
        final mab = getMid(ka, kb), mac = getMid(ka, kc);
        triList.addAll([a, mab, mac]);
      } else if (bIn) {
        final mab = getMid(ka, kb), mbc = getMid(kb, kc);
        triList.addAll([mab, b, mbc]);
      } else {
        final mac = getMid(ka, kc), mbc = getMid(kb, kc);
        triList.addAll([mac, mbc, c]);
      }
    }
    // cnt == 0: fully outside — skip
  }

  for (int j = 0; j < N - 1; j++) {
    for (int i = 0; i < N - 1; i++) {
      final ka = j * N + i,       kb = j * N + i + 1;
      final kc = (j+1) * N + i,   kd = (j+1) * N + i + 1;
      final a = gridIdx[ka], b = gridIdx[kb];
      final c = gridIdx[kc], d = gridIdx[kd];
      final aIn = gridIn[ka], bIn = gridIn[kb];
      final cIn = gridIn[kc], dIn = gridIn[kd];

      if (j.isEven) {
        // even row j → odd row j+1 (odd shifted +0.5 in x):
        //   ▲ TL(even,i) – TR(even,i+1) – BL(odd,i)
        //   ▽ BL(odd,i)  – TR(even,i+1) – BR(odd,i+1)
        clipTri(a, b, c, aIn, bIn, cIn, ka, kb, kc);
        clipTri(c, b, d, cIn, bIn, dIn, kc, kb, kd);
      } else {
        // odd row j → even row j+1 (odd shifted +0.5 in x):
        //   ▲ TL(odd,i) – BR(even,i+1) – BL(even,i)
        //   ▽ TL(odd,i) – TR(odd,i+1)  – BR(even,i+1)
        clipTri(a, d, c, aIn, dIn, cIn, ka, kd, kc);
        clipTri(a, b, d, aIn, bIn, dIn, ka, kb, kd);
      }
    }
  }

  debugPrint('[Mesh]   raw verts=${verts.length}  raw tris=${triList.length ~/ 3}');
  if (triList.isEmpty) debugPrint('[Mesh] WARNING: no triangles — mesh is empty!');

  // ── 3. Compact: remove area-included-but-unreferenced vertices ─────────────
  // Area-sampled vertices that are outside the mask and never clipped into a
  // triangle are isolated — remove them before ARAP to avoid solver issues.
  debugPrint('[Mesh] step 3 — compact vertices');
  final usedSet = <int>{};
  for (final idx in triList) { usedSet.add(idx); }

  final numRaw = verts.length;
  final remap = Int32List(numRaw)..fillRange(0, numRaw, -1);
  var compactCount = 0;
  final compactVerts = <MeshVertex>[];
  for (int v = 0; v < numRaw; v++) {
    if (usedSet.contains(v)) {
      remap[v] = compactCount++;
      compactVerts.add(verts[v]);
    }
  }
  if (compactVerts.isEmpty) throw StateError('No triangles generated — check mask data');

  final compactTri = List<int>.generate(triList.length, (i) => remap[triList[i]]);
  debugPrint('[Mesh]   compact verts=$compactCount (removed ${numRaw - compactCount} isolated)  tris=${compactTri.length ~/ 3}');

  // ── 4. Laplacian smoothing (interior vertices only) ────────────────────────
  debugPrint('[Mesh] step 4 — Laplacian smoothing');
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
  debugPrint('[Mesh]   boundary=${isBoundary.where((b)=>b).length}  interior=${isBoundary.where((b)=>!b).length}');

  var xs = Float64List(numVerts);
  var ys = Float64List(numVerts);
  for (int v = 0; v < numVerts; v++) { xs[v] = compactVerts[v].x; ys[v] = compactVerts[v].y; }

  for (int iter = 0; iter < 3; iter++) {
    final nxs = Float64List.fromList(xs);
    final nys = Float64List.fromList(ys);
    for (int v = 0; v < numVerts; v++) {
      if (isBoundary[v] || adj[v].isEmpty) continue;
      var sx = 0.0, sy = 0.0;
      for (final n in adj[v]) { sx += xs[n]; sy += ys[n]; }
      nxs[v] = sx / adj[v].length;
      nys[v] = sy / adj[v].length;
    }
    xs = nxs; ys = nys;
  }

  final smoothedVerts = List<MeshVertex>.generate(numVerts, (v) => MeshVertex(xs[v], ys[v]));

  // ── 5. BFS joint-to-triangle mapping ───────────────────────────────────────
  debugPrint('[Mesh] step 5 — BFS joint-to-triangle mapping');
  final triangles = Uint16List.fromList(compactTri);
  final jointToTri = _buildJointToTriMap(maskData, imgDim, charCfg, smoothedVerts, triangles);
  debugPrint('[Mesh]   jointToTri entries=${jointToTri.length}  keys: ${jointToTri.keys.take(5).join(", ")}');

  debugPrint('[Mesh] buildMesh DONE  verts=${smoothedVerts.length}  tris=${triangles.length ~/ 3}');
  return CharMesh(vertices: smoothedVerts, triangles: triangles, jointToTriIndices: jointToTri);
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

  // Seed: 20 sample points per bone segment
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
