// Port of animated_drawings/model/arap.py
// Reference: Igarashi & Igarashi, "Implementing As-Rigid-As-Possible Shape
// Manipulation and Surface Flattening", JGT 2009.
//
// Linear systems are solved via precomputed Cholesky inverses (ml_linalg),
// matching Python's scipy.sparse.linalg.spsolve behaviour without iterative CG.
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:ml_linalg/linalg.dart';

// ─── Sparse matrix (CSR) — used only during build for matrix assembly ─────────

class _Csr {
  final int rows, cols;
  final Int32List rowPtr;
  final Int32List colIdx;
  final Float64List vals;
  int get nnz => vals.length;

  const _Csr(this.rows, this.cols, this.rowPtr, this.colIdx, this.vals);

  factory _Csr.fromCoo(
      int rows, int cols, List<(int, int, double)> entries) {
    final rowMap = <int, Map<int, double>>{};
    for (final (r, c, v) in entries) {
      ((rowMap[r] ??= {}))[c] = ((rowMap[r]!)[c] ?? 0.0) + v;
    }
    final rowPtr = Int32List(rows + 1);
    for (int r = 0; r < rows; r++) {
      rowPtr[r + 1] = rowPtr[r] + (rowMap[r]?.length ?? 0);
    }
    final nnz = rowPtr[rows];
    final colIdx = Int32List(nnz);
    final vals = Float64List(nnz);
    for (int r = 0; r < rows; r++) {
      final m = rowMap[r];
      if (m == null) continue;
      final sorted = m.entries.toList()..sort((a, b) => a.key - b.key);
      int pos = rowPtr[r];
      for (final e in sorted) {
        colIdx[pos] = e.key;
        vals[pos] = e.value;
        pos++;
      }
    }
    return _Csr(rows, cols, rowPtr, colIdx, vals);
  }

  /// y = A * x
  Float64List matvec(Float64List x) {
    final y = Float64List(rows);
    for (int r = 0; r < rows; r++) {
      double s = 0;
      for (int p = rowPtr[r]; p < rowPtr[r + 1]; p++) {
        s += vals[p] * x[colIdx[p]];
      }
      y[r] = s;
    }
    return y;
  }

  _Csr transpose() {
    final entries = <(int, int, double)>[];
    for (int r = 0; r < rows; r++) {
      for (int p = rowPtr[r]; p < rowPtr[r + 1]; p++) {
        entries.add((colIdx[p], r, vals[p]));
      }
    }
    return _Csr.fromCoo(cols, rows, entries);
  }

  _Csr multiply(_Csr B) {
    assert(cols == B.rows);
    final entries = <(int, int, double)>[];
    for (int r = 0; r < rows; r++) {
      for (int pA = rowPtr[r]; pA < rowPtr[r + 1]; pA++) {
        final k = colIdx[pA];
        final a = vals[pA];
        for (int pB = B.rowPtr[k]; pB < B.rowPtr[k + 1]; pB++) {
          entries.add((r, B.colIdx[pB], a * B.vals[pB]));
        }
      }
    }
    return _Csr.fromCoo(rows, B.cols, entries);
  }

  _Csr addDiag(double eps) {
    final entries = <(int, int, double)>[];
    for (int r = 0; r < rows; r++) {
      for (int p = rowPtr[r]; p < rowPtr[r + 1]; p++) {
        entries.add((r, colIdx[p], vals[p]));
      }
      if (r < cols) entries.add((r, r, eps));
    }
    return _Csr.fromCoo(rows, cols, entries);
  }

  /// Convert to ml_linalg dense Matrix (float64).
  Matrix toDense() {
    final flat = List<List<double>>.generate(
        rows, (r) => List<double>.filled(cols, 0.0));
    for (int r = 0; r < rows; r++) {
      for (int p = rowPtr[r]; p < rowPtr[r + 1]; p++) {
        flat[r][colIdx[p]] = vals[p];
      }
    }
    return Matrix.fromList(flat, dtype: DType.float64);
  }
}

// ─── Barycentric helpers ──────────────────────────────────────────────────────

List<double> _barycentricCoords(double px, double py, double ax, double ay,
    double bx, double by, double cx, double cy) {
  final v0x = bx - ax, v0y = by - ay;
  final v1x = cx - ax, v1y = cy - ay;
  final v2x = px - ax, v2y = py - ay;
  final d00 = v0x * v0x + v0y * v0y;
  final d01 = v0x * v1x + v0y * v1y;
  final d11 = v1x * v1x + v1y * v1y;
  final d20 = v2x * v0x + v2y * v0y;
  final d21 = v2x * v1x + v2y * v1y;
  final denom = d00 * d11 - d01 * d01;
  if (denom.abs() < 1e-14) return [1 / 3, 1 / 3, 1 / 3];
  final v = (d11 * d20 - d01 * d21) / denom;
  final w = (d00 * d21 - d01 * d20) / denom;
  return [1.0 - v - w, v, w];
}

// ─── ARAP solver ─────────────────────────────────────────────────────────────

/// As-Rigid-As-Possible mesh deformation.
/// Precomputes Cholesky inverses of the two SPD system matrices at build time,
/// then solves each frame with two dense matrix-vector multiplies — no CG, no
/// convergence issues, exact match to Python's spsolve behaviour.
class ArapSolver {
  static const double _w = 1000.0;

  final int numVertices;
  final int numJoints;
  final int _edgeNum;

  final Float64List _origVerts;
  final Float64List _edgeVectors;
  final _Csr _tA1; // [2V × 2*(E+J)]  — RHS of step-1
  final _Csr _tA2; // [V  × (E+J)]    — RHS of step-2
  final _Csr _rotG; // [2E × 2V]       — rotation extraction

  // Precomputed dense inverses — solve is a single matrix-vector multiply.
  final Matrix _invA1; // (2V)×(2V) = inverse of tA1ᵀ A1
  final Matrix _invA2; // V×V        = inverse of tA2ᵀ A2

  final List<int> _validPinOrigIdx;

  ArapSolver._({
    required this.numVertices,
    required this.numJoints,
    required int edgeNum,
    required Float64List origVerts,
    required Float64List edgeVectors,
    required _Csr tA1,
    required _Csr tA2,
    required _Csr rotG,
    required Matrix invA1,
    required Matrix invA2,
    required List<int> validPinOrigIdx,
  })  : _edgeNum = edgeNum,
        _origVerts = origVerts,
        _edgeVectors = edgeVectors,
        _tA1 = tA1,
        _tA2 = tA2,
        _rotG = rotG,
        _invA1 = invA1,
        _invA2 = invA2,
        _validPinOrigIdx = validPinOrigIdx;

  factory ArapSolver({
    required Float32List origVerts,
    required Float32List origJoints,
    required Int32List parentIndices,
    required Uint16List triangles,
  }) {
    return _build(origVerts, origJoints, triangles);
  }

  // ─── Build ──────────────────────────────────────────────────────────────────

  static ArapSolver _build(
      Float32List verts32, Float32List joints32, Uint16List tris) {
    final V = verts32.length ~/ 2;
    final T = tris.length ~/ 3;
    final J = joints32.length ~/ 2;

    final verts = Float64List(V * 2);
    for (int i = 0; i < V * 2; i++) verts[i] = verts32[i];
    final pins = Float64List(J * 2);
    for (int i = 0; i < J * 2; i++) pins[i] = joints32[i];

    // ── deduplicated edge list ────────────────────────────────────────────────
    final edgeKeys = <int>{};
    final edgeList = <(int, int)>[];
    for (int t = 0; t < T; t++) {
      for (final (a, b) in [
        (tris[t * 3], tris[t * 3 + 1]),
        (tris[t * 3 + 1], tris[t * 3 + 2]),
        (tris[t * 3 + 2], tris[t * 3]),
      ]) {
        final lo = math.min(a, b), hi = math.max(a, b);
        final key = lo * 200000 + hi;
        if (edgeKeys.add(key)) edgeList.add((lo, hi));
      }
    }
    final E = edgeList.length;

    // ── edge vectors ─────────────────────────────────────────────────────────
    final edgeVectors = Float64List(E * 2);
    for (int k = 0; k < E; k++) {
      final vi = edgeList[k].$1, vj = edgeList[k].$2;
      edgeVectors[k * 2]     = verts[vj * 2]     - verts[vi * 2];
      edgeVectors[k * 2 + 1] = verts[vj * 2 + 1] - verts[vi * 2 + 1];
    }

    // ── vertex neighbour map ──────────────────────────────────────────────────
    final vNbrs = List<Set<int>>.generate(V, (_) => <int>{});
    for (int t = 0; t < T; t++) {
      final v0 = tris[t * 3], v1 = tris[t * 3 + 1], v2 = tris[t * 3 + 2];
      vNbrs[v0].add(v1); vNbrs[v0].add(v2);
      vNbrs[v1].add(v0); vNbrs[v1].add(v2);
      vNbrs[v2].add(v0); vNbrs[v2].add(v1);
    }

    // ── barycentric pin lookup ────────────────────────────────────────────────
    final pinsBc = <List<(int, double)>>[];
    final validPinOrigIdx = <int>[];
    for (int pj = 0; pj < J; pj++) {
      final px = pins[pj * 2], py = pins[pj * 2 + 1];
      bool found = false;
      for (int t = 0; t < T && !found; t++) {
        final v0 = tris[t * 3], v1 = tris[t * 3 + 1], v2 = tris[t * 3 + 2];
        final uvw = _barycentricCoords(
            px, py,
            verts[v0 * 2], verts[v0 * 2 + 1],
            verts[v1 * 2], verts[v1 * 2 + 1],
            verts[v2 * 2], verts[v2 * 2 + 1]);
        if (uvw[0] >= -1e-5 && uvw[1] >= -1e-5 && uvw[2] >= -1e-5) {
          pinsBc.add([(v0, uvw[0]), (v1, uvw[1]), (v2, uvw[2])]);
          validPinOrigIdx.add(pj);
          found = true;
        }
      }
      if (!found) {
        double bestDist = double.infinity;
        int nearestV = 0;
        for (int v = 0; v < V; v++) {
          final dx = verts[v * 2] - px;
          final dy = verts[v * 2 + 1] - py;
          final d = dx * dx + dy * dy;
          if (d < bestDist) { bestDist = d; nearestV = v; }
        }
        for (int t = 0; t < T && !found; t++) {
          final v0 = tris[t * 3], v1 = tris[t * 3 + 1], v2 = tris[t * 3 + 2];
          if (v0 == nearestV || v1 == nearestV || v2 == nearestV) {
            pinsBc.add([
              (v0, v0 == nearestV ? 1.0 : 0.0),
              (v1, v1 == nearestV ? 1.0 : 0.0),
              (v2, v2 == nearestV ? 1.0 : 0.0),
            ]);
            validPinOrigIdx.add(pj);
            found = true;
            debugPrint('[ARAP] pin $pj outside mesh — snapped to nearest vertex $nearestV');
          }
        }
      }
    }
    final Jv = pinsBc.length;

    // ── A1 matrix [2*(E+Jv) × 2*V] and G matrix [2*E × 2*V] ─────────────────
    final a1 = <(int, int, double)>[];
    final gCoo = <(int, int, double)>[];

    for (int k = 0; k < E; k++) {
      final vi = edgeList[k].$1, vj = edgeList[k].$2;

      a1.add((2 * k, 2 * vi, -1.0));
      a1.add((2 * k + 1, 2 * vi + 1, -1.0));
      a1.add((2 * k, 2 * vj, 1.0));
      a1.add((2 * k + 1, 2 * vj + 1, 1.0));

      final shared = vNbrs[vi].intersection(vNbrs[vj]).toList();
      final nbrs = [vi, vj, ...shared];
      final n = nbrs.length;

      final gkRows = 2 * (n - 1);
      final Gk = Float64List(gkRows * 2);
      for (int i = 1; i < n; i++) {
        final v = nbrs[i];
        final vx = verts[v * 2] - verts[vi * 2];
        final vy = verts[v * 2 + 1] - verts[vi * 2 + 1];
        Gk[(2 * (i - 1)) * 2]         = vx;
        Gk[(2 * (i - 1)) * 2 + 1]     = vy;
        Gk[(2 * (i - 1) + 1) * 2]     = vy;
        Gk[(2 * (i - 1) + 1) * 2 + 1] = -vx;
      }

      double m00 = 0, m01 = 0, m11 = 0;
      for (int r = 0; r < gkRows; r++) {
        m00 += Gk[r * 2] * Gk[r * 2];
        m01 += Gk[r * 2] * Gk[r * 2 + 1];
        m11 += Gk[r * 2 + 1] * Gk[r * 2 + 1];
      }
      final det = m00 * m11 - m01 * m01;
      if (det.abs() < 1e-12) continue;
      final inv = [m11 / det, -m01 / det, -m01 / det, m00 / det];

      final emCols = 2 + gkRows;
      final Gks = Float64List(2 * gkRows);
      for (int r = 0; r < 2; r++) {
        for (int c = 0; c < gkRows; c++) {
          Gks[r * gkRows + c] =
              inv[r * 2] * Gk[c * 2] + inv[r * 2 + 1] * Gk[c * 2 + 1];
        }
      }

      final g = Float64List(2 * emCols);
      for (int r = 0; r < 2; r++) {
        for (int c = 0; c < emCols; c++) {
          double val = 0;
          for (int j = 0; j < gkRows; j++) {
            final emVal =
                c < 2 ? (j % 2 == c ? -1.0 : 0.0) : (j == c - 2 ? 1.0 : 0.0);
            val += Gks[r * gkRows + j] * emVal;
          }
          g[r * emCols + c] = val;
        }
      }

      final ex = edgeVectors[k * 2], ey = edgeVectors[k * 2 + 1];
      final h = Float64List(2 * emCols);
      for (int c = 0; c < emCols; c++) {
        h[0 * emCols + c] = ex * g[0 * emCols + c] + ey * g[1 * emCols + c];
        h[1 * emCols + c] = ey * g[0 * emCols + c] - ex * g[1 * emCols + c];
      }

      for (int off = 0; off < n; off++) {
        final v = nbrs[off];
        for (int r = 0; r < 2; r++) {
          for (int c = 0; c < 2; c++) {
            final hv = h[r * emCols + 2 * off + c];
            if (hv.abs() > 1e-15) a1.add((2 * k + r, 2 * v + c, -hv));
            final gv = g[r * emCols + 2 * off + c];
            if (gv.abs() > 1e-15) gCoo.add((2 * k + r, 2 * v + c, gv));
          }
        }
      }
    }

    for (int pj = 0; pj < Jv; pj++) {
      for (final (vIdx, vW) in pinsBc[pj]) {
        a1.add((2 * E + 2 * pj,     2 * vIdx,     _w * vW));
        a1.add((2 * E + 2 * pj + 1, 2 * vIdx + 1, _w * vW));
      }
    }

    // ── A2 matrix [(E+Jv) × V] ───────────────────────────────────────────────
    final a2 = <(int, int, double)>[];
    for (int k = 0; k < E; k++) {
      a2.add((k, edgeList[k].$1, -1.0));
      a2.add((k, edgeList[k].$2,  1.0));
    }
    for (int pj = 0; pj < Jv; pj++) {
      for (final (vIdx, vW) in pinsBc[pj]) {
        a2.add((E + pj, vIdx, _w * vW));
      }
    }

    // ── Build CSR matrices ────────────────────────────────────────────────────
    final csrA1 = _Csr.fromCoo(2 * (E + Jv), 2 * V, a1);
    final csrA2 = _Csr.fromCoo(E + Jv, V, a2);
    final csrG  = _Csr.fromCoo(2 * E, 2 * V, gCoo);

    final tA1 = csrA1.transpose();
    final tA2 = csrA2.transpose();
    final tA1xA1 = tA1.multiply(csrA1).addDiag(1e-8);
    final tA2xA2 = tA2.multiply(csrA2).addDiag(1e-8);

    debugPrint('[ARAP] build: V=$V E=$E J=$J validJ=$Jv '
        'nnz(tA1xA1)=${tA1xA1.nnz} nnz(tA2xA2)=${tA2xA2.nnz}');

    // ── Precompute dense Cholesky inverses ────────────────────────────────────
    // These are the only matrices we need at solve time; both are SPD.
    // invA1 is (2V)×(2V), invA2 is V×V.
    debugPrint('[ARAP] inverting tA1xA1 (${2*V}×${2*V})…');
    final invA1 = tA1xA1.toDense().inverse(Inverse.cholesky);
    debugPrint('[ARAP] inverting tA2xA2 (${V}×${V})…');
    final invA2 = tA2xA2.toDense().inverse(Inverse.cholesky);
    debugPrint('[ARAP] inverses ready');

    return ArapSolver._(
      numVertices: V,
      numJoints: J,
      edgeNum: E,
      origVerts: verts,
      edgeVectors: edgeVectors,
      tA1: tA1,
      tA2: tA2,
      rotG: csrG,
      invA1: invA1,
      invA2: invA2,
      validPinOrigIdx: validPinOrigIdx,
    );
  }

  // ─── Solve ──────────────────────────────────────────────────────────────────

  int _solveCount = 0;

  /// Given new joint positions [J×2], return new vertex positions [V×2].
  Float32List solve(Float32List newJoints) {
    final E  = _edgeNum;
    final Jv = _validPinOrigIdx.length;
    final logThis = (_solveCount++ % 60) == 0;

    // ── Step 1: find initial deformation (rotation + scale free) ─────────────
    final b1 = Float64List(2 * (E + Jv));
    for (int pj = 0; pj < Jv; pj++) {
      final oi = _validPinOrigIdx[pj];
      b1[2 * E + 2 * pj]     = _w * newJoints[oi * 2];
      b1[2 * E + 2 * pj + 1] = _w * newJoints[oi * 2 + 1];
    }
    // v1 = (tA1xA1)^{-1} * tA1 * b1
    final rhs1 = _tA1.matvec(b1);
    final v1   = _denseMatvec(_invA1, rhs1);

    if (logThis) {
      double v1min = double.infinity, v1max = double.negativeInfinity;
      for (final v in v1) { if (v < v1min) v1min = v; if (v > v1max) v1max = v; }
      debugPrint('[ARAP #$_solveCount] v1: [${v1min.toStringAsFixed(4)}, ${v1max.toStringAsFixed(4)}]');
    }

    // ── Extract per-edge rotations ────────────────────────────────────────────
    final T1 = _rotG.matvec(v1);

    // ── Step 2: rotation-constrained solve (x and y decoupled) ───────────────
    final b2x = Float64List(E + Jv);
    final b2y = Float64List(E + Jv);
    for (int k = 0; k < E; k++) {
      double c = T1[2 * k], s = T1[2 * k + 1];
      final len = math.sqrt(c * c + s * s);
      if (len > 1e-12) { c /= len; s /= len; }
      final ex = _edgeVectors[k * 2], ey = _edgeVectors[k * 2 + 1];
      b2x[k] =  c * ex + s * ey;
      b2y[k] = -s * ex + c * ey;
    }
    for (int pj = 0; pj < Jv; pj++) {
      final oi = _validPinOrigIdx[pj];
      b2x[E + pj] = _w * newJoints[oi * 2];
      b2y[E + pj] = _w * newJoints[oi * 2 + 1];
    }
    // v2x/y = (tA2xA2)^{-1} * tA2 * b2x/y
    final v2x = _denseMatvec(_invA2, _tA2.matvec(b2x));
    final v2y = _denseMatvec(_invA2, _tA2.matvec(b2y));

    final result = Float32List(numVertices * 2);
    for (int vi = 0; vi < numVertices; vi++) {
      final x = v2x[vi], y = v2y[vi];
      result[vi * 2]     = x.isFinite ? x : _origVerts[vi * 2];
      result[vi * 2 + 1] = y.isFinite ? y : _origVerts[vi * 2 + 1];
    }

    if (logThis) {
      double xmin = double.infinity, xmax = double.negativeInfinity;
      double ymin = double.infinity, ymax = double.negativeInfinity;
      for (int vi = 0; vi < numVertices; vi++) {
        final x = result[vi * 2], y = result[vi * 2 + 1];
        if (x < xmin) xmin = x; if (x > xmax) xmax = x;
        if (y < ymin) ymin = y; if (y > ymax) ymax = y;
      }
      debugPrint('[ARAP #$_solveCount] output x: [${xmin.toStringAsFixed(4)}, ${xmax.toStringAsFixed(4)}]'
          '  y: [${ymin.toStringAsFixed(4)}, ${ymax.toStringAsFixed(4)}]');
    }
    return result;
  }
}

/// Dense matrix-vector product: returns M * v as Float64List.
/// Uses ml_linalg internally but avoids per-element boxing overhead by
/// extracting a row at a time via the row iterator.
Float64List _denseMatvec(Matrix M, Float64List v) {
  final rows = M.rowCount;
  final cols = M.columnCount;
  assert(cols == v.length);
  final result = Float64List(rows);
  // Build a Vector from v once; ml_linalg dot product is SIMD-accelerated.
  final vVec = Vector.fromList(v, dtype: DType.float64);
  for (int r = 0; r < rows; r++) {
    result[r] = M.getRow(r).dot(vVec);
  }
  return result;
}
