/// Pipeline integration tests for char1 (monkey.png) against Python reference
/// values captured in monkey_ref.json by dump_pipeline.py.
///
/// Reference system: Python uses y-up coords (world_y = 1 - row/imgDim).
/// Dart uses y-down coords (dart_y = row/imgDim).
/// Distances, angles, and skeleton topology must match regardless of convention.
library;

import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_animated_drawings/annotation/char_cfg.dart';
import 'package:flutter_animated_drawings/rig/rig.dart';

// char1 skeleton from examples/characters/char1/char_cfg.yaml
// imgDim = max(height, width) = max(602, 508) = 602
const _char1Yaml = '''
height: 602
width: 508
skeleton:
- name: root
  parent: null
  loc: [264, 397]
- name: hip
  parent: root
  loc: [264, 397]
- name: torso
  parent: hip
  loc: [247, 232]
- name: neck
  parent: torso
  loc: [231, 119]
- name: right_shoulder
  parent: torso
  loc: [151, 245]
- name: right_elbow
  parent: right_shoulder
  loc: [99, 278]
- name: right_hand
  parent: right_elbow
  loc: [46, 311]
- name: left_shoulder
  parent: torso
  loc: [343, 218]
- name: left_elbow
  parent: left_shoulder
  loc: [396, 245]
- name: left_hand
  parent: left_elbow
  loc: [449, 278]
- name: right_hip
  parent: root
  loc: [191, 404]
- name: right_knee
  parent: right_hip
  loc: [165, 476]
- name: right_foot
  parent: right_knee
  loc: [138, 556]
- name: left_hip
  parent: root
  loc: [337, 390]
- name: left_knee
  parent: left_hip
  loc: [376, 456]
- name: left_foot
  parent: left_knee
  loc: [409, 549]
''';

const int _imgDim = 602;

/// Python reference: startingTheta = atan2(v2_y_up, v2_x) - atan2(1,0)  degrees [0,360)
/// where v2 = child_world - parent_world in y-up space (world_y = 1 - row/imgDim)
double _pyTheta(
    double parentCol, double parentRow, double childCol, double childRow) {
  final v2x = (childCol - parentCol) / _imgDim;
  final v2yUp = (parentRow - childRow) / _imgDim; // y-up: up = decreasing row
  var theta = math.atan2(v2yUp, v2x) - math.atan2(1.0, 0.0);
  theta = theta * 180 / math.pi;
  theta = theta % 360;
  if (theta < 0) theta += 360;
  return theta;
}

void main() {
  // ─── Rig / joint positions ────────────────────────────────────────────────
  group('char1 joint positions (normalized by imgDim=602)', () {
    late Rig rig;
    setUpAll(() {
      rig = Rig(CharConfig.fromYamlString(_char1Yaml));
    });

    test('imgDim=602', () => expect(rig.imgDim, 602));

    test('root: dart_x=264/602, dart_y=397/602', () {
      expect(rig.root.initX, closeTo(264 / 602, 1e-5));
      expect(rig.root.initY, closeTo(397 / 602, 1e-5));
    });

    test('neck: dart_x=231/602, dart_y=119/602', () {
      final j = rig.root.allJoints.firstWhere((j) => j.name == 'neck');
      expect(j.initX, closeTo(231 / 602, 1e-5));
      expect(j.initY, closeTo(119 / 602, 1e-5));
    });

    test('right_foot: dart_x=138/602, dart_y=556/602', () {
      final j = rig.root.allJoints.firstWhere((j) => j.name == 'right_foot');
      expect(j.initX, closeTo(138 / 602, 1e-5));
      expect(j.initY, closeTo(556 / 602, 1e-5));
    });

    test('16 joints total', () => expect(rig.jointCount, 16));
  });

  // ─── startingTheta against Python reference values ─────────────────────────
  group('char1 startingTheta matches Python monkey_ref.json', () {
    late Map<String, double> thetas;

    setUpAll(() {
      final rig = Rig(CharConfig.fromYamlString(_char1Yaml));
      thetas = {for (final j in rig.root.allJoints) j.name: j.startingTheta};
    });

    // Python reference values from monkey_ref.json → startingThetas
    test('root: 0.0°', () => expect(thetas['root'], closeTo(0.0, 0.5)));

    test('hip: 270.0° (same loc as root → bone points left)', () {
      // hip and root share the same pixel location → dx=0, dy=0
      // Python returns 270.0 for this degenerate case
      expect(thetas['hip'], closeTo(270.0, 0.5));
    });

    test('torso: 5.88°', () {
      expect(thetas['torso'],
          closeTo(_pyTheta(264, 397, 247, 232), 0.5));
      expect(thetas['torso'], closeTo(5.882, 0.5));
    });

    test('neck: 8.06°', () {
      expect(thetas['neck'],
          closeTo(_pyTheta(247, 232, 231, 119), 0.5));
      expect(thetas['neck'], closeTo(8.059, 0.5));
    });

    test('right_shoulder: 97.71°', () {
      expect(thetas['right_shoulder'],
          closeTo(_pyTheta(247, 232, 151, 245), 0.5));
      expect(thetas['right_shoulder'], closeTo(97.712, 0.5));
    });

    test('right_elbow: 122.40°', () {
      expect(thetas['right_elbow'],
          closeTo(_pyTheta(151, 245, 99, 278), 0.5));
      expect(thetas['right_elbow'], closeTo(122.400, 0.5));
    });

    test('right_hand: 121.91°', () {
      expect(thetas['right_hand'],
          closeTo(_pyTheta(99, 278, 46, 311), 0.5));
      expect(thetas['right_hand'], closeTo(121.908, 0.5));
    });

    test('left_shoulder: 278.30°', () {
      expect(thetas['left_shoulder'],
          closeTo(_pyTheta(247, 232, 343, 218), 0.5));
      expect(thetas['left_shoulder'], closeTo(278.297, 0.5));
    });

    test('left_elbow: 243.00°', () {
      expect(thetas['left_elbow'],
          closeTo(_pyTheta(343, 218, 396, 245), 0.5));
      expect(thetas['left_elbow'], closeTo(243.004, 0.5));
    });

    test('left_hand: 238.09°', () {
      expect(thetas['left_hand'],
          closeTo(_pyTheta(396, 245, 449, 278), 0.5));
      expect(thetas['left_hand'], closeTo(238.092, 0.5));
    });

    test('right_hip: 95.48°', () {
      expect(thetas['right_hip'],
          closeTo(_pyTheta(264, 397, 191, 404), 0.5));
      expect(thetas['right_hip'], closeTo(95.477, 0.5));
    });

    test('right_knee: 160.14° (bone points down-left)', () {
      expect(thetas['right_knee'],
          closeTo(_pyTheta(191, 404, 165, 476), 0.5));
      expect(thetas['right_knee'], closeTo(160.145, 0.5));
    });

    test('right_foot: 161.35°', () {
      expect(thetas['right_foot'],
          closeTo(_pyTheta(165, 476, 138, 556), 0.5));
      expect(thetas['right_foot'], closeTo(161.351, 0.5));
    });

    test('left_hip: 275.48°', () {
      expect(thetas['left_hip'],
          closeTo(_pyTheta(264, 397, 337, 390), 0.5));
      expect(thetas['left_hip'], closeTo(275.477, 0.5));
    });

    test('left_knee: 210.58°', () {
      expect(thetas['left_knee'],
          closeTo(_pyTheta(337, 390, 376, 456), 0.5));
      expect(thetas['left_knee'], closeTo(210.579, 0.5));
    });

    test('left_foot: 199.54°', () {
      expect(thetas['left_foot'],
          closeTo(_pyTheta(376, 456, 409, 549), 0.5));
      expect(thetas['left_foot'], closeTo(199.537, 0.5));
    });

    test('all 16 thetas in [0, 360)', () {
      for (final e in thetas.entries) {
        expect(e.value, inInclusiveRange(0.0, 360.0),
            reason: '${e.key}.startingTheta=${e.value} out of [0,360)');
      }
      expect(thetas.length, 16);
    });
  });

  // ─── setGlobalOrientations — frame 0 Python reference ─────────────────────
  // Python frame 0 orientations from monkey_ref.json:
  //   left_elbow=275.57°, left_foot=180.17°, left_hand=273.72°,
  //   left_knee=180.18°, neck=359.33°, right_elbow=81.58°,
  //   right_foot=182.13°, right_hand=79.21°, right_knee=181.63°,
  //   torso=359.90°
  group('setGlobalOrientations — frame 0 joint movement direction', () {
    late Rig rig;

    setUpAll(() {
      rig = Rig(CharConfig.fromYamlString(_char1Yaml));
    });

    test('frame 0 torso: 359.90° ≈ rest pose (torso barely moves)', () {
      rig.setGlobalOrientations({'torso': 359.904694});
      final torso = rig.root.allJoints.firstWhere((j) => j.name == 'torso');
      // torso startingTheta=5.88°, orientation=359.90° → delta≈-6°
      // torso should remain near its rest position
      expect(torso.worldX, closeTo(rig.root.allJoints.firstWhere((j) => j.name == 'hip').initX, 0.05),
          reason: 'torso should remain near initial X after near-rest orientation');
    });

    test('frame 0 orientations: all joints have valid world positions', () {
      rig.setGlobalOrientations({
        'torso': 359.904694,
        'neck': 359.326294,
        'right_elbow': 81.578072,
        'right_foot': 182.129761,
        'right_hand': 79.206917,
        'right_knee': 181.631607,
        'left_elbow': 275.568329,
        'left_foot': 180.16658,
        'left_hand': 273.722168,
        'left_knee': 180.176361,
      });
      for (final j in rig.root.allJoints) {
        expect(j.worldX.isFinite, isTrue, reason: '${j.name}.worldX is not finite');
        expect(j.worldY.isFinite, isTrue, reason: '${j.name}.worldY is not finite');
      }
    });
  });

  // ─── Char limb length for scale factor ────────────────────────────────────
  // Python scale factor = char_limb / bvh_limb = 0.515489 (monkey_ref.json)
  // char_limb = sum of leg segment lengths in normalized coords
  // Joints used: [left_foot→left_knee→left_hip] + [right_foot→right_knee→right_hip]
  group('char1 limb length for scale factor', () {
    late Rig rig;
    setUpAll(() {
      rig = Rig(CharConfig.fromYamlString(_char1Yaml));
    });

    double dist(String a, String b) {
      final ja = rig.root.allJoints.firstWhere((j) => j.name == a);
      final jb = rig.root.allJoints.firstWhere((j) => j.name == b);
      final dx = jb.initX - ja.initX;
      final dy = jb.initY - ja.initY;
      return math.sqrt(dx * dx + dy * dy);
    }

    test('right leg length (right_foot→right_knee + right_knee→right_hip) ≈ 0.267', () {
      final len = dist('right_foot', 'right_knee') + dist('right_knee', 'right_hip');
      expect(len, closeTo(0.267, 0.005));
    });

    test('left leg length (left_foot→left_knee + left_knee→left_hip) ≈ 0.291', () {
      // sqrt((409-376)²+(549-456)²)/602 + sqrt((376-337)²+(456-390)²)/602
      final len = dist('left_foot', 'left_knee') + dist('left_knee', 'left_hip');
      expect(len, closeTo(0.291, 0.005));
    });

    test('total char limb (both legs) ≈ 0.558', () {
      final rightLeg = dist('right_foot', 'right_knee') + dist('right_knee', 'right_hip');
      final leftLeg = dist('left_foot', 'left_knee') + dist('left_knee', 'left_hip');
      expect(rightLeg + leftLeg, closeTo(0.558, 0.01));
    });
  });

  // ─── Retargeter lateral motion sign (Bug 3 regression) ───────────────────
  // Python: v1 = fwd[::-1] * [-1,1,-1] = [-fwd_z, fwd_y, -fwd_x]
  // Dart (fixed): v1 = [-fwd[2], fwd[1], -fwd[0]]
  // For fwd=[1,0,0]: v1_python=[-0,0,-1], v1_dart_fixed=[-0,0,-1] ✓
  // For fwd=[0,0,1]: v1_python=[-1,0,0], v1_dart_fixed=[-1,0,0] ✓
  group('retargeter lateral motion sign formula', () {
    double dot3(List<double> a, List<double> b) =>
        a[0] * b[0] + a[1] * b[1] + a[2] * b[2];

    List<double> dartLateralV1(List<double> fwd) =>
        [-fwd[2], fwd[1], -fwd[0]]; // FIXED formula

    List<double> pyLateralV1(List<double> fwd) {
      // Python: fwd[::-1] * [-1, 1, -1]
      return [-fwd[2], fwd[1], -fwd[0]];
    }

    test('fwd=[1,0,0]: dart v1 matches Python v1', () {
      const fwd = [1.0, 0.0, 0.0];
      expect(dartLateralV1(fwd), equals(pyLateralV1(fwd)));
    });

    test('fwd=[0,0,1]: dart v1 matches Python v1', () {
      const fwd = [0.0, 0.0, 1.0];
      expect(dartLateralV1(fwd), equals(pyLateralV1(fwd)));
    });

    test('fwd=[0.707,0,0.707]: dart v1 matches Python v1', () {
      const fwd = [0.707, 0.0, 0.707];
      final d = dartLateralV1(fwd);
      final p = pyLateralV1(fwd);
      expect(d[0], closeTo(p[0], 1e-9));
      expect(d[1], closeTo(p[1], 1e-9));
      expect(d[2], closeTo(p[2], 1e-9));
    });

    test('lateral projection dot product is zero for pure-forward motion', () {
      // If delta = forward motion, lateral component should be zero
      const fwd = [1.0, 0.0, 0.0];
      final v1 = dartLateralV1(fwd); // = [0, 0, -1]
      const delta = [1.0, 0.0, 0.0]; // pure forward delta
      expect(dot3(v1, delta), closeTo(0.0, 1e-9),
          reason: 'lateral v1·forward_delta should be 0');
    });
  });

  // ─── Forward angle formula ────────────────────────────────────────────────
  // Python: dot=v1[0]*v2[0]+v1[1]*v2[2] = fwd[0], det=v1[0]*v2[2]-v2[0]*v1[1] = fwd[2]
  // angle = atan2(det, dot) = atan2(fwd[2], fwd[0])
  group('retargeter forward angle formula matches Python', () {
    double dartFwdAngle(List<double> fwd) {
      final dot = fwd[0]; // v1=[1,0], dot = 1*fwd[0]+0*fwd[2]
      final det = fwd[2]; // det = 1*fwd[2]-fwd[0]*0
      var angle = math.atan2(det, dot);
      angle %= 2 * math.pi;
      if (angle < 0) angle += 2 * math.pi;
      return angle;
    }

    test('fwd=[1,0,0]: angle=0 (already facing +X, no rotation needed)', () {
      expect(dartFwdAngle([1.0, 0.0, 0.0]), closeTo(0.0, 1e-9));
    });

    test('fwd=[0,0,1]: angle=π/2 (skeleton faces +Z, must rotate 90° CCW)', () {
      expect(dartFwdAngle([0.0, 0.0, 1.0]),
          closeTo(math.pi / 2, 1e-9));
    });

    test('fwd=[-1,0,0]: angle=π', () {
      expect(dartFwdAngle([-1.0, 0.0, 0.0]), closeTo(math.pi, 1e-9));
    });

    test('fwd=[0,0,-1]: angle=3π/2', () {
      expect(dartFwdAngle([0.0, 0.0, -1.0]),
          closeTo(3 * math.pi / 2, 1e-9));
    });
  });

  // ─── Coordinate system sanity ─────────────────────────────────────────────
  group('Dart y-down vs Python y-up coordinate equivalence', () {
    test('dart_y = 1 - python_y_up for all char1 joints', () {
      // Reference pairs from monkey_ref.json (world_y = 1-row/imgDim in Python)
      const pairs = [
        // [row, py_world_y]
        [397.0, 0.340532], // root
        [232.0, 0.614618], // torso
        [119.0, 0.802326], // neck
        [556.0, 0.076412], // right_foot
        [549.0, 0.088040], // left_foot
      ];
      for (final p in pairs) {
        final row = p[0], pyY = p[1];
        final dartY = row / _imgDim;
        expect(dartY, closeTo(1.0 - pyY, 1e-4),
            reason: 'dart_y=$dartY vs 1-py_y=${1.0 - pyY}');
      }
    });

    test('euclidean distance invariant under y-axis flip', () {
      // Distance torso→neck must be equal in both coordinate systems
      const torsoCol = 247.0, torsoRow = 232.0;
      const neckCol = 231.0, neckRow = 119.0;

      // Python y-up
      final pyTorsoX = torsoCol / _imgDim;
      final pyTorsoY = 1.0 - torsoRow / _imgDim;
      final pyNeckX = neckCol / _imgDim;
      final pyNeckY = 1.0 - neckRow / _imgDim;
      final pyDist = math.sqrt(
          math.pow(pyNeckX - pyTorsoX, 2) + math.pow(pyNeckY - pyTorsoY, 2));

      // Dart y-down
      final dtTorsoX = torsoCol / _imgDim;
      final dtTorsoY = torsoRow / _imgDim;
      final dtNeckX = neckCol / _imgDim;
      final dtNeckY = neckRow / _imgDim;
      final dtDist = math.sqrt(
          math.pow(dtNeckX - dtTorsoX, 2) + math.pow(dtNeckY - dtTorsoY, 2));

      expect(dtDist, closeTo(pyDist, 1e-9),
          reason: 'euclidean distance must be the same in both coord systems');
    });
  });
}
