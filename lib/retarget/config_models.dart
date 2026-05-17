import 'package:yaml/yaml.dart';

class MotionConfig {
  final String bvhPath;     // asset path, e.g. 'assets/bvh/fair1/dab.bvh'
  final int startFrame;
  final int? endFrame; // null → use all frames
  final String groundplaneJoint;
  final List<List<String>> forwardPerpJointVectors; // pairs of joint names
  final double scale;
  final String up; // '+y' or '+z'
  final double? frameTime; // override BVH frame time

  const MotionConfig({
    required this.bvhPath,
    required this.startFrame,
    this.endFrame,
    required this.groundplaneJoint,
    required this.forwardPerpJointVectors,
    required this.scale,
    required this.up,
    this.frameTime,
  });

  factory MotionConfig.fromYamlString(String content, String assetPrefix) {
    final doc = loadYaml(content) as YamlMap;
    // rewrite relative BVH path to Flutter asset path
    final rawPath = doc['filepath'] as String;
    // Strip 'examples/' prefix that exists in Python configs but not in Flutter assets
    final normalizedPath = rawPath.startsWith('examples/') ? rawPath.substring('examples/'.length) : rawPath;
    final bvhPath = normalizedPath.startsWith('assets/') ? normalizedPath : '$assetPrefix/$normalizedPath';
    final fwd = (doc['forward_perp_joint_vectors'] as YamlList)
        .map((pair) => (pair as YamlList).map((s) => s as String).toList())
        .toList();
    return MotionConfig(
      bvhPath: bvhPath,
      startFrame: (doc['start_frame_idx'] as num? ?? 0).toInt(),
      endFrame: (doc['end_frame_idx'] as num?)?.toInt(),
      groundplaneJoint: doc['groundplane_joint'] as String,
      forwardPerpJointVectors: fwd,
      scale: (doc['scale'] as num).toDouble(),
      up: doc['up'] as String,
      frameTime: doc['frame_time'] != null ? (doc['frame_time'] as num).toDouble() : null,
    );
  }
}

class BvhProjectionGroup {
  final String name;
  final List<String> bvhJointNames;
  final String method; // 'pca', 'frontal', 'sagittal'

  const BvhProjectionGroup({
    required this.name,
    required this.bvhJointNames,
    required this.method,
  });
}

class CharBodypartGroup {
  final List<String> bvhDepthDrivers;
  final List<String> charJoints;

  const CharBodypartGroup({
    required this.bvhDepthDrivers,
    required this.charJoints,
  });
}

class RetargetConfig {
  final List<double> charStartLoc; // [x, y, z]
  final List<BvhProjectionGroup> bvhProjectionGroups;
  final List<CharBodypartGroup> charBodypartGroups;
  // maps char joint name -> (prox_bvh_joint, dist_bvh_joint)
  final Map<String, List<String>> charJointBvhMapping;
  final String? rootOffsetBvhGroup;
  // Joint chains used to compute char-to-BVH limb length scale factor
  final List<List<String>>? charRootOffsetCharJoints;
  final List<List<String>>? charRootOffsetBvhJoints;

  const RetargetConfig({
    required this.charStartLoc,
    required this.bvhProjectionGroups,
    required this.charBodypartGroups,
    required this.charJointBvhMapping,
    this.rootOffsetBvhGroup,
    this.charRootOffsetCharJoints,
    this.charRootOffsetBvhJoints,
  });

  factory RetargetConfig.fromYamlString(String raw) {
    // strip !!python/tuple tags which the Dart YAML parser can't handle
    final content = raw.replaceAll('!!python/tuple', '');
    final doc = loadYaml(content) as YamlMap;

    final startLoc = doc['char_starting_location'] != null
        ? (doc['char_starting_location'] as YamlList)
            .map((v) => (v as num).toDouble())
            .toList()
        : [0.0, 0.0, 0.0];

    final groups = (doc['bvh_projection_bodypart_groups'] as YamlList).map((g) {
      final gm = g as YamlMap;
      return BvhProjectionGroup(
        name: gm['name'] as String,
        bvhJointNames: (gm['bvh_joint_names'] as YamlList)
            .map((s) => s as String)
            .toList(),
        method: gm['method'] as String,
      );
    }).toList();

    final charGroups = (doc['char_bodypart_groups'] as YamlList).map((g) {
      final gm = g as YamlMap;
      return CharBodypartGroup(
        bvhDepthDrivers: (gm['bvh_depth_drivers'] as YamlList)
            .map((s) => s as String)
            .toList(),
        charJoints: (gm['char_joints'] as YamlList)
            .map((s) => s as String)
            .toList(),
      );
    }).toList();

    final mapping = <String, List<String>>{};
    final rawMapping = doc['char_joint_bvh_joints_mapping'] as YamlMap;
    rawMapping.forEach((k, v) {
      mapping[k as String] =
          (v as YamlList).map((s) => s as String).toList();
    });

    final rootOffsetMap = doc['char_bvh_root_offset'] as YamlMap?;
    final rootOffsetGroup =
        rootOffsetMap?['bvh_projection_bodypart_group_for_offset'] as String?;

    List<List<String>>? parseJointGroups(dynamic raw) {
      if (raw == null) return null;
      return (raw as YamlList).map((group) =>
          (group as YamlList).map((s) => s as String).toList()
      ).toList();
    }

    final charRootCharJoints = parseJointGroups(rootOffsetMap?['char_joints']);
    final charRootBvhJoints = parseJointGroups(rootOffsetMap?['bvh_joints']);

    return RetargetConfig(
      charStartLoc: startLoc,
      bvhProjectionGroups: groups,
      charBodypartGroups: charGroups,
      charJointBvhMapping: mapping,
      rootOffsetBvhGroup: rootOffsetGroup,
      charRootOffsetCharJoints: charRootCharJoints,
      charRootOffsetBvhJoints: charRootBvhJoints,
    );
  }
}
