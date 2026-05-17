import 'dart:math' as math;

/// Quaternion as [w, x, y, z]
typedef Quat = List<double>;

Quat quatIdentity() => [1.0, 0.0, 0.0, 0.0];

/// Multiply two quaternions (Hamilton product)
Quat quatMul(Quat a, Quat b) {
  final aw = a[0], ax = a[1], ay = a[2], az = a[3];
  final bw = b[0], bx = b[1], by = b[2], bz = b[3];
  return [
    aw * bw - ax * bx - ay * by - az * bz,
    aw * bx + ax * bw + ay * bz - az * by,
    aw * by - ax * bz + ay * bw + az * bx,
    aw * bz + ax * by - ay * bx + az * bw,
  ];
}

/// Convert Euler angles (in degrees) to quaternion.
/// [axes] is a string like 'xyz' or 'zyx' specifying rotation order.
/// Rotations applied right-to-left (intrinsic): e.g. 'xyz' = Rz * Ry * Rx
Quat eulerToQuat(String axes, List<double> anglesDeg) {
  Quat q = quatIdentity();
  for (int i = axes.length - 1; i >= 0; i--) {
    final angle = anglesDeg[i] * math.pi / 180.0;
    final half = angle / 2;
    final cos = math.cos(half);
    final sin = math.sin(half);
    Quat axisQ;
    switch (axes[i]) {
      case 'x':
        axisQ = [cos, sin, 0.0, 0.0];
        break;
      case 'y':
        axisQ = [cos, 0.0, sin, 0.0];
        break;
      case 'z':
        axisQ = [cos, 0.0, 0.0, sin];
        break;
      default:
        throw ArgumentError('Unknown axis: ${axes[i]}');
    }
    q = quatMul(axisQ, q);
  }
  return q;
}

/// Rotate a 3D vector [x,y,z] by quaternion q = [w,x,y,z]
List<double> quatRotateVec(Quat q, List<double> v) {
  final qw = q[0], qx = q[1], qy = q[2], qz = q[3];
  final vx = v[0], vy = v[1], vz = v[2];
  // p = q * [0,vx,vy,vz] * q^-1
  final tx = 2 * (qy * vz - qz * vy);
  final ty = 2 * (qz * vx - qx * vz);
  final tz = 2 * (qx * vy - qy * vx);
  return [
    vx + qw * tx + qy * tz - qz * ty,
    vy + qw * ty + qz * tx - qx * tz,
    vz + qw * tz + qx * ty - qy * tx,
  ];
}

/// Normalize a quaternion.
Quat quatNorm(Quat q) {
  final len = math.sqrt(q[0]*q[0] + q[1]*q[1] + q[2]*q[2] + q[3]*q[3]);
  if (len < 1e-12) return quatIdentity();
  return [q[0]/len, q[1]/len, q[2]/len, q[3]/len];
}

/// Conjugate (inverse for unit quaternion)
Quat quatConj(Quat q) => [q[0], -q[1], -q[2], -q[3]];
