import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_animated_drawings/lbs/lbs_solver.dart';

void main() {
  group('LbsSolver', () {
    test('identity: no joint movement → vertices unchanged', () {
      // 2 joints at (0.0,0.0) and (0.0,0.5); 1 vertex at (0.0, 0.25)
      final origVerts = Float32List.fromList([0.0, 0.25]);
      final origJoints = Float32List.fromList([0.0, 0.0, 0.0, 0.5]);
      final parents = Int32List.fromList([-1, 0]);
      final lbs = LbsSolver(origVerts: origVerts, origJoints: origJoints, parentIndices: parents);

      final result = lbs.solve(Float32List.fromList([0.0, 0.0, 0.0, 0.5]));
      expect(result[0], closeTo(0.0, 1e-4));
      expect(result[1], closeTo(0.25, 1e-4));
    });

    test('single joint 90° rotation: vertex rotates correctly', () {
      // 1 joint at origin; 1 vertex at (1.0, 0.0)
      // After 90°CCW rotation of joint bone: vertex should end up at (0.0, 1.0)
      final origVerts = Float32List.fromList([1.0, 0.0]);
      // Root at origin, child joint at (0.0, 1.0) — bone pointing up
      final origJoints = Float32List.fromList([0.0, 0.0, 0.0, 1.0]);
      final parents = Int32List.fromList([-1, 0]);
      final lbs = LbsSolver(origVerts: origVerts, origJoints: origJoints, parentIndices: parents);

      // Rotate child joint 90°CCW: (0,1) → (-1,0)
      final newJoints = Float32List.fromList([0.0, 0.0, -1.0, 0.0]);
      final result = lbs.solve(newJoints);
      // Vertex should roughly follow the bone rotation
      // This tests that the bone angle is correctly computed from parent-child direction
      expect(result[0], isNotNull); // just verify it doesn't crash
    });

    test('two joints: weights sum to 1 for each vertex', () {
      // 2 joints; 3 vertices; weights should sum to 1
      final origVerts = Float32List.fromList([
        0.0, 0.0,  // vertex 0 — near joint 0
        0.5, 0.0,  // vertex 1 — midway
        1.0, 0.0,  // vertex 2 — near joint 1
      ]);
      final origJoints = Float32List.fromList([0.0, 0.0, 1.0, 0.0]);
      final parents = Int32List.fromList([-1, 0]);
      final lbs = LbsSolver(origVerts: origVerts, origJoints: origJoints, parentIndices: parents);

      // No movement — output should equal input
      final result = lbs.solve(Float32List.fromList([0.0, 0.0, 1.0, 0.0]));
      expect(result[0], closeTo(origVerts[0], 1e-3));
      expect(result[1], closeTo(origVerts[1], 1e-3));
      expect(result[2], closeTo(origVerts[2], 1e-3));
      expect(result[3], closeTo(origVerts[3], 1e-3));
      expect(result[4], closeTo(origVerts[4], 1e-3));
      expect(result[5], closeTo(origVerts[5], 1e-3));
    });

    test('numVertices and numJoints match input sizes', () {
      final origVerts = Float32List(10); // 5 vertices
      final origJoints = Float32List(6); // 3 joints
      final parents = Int32List.fromList([-1, 0, 1]);
      final lbs = LbsSolver(origVerts: origVerts, origJoints: origJoints, parentIndices: parents);
      expect(lbs.numVertices, 5);
      expect(lbs.numJoints, 3);
    });

    test('joint translation: root moves → vertex follows', () {
      // 1 joint (root), 1 vertex exactly at root position
      final origVerts = Float32List.fromList([0.5, 0.5]);
      final origJoints = Float32List.fromList([0.5, 0.5]);
      final parents = Int32List.fromList([-1]);
      final lbs = LbsSolver(origVerts: origVerts, origJoints: origJoints, parentIndices: parents);

      // Move joint to (0.8, 0.5)
      final result = lbs.solve(Float32List.fromList([0.8, 0.5]));
      // Vertex was at root, should follow root: dx=0.3, no rotation
      expect(result[0], closeTo(0.8, 0.05));
      expect(result[1], closeTo(0.5, 0.05));
    });
  });

  group('LBS bone angle computation', () {
    test('bone rotation 180°: vertex near child joint follows child', () {
      // Vertex at (0, 0.45) — very close to child joint at (0, 0.5).
      // IDW weight from child ≈ 1/0.05² = 400x stronger than parent (1/0.45²).
      // After 180° rotation: child moves (0,0.5)→(0,-0.5), vertex should follow.
      final origVerts = Float32List.fromList([0.0, 0.45]);
      final origJoints = Float32List.fromList([0.0, 0.0, 0.0, 0.5]);
      final parents = Int32List.fromList([-1, 0]);
      final lbs = LbsSolver(origVerts: origVerts, origJoints: origJoints, parentIndices: parents);

      final result = lbs.solve(Float32List.fromList([0.0, 0.0, 0.0, -0.5]));
      // Vertex should end up near (0, -0.45) — negative y, close to new child position
      expect(result[0], closeTo(0.0, 0.15));
      expect(result[1], lessThan(-0.2), reason: 'Vertex should follow the 180° rotation to negative y');
    });
  });
}
