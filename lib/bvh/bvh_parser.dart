import 'dart:typed_data';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;

import 'quaternion_utils.dart';

class BvhJoint {
  final String name;
  final List<double> offset; // [x, y, z]
  final List<String> channels;
  final List<BvhJoint> children;
  // world position set each frame
  List<double> worldPos = [0.0, 0.0, 0.0];
  Quat worldRot = quatIdentity();

  BvhJoint({
    required this.name,
    required this.offset,
    required this.channels,
    required this.children,
  });

  int get jointCount {
    int count = 1;
    for (final c in children) {
      count += c.jointCount;
    }
    return count;
  }

  List<String> get chainJointNames {
    final names = [name];
    for (final c in children) {
      names.addAll(c.chainJointNames);
    }
    return names;
  }

  /// Returns flat list [x0,y0,z0, x1,y1,z1, ...] of all joint world positions.
  List<double> getChainWorldPos() {
    final result = [...worldPos];
    for (final c in children) {
      result.addAll(c.getChainWorldPos());
    }
    return result;
  }
}

class BvhData {
  final String name;
  final BvhJoint root;
  final int frameCount;
  double frameTime;
  /// pos_data[frame][0..2] = root xyz position
  final Float32List posData; // [frameCount × 3]
  /// rot_data[frame][jointIdx][0..3] = quaternion [w,x,y,z]
  final List<List<Quat>> rotData; // [frameCount][jointCount][4]

  BvhData({
    required this.name,
    required this.root,
    required this.frameCount,
    required this.frameTime,
    required this.posData,
    required this.rotData,
  });

  List<String> get jointNames => root.chainJointNames;
  int get jointCount => root.jointCount;

  /// Apply frame data: sets worldPos/worldRot on all joints.
  void applyFrame(int frameIdx) {
    root.worldPos = [
      posData[frameIdx * 3],
      posData[frameIdx * 3 + 1],
      posData[frameIdx * 3 + 2],
    ];
    root.worldRot = quatIdentity();
    _applyRotations(root, frameIdx, _Counter(0));
    _updateTransforms(root, [0.0, 0.0, 0.0], quatIdentity());
  }

  void _applyRotations(BvhJoint joint, int frame, _Counter ptr) {
    joint.worldRot = rotData[frame][ptr.value];
    ptr.value++;
    for (final c in joint.children) {
      _applyRotations(c, frame, ptr);
    }
  }

  void _updateTransforms(BvhJoint joint, List<double> parentPos, Quat parentRot) {
    // world_pos = parent_pos + parent_rot.rotate(joint.offset)
    final rotOffset = quatRotateVec(parentRot, joint.offset);
    joint.worldPos = [
      parentPos[0] + rotOffset[0],
      parentPos[1] + rotOffset[1],
      parentPos[2] + rotOffset[2],
    ];
    final combinedRot = quatNorm(quatMul(parentRot, joint.worldRot));
    joint.worldRot = combinedRot;
    for (final c in joint.children) {
      _updateTransforms(c, joint.worldPos, joint.worldRot);
    }
  }

  static Future<BvhData> fromAsset(
      String assetPath, {
      int startFrame = 0,
      int? endFrame,
  }) async {
    final content = await rootBundle.loadString(assetPath);
    return _parse(content, assetPath.split('/').last, startFrame, endFrame);
  }

  static BvhData fromString(
      String content, String name, {
      int startFrame = 0,
      int? endFrame,
  }) {
    return _parse(content, name, startFrame, endFrame);
  }

  static BvhData _parse(
      String content, String name, int startFrame, int? endFrame) {
    debugPrint('[BVH] _parse  name=$name  startFrame=$startFrame  endFrame=$endFrame');
    final lines = content.split('\n').map((l) => l.trim()).toList();
    debugPrint('[BVH]   total lines=${lines.length}');
    int ptr = 0;

    if (lines[ptr++] != 'HIERARCHY') {
      throw const FormatException('BVH: expected HIERARCHY');
    }

    final root = _parseSkeleton(lines, _Counter(ptr));
    final totalJoints = root.jointCount;
    final jointNames = root.chainJointNames;
    debugPrint('[BVH]   skeleton joints=$totalJoints  root="${root.name}"');
    debugPrint('[BVH]   joint names: ${jointNames.take(6).join(", ")}${totalJoints > 6 ? "..." : ""}');

    ptr = (lines.indexOf('MOTION'));
    if (ptr < 0) throw const FormatException('BVH: no MOTION section');
    ptr++;

    final frameCount = int.parse(lines[ptr++].split(':').last.trim());
    final frameTime = double.parse(lines[ptr++].split(':').last.trim());
    debugPrint('[BVH]   frameCount=$frameCount  frameTime=${frameTime}s  (~${(frameCount * frameTime).toStringAsFixed(1)}s total)');

    final frames = <List<double>>[];
    while (ptr < lines.length && lines[ptr].isNotEmpty) {
      final parts = lines[ptr++].trim().split(RegExp(r'\s+'));
      if (parts.isEmpty || parts.first.isEmpty) continue;
      frames.add(parts.map(double.parse).toList());
    }
    debugPrint('[BVH]   parsed frame rows=${frames.length}  channels/frame=${frames.isEmpty ? 0 : frames[0].length}');

    final (posData, rotData) = _processFrameData(root, frames);

    final finalEnd = (endFrame ?? frameCount).clamp(0, frameCount);
    final finalStart = startFrame.clamp(0, finalEnd);
    final slicedFrames = finalEnd - finalStart;
    debugPrint('[BVH]   sliced [$finalStart, $finalEnd) → $slicedFrames frames');

    final posSliced = Float32List(slicedFrames * 3);
    for (int i = 0; i < slicedFrames; i++) {
      posSliced[i * 3] = posData[(finalStart + i) * 3];
      posSliced[i * 3 + 1] = posData[(finalStart + i) * 3 + 1];
      posSliced[i * 3 + 2] = posData[(finalStart + i) * 3 + 2];
    }

    final rotSliced = rotData.sublist(finalStart, finalEnd);
    debugPrint('[BVH] _parse DONE  frames=$slicedFrames  joints=$totalJoints');

    return BvhData(
      name: name,
      root: root,
      frameCount: slicedFrames,
      frameTime: frameTime,
      posData: posSliced,
      rotData: rotSliced,
    );
  }

  static BvhJoint _parseSkeleton(List<String> lines, _Counter ptr) {
    final header = lines[ptr.value++];
    String jointName;
    if (header.startsWith('ROOT')) {
      jointName = header.split(' ').last;
    } else if (header.startsWith('JOINT')) {
      jointName = header.split(' ').last;
    } else if (header.startsWith('End Site')) {
      jointName = 'End Site';
    } else {
      throw FormatException('BVH: unexpected header: $header');
    }

    if (lines[ptr.value++] != '{') throw const FormatException('BVH: expected {');

    // OFFSET
    final offsetLine = lines[ptr.value++].trim();
    final offsetParts = offsetLine.split(RegExp(r'\s+'));
    final offset = [
      double.parse(offsetParts[1]),
      double.parse(offsetParts[2]),
      double.parse(offsetParts[3]),
    ];

    // CHANNELS (optional)
    List<String> channels = [];
    if (lines[ptr.value].startsWith('CHANNELS')) {
      final parts = lines[ptr.value++].split(RegExp(r'\s+'));
      final count = int.parse(parts[1]);
      channels = parts.sublist(2, 2 + count);
    }

    // Children
    final children = <BvhJoint>[];
    while (lines[ptr.value] != '}') {
      children.add(_parseSkeleton(lines, ptr));
    }
    ptr.value++; // consume '}'

    return BvhJoint(
        name: jointName, offset: offset, channels: channels, children: children);
  }

  static (Float32List, List<List<Quat>>) _processFrameData(
      BvhJoint root, List<List<double>> frames) {
    // Flatten channel order
    final allChannels = _getChannelOrder(root);

    // Build mask: keep rotation channels + first 3 (root pos)
    final mask = List.generate(
      allChannels.length,
      (i) => i < 3 || allChannels[i].toLowerCase().contains('rotation'),
    );

    // Filter frames
    final filteredFrames = frames.map((row) {
      return [for (int i = 0; i < row.length && i < mask.length; i++) if (mask[i]) row[i]];
    }).toList();

    final posData = Float32List(frames.length * 3);
    final rotData = <List<Quat>>[];

    for (int fi = 0; fi < filteredFrames.length; fi++) {
      final row = filteredFrames[fi];
      posData[fi * 3] = row[0];
      posData[fi * 3 + 1] = row[1];
      posData[fi * 3 + 2] = row[2];

      final rots = <Quat>[];
      final eulerData = row.sublist(3);
      int ePtr = 0;
      _convertRotations(root, eulerData, rots, _Counter(ePtr));
      rotData.add(rots);
    }

    return (posData, rotData);
  }

  static List<String> _getChannelOrder(BvhJoint joint) {
    final channels = List<String>.from(joint.channels);
    for (final c in joint.children) {
      channels.addAll(_getChannelOrder(c));
    }
    return channels;
  }

  static void _convertRotations(
      BvhJoint joint, List<double> eulerData, List<Quat> rots, _Counter ptr) {
    final rotChans = joint.channels
        .where((c) => c.toLowerCase().contains('rotation'))
        .toList();
    if (rotChans.isNotEmpty) {
      final axes = rotChans.map((c) => c[0].toLowerCase()).join();
      final angles = eulerData.sublist(ptr.value, ptr.value + rotChans.length);
      rots.add(eulerToQuat(axes, angles));
      ptr.value += rotChans.length;
    } else {
      rots.add(quatIdentity());
    }
    for (final c in joint.children) {
      _convertRotations(c, eulerData, rots, ptr);
    }
  }
}

class _Counter {
  int value;
  _Counter(this.value);
}
