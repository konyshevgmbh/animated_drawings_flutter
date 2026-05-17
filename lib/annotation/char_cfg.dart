import 'package:yaml/yaml.dart';

class CharJoint {
  final String name;
  final String? parent;
  final double x; // pixel coord
  final double y; // pixel coord

  const CharJoint({required this.name, this.parent, required this.x, required this.y});
}

class CharConfig {
  final int height;
  final int width;
  final List<CharJoint> skeleton;

  const CharConfig({required this.height, required this.width, required this.skeleton});

  int get imgDim => height > width ? height : width;

  factory CharConfig.fromYamlString(String content) {
    final doc = loadYaml(content) as YamlMap;
    final h = (doc['height'] as num).toInt();
    final w = (doc['width'] as num).toInt();
    final skelList = doc['skeleton'] as YamlList;
    final joints = skelList.map((j) {
      final m = j as YamlMap;
      final loc = m['loc'] as YamlList;
      return CharJoint(
        name: m['name'] as String,
        parent: m['parent'] as String?,
        x: (loc[0] as num).toDouble(),
        y: (loc[1] as num).toDouble(),
      );
    }).toList();
    return CharConfig(height: h, width: w, skeleton: joints);
  }

  String toYamlString() {
    final buf = StringBuffer();
    buf.writeln('height: $height');
    buf.writeln('width: $width');
    buf.writeln('skeleton:');
    for (final j in skeleton) {
      buf.writeln('- name: ${j.name}');
      buf.writeln('  parent: ${j.parent}');
      buf.writeln('  loc: [${j.x.round()}, ${j.y.round()}]');
    }
    return buf.toString();
  }
}
