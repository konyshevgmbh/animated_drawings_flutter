import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_animated_drawings/annotation/char_cfg.dart';

// Python-produced char_cfg.yaml from C:\Users\...\annotation_out\char_cfg.yaml
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

void main() {
  group('CharConfig parsing', () {
    late CharConfig cfg;
    setUpAll(() {
      cfg = CharConfig.fromYamlString(_charCfgYaml);
    });

    test('dimensions', () {
      expect(cfg.height, 412);
      expect(cfg.width, 223);
      expect(cfg.imgDim, 412); // max(412, 223)
    });

    test('16 joints', () {
      expect(cfg.skeleton.length, 16);
    });

    test('root has no parent', () {
      final root = cfg.skeleton.firstWhere((j) => j.name == 'root');
      expect(root.parent, isNull);
      expect(root.x, 120.0);
      expect(root.y, 283.0);
    });

    test('torso coords', () {
      final torso = cfg.skeleton.firstWhere((j) => j.name == 'torso');
      expect(torso.parent, 'hip');
      expect(torso.x, 124.0);
      expect(torso.y, 157.0);
    });

    test('all joints have valid pixel coords within image', () {
      for (final j in cfg.skeleton) {
        expect(j.x, inInclusiveRange(0, cfg.width.toDouble()),
            reason: '${j.name}.x out of range');
        expect(j.y, inInclusiveRange(0, cfg.height.toDouble()),
            reason: '${j.name}.y out of range');
      }
    });

    test('fromFile matches fromYamlString', () async {
      const path = r'C:\Users\IGORKO~1\AppData\Local\Temp\annotation_out\char_cfg.yaml';
      final file = File(path);
      if (!file.existsSync()) {
        markTestSkipped('Python output not found: $path');
        return;
      }
      final content = await file.readAsString();
      final fromFile = CharConfig.fromYamlString(content);
      expect(fromFile.height, cfg.height);
      expect(fromFile.width, cfg.width);
      expect(fromFile.skeleton.length, cfg.skeleton.length);
    });
  });
}
