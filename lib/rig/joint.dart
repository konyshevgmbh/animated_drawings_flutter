import 'dart:math' as math;

/// 2D animated drawing joint.
class RigJoint {
  final String name;

  // Initial normalized position [0,1] from char_cfg / img_dim
  final double initX;
  final double initY;

  // Local offset from parent in initial pose
  double _localDx = 0.0;
  double _localDy = 0.0;

  // Current local rotation at THIS joint (radians CCW) — affects children's positions
  double localRot = 0.0;

  // Accumulated world rotation = sum of all ancestor localRots up to (but not including) this joint.
  // Equivalent to parent.worldRot + parent.localRot. Used so bone direction = worldRot * restOffset,
  // matching the Python 3D Transform hierarchy where worldMatrix = product of all ancestor localMatrices.
  double worldRot = 0.0;

  // Current world position (updated by updateTransforms)
  double worldX = 0.0;
  double worldY = 0.0;

  // Hierarchy tracking
  RigJoint? parent;
  final List<RigJoint> children = [];

  // Rotation tracking for _setGlobalOrientations
  double startingTheta = 0.0; // angle of bone (parent→this) from +Y, degrees CCW
  double currentTheta = 0.0;  // delta from starting orientation (radians)
  bool currentThetaSet = false;

  RigJoint(this.name, this.initX, this.initY);

  /// After building the hierarchy, call this on root to initialize local offsets
  /// and starting thetas. Sets worldX/Y = initX/Y.
  void initHierarchy() {
    worldX = initX;
    worldY = initY;
    if (parent != null) {
      _localDx = initX - parent!.initX;
      _localDy = initY - parent!.initY;

      // starting_theta = angle of bone (parent→this) CCW from +Y axis, in degrees
      final v2x = initX - parent!.initX;
      final v2y = initY - parent!.initY;
      var theta = math.atan2(-v2y, v2x) - math.atan2(1.0, 0.0); // CCW from +Y (negate y: Dart y-down → y-up)
      theta = theta * 180 / math.pi;
      theta = theta % 360;
      if (theta < 0) theta += 360;
      startingTheta = theta;
    }
    for (final c in children) {
      c.initHierarchy();
    }
  }

  void setRotation(double radians) {
    localRot = radians;
  }

  /// Recompute this joint's worldX/Y from parent's accumulated worldRot,
  /// then recurse to children.
  void updateTransforms() {
    if (parent != null) {
      // Accumulate: worldRot = all ancestor localRots summed (matches Python 3D worldMatrix chain).
      // This makes _setGlobalOrientations' "theta -= parent.currentTheta" subtraction correct.
      worldRot = parent!.worldRot + parent!.localRot;
      final cos = math.cos(worldRot);
      final sin = math.sin(worldRot);
      worldX = parent!.worldX + cos * _localDx + sin * _localDy;
      worldY = parent!.worldY - sin * _localDx + cos * _localDy;
    }
    for (final c in children) {
      c.updateTransforms();
    }
  }

  /// Traversal helpers
  List<RigJoint> get allJoints {
    final result = <RigJoint>[this];
    for (final c in children) {
      result.addAll(c.allJoints);
    }
    return result;
  }
}
