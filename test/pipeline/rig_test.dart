import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_animated_drawings/annotation/char_cfg.dart';
import 'package:flutter_animated_drawings/rig/rig.dart';

// Expected startingTheta values computed from Python animated_drawing.py logic:
//   offset[j] = [col/imgDim, 1 - row/imgDim, 0]   (y-up)
//   v2 = offset[child] - offset[parent]
//   startingTheta = atan2(v2.y, v2.x) - atan2(1,0)  (degrees, wrapped to [0,360))
const _charCfgYaml = '''
height: 412
width: 223
skeleton:
- name: root
  parent: null
  loc: [120, 283]
- name: hip
  parent: root
  loc: [120, 283]
- name: torso
  parent: hip
  loc: [124, 157]
- name: neck
  parent: torso
  loc: [113, 115]
- name: right_shoulder
  parent: torso
  loc: [81, 154]
- name: right_elbow
  parent: right_shoulder
  loc: [41, 131]
- name: right_hand
  parent: right_elbow
  loc: [33, 78]
- name: left_shoulder
  parent: torso
  loc: [166, 160]
- name: left_elbow
  parent: left_shoulder
  loc: [190, 145]
- name: left_hand
  parent: left_elbow
  loc: [202, 83]
- name: right_hip
  parent: root
  loc: [91, 282]
- name: right_knee
  parent: right_hip
  loc: [88, 298]
- name: right_foot
  parent: right_knee
  loc: [80, 344]
- name: left_hip
  parent: root
  loc: [148, 284]
- name: left_knee
  parent: left_hip
  loc: [152, 300]
- name: left_foot
  parent: left_knee
  loc: [163, 346]
''';

double _pyTheta(double parentCol, double parentRow, double childCol, double childRow, int imgDim) {
  final v2x = (childCol - parentCol) / imgDim;
  final v2yUp = (parentRow - childRow) / imgDim; // y-up: parentRow > childRow means bone points up
  var theta = math.atan2(v2yUp, v2x) - math.atan2(1.0, 0.0);
  theta = theta * 180 / math.pi;
  theta = theta % 360;
  if (theta < 0) theta += 360;
  return theta;
}

void main() {
  group('Rig startingTheta (matches Python starting_theta)', () {
    late Rig rig;
    late Map<String, double> thetas;
    const imgDim = 412;

    setUpAll(() {
      final cfg = CharConfig.fromYamlString(_charCfgYaml);
      rig = Rig(cfg);
      final all = rig.root.allJoints;
      thetas = {for (final j in all) j.name: j.startingTheta};
    });

    test('torso ≈ 358.2° (nearly vertical, slight lean)', () {
      // parent=hip(120,283) child=torso(124,157) — bone points up
      expect(thetas['torso'], closeTo(_pyTheta(120, 283, 124, 157, imgDim), 0.5));
    });

    test('neck ≈ 14.7° (leans left of vertical)', () {
      expect(thetas['neck'], closeTo(_pyTheta(124, 157, 113, 115, imgDim), 0.5));
    });

    test('right_shoulder ≈ 86.0° (nearly horizontal, arm extends left)', () {
      expect(thetas['right_shoulder'], closeTo(_pyTheta(124, 157, 81, 154, imgDim), 0.5));
    });

    test('right_elbow ≈ 60.1°', () {
      expect(thetas['right_elbow'], closeTo(_pyTheta(81, 154, 41, 131, imgDim), 0.5));
    });

    test('right_hand ≈ 8.6°', () {
      expect(thetas['right_hand'], closeTo(_pyTheta(41, 131, 33, 78, imgDim), 0.5));
    });

    test('right_hip ≈ 88.0° (nearly horizontal)', () {
      expect(thetas['right_hip'], closeTo(_pyTheta(120, 283, 91, 282, imgDim), 0.5));
    });

    test('right_knee: bone points downward — theta in (90,270)', () {
      // parent=right_hip(91,282) child=right_knee(88,298) — row increases → down
      final expected = _pyTheta(91, 282, 88, 298, imgDim);
      expect(thetas['right_knee'], closeTo(expected, 0.5));
      expect(expected, greaterThan(90)); // downward bones have theta in (90,270)
    });

    test('all startingTheta in [0, 360)', () {
      for (final entry in thetas.entries) {
        expect(entry.value, inInclusiveRange(0.0, 360.0),
            reason: '${entry.key}.startingTheta out of [0,360)');
      }
    });

    test('all 16 thetas computed', () {
      expect(thetas.length, 16);
    });
  });

  // Regression test for rotation direction bug (Fix 7).
  // Python applies rotations in y-up space where positive angle = CCW visually.
  // Dart uses y-down; the updateTransforms matrix must be y-flipped so that
  // positive θ also = CCW visually.  The wrong matrix had +sin signs that made
  // positive angles rotate CW, mirroring the animation vs Python.
  group('Rig rotation direction (CCW = positive, matches Python y-up)', () {
    // Minimal 2-joint rig: root at (0.5, 0.8), child directly above at (0.5, 0.4)
    // bone points upward (dy_down = 0.4 - 0.8 = -0.4, dx = 0)
    // Apply +90° (π/2) to root. CCW in visual space means:
    //   child should move to the LEFT of root (worldX < 0.5)
    // Wrong matrix (+sin*dy, -sin*dx) gives: worldX = 0.5 + sin(π/2)*(-0.4) = 0.5 - 0.4 = 0.1 (CW! right?)
    // Wait — let's be concrete:
    //   _localDx = childX - parentX = 0
    //   _localDy = childY - parentY = 0.4 - 0.8 = -0.4  (y-down, child is higher)
    //   Correct matrix (y-flipped): worldX = parentX + cos*dx + sin*dy = 0.5 + cos(90°)*0 + sin(90°)*(-0.4) = 0.5 - 0.4 = 0.1
    //   Wrong matrix:               worldX = parentX + cos*dx - sin*dy = 0.5 + 0 - sin(90°)*(-0.4) = 0.5 + 0.4 = 0.9
    //
    // In Python (y-up): bone (0,0)→(0,+0.4), after +90° → bone (0,0)→(-0.4,0): child moves LEFT.
    //   In screen coords (y-down): child moves LEFT too (x decreases).
    // So correct result: worldX < parentX (child moved left)
    late Rig rig;

    setUpAll(() {
      // Build a tiny 2-joint config: root + one child above it
      const yaml = '''
height: 100
width: 100
skeleton:
- name: root
  parent: null
  loc: [50, 80]
- name: child
  parent: root
  loc: [50, 40]
''';
      rig = Rig(CharConfig.fromYamlString(yaml));
    });

    test('+90° on upward bone: child moves LEFT (CCW = positive, matches Python)', () {
      // root at col=50,row=80 → (0.50, 0.80); child at col=50,row=40 → (0.50, 0.40)
      // bone is vertical (pointing UP in visual space: row 40 < row 80)
      // Apply +90° rotation to root joint
      rig.root.setRotation(math.pi / 2);
      rig.root.updateTransforms();

      final child = rig.root.children.first;
      // CCW rotation of an upward bone by 90° → bone points LEFT → child.worldX < root.worldX
      expect(child.worldX, lessThan(rig.root.worldX),
          reason: 'Positive rotation should move child LEFT (CCW), not right. '
              'Got child.worldX=${child.worldX.toStringAsFixed(4)}, '
              'root.worldX=${rig.root.worldX.toStringAsFixed(4)}. '
              'If child moved RIGHT, rotation matrix has wrong sign (CW instead of CCW).');
      expect(child.worldX, closeTo(rig.root.worldX - 0.4, 0.02),
          reason: 'After +90° on vertical bone of length 0.4, child should be 0.4 units left of root');
      expect(child.worldY, closeTo(rig.root.worldY, 0.02),
          reason: 'After +90° on vertical bone, child should have same Y as root');
    });

    test('-90° on upward bone: child moves RIGHT (CW = negative)', () {
      rig.root.setRotation(-math.pi / 2);
      rig.root.updateTransforms();

      final child = rig.root.children.first;
      expect(child.worldX, greaterThan(rig.root.worldX),
          reason: 'Negative rotation should move child RIGHT (CW)');
      expect(child.worldX, closeTo(rig.root.worldX + 0.4, 0.02));
      expect(child.worldY, closeTo(rig.root.worldY, 0.02));
    });

    test('180° rotation: child appears below root (bone flips down)', () {
      rig.root.setRotation(math.pi);
      rig.root.updateTransforms();

      final child = rig.root.children.first;
      // Upward bone rotated 180° → now points DOWN in visual space (worldY > root.worldY)
      expect(child.worldY, greaterThan(rig.root.worldY),
          reason: '180° flip of upward bone should point it DOWN (worldY increases in y-down)');
      expect(child.worldX, closeTo(rig.root.worldX, 0.02));
    });
  });

  group('Rig structure', () {
    late Rig rig;

    setUpAll(() {
      final cfg = CharConfig.fromYamlString(_charCfgYaml);
      rig = Rig(cfg);
    });

    test('root at (120/412, 283/412)', () {
      expect(rig.root.initX, closeTo(120 / 412, 1e-6));
      expect(rig.root.initY, closeTo(283 / 412, 1e-6));
    });

    test('all joint positions within character bounds', () {
      const maxX = 223 / 412;
      for (final j in rig.root.allJoints) {
        expect(j.initX, inInclusiveRange(0.0, maxX + 0.01),
            reason: '${j.name}.initX=${j.initX} exceeds character width');
        expect(j.initY, inInclusiveRange(0.0, 1.01),
            reason: '${j.name}.initY=${j.initY} out of [0,1]');
      }
    });

    test('16 joints total', () {
      expect(rig.jointCount, 16);
    });

    test('parent indices: root=-1, hip→root, torso→hip', () {
      final all = rig.root.allJoints;
      final nameToIdx = {for (int i = 0; i < all.length; i++) all[i].name: i};
      final indices = rig.getParentIndices();
      expect(indices[nameToIdx['root']!], -1);
      expect(indices[nameToIdx['hip']!], nameToIdx['root']);
      expect(indices[nameToIdx['torso']!], nameToIdx['hip']);
    });
  });
}
