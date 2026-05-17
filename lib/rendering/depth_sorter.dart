import 'dart:typed_data';

import '../retarget/config_models.dart';

/// Port of animated_drawing.py:_set_draw_indices().
/// Returns concatenated triangle index arrays, sorted back-to-front by joint depth.
Uint16List sortTrianglesByDepth(
    Map<String, Uint16List> jointToTriIndices,
    List<CharBodypartGroup> charBodypartGroups,
    Map<String, double> jointDepths,
) {
  // For each bodypart group, compute mean depth of its depth drivers
  final renderOrder = <(int, double)>[];
  for (int i = 0; i < charBodypartGroups.length; i++) {
    final group = charBodypartGroups[i];
    double sumDepth = 0;
    int count = 0;
    for (final driver in group.bvhDepthDrivers) {
      if (jointDepths.containsKey(driver)) {
        sumDepth += jointDepths[driver]!;
        count++;
      }
    }
    final avgDepth = count > 0 ? sumDepth / count : 0.0;
    renderOrder.add((i, avgDepth));
  }

  // Sort by increasing depth (back = negative depth first, front = positive last)
  renderOrder.sort((a, b) => a.$2.compareTo(b.$2));

  final indices = <int>[];
  for (final (idx, dist) in renderOrder) {
    final group = charBodypartGroups[idx];
    // If depth driver is behind plane (dist > 0 = closer to camera in frontal view),
    // render joints in normal order; otherwise reverse.
    final order = dist > 0 ? 1 : -1;
    final joints = order == 1
        ? group.charJoints
        : group.charJoints.reversed.toList();
    for (final jn in joints) {
      final tris = jointToTriIndices[jn];
      if (tris != null) indices.addAll(tris);
    }
  }

  return Uint16List.fromList(indices);
}
