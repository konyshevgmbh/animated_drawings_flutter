# Animated Drawings Flutter

<p align="center">
  <img src="example_input.png" alt="Hand-drawn character" height="220"/>
  &nbsp;&nbsp;&nbsp;
  <img src="example_animation.gif" alt="Animated result" height="220"/>
  &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;
  <img src="example_girl.png" alt="Hand-drawn character 2" height="220"/>
  &nbsp;&nbsp;&nbsp;
  <img src="example_girl_animation.gif" alt="Animated result 2" height="220"/>
</p>

A Flutter application that brings hand-drawn characters to life using computer vision and pose estimation.

> **Note:** The animation quality depends heavily on the mesh triangulation.
> It's worth experimenting with the grid density `N` and other parameters
> in [`lib/mesh/triangulation.dart`](lib/mesh/triangulation.dart) for your specific drawings.

## About

The app lets users animate their own drawings: take a photo of a hand-drawn character, and the AI automatically segments the figure, builds a skeleton, and applies motion animation.

This project is based on Meta AI research:

- [Meta AI Blog: AI Dataset & Animation of Drawings](https://ai.meta.com/blog/ai-dataset-animation-drawings/)
- [facebookresearch/AnimatedDrawings](https://github.com/facebookresearch/AnimatedDrawings) — core engine for character segmentation and animation

Character detection and segmentation is powered by a YOLOv8 model trained on a dataset of children's drawings:

- [konyshevgmbh/animated_drawings_yolov8](https://github.com/konyshevgmbh/animated_drawings_yolov8)

## Tech Stack

- Flutter — cross-platform UI
- YOLOv8 — character detection on drawings
- AnimatedDrawings (Meta AI) — skeleton rigging and animation
