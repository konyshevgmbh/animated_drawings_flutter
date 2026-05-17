import 'dart:math' as math;

/// 3×3 symmetric matrix eigendecomposition via Jacobi iteration.
/// Returns eigenvectors as rows, sorted by descending eigenvalue.
/// Input: flat row-major 3×3 matrix.
List<List<double>> jacobi3x3(List<double> m) {
  // Working copy as 2D
  final a = [
    [m[0], m[1], m[2]],
    [m[3], m[4], m[5]],
    [m[6], m[7], m[8]],
  ];
  // Eigenvector matrix (identity to start)
  var v = [
    [1.0, 0.0, 0.0],
    [0.0, 1.0, 0.0],
    [0.0, 0.0, 1.0],
  ];

  for (int iter = 0; iter < 50; iter++) {
    // Find largest off-diagonal element
    int p = 0, q = 1;
    double maxOff = 0;
    for (int i = 0; i < 3; i++) {
      for (int j = i + 1; j < 3; j++) {
        if (a[i][j].abs() > maxOff) {
          maxOff = a[i][j].abs();
          p = i;
          q = j;
        }
      }
    }
    if (maxOff < 1e-12) break;

    // Compute rotation angle
    final theta = (a[q][q] - a[p][p]) / (2 * a[p][q]);
    final t = (theta >= 0 ? 1 : -1) / (theta.abs() + math.sqrt(theta * theta + 1));
    final c = 1.0 / math.sqrt(t * t + 1);
    final s = t * c;

    // Apply Jacobi rotation
    final app = a[p][p], aqq = a[q][q], apq = a[p][q];
    a[p][p] = app - t * apq;
    a[q][q] = aqq + t * apq;
    a[p][q] = 0.0;
    a[q][p] = 0.0;
    for (int r = 0; r < 3; r++) {
      if (r == p || r == q) continue;
      final apr = a[p][r], aqr = a[q][r];
      a[p][r] = c * apr - s * aqr;
      a[r][p] = a[p][r];
      a[q][r] = s * apr + c * aqr;
      a[r][q] = a[q][r];
    }
    // Update eigenvectors
    for (int r = 0; r < 3; r++) {
      final vpr = v[r][p], vqr = v[r][q];
      v[r][p] = c * vpr - s * vqr;
      v[r][q] = s * vpr + c * vqr;
    }
  }

  // Eigenvalues on diagonal of a
  final eigenvals = [a[0][0], a[1][1], a[2][2]];

  // Sort by descending eigenvalue; return eigenvectors as rows
  final order = [0, 1, 2]..sort((i, j) => eigenvals[j].compareTo(eigenvals[i]));
  return [
    for (final idx in order) [v[0][idx], v[1][idx], v[2][idx]],
  ];
}

/// Given a list of 3D points (each = [x,y,z]), returns the normal of the
/// best-fit plane (= third principal component, smallest variance direction).
List<double> planaNormalPca(List<List<double>> points) {
  if (points.length < 3) return [1.0, 0.0, 0.0];

  // Center the data
  double mx = 0, my = 0, mz = 0;
  for (final p in points) {
    mx += p[0]; my += p[1]; mz += p[2];
  }
  final n = points.length;
  mx /= n; my /= n; mz /= n;

  // 3×3 covariance matrix
  double c00 = 0, c01 = 0, c02 = 0, c11 = 0, c12 = 0, c22 = 0;
  for (final p in points) {
    final dx = p[0] - mx, dy = p[1] - my, dz = p[2] - mz;
    c00 += dx * dx; c01 += dx * dy; c02 += dx * dz;
    c11 += dy * dy; c12 += dy * dz; c22 += dz * dz;
  }
  final inv = 1.0 / n;
  final cov = [c00*inv, c01*inv, c02*inv, c01*inv, c11*inv, c12*inv, c02*inv, c12*inv, c22*inv];

  final eigvecs = jacobi3x3(cov);
  // Third component = smallest eigenvalue = plane normal
  return eigvecs[2];
}
