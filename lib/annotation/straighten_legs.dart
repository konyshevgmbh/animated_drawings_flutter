import 'dart:ui' show Offset;

/// Port of annotate_yolo.py:straighten_leg().
/// Projects knee onto the hip→ankle line to remove lateral bend.
Offset projectKneeOntoLine(Offset hip, Offset knee, Offset ankle) {
  final leg = ankle - hip;
  final legLenSq = leg.dx * leg.dx + leg.dy * leg.dy;
  if (legLenSq < 1e-12) return knee; // degenerate
  final kneeRelHip = knee - hip;
  double t = (kneeRelHip.dx * leg.dx + kneeRelHip.dy * leg.dy) / legLenSq;
  t = t.clamp(0.0, 1.0);
  return Offset(hip.dx + t * leg.dx, hip.dy + t * leg.dy);
}

/// Straighten both legs in a COCO-17 keypoint list.
/// kpts indices: 11=l_hip, 12=r_hip, 13=l_knee, 14=r_knee, 15=l_ankle, 16=r_ankle
List<Offset> straightenLegs(List<Offset> kpts) {
  final out = List<Offset>.from(kpts);
  out[13] = projectKneeOntoLine(kpts[11], kpts[13], kpts[15]); // left
  out[14] = projectKneeOntoLine(kpts[12], kpts[14], kpts[16]); // right
  return out;
}
