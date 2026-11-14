import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:classsweep/vision/references.dart';

/// Intentionally native: run after dartcv4's capped native build completes.
/// No camera, sensors, network, face fixtures, or plugin mocks are involved.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late String yunet, sface;
  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('classsweep_native_test_');
    Future<String> unpack(String name) async {
      final bytes = await rootBundle.load('assets/models/$name');
      final file = File('${temp.path}/$name');
      await file.writeAsBytes(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
      return file.path;
    }

    yunet = await unpack('face_detection_yunet_2023mar.onnx');
    sface = await unpack('face_recognition_sface_2021dec_int8.onnx');
  });
  tearDownAll(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('native YuNet loads bundled ONNX and rejects blank frame', () {
    final detector = cv.FaceDetectorYN.fromFile(yunet, '', (320, 320));
    final image = cv.Mat.zeros(320, 320, cv.MatType.CV_8UC3);
    try {
      final faces = detector.detect(image);
      try {
        expect(faces.rows, 0);
      } finally {
        faces.dispose();
      }
    } finally {
      image.dispose();
      detector.dispose();
    }
  });

  test('native int8 SFace inference produces finite 128-dimensional feature', () {
    final recognizer = cv.FaceRecognizerSF.fromFile(sface, '');
    // This tests model execution only; a blank aligned patch is NOT enrollment.
    final patch = cv.Mat.zeros(112, 112, cv.MatType.CV_8UC3);
    try {
      final feature = recognizer.feature(patch, clone: true);
      try {
        expect(feature.rows, 1);
        expect(feature.cols, 128);
        final values = List.generate(128, (i) => feature.at<double>(0, i));
        expect(values.every((x) => x.isFinite), isTrue);
        expect(values.any((x) => x != 0), isTrue);
        final ref = FaceReference(values);
        expect(FaceReference.fromJson(ref.toJson()).embedding, values);
        expect(recognizer.match(feature, feature), closeTo(1, .001));
      } finally {
        feature.dispose();
      }
    } finally {
      patch.dispose();
      recognizer.dispose();
    }
  });

  test(
    'native ORB descriptors survive reference bytes and match geometrically',
    () {
      final rng = Random(241);
      final pixels = List<int>.generate(320 * 240, (_) => rng.nextInt(256));
      final image = cv.Mat.fromList(240, 320, cv.MatType.CV_8UC1, pixels);
      final orb = cv.ORB.create(nFeatures: 800);
      final mask = cv.Mat.empty();
      try {
        final (points, descriptors) = orb.detectAndCompute(image, mask);
        try {
          expect(points.length, greaterThanOrEqualTo(16));
          expect(descriptors.cols, 32);
          final keypoints = List.generate(points.length, (i) {
            final p = points[i];
            try {
              return [p.x, p.y];
            } finally {
              p.dispose();
            }
          });
          final ref = SceneReference(
            width: 320,
            height: 240,
            keypoints: keypoints,
            descriptors: List.generate(
              descriptors.rows,
              (r) => List.generate(32, (c) => descriptors.at<int>(r, c)),
            ),
          );
          final restored = SceneReference.fromBytes(ref.toBytes());
          expect(restored.toJson(), ref.toJson());
          final train = cv.Mat.fromList(
            restored.descriptors.length,
            32,
            cv.MatType.CV_8UC1,
            restored.descriptors.expand((d) => d).toList(),
          );
          final matcher = cv.BFMatcher.create(type: cv.NORM_HAMMING);
          try {
            final pairs = matcher.knnMatch(descriptors, train, 2);
            try {
              var zeroMatches = 0;
              for (var i = 0; i < pairs.length; i++) {
                final pair = pairs[i];
                try {
                  final best = pair[0];
                  try {
                    if (best.distance == 0) zeroMatches++;
                  } finally {
                    best.dispose();
                  }
                } finally {
                  pair.dispose();
                }
              }
              expect(zeroMatches, descriptors.rows);
            } finally {
              pairs.dispose();
            }
            final coords = keypoints.expand((p) => p).toList();
            final src = cv.Mat.fromList(
              keypoints.length,
              1,
              cv.MatType.CV_32FC2,
              coords,
            );
            final inlierMask = cv.Mat.empty();
            try {
              final h = cv.findHomography(
                src,
                src,
                method: cv.RANSAC,
                mask: inlierMask,
              );
              try {
                expect(h.isEmpty, isFalse);
                final inliers = inlierMask.data.where((n) => n != 0).length;
                expect(
                  SceneMatch(
                    hasReference: true,
                    matches: keypoints.length,
                    inliers: inliers,
                  ).passed,
                  isTrue,
                );
              } finally {
                h.dispose();
              }
            } finally {
              src.dispose();
              inlierMask.dispose();
            }
          } finally {
            train.dispose();
            matcher.dispose();
          }
        } finally {
          points.dispose();
          descriptors.dispose();
        }
      } finally {
        image.dispose();
        mask.dispose();
        orb.dispose();
      }
    },
  );
  test('native video module tracks a translated textured frame', () {
    final random = Random(17);
    const width = 240, height = 180;
    final pixels = List<int>.generate(
      width * height,
      (_) => random.nextInt(256),
    );
    final shifted = List<int>.generate(
      width * height,
      (i) => i % width >= 3 ? pixels[i - 3] : 0,
    );
    final before = cv.Mat.fromList(height, width, cv.MatType.CV_8UC1, pixels);
    final after = cv.Mat.fromList(height, width, cv.MatType.CV_8UC1, shifted);
    final points = cv.goodFeaturesToTrack(before, 100, .01, 8);
    final next = cv.VecPoint2f();
    try {
      expect(points.length, greaterThan(12));
      final (_, status, error) = cv.calcOpticalFlowPyrLK(
        before,
        after,
        points,
        next,
      );
      try {
        final displacements = <double>[];
        for (var i = 0; i < points.length; i++) {
          final a = points[i], b = next[i];
          try {
            if (status![i] != 0 && error![i] < 25) displacements.add(b.x - a.x);
          } finally {
            a.dispose();
            b.dispose();
          }
        }
        displacements.sort();
        expect(displacements.length, greaterThanOrEqualTo(12));
        expect(displacements[displacements.length ~/ 2], closeTo(3, .4));
      } finally {
        status?.dispose();
        error?.dispose();
      }
    } finally {
      points.dispose();
      next.dispose();
      before.dispose();
      after.dispose();
    }
  });
}
