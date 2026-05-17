import 'dart:math' as math;
import 'dart:typed_data';

import '../annotation/char_cfg.dart';
import 'joint.dart';

/// 2D skeletal rig for an animated drawing.
/// Port of AnimatedDrawingRig from animated_drawings/model/animated_drawing.py.
class Rig {
  late final RigJoint root;
  late final Map<String, RigJoint> _joints;
  final int imgDim;

  Rig(CharConfig charCfg)
      : imgDim = charCfg.imgDim {
    // Build joint map from pixel coords → normalized [0,1]
    _joints = {
      for (final j in charCfg.skeleton)
        j.name: RigJoint(j.name, j.x / imgDim, j.y / imgDim),
    };

    // Wire parent→child relationships
    for (final j in charCfg.skeleton) {
      if (j.parent == null) continue;
      final parent = _joints[j.parent]!;
      final child = _joints[j.name]!;
      child.parent = parent;
      parent.children.add(child);
    }

    root = _joints['root']!;

    // Initialize local offsets and starting thetas
    root.initHierarchy();
  }

  /// Apply orientations from retargeter (degrees CCW from +Y per char joint).
  void setGlobalOrientations(Map<String, double> orientations) {
    // Reset currentThetaSet flags
    for (final j in root.allJoints) {
      j.currentThetaSet = false;
      j.currentTheta = 0.0;
    }
    _setGlobalOrientations(root, orientations);
  }

  void _setGlobalOrientations(RigJoint joint, Map<String, double> orientations) {
    if (orientations.containsKey(joint.name)) {
      final targetGlobal = orientations[joint.name]!;
      double theta = (targetGlobal - joint.startingTheta) * math.pi / 180;
      joint.currentTheta = theta;
      joint.currentThetaSet = true;

      final parent = joint.parent;
      if (parent != null) {
        if (parent.currentThetaSet) {
          theta -= parent.currentTheta;
        }
        parent.setRotation(theta);
        parent.updateTransforms();
      }
    }
    for (final c in joint.children) {
      _setGlobalOrientations(c, orientations);
    }
  }

  /// Set root world position (in normalized [0,1] coords).
  void setRootPosition(double x, double y) {
    root.worldX = x;
    root.worldY = y;
  }

  /// Returns flat Float32List [x0,y0, x1,y1, ...] of all joint world positions
  /// in the same order as charCfg.skeleton (DFS traversal).
  Float32List getJoints2DPositions() {
    final all = root.allJoints;
    final result = Float32List(all.length * 2);
    for (int i = 0; i < all.length; i++) {
      result[i * 2] = all[i].worldX;
      result[i * 2 + 1] = all[i].worldY;
    }
    return result;
  }

  int get jointCount => root.allJoints.length;

  /// Returns parent index for each joint in DFS order (-1 for root).
  Int32List getParentIndices() {
    final all = root.allJoints;
    final nameToIdx = {for (int i = 0; i < all.length; i++) all[i].name: i};
    final result = Int32List(all.length);
    for (int i = 0; i < all.length; i++) {
      final p = all[i].parent;
      result[i] = p != null ? nameToIdx[p.name]! : -1;
    }
    return result;
  }
}
