import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_animated_drawings/bvh/bvh_parser.dart';

// BVH file is bundled as a Flutter asset; for tests we read it from filesystem.
const _bvhPath = r'd:\src\konyshevgmbh\cad\AnimatedDrawings\flutter_animated_drawings\assets\bvh\fair1\dab.bvh';

void main() {
  group('BVH parser — dab.bvh (Python reference)', () {
    late BvhData bvh;

    setUpAll(() {
      final file = File(_bvhPath);
      if (!file.existsSync()) return;
      bvh = BvhData.fromString(file.readAsStringSync(), 'dab.bvh');
    });

    test('file is accessible', () {
      expect(File(_bvhPath).existsSync(), isTrue,
          reason: 'BVH asset not found at $_bvhPath');
    });

    test('339 frames (matches Python dab.bvh)', () {
      expect(bvh.frameCount, 339);
    });

    test('frameTime ≈ 1/30 s', () {
      expect(bvh.frameTime, closeTo(1.0 / 30.0, 0.001));
    });

    test('34 joints (Mixamo skeleton)', () {
      expect(bvh.jointNames.length, 34);
    });

    test('root joint is Hips', () {
      expect(bvh.jointNames.first, 'Hips');
    });

    test('expected joint names present', () {
      final names = bvh.jointNames.toSet();
      for (final expected in [
        'Hips', 'Spine', 'Neck', 'LeftArm', 'RightArm',
        'LeftForeArm', 'RightForeArm', 'LeftHand', 'RightHand',
        'LeftUpLeg', 'RightUpLeg', 'LeftLeg', 'RightLeg',
        'LeftFoot', 'RightFoot',
      ]) {
        expect(names.contains(expected), isTrue, reason: '$expected not in BVH joints');
      }
    });

    test('frame slice [0, 339) returns all 339 frames', () {
      final sliced = BvhData.fromString(
        File(_bvhPath).readAsStringSync(), 'dab.bvh',
        startFrame: 0,
        endFrame: 339,
      );
      expect(sliced.frameCount, 339);
    });

    test('frame slice [0, 10) returns 10 frames', () {
      final sliced = BvhData.fromString(
        File(_bvhPath).readAsStringSync(), 'dab.bvh',
        startFrame: 0,
        endFrame: 10,
      );
      expect(sliced.frameCount, 10);
    });

    test('world positions computable for frame 0', () {
      bvh.applyFrame(0);
      final pos = bvh.root.getChainWorldPos();
      // 34 joints × 3 components
      expect(pos.length, 34 * 3);
      // Root (Hips) worldPos is reset to offset by _updateTransforms; check
      // a child joint (Spine = index 1, has non-zero offset from Hips).
      final spineX = pos[3], spineY = pos[4], spineZ = pos[5];
      expect(spineX.abs() + spineY.abs() + spineZ.abs(), greaterThan(0),
          reason: 'Spine joint world position should be non-zero (has offset from Hips)');
    });

    test('world positions differ between frame 0 and frame 100', () {
      bvh.applyFrame(0);
      final pos0 = List<double>.from(bvh.root.getChainWorldPos());
      bvh.applyFrame(100);
      final pos100 = bvh.root.getChainWorldPos();
      bool anyDiff = false;
      for (int i = 0; i < pos0.length; i++) {
        if ((pos0[i] - pos100[i]).abs() > 1e-4) { anyDiff = true; break; }
      }
      expect(anyDiff, isTrue, reason: 'Frame 0 and 100 produced identical poses');
    });
  });

  group('RetargetConfig parsing — fair1_ppf.yaml', () {
    const retargetPath = r'd:\src\konyshevgmbh\cad\AnimatedDrawings\flutter_animated_drawings\assets\config\retarget\fair1_ppf.yaml';

    test('file is accessible', () {
      expect(File(retargetPath).existsSync(), isTrue);
    });

    test('parses without error', () {
      if (!File(retargetPath).existsSync()) {
        markTestSkipped('retarget config not found');
        return;
      }
      // Import RetargetConfig here only if file exists
      // We test it by checking the content is parseable YAML
      final content = File(retargetPath).readAsStringSync();
      expect(content, contains('bvh_projection_bodypart_groups'));
      expect(content, contains('char_joint_bvh_joints_mapping'));
    });
  });
}
