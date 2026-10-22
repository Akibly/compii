import 'dart:math' as math;
import 'dart:ui';

/// A point in the small 3D space the crystal characters are carved from.
/// x runs right, y runs down, and z runs away from the viewer.
class Vec3 {
  const Vec3(this.x, this.y, this.z);

  final double x;
  final double y;
  final double z;

  Vec3 operator +(Vec3 other) => Vec3(x + other.x, y + other.y, z + other.z);
  Vec3 operator -(Vec3 other) => Vec3(x - other.x, y - other.y, z - other.z);
  Vec3 operator *(double scale) => Vec3(x * scale, y * scale, z * scale);

  double dot(Vec3 other) => x * other.x + y * other.y + z * other.z;

  Vec3 cross(Vec3 other) => Vec3(
    y * other.z - z * other.y,
    z * other.x - x * other.z,
    x * other.y - y * other.x,
  );

  double get length => math.sqrt(dot(this));

  Vec3 get unit {
    final l = length;
    return l < 1e-9 ? this : this * (1 / l);
  }
}

class GemFace {
  const GemFace({
    required this.path,
    required this.center,
    required this.depth,
    required this.lit,
    required this.front,
  });

  final Path path;
  final Offset center;

  /// Painter-space z of the face centre; larger is farther from the viewer.
  final double depth;

  /// 0..1 lambert value against the studio light.
  final double lit;

  /// Facing the viewer.
  final bool front;
}

/// A cut crystal: two rings of facets joining a point above and below.
/// Rotating the model and projecting it with a touch of perspective is enough
/// to read as a solid object; the painter supplies the glass, glow and mirror.
class GemGeometry {
  const GemGeometry({
    this.top = -1.04,
    this.upperY = -0.36,
    this.upperRadius = 0.30,
    this.lowerY = 0.33,
    this.lowerRadius = 0.34,
    this.bottom = 1.02,
    this.sides = 6,
  });

  final double top;
  final double upperY;
  final double upperRadius;
  final double lowerY;
  final double lowerRadius;
  final double bottom;
  final int sides;

  static const studioLight = Vec3(-0.42, -0.72, -0.55);

  List<Vec3> get _vertices {
    final upper = <Vec3>[];
    final lower = <Vec3>[];
    for (var i = 0; i < sides; i++) {
      final a = i / sides * math.pi * 2 + math.pi / sides;
      upper.add(Vec3(math.cos(a) * upperRadius, upperY, math.sin(a) * upperRadius));
      lower.add(Vec3(math.cos(a) * lowerRadius, lowerY, math.sin(a) * lowerRadius));
    }
    return [Vec3(0, top, 0), ...upper, ...lower, Vec3(0, bottom, 0)];
  }

  List<List<int>> get _indices {
    final apexTop = 0;
    final upper = [for (var i = 0; i < sides; i++) 1 + i];
    final lower = [for (var i = 0; i < sides; i++) 1 + sides + i];
    final apexBottom = 1 + sides * 2;
    final faces = <List<int>>[];
    for (var i = 0; i < sides; i++) {
      final next = (i + 1) % sides;
      faces.add([apexTop, upper[i], upper[next]]);
      faces.add([upper[i], upper[next], lower[next], lower[i]]);
      faces.add([lower[i], lower[next], apexBottom]);
    }
    return faces;
  }

  /// Faces ready to paint, sorted far to near. [scale] is in painter units per
  /// model unit; the model is about two units tall.
  List<GemFace> faces({
    required double yaw,
    required double pitch,
    required double cx,
    required double cy,
    required double scale,
    double perspective = 3.4,
    Vec3 light = studioLight,
  }) {
    final base = _vertices;
    final cosY = math.cos(yaw), sinY = math.sin(yaw);
    final cosX = math.cos(pitch), sinX = math.sin(pitch);
    final turned = [
      for (final v in base)
        () {
          final x = v.x * cosY + v.z * sinY;
          final z = -v.x * sinY + v.z * cosY;
          return Vec3(x, v.y * cosX - z * sinX, v.y * sinX + z * cosX);
        }(),
    ];
    final projected = [
      for (final v in turned)
        () {
          final p = perspective / (perspective + v.z);
          return Offset(cx + v.x * scale * p, cy + v.y * scale * p);
        }(),
    ];
    final key = light.unit;
    final out = <GemFace>[];
    for (final indexes in _indices) {
      final a = turned[indexes[0]];
      final b = turned[indexes[1]];
      final c = turned[indexes[2]];
      var normal = (b - a).cross(c - a).unit;
      final centroid = indexes
          .map((i) => turned[i])
          .reduce((value, element) => value + element) *
          (1 / indexes.length);
      if (normal.dot(centroid) < 0) normal = normal * -1;
      final points = [for (final i in indexes) projected[i]];
      final path = Path()..addPolygon(points, true);
      final center = points.reduce((value, element) => value + element) * (1 / points.length);
      out.add(GemFace(
        path: path,
        center: center,
        depth: centroid.z,
        lit: normal.dot(key).clamp(0.0, 1.0),
        front: normal.z < 0,
      ));
    }
    out.sort((a, b) => b.depth.compareTo(a.depth));
    return out;
  }

  /// The outer silhouette, for a clean rim at any size.
  List<Offset> silhouette({
    required double yaw,
    required double pitch,
    required double cx,
    required double cy,
    required double scale,
    double perspective = 3.4,
  }) {
    final base = _vertices;
    final cosY = math.cos(yaw), sinY = math.sin(yaw);
    final cosX = math.cos(pitch), sinX = math.sin(pitch);
    final points = <Offset>[];
    for (final v in base) {
      final x = v.x * cosY + v.z * sinY;
      final z = -v.x * sinY + v.z * cosY;
      final y = v.y * cosX - z * sinX;
      final zz = v.y * sinX + z * cosX;
      final p = perspective / (perspective + zz);
      points.add(Offset(cx + x * scale * p, cy + y * scale * p));
    }
    return convexHull(points);
  }
}

/// Andrew's monotone chain; enough for a dozen projected points.
List<Offset> convexHull(List<Offset> input) {
  if (input.length < 3) return List.of(input);
  final points = List<Offset>.of(input)..sort((a, b) => a.dx == b.dx ? a.dy.compareTo(b.dy) : a.dx.compareTo(b.dx));

  double cross(Offset o, Offset a, Offset b) =>
      (a.dx - o.dx) * (b.dy - o.dy) - (a.dy - o.dy) * (b.dx - o.dx);

  final lower = <Offset>[];
  for (final p in points) {
    while (lower.length >= 2 && cross(lower[lower.length - 2], lower.last, p) <= 0) {
      lower.removeLast();
    }
    lower.add(p);
  }
  final upper = <Offset>[];
  for (final p in points.reversed) {
    while (upper.length >= 2 && cross(upper[upper.length - 2], upper.last, p) <= 0) {
      upper.removeLast();
    }
    upper.add(p);
  }
  lower.removeLast();
  upper.removeLast();
  return [...lower, ...upper];
}

Path pathFrom(List<Offset> points) => Path()..addPolygon(points, true);
