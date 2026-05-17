import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:flutter_animated_drawings/annotation/char_cfg.dart';
import 'package:flutter_animated_drawings/mesh/triangulation.dart';

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

// Load mask.png (portrait, no rotation) and pad to imgDim×imgDim
Uint8List? _loadMask(String path, int imgDim) {
  final file = File(path);
  if (!file.existsSync()) return null;
  final decoded = img.decodeImage(file.readAsBytesSync())!;
  // Pad to square: character in top-left corner
  final padded = img.Image(width: imgDim, height: imgDim);
  img.compositeImage(padded, decoded, dstX: 0, dstY: 0);
  final data = Uint8List(imgDim * imgDim);
  for (int y = 0; y < imgDim; y++) {
    for (int x = 0; x < imgDim; x++) {
      data[y * imgDim + x] = padded.getPixel(x, y).r.toInt();
    }
  }
  return data;
}

void main() {
  const maskPath = r'C:\Users\IGORKO~1\AppData\Local\Temp\annotation_out\mask.png';

  group('buildMesh with Python mask.png', () {
    late CharMesh mesh;
    late CharConfig cfg;

    setUpAll(() {
      cfg = CharConfig.fromYamlString(_charCfgYaml);
      final maskData = _loadMask(maskPath, cfg.imgDim);
      if (maskData == null) {
        // Skip all tests if Python output not available
        return;
      }
      mesh = buildMesh(maskData, cfg.imgDim, cfg);
    });

    test('mesh is built when mask is available', () {
      final maskData = _loadMask(maskPath, cfg.imgDim);
      if (maskData == null) {
        markTestSkipped('Python mask not found: $maskPath');
        return;
      }
      expect(mesh.vertices, isNotEmpty);
      expect(mesh.triangles, isNotEmpty);
    });

    test('vertex count > 500 (contour + interior)', () {
      final maskData = _loadMask(maskPath, cfg.imgDim);
      if (maskData == null) { markTestSkipped('no mask'); return; }
      expect(mesh.vertices.length, greaterThan(500));
    });

    test('≥15 joints mapped (root has no parent so gets no seeds)', () {
      final maskData = _loadMask(maskPath, cfg.imgDim);
      if (maskData == null) { markTestSkipped('no mask'); return; }
      // root has no parent → no BFS seeds → never mapped. All 15 other joints should map.
      expect(mesh.jointToTriIndices.length, greaterThanOrEqualTo(15),
          reason: 'Only ${mesh.jointToTriIndices.keys} mapped — BFS seeds may be wrong');
    });

    test('vertex x within portrait character width [0, 223/412]', () {
      final maskData = _loadMask(maskPath, cfg.imgDim);
      if (maskData == null) { markTestSkipped('no mask'); return; }
      const maxX = 223 / 412;
      for (int i = 0; i < mesh.vertices.length; i++) {
        expect(mesh.vertices[i].x, inInclusiveRange(0.0, maxX + 0.01),
            reason: 'vertex[$i].x=${mesh.vertices[i].x} exceeds character width');
      }
    });

    test('vertex y within [0, 1] (portrait height fills imgDim)', () {
      final maskData = _loadMask(maskPath, cfg.imgDim);
      if (maskData == null) { markTestSkipped('no mask'); return; }
      for (int i = 0; i < mesh.vertices.length; i++) {
        expect(mesh.vertices[i].y, inInclusiveRange(0.0, 1.01),
            reason: 'vertex[$i].y=${mesh.vertices[i].y} out of [0,1]');
      }
    });

    test('torso and neck are in jointToTriIndices', () {
      final maskData = _loadMask(maskPath, cfg.imgDim);
      if (maskData == null) { markTestSkipped('no mask'); return; }
      expect(mesh.jointToTriIndices.containsKey('torso'), isTrue);
      expect(mesh.jointToTriIndices.containsKey('neck'), isTrue);
    });

    test('all triangle indices within vertex count', () {
      final maskData = _loadMask(maskPath, cfg.imgDim);
      if (maskData == null) { markTestSkipped('no mask'); return; }
      final maxIdx = mesh.vertices.length;
      for (int i = 0; i < mesh.triangles.length; i++) {
        expect(mesh.triangles[i], lessThan(maxIdx),
            reason: 'triangle index ${mesh.triangles[i]} out of range');
      }
    });
  });

  group('buildMesh with synthetic 10×10 square mask', () {
    // A simple 10×10 filled square in the center of a 20×20 mask
    late CharMesh mesh;

    setUpAll(() {
      const dim = 20;
      final data = Uint8List(dim * dim);
      for (int y = 5; y < 15; y++) {
        for (int x = 5; x < 15; x++) {
          data[y * dim + x] = 255;
        }
      }
      // Minimal skeleton: one root joint in the center of the square
      final cfg = CharConfig(
        height: dim,
        width: dim,
        skeleton: [
          const CharJoint(name: 'root', parent: null, x: 10, y: 10),
          const CharJoint(name: 'neck', parent: 'root', x: 10, y: 6),
        ],
      );
      mesh = buildMesh(data, dim, cfg);
    });

    test('mesh has vertices', () {
      expect(mesh.vertices, isNotEmpty);
    });

    test('mesh has triangles', () {
      expect(mesh.triangles.length, greaterThan(0));
    });

    test('all vertices inside [0,1] square', () {
      for (final v in mesh.vertices) {
        expect(v.x, inInclusiveRange(0.0, 1.01));
        expect(v.y, inInclusiveRange(0.0, 1.01));
      }
    });
  });
}
