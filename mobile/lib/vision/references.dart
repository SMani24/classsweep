import 'dart:convert';
import 'dart:typed_data';

class SceneReference {
  SceneReference({
    required this.width,
    required this.height,
    required this.keypoints,
    required this.descriptors,
    this.id = 'local',
  }) {
    if (width <= 0 ||
        height <= 0 ||
        keypoints.length < 12 ||
        keypoints.length > 2000 ||
        descriptors.length != keypoints.length ||
        keypoints.any(
          (p) =>
              p.length != 2 ||
              p.any((v) => !v.isFinite) ||
              p[0] < 0 ||
              p[0] >= width ||
              p[1] < 0 ||
              p[1] >= height,
        ) ||
        descriptors.any(
          (d) => d.length != 32 || d.any((v) => v < 0 || v > 255),
        )) {
      throw const FormatException('Invalid ORB reference');
    }
  }
  final String id;
  final int width, height;
  final List<List<double>> keypoints;
  final List<List<int>> descriptors;
  Map<String, dynamic> toJson() => {
    'id': id,
    'width': width,
    'height': height,
    'keypoints': keypoints,
    'descriptors': descriptors,
  };
  factory SceneReference.fromJson(Map<String, dynamic> j) {
    if (j['version'] != null && j['version'] != 1) {
      throw const FormatException('Unsupported reference version');
    }
    return SceneReference(
      id: j['id'] as String? ?? 'local',
      width: j['width'] as int,
      height: j['height'] as int,
      keypoints: (j['keypoints'] as List)
          .map((p) => (p as List).map((n) => (n as num).toDouble()).toList())
          .toList(),
      descriptors: (j['descriptors'] as List)
          .map((d) => (d as List).cast<int>())
          .toList(),
    );
  }
  Uint8List toBytes() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));
  factory SceneReference.fromBytes(Uint8List bytes) {
    if (bytes.length > 2000000) {
      throw const FormatException('Reference too large');
    }
    return SceneReference.fromJson(
      jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>,
    );
  }
}

class FaceReference {
  FaceReference(List<double> values) : embedding = List.unmodifiable(values) {
    if (embedding.length != 128 ||
        embedding.any((x) => !x.isFinite) ||
        embedding.every((x) => x == 0)) {
      throw const FormatException(
        'Expected nonzero 128-dimensional SFace embedding',
      );
    }
  }
  final List<double> embedding;
  Map<String, dynamic> toJson() => {
    'version': 1,
    'model': 'sface-2021dec-int8',
    'embedding': embedding,
  };
  factory FaceReference.fromJson(Map<String, dynamic> j) {
    if (j['model'] != 'sface-2021dec-int8' || j['version'] != 1) {
      throw const FormatException('Unsupported face reference');
    }
    return FaceReference(
      (j['embedding'] as List).map((v) => (v as num).toDouble()).toList(),
    );
  }
}

class SceneMatch {
  const SceneMatch({
    required this.hasReference,
    this.matches = 0,
    this.inliers = 0,
  });
  final bool hasReference;
  final int matches, inliers;
  double get inlierRatio => matches == 0 ? 0 : inliers / matches;
  bool get passed =>
      hasReference && matches >= 16 && inliers >= 12 && inlierRatio >= .45;
}
