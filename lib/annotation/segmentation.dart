import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:image/image.dart' as img;

/// Port of annotate_yolo.py:segment().
/// Returns a grayscale mask (0=background, 255=foreground) as a flat row-major Uint8List.
Uint8List segmentImage(img.Image image) {
  final h = image.height;
  final w = image.width;

  // Step 1: take min of R,G,B channels per pixel → grayscale
  final gray = Uint8List(h * w);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final px = image.getPixel(x, y);
      final r = px.r.toInt();
      final g = px.g.toInt();
      final b = px.b.toInt();
      gray[y * w + x] = math.min(r, math.min(g, b));
    }
  }

  // Step 2: adaptive threshold (Gaussian, blockSize=115, C=8)
  final thresh = _adaptiveThreshold(gray, w, h, blockSize: 115, c: 8);

  // Step 3: invert
  for (int i = 0; i < thresh.length; i++) {
    thresh[i] = thresh[i] == 0 ? 255 : 0;
  }

  // Step 4: morphological close (3×3, 2 iters) then dilate (3×3, 2 iters)
  var processed = _morphClose(thresh, w, h, 2);
  processed = _morphDilate(processed, w, h, 2);

  // Step 5: flood fill from edge seeds → background = 0, character = 255
  // Start with all 255; BFS from edges zeros out background pixels only.
  // Character outline (255 barrier) blocks BFS → character stays 255.
  final floodfill = Uint8List.fromList(List.filled(h * w, 255));
  final visitBarrier = Uint8List.fromList(processed); // barrier = character pixels

  for (int x = 0; x < w; x += 10) {
    _bfsFloodFill(floodfill, visitBarrier, w, h, x, 0, 0);
    _bfsFloodFill(floodfill, visitBarrier, w, h, x, h - 1, 0);
  }
  for (int y = 0; y < h; y += 10) {
    _bfsFloodFill(floodfill, visitBarrier, w, h, 0, y, 0);
    _bfsFloodFill(floodfill, visitBarrier, w, h, w - 1, y, 0);
  }
  // Force border to background
  for (int x = 0; x < w; x++) {
    floodfill[x] = 0;
    floodfill[(h - 1) * w + x] = 0;
  }
  for (int y = 0; y < h; y++) {
    floodfill[y * w] = 0;
    floodfill[y * w + (w - 1)] = 0;
  }

  // Step 6: floodfill already IS the mask (character=255, background=0).
  // No inversion needed — fill any interior holes.
  _fillHoles(floodfill, w, h);

  return floodfill;
}

// ─── Internal helpers ──────────────────────────────────────────────────────

/// Gaussian-weighted adaptive threshold matching OpenCV ADAPTIVE_THRESH_GAUSSIAN_C.
/// sigma = 0.3 * ((blockSize-1)*0.5 - 1) + 0.8  (OpenCV formula).
/// Border handling: BORDER_REPLICATE (clamp to edge pixel).
Uint8List _adaptiveThreshold(
    Uint8List gray, int w, int h, {required int blockSize, required int c}) {
  final half = blockSize ~/ 2;
  final sigma = 0.3 * ((blockSize - 1) * 0.5 - 1) + 0.8;

  // Build normalised 1-D Gaussian kernel of length blockSize.
  final kernel = Float64List(blockSize);
  double ksum = 0;
  for (int i = 0; i < blockSize; i++) {
    final x = (i - half).toDouble();
    kernel[i] = math.exp(-x * x / (2 * sigma * sigma));
    ksum += kernel[i];
  }
  for (int i = 0; i < blockSize; i++) { kernel[i] /= ksum; }

  // Horizontal pass with BORDER_REPLICATE.
  final temp = Float64List(w * h);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      double s = 0;
      for (int k = 0; k < blockSize; k++) {
        final nx = (x - half + k).clamp(0, w - 1);
        s += kernel[k] * gray[y * w + nx];
      }
      temp[y * w + x] = s;
    }
  }

  // Vertical pass with BORDER_REPLICATE → threshold.
  final out = Uint8List(h * w);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      double s = 0;
      for (int k = 0; k < blockSize; k++) {
        final ny = (y - half + k).clamp(0, h - 1);
        s += kernel[k] * temp[ny * w + x];
      }
      out[y * w + x] = gray[y * w + x] > (s - c) ? 255 : 0;
    }
  }
  return out;
}

Uint8List _morphClose(Uint8List src, int w, int h, int iters) {
  var buf = Uint8List.fromList(src);
  for (int i = 0; i < iters; i++) {
    buf = _morphDilate(buf, w, h, 1);
  }
  for (int i = 0; i < iters; i++) {
    buf = _morphErode(buf, w, h, 1);
  }
  return buf;
}

Uint8List _morphDilate(Uint8List src, int w, int h, int iters) {
  var buf = Uint8List.fromList(src);
  for (int it = 0; it < iters; it++) {
    final out = Uint8List(w * h);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        int maxVal = 0;
        for (int dy = -1; dy <= 1; dy++) {
          for (int dx = -1; dx <= 1; dx++) {
            final nx = x + dx;
            final ny = y + dy;
            if (nx >= 0 && nx < w && ny >= 0 && ny < h) {
              if (buf[ny * w + nx] > maxVal) maxVal = buf[ny * w + nx];
            }
          }
        }
        out[y * w + x] = maxVal;
      }
    }
    buf = out;
  }
  return buf;
}

Uint8List _morphErode(Uint8List src, int w, int h, int iters) {
  var buf = Uint8List.fromList(src);
  for (int it = 0; it < iters; it++) {
    final out = Uint8List(w * h);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        int minVal = 255;
        for (int dy = -1; dy <= 1; dy++) {
          for (int dx = -1; dx <= 1; dx++) {
            final nx = x + dx;
            final ny = y + dy;
            if (nx >= 0 && nx < w && ny >= 0 && ny < h) {
              if (buf[ny * w + nx] < minVal) minVal = buf[ny * w + nx];
            }
          }
        }
        out[y * w + x] = minVal;
      }
    }
    buf = out;
  }
  return buf;
}

void _bfsFloodFill(
    Uint8List img, Uint8List barrier, int w, int h, int sx, int sy, int fillValue) {
  if (img[sy * w + sx] == fillValue) return;
  if (barrier[sy * w + sx] != 0) return;
  final queue = Queue<int>();
  queue.add(sy * w + sx);
  img[sy * w + sx] = fillValue;
  while (queue.isNotEmpty) {
    final idx = queue.removeFirst();
    final cx = idx % w;
    final cy = idx ~/ w;
    for (final d in const [[-1, 0], [1, 0], [0, -1], [0, 1]]) {
      final nx = cx + d[0];
      final ny = cy + d[1];
      if (nx < 0 || nx >= w || ny < 0 || ny >= h) continue;
      final ni = ny * w + nx;
      if (img[ni] == fillValue) continue;
      if (barrier[ni] != 0) continue;
      img[ni] = fillValue;
      queue.add(ni);
    }
  }
}

void _fillHoles(Uint8List mask, int w, int h) {
  // Flood fill from border with 0, mark as 'outside'. Everything else is inside.
  final outside = Uint8List(w * h);
  final queue = Queue<int>();
  void seedIfBg(int x, int y) {
    final idx = y * w + x;
    if (mask[idx] == 0 && outside[idx] == 0) {
      outside[idx] = 1;
      queue.add(idx);
    }
  }

  for (int x = 0; x < w; x++) {
    seedIfBg(x, 0);
    seedIfBg(x, h - 1);
  }
  for (int y = 1; y < h - 1; y++) {
    seedIfBg(0, y);
    seedIfBg(w - 1, y);
  }
  while (queue.isNotEmpty) {
    final idx = queue.removeFirst();
    final cx = idx % w;
    final cy = idx ~/ w;
    for (final d in const [[-1, 0], [1, 0], [0, -1], [0, 1]]) {
      final nx = cx + d[0];
      final ny = cy + d[1];
      if (nx < 0 || nx >= w || ny < 0 || ny >= h) continue;
      final ni = ny * w + nx;
      if (outside[ni] != 0 || mask[ni] != 0) continue;
      outside[ni] = 1;
      queue.add(ni);
    }
  }
  // Everything not reached by BFS from border that was background → fill as foreground
  for (int i = 0; i < w * h; i++) {
    if (mask[i] == 0 && outside[i] == 0) {
      mask[i] = 255;
    }
  }
}
