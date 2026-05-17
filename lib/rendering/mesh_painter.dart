import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// CustomPainter that renders the animated drawing mesh using Canvas.drawVertices + ImageShader.
class MeshPainter extends CustomPainter {
  final ui.Image texture;
  final int imgDim;
  /// Actual bounding rect of all animation frames, in imgDim-normalised units.
  /// Covers the full range of deformed vertex positions so limbs are never clipped.
  final ui.Rect animBounds;
  /// Deformed vertex positions [numVerts × 2] normalized [0,1]
  final Float32List vertexPositions;
  /// UV texture coordinates [numVerts × 2] normalized [0,1]
  final Float32List texCoords;
  /// Triangle indices
  final Uint16List indices;

  MeshPainter({
    required this.texture,
    required this.imgDim,
    required this.animBounds,
    required this.vertexPositions,
    required this.texCoords,
    required this.indices,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final n = vertexPositions.length ~/ 2;
    if (n == 0 || indices.isEmpty) return;

    // Map [animBounds.left..right] × [animBounds.top..bottom] → canvas pixels.
    final bw = animBounds.width;
    final bh = animBounds.height;

    final positions = Float32List(n * 2);
    for (int i = 0; i < n; i++) {
      positions[i * 2]     = (vertexPositions[i * 2]     - animBounds.left) / bw * size.width;
      positions[i * 2 + 1] = (vertexPositions[i * 2 + 1] - animBounds.top)  / bh * size.height;
    }

    // Map UV [0,1] to image pixel coords
    final uvPixels = Float32List(n * 2);
    for (int i = 0; i < n; i++) {
      uvPixels[i * 2] = texCoords[i * 2] * imgDim;
      uvPixels[i * 2 + 1] = texCoords[i * 2 + 1] * imgDim;
    }

    // Build Vertices object
    final vertices = ui.Vertices.raw(
      ui.VertexMode.triangles,
      positions,
      textureCoordinates: uvPixels,
      indices: indices,
    );

    // ImageShader samples image at texCoord pixel coordinates directly
    final shader = ui.ImageShader(
      texture,
      ui.TileMode.clamp,
      ui.TileMode.clamp,
      Matrix4.identity().storage,
    );

    final paint = Paint()..shader = shader;
    canvas.drawVertices(vertices, BlendMode.srcOver, paint);
  }

  @override
  bool shouldRepaint(MeshPainter old) =>
      old.vertexPositions != vertexPositions ||
      old.indices != indices ||
      old.texture != texture ||
      old.animBounds != animBounds;
}
