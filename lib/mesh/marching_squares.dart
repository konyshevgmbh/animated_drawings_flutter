import 'dart:typed_data';
import 'dart:ui' show Offset;
import 'package:flutter/foundation.dart' show debugPrint;

/// Extracts the boundary contour from a binary mask using marching squares.
/// Returns the LONGEST connected chain of contour points (pixel coords).
List<Offset> marchingSquares(Uint8List mask, int width, int height) {
  final segments = <(Offset, Offset)>[];

  for (int row = 0; row < height - 1; row++) {
    for (int col = 0; col < width - 1; col++) {
      final tl = mask[row * width + col] > 0 ? 1 : 0;
      final tr = mask[row * width + col + 1] > 0 ? 1 : 0;
      final bl = mask[(row + 1) * width + col] > 0 ? 1 : 0;
      final br = mask[(row + 1) * width + col + 1] > 0 ? 1 : 0;
      final idx = (tl << 3) | (tr << 2) | (br << 1) | bl;

      final t = Offset(col + 0.5, row.toDouble());
      final b = Offset(col + 0.5, row + 1.0);
      final l = Offset(col.toDouble(), row + 0.5);
      final r = Offset(col + 1.0, row + 0.5);

      switch (idx) {
        case 1:  segments.add((l, b)); break;
        case 2:  segments.add((b, r)); break;
        case 3:  segments.add((l, r)); break;
        case 4:  segments.add((t, r)); break;
        case 5:  segments.add((l, t)); segments.add((b, r)); break;
        case 6:  segments.add((t, b)); break;
        case 7:  segments.add((l, t)); break;
        case 8:  segments.add((l, t)); break;
        case 9:  segments.add((t, b)); break;
        case 10: segments.add((l, b)); segments.add((t, r)); break;
        case 11: segments.add((t, r)); break;
        case 12: segments.add((l, r)); break;
        case 13: segments.add((b, r)); break;
        case 14: segments.add((l, b)); break;
      }
    }
  }

  debugPrint('[MS]   total segments=${segments.length}');
  if (segments.isEmpty) return [];

  // Build adjacency and track original Offset for each key
  final adjacency = <_OKey, List<Offset>>{};
  final keyToOffset = <_OKey, Offset>{};

  for (final seg in segments) {
    final k1 = _OKey(seg.$1);
    final k2 = _OKey(seg.$2);
    adjacency.putIfAbsent(k1, () => []).add(seg.$2);
    adjacency.putIfAbsent(k2, () => []).add(seg.$1);
    keyToOffset[k1] = seg.$1;
    keyToOffset[k2] = seg.$2;
  }

  // Walk ALL connected components; return the longest chain.
  final globalVisited = <_OKey>{};
  List<Offset> best = [];

  for (final startKey in adjacency.keys) {
    if (globalVisited.contains(startKey)) continue;
    final start = keyToOffset[startKey]!;
    final chain = _walkChain(start, adjacency, keyToOffset);
    for (final pt in chain) {
      globalVisited.add(_OKey(pt));
    }
    debugPrint('[MS]   component len=${chain.length}  start=(${start.dx.toStringAsFixed(1)},${start.dy.toStringAsFixed(1)})');
    if (chain.length > best.length) best = chain;
  }

  debugPrint('[MS]   longest chain=${best.length}');
  return best;
}

List<Offset> _walkChain(
  Offset start,
  Map<_OKey, List<Offset>> adjacency,
  Map<_OKey, Offset> keyToOffset,
) {
  final visited = <_OKey>{};
  final chain = <Offset>[];
  var current = start;
  chain.add(current);
  visited.add(_OKey(current));

  while (true) {
    final neighbors = adjacency[_OKey(current)];
    if (neighbors == null) break;
    Offset? next;
    for (final n in neighbors) {
      if (!visited.contains(_OKey(n))) {
        next = n;
        break;
      }
    }
    if (next == null) break;
    chain.add(next);
    visited.add(_OKey(next));
    current = next;
  }
  return chain;
}

class _OKey {
  final double x, y;
  _OKey(Offset o) : x = o.dx, y = o.dy;

  @override
  bool operator ==(Object other) =>
      other is _OKey && x == other.x && y == other.y;

  @override
  int get hashCode => Object.hash(x, y);
}
