/// On-device ClassSweep facade. Calls are serialized; await each frame.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart'
    as ml;
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart'
    as text;
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:path_provider/path_provider.dart';
import 'package:sensors_plus/sensors_plus.dart';

import 'camera_conversion.dart';
import 'evidence.dart';
import 'references.dart';
export 'camera_conversion.dart' show frameRotation;
export 'evidence.dart';
export 'references.dart';

class RearFrameResult {
  const RearFrameResult({
    required this.codes,
    required this.stableCodes,
    required this.motion,
    required this.sweep,
    required this.sceneMatch,
    required this.ocrTimestamp,
    required this.sceneTimestamp,
    required this.ocrFresh,
    required this.sceneFresh,
  });
  final List<String> codes, stableCodes;
  final MotionSample motion;
  final SweepProgress sweep;
  final SceneMatch sceneMatch;
  final DateTime ocrTimestamp, sceneTimestamp;
  final bool ocrFresh, sceneFresh;
}

class SelfieFrameResult {
  const SelfieFrameResult({
    required this.faceCount,
    required this.similarity,
    required this.headYaw,
    required this.identityMatches,
    required this.liveness,
    this.trackedFace,
  });
  final int faceCount;
  final double? similarity, headYaw;
  final bool identityMatches;
  final LivenessProgress? liveness;
  final int? trackedFace;
}

class EnrollmentFrame {
  const EnrollmentFrame(
    this.message, {
    this.inPosition = false,
    this.sample,
    this.photo,
  });
  final String message;
  final bool inPosition;
  final FaceReference? sample;
  final Uint8List? photo;
}

class ClassSweepVision {
  ClassSweepVision({this.faceCosineThreshold = .45, int codeLength = 4})
    : _voter = CodeVoter(codeLength: codeLength),
      _codeLength = codeLength;
  final double faceCosineThreshold;
  final CodeVoter _voter;
  final int _codeLength;
  cv.FaceDetectorYN? _detector;
  cv.FaceRecognizerSF? _recognizer;
  cv.ORB? _orb;
  final _text = text.TextRecognizer(script: text.TextRecognitionScript.latin);
  final _faces = ml.FaceDetector(
    options: ml.FaceDetectorOptions(
      performanceMode: ml.FaceDetectorMode.accurate,
      enableTracking: true,
    ),
  );
  Directory? _temp;
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  final List<GyroscopeEvent> _gyro = [];
  final Stopwatch _sensorClock = Stopwatch();
  DateTime? _sensorEpoch, _lastGyroSource, _lastGyroReceipt;
  cv.Mat? _previousGray;
  DateTime? _previousAt;
  DeviceOrientation? _previousOrientation;
  SceneReference? _scene;
  FaceReference? _face;
  SweepChallenge? _sweep;
  HeadChallenge? _head;
  bool _busy = false, _ready = false, _disposed = false;
  String? sensorError;
  DateTime? _lastOcrAt, _lastSceneAt;
  List<String> _lastCodes = [];
  SceneMatch _lastSceneMatch = const SceneMatch(hasReference: false);

  Future<void> start() async {
    if (_disposed) {
      throw StateError('Create a new vision instance after disposal');
    }
    if (_ready) return;
    _temp = await (await getTemporaryDirectory()).createTemp('classsweep_');
    try {
      Future<String> model(String name) async {
        final data = await rootBundle.load('assets/models/$name');
        final file = File('${_temp!.path}/$name');
        await file.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
        return file.path;
      }

      _detector = cv.FaceDetectorYN.fromFile(
        await model('face_detection_yunet_2023mar.onnx'),
        '',
        (320, 320),
      );
      _recognizer = cv.FaceRecognizerSF.fromFile(
        await model('face_recognition_sface_2021dec_int8.onnx'),
        '',
      );
      _orb = cv.ORB.create(nFeatures: 800);
      _sensorEpoch = DateTime.now();
      _sensorClock.start();
      _gyroSub =
          gyroscopeEventStream(samplingPeriod: const Duration(milliseconds: 20))
              .listen(
                (e) {
                  // sensors_plus timestamps are platform sensor time, not Unix camera time.
                  // Anchor source deltas to monotonic receipt time once, retaining source timing.
                  _gyro.add(e);
                  _lastGyroSource = e.timestamp;
                  _lastGyroReceipt = _sensorEpoch!.add(_sensorClock.elapsed);
                  if (_gyro.length > 300) _gyro.removeAt(0);
                },
                onError: (Object e) {
                  sensorError = e.toString();
                  _gyro.clear();
                },
              );
      _ready = true;
    } catch (_) {
      await dispose();
      rethrow;
    }
  }

  void _check() {
    if (!_ready) throw StateError('Call and await start() first');
    if (_busy) throw StateError('Await previous vision operation');
  }

  void setSceneReference(SceneReference reference) {
    _check();
    _scene = reference;
    _lastSceneAt = null;
    _lastSceneMatch = const SceneMatch(hasReference: false);
  }

  void setSceneReferenceBytes(Uint8List bytes) =>
      setSceneReference(SceneReference.fromBytes(bytes));
  Uint8List exportSceneReferenceBytes() {
    if (_scene == null) throw StateError('No scene enrolled');
    return _scene!.toBytes();
  }

  void setFaceReference(FaceReference reference) {
    _check();
    _face = reference;
    _head = null;
  }

  SweepProgress beginSweep({String? direction}) {
    resetRearSession();
    _sweep = SweepChallenge(direction: direction);
    return _sweep!.progress;
  }

  LivenessProgress beginLiveness({String? direction}) {
    _head = HeadChallenge(direction: direction);
    return _head!.progress;
  }

  void resetRearSession() {
    resetRearFrameHistory();
    _sweep = null;
  }

  /// Discard measurements that cross a camera zoom change. Keep the sweep phase.
  void resetRearFrameHistory() {
    _check();
    _previousGray?.dispose();
    _previousGray = null;
    _previousAt = null;
    _previousOrientation = null;
    _voter.reset();
    _lastOcrAt = null;
    _lastSceneAt = null;
    _lastCodes = [];
    _lastSceneMatch = const SceneMatch(hasReference: false);
  }

  cv.Mat _small(cv.Mat bgr) {
    if (bgr.cols <= 960 && bgr.rows <= 960) return bgr.clone();
    final scale = 960 / max(bgr.cols, bgr.rows);
    return cv.resize(bgr, (
      (bgr.cols * scale).round(),
      (bgr.rows * scale).round(),
    ));
  }

  Future<SceneReference> enrollScene(Uint8List jpeg) async {
    _check();
    _busy = true;
    cv.Mat? decoded;
    try {
      decoded = cv.imdecode(jpeg, cv.IMREAD_COLOR);
      if (decoded.isEmpty) {
        throw const FormatException('Invalid reference image');
      }
      final image = _small(decoded);
      final mask = cv.Mat.empty();
      try {
        final (kp, desc) = _orb!.detectAndCompute(image, mask);
        try {
          final ref = SceneReference(
            width: image.cols,
            height: image.rows,
            keypoints: List.generate(kp.length, (i) {
              final p = kp[i];
              try {
                return [p.x, p.y];
              } finally {
                p.dispose();
              }
            }),
            descriptors: List.generate(
              desc.rows,
              (y) => List.generate(desc.cols, (x) => desc.at<int>(y, x)),
            ),
          );
          _scene = ref;
          return ref;
        } finally {
          kp.dispose();
          desc.dispose();
        }
      } finally {
        mask.dispose();
        image.dispose();
      }
    } finally {
      decoded?.dispose();
      _busy = false;
    }
  }

  SceneMatch _matchScene(cv.Mat image) {
    final ref = _scene;
    if (ref == null) return const SceneMatch(hasReference: false);
    final mask = cv.Mat.empty();
    final (kp, desc) = _orb!.detectAndCompute(image, mask);
    mask.dispose();
    try {
      if (desc.rows < 2) return const SceneMatch(hasReference: true);
      final train = cv.Mat.fromList(
        ref.descriptors.length,
        32,
        cv.MatType.CV_8UC1,
        ref.descriptors.expand((d) => d).toList(),
      );
      final matcher = cv.BFMatcher.create(type: cv.NORM_HAMMING);
      try {
        final pairs = matcher.knnMatch(desc, train, 2);
        final src = <double>[], dst = <double>[];
        final used = <int>{};
        try {
          for (var i = 0; i < pairs.length; i++) {
            final pair = pairs[i];
            try {
              if (pair.length < 2) continue;
              final a = pair[0], b = pair[1];
              try {
                if (a.distance < .75 * b.distance &&
                    a.distance <= 64 &&
                    used.add(a.trainIdx)) {
                  final p = kp[a.queryIdx];
                  try {
                    src.addAll([p.x, p.y]);
                  } finally {
                    p.dispose();
                  }
                  dst.addAll(ref.keypoints[a.trainIdx]);
                }
              } finally {
                a.dispose();
                b.dispose();
              }
            } finally {
              pair.dispose();
            }
          }
        } finally {
          pairs.dispose();
        }
        final count = src.length ~/ 2;
        if (count < 4) return SceneMatch(hasReference: true, matches: count);
        final a = cv.Mat.fromList(count, 1, cv.MatType.CV_32FC2, src);
        final b = cv.Mat.fromList(count, 1, cv.MatType.CV_32FC2, dst);
        final inlierMask = cv.Mat.empty();
        try {
          final h = cv.findHomography(
            a,
            b,
            method: cv.RANSAC,
            ransacReprojThreshold: 4,
            mask: inlierMask,
          );
          try {
            return SceneMatch(
              hasReference: true,
              matches: count,
              inliers: h.isEmpty
                  ? 0
                  : inlierMask.data.where((n) => n != 0).length,
            );
          } finally {
            h.dispose();
          }
        } finally {
          a.dispose();
          b.dispose();
          inlierMask.dispose();
        }
      } finally {
        matcher.dispose();
        train.dispose();
      }
    } finally {
      kp.dispose();
      desc.dispose();
    }
  }

  FaceReference? _embedding(cv.Mat image, {bool liveFaceConfirmed = false}) {
    // Live frames already have a single face confirmed by ML Kit. Accept
    // weaker YuNet landmark confidence there, especially on side poses.
    _detector!.setScoreThreshold(liveFaceConfirmed ? .78 : .90);
    _detector!.setInputSize((image.cols, image.rows));
    final boxes = _detector!.detect(image);
    try {
      if (boxes.rows != 1) return null;
      final box = boxes.row(0);
      final crop = _recognizer!.alignCrop(image, box);
      box.dispose();
      try {
        final feature = _recognizer!.feature(crop, clone: true);
        try {
          return FaceReference(
            List.generate(feature.cols, (x) => feature.at<double>(0, x)),
          );
        } finally {
          feature.dispose();
        }
      } finally {
        crop.dispose();
      }
    } finally {
      boxes.dispose();
    }
  }

  Future<FaceReference> enrollFace(Uint8List jpeg) async {
    _check();
    _busy = true;
    cv.Mat? decoded;
    try {
      decoded = cv.imdecode(jpeg, cv.IMREAD_COLOR);
      if (decoded.isEmpty) throw const FormatException('Invalid face image');
      final image = _small(decoded);
      try {
        final ref = _embedding(image);
        if (ref == null) throw StateError('Exactly one YuNet face required');
        _face = ref;
        _head = null;
        return ref;
      } finally {
        image.dispose();
      }
    } finally {
      decoded?.dispose();
      _busy = false;
    }
  }

  double compareFaces(FaceReference first, FaceReference second) {
    final a = cv.Mat.fromList(1, 128, cv.MatType.CV_32FC1, first.embedding);
    final b = cv.Mat.fromList(1, 128, cv.MatType.CV_32FC1, second.embedding);
    try {
      final value = _recognizer!.match(a, b);
      return value.isFinite ? value : -1;
    } finally {
      a.dispose();
      b.dispose();
    }
  }

  double? _similarity(FaceReference? candidate, double? yaw) {
    final reference = _face;
    if (candidate == null || reference == null) return null;
    final frontal = compareFaces(candidate, reference);
    if (yaw == null || yaw.abs() <= 12 || reference.profiles.length != 2) {
      return frontal;
    }
    // The front-facing phases still require the exact approved frontal reference.
    return max(
      frontal,
      compareFaces(candidate, reference.profiles[yaw > 0 ? 0 : 1]),
    );
  }

  double? _gyroYaw(
    DateTime start,
    DateTime end,
    DeviceOrientation orientation,
  ) {
    if (_gyro.length < 2 || _lastGyroSource == null) return null;
    // Timestamp origin differs by platform. Map newest source timestamp to the
    // current monotonic receipt clock, then integrate source deltas in frame interval.
    if (_lastGyroReceipt == null ||
        end.difference(_lastGyroReceipt!).abs() >
            const Duration(milliseconds: 150)) {
      return null;
    }
    final sourceEnd = _lastGyroSource!.subtract(
      _lastGyroReceipt!.difference(end),
    );
    final sourceStart = sourceEnd.subtract(end.difference(start));
    final events = _gyro
        .where(
          (g) =>
              !g.timestamp.isBefore(
                sourceStart.subtract(const Duration(milliseconds: 40)),
              ) &&
              !g.timestamp.isAfter(
                sourceEnd.add(const Duration(milliseconds: 20)),
              ),
        )
        .toList();
    if (events.length < 2 ||
        events.last.timestamp.difference(sourceEnd).abs() >
            const Duration(milliseconds: 100)) {
      return null;
    }
    double axis(GyroscopeEvent g) => switch (orientation) {
      DeviceOrientation.portraitUp => g.y,
      DeviceOrientation.portraitDown => -g.y,
      DeviceOrientation.landscapeLeft => -g.x,
      DeviceOrientation.landscapeRight => g.x,
    };
    return events.map(axis).reduce((a, b) => a + b) / events.length;
  }

  MotionSample _motion(
    cv.Mat image,
    DateTime at,
    DeviceOrientation orientation,
  ) {
    final gray = cv.cvtColor(image, cv.COLOR_BGR2GRAY);
    final prev = _previousGray, oldAt = _previousAt;
    _previousGray = gray;
    _previousAt = at;
    final sameOrientation = _previousOrientation == orientation;
    _previousOrientation = orientation;
    double fx = 0, fy = 0;
    int tracks = 0;
    final dt = oldAt == null ? 0 : at.difference(oldAt).inMicroseconds / 1e6;
    try {
      if (prev != null &&
          dt > 0 &&
          dt <= .6 &&
          sameOrientation &&
          prev.rows == gray.rows &&
          prev.cols == gray.cols) {
        final points = cv.goodFeaturesToTrack(prev, 180, .01, 8);
        final next = cv.VecPoint2f();
        try {
          if (points.length >= 12) {
            final (_, status, err) = cv.calcOpticalFlowPyrLK(
              prev,
              gray,
              points,
              next,
            );
            try {
              final dx = <double>[], dy = <double>[];
              for (var i = 0; i < points.length; i++) {
                final a = points[i], b = next[i];
                try {
                  if (status![i] != 0 &&
                      err![i] < 25 &&
                      b.x >= 0 &&
                      b.x < gray.cols &&
                      b.y >= 0 &&
                      b.y < gray.rows) {
                    dx.add(b.x - a.x);
                    dy.add(b.y - a.y);
                  }
                } finally {
                  a.dispose();
                  b.dispose();
                }
              }
              if (dx.isNotEmpty) {
                final mx = median(dx), my = median(dy);
                final mad = median(
                  List.generate(
                    dx.length,
                    (i) => (dx[i] - mx).abs() + (dy[i] - my).abs(),
                  ),
                );
                final ix = <double>[], iy = <double>[];
                for (var i = 0; i < dx.length; i++) {
                  if ((dx[i] - mx).abs() + (dy[i] - my).abs() <=
                      max(2, 3 * mad)) {
                    ix.add(dx[i]);
                    iy.add(dy[i]);
                  }
                }
                tracks = ix.length;
                if (tracks >= 12) {
                  fx = median(ix) / gray.cols / dt;
                  fy = median(iy) / gray.rows / dt;
                }
              }
            } finally {
              status?.dispose();
              err?.dispose();
            }
          }
        } finally {
          points.dispose();
          next.dispose();
        }
      }
      return MotionSample(
        timestamp: at,
        flowX: fx,
        flowY: fy,
        tracks: tracks,
        gyroYaw: oldAt == null ? null : _gyroYaw(oldAt, at, orientation),
        valid: tracks >= 12 && fx.isFinite && fy.isFinite,
      );
    } finally {
      prev?.dispose();
    }
  }

  ml.InputImage _mlImage(CameraImage image, int rotation) {
    final rawRotation = ml.InputImageRotationValue.fromRawValue(rotation);
    if (rawRotation == null) throw ArgumentError('Unsupported camera rotation');
    final bool bgra = image.format.group == ImageFormatGroup.bgra8888;
    final Uint8List bytes;
    if (bgra) {
      final plane = image.planes.single;
      bytes = Uint8List(image.width * image.height * 4);
      for (var y = 0; y < image.height; y++) {
        bytes.setRange(
          y * image.width * 4,
          (y + 1) * image.width * 4,
          plane.bytes,
          y * plane.bytesPerRow,
        );
      }
    } else {
      bytes = packNv21(image);
    }
    return ml.InputImage.fromBytes(
      bytes: bytes,
      metadata: ml.InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rawRotation,
        format: bgra ? ml.InputImageFormat.bgra8888 : ml.InputImageFormat.nv21,
        bytesPerRow: image.width * (bgra ? 4 : 1),
      ),
    );
  }

  Future<RearFrameResult> processRearFrame(
    CameraImage image, {
    required int sensorOrientation,
    required DeviceOrientation deviceOrientation,
    DateTime? timestamp,
    bool allowSweepPause = true,
  }) async {
    _check();
    _busy = true;
    cv.Mat? bgr, small;
    try {
      final at = timestamp ?? _sensorEpoch!.add(_sensorClock.elapsed);
      bgr = cameraBgr(
        image,
        frameRotation(sensorOrientation, deviceOrientation),
      );
      small = _small(bgr);
      final motion = _motion(small, at, deviceOrientation);
      _sweep ??= SweepChallenge();
      final sweep = _sweep!.add(motion, allowPause: allowSweepPause);
      final sceneFresh =
          _lastSceneAt == null ||
          at.difference(_lastSceneAt!).inMilliseconds >= 300;
      if (sceneFresh) {
        _lastSceneMatch = _matchScene(small);
        _lastSceneAt = at;
      }
      final ocrFresh =
          _lastOcrAt == null ||
          at.difference(_lastOcrAt!).inMilliseconds >= 300;
      if (ocrFresh) {
        final recognized = await _text.processImage(
          _mlImage(image, frameRotation(sensorOrientation, deviceOrientation)),
        );
        _voter.add(recognized.text, at);
        _lastCodes = RegExp('(?<![0-9])[0-9]{$_codeLength}(?![0-9])')
            .allMatches(recognized.text)
            .map((m) => m.group(0)!)
            .toSet()
            .toList();
        _lastOcrAt = at;
      }
      final stable = _voter.stable(at);
      return RearFrameResult(
        codes: List.unmodifiable(_lastCodes),
        stableCodes: stable,
        motion: motion,
        sweep: sweep,
        sceneMatch: _lastSceneMatch,
        ocrTimestamp: _lastOcrAt!,
        sceneTimestamp: _lastSceneAt!,
        ocrFresh: ocrFresh,
        sceneFresh: sceneFresh,
      );
    } finally {
      small?.dispose();
      bgr?.dispose();
      _busy = false;
    }
  }

  Future<SelfieFrameResult> processSelfieFrame(
    CameraImage image, {
    required int sensorOrientation,
    required DeviceOrientation deviceOrientation,
    DateTime? timestamp,
  }) async {
    _check();
    _busy = true;
    cv.Mat? bgr, small;
    try {
      final at = timestamp ?? _sensorEpoch!.add(_sensorClock.elapsed);
      bgr = cameraBgr(
        image,
        frameRotation(sensorOrientation, deviceOrientation, front: true),
      );
      small = _small(bgr);
      final faces = await _faces.processImage(
        _mlImage(
          image,
          frameRotation(sensorOrientation, deviceOrientation, front: true),
        ),
      );
      final yaw = faces.length == 1 ? faces.single.headEulerAngleY : null;
      final similarity = faces.length == 1
          ? _similarity(_embedding(small, liveFaceConfirmed: true), yaw)
          : null;
      final matches = similarity != null && similarity >= faceCosineThreshold;
      final progress = _head?.add(
        at: at,
        yaw: yaw,
        identityMatches: matches,
        faceCount: faces.length,
        trackingId: faces.length == 1 ? faces.single.trackingId : null,
        identityObserved: similarity != null,
      );
      return SelfieFrameResult(
        faceCount: faces.length,
        similarity: similarity,
        headYaw: yaw,
        identityMatches: matches,
        liveness: progress,
        trackedFace: faces.length == 1 ? faces.single.trackingId : null,
      );
    } finally {
      small?.dispose();
      bgr?.dispose();
      _busy = false;
    }
  }

  Future<EnrollmentFrame> enrollmentFrame(
    CameraImage image, {
    required int sensorOrientation,
    required DeviceOrientation deviceOrientation,
    required int pose,
    required bool capture,
    FaceReference? frontal,
  }) async {
    _check();
    _busy = true;
    cv.Mat? bgr;
    try {
      final rotation = frameRotation(
        sensorOrientation,
        deviceOrientation,
        front: true,
      );
      final faces = await _faces.processImage(_mlImage(image, rotation));
      if (faces.length != 1) {
        return EnrollmentFrame(
          faces.isEmpty
              ? 'Position your face in the oval'
              : 'Keep only one face in view',
        );
      }
      final face = faces.single;
      final portrait = rotation == 90 || rotation == 270;
      final width = portrait ? image.height : image.width;
      final height = portrait ? image.width : image.height;
      final box = face.boundingBox;
      if ((box.center.dx / width - .5).abs() > .19 ||
          (box.center.dy / height - .5).abs() > .20) {
        return const EnrollmentFrame('Center your face');
      }
      if (box.width / width < .29 || box.height / height < .26) {
        return const EnrollmentFrame('Move a little closer');
      }
      if (box.width / width > .78 || box.height / height > .75) {
        return const EnrollmentFrame('Move a little farther back');
      }
      final yaw = face.headEulerAngleY;
      final tilted =
          (face.headEulerAngleZ ?? 0).abs() > 14 ||
          (face.headEulerAngleX ?? 0).abs() > 18;
      if (yaw == null || tilted) {
        return const EnrollmentFrame('Hold your head upright');
      }
      final directed = pose == 1 ? yaw : -yaw;
      final good = pose == 0
          ? yaw.abs() <= 11
          : directed >= 15 && directed <= 31;
      if (!good) {
        return EnrollmentFrame(
          pose == 0
              ? 'Look straight ahead'
              : directed > 31
              ? 'Turn a little less'
              : pose == 1
              ? 'Turn slightly to your left'
              : 'Turn slightly to your right',
        );
      }
      if (!capture) {
        return const EnrollmentFrame('Hold still', inPosition: true);
      }
      bgr = cameraBgr(image, rotation);
      final sample = _embedding(bgr, liveFaceConfirmed: pose != 0);
      if (sample == null) {
        return const EnrollmentFrame('Improve the light and hold still');
      }
      if (frontal != null &&
          compareFaces(frontal, sample) < faceCosineThreshold) {
        return const EnrollmentFrame('Turn a little less and try again');
      }
      final (encoded, jpeg) = cv.imencode('.jpg', bgr);
      if (!encoded) throw StateError('Could not save this frame');
      return EnrollmentFrame(
        'Captured',
        inPosition: true,
        sample: sample,
        photo: jpeg,
      );
    } finally {
      bgr?.dispose();
      _busy = false;
    }
  }

  Future<void> dispose() async {
    if (_busy) throw StateError('Await active processing before dispose');
    if (_disposed) return;
    _disposed = true;
    _ready = false;
    await _gyroSub?.cancel();
    _gyroSub = null;
    _sensorClock.stop();
    _gyro.clear();
    _previousGray?.dispose();
    _previousGray = null;
    _detector?.dispose();
    _detector = null;
    _recognizer?.dispose();
    _recognizer = null;
    _orb?.dispose();
    _orb = null;
    await _text.close();
    await _faces.close();
    if (_temp != null && await _temp!.exists()) {
      await _temp!.delete(recursive: true);
    }
    _temp = null;
  }
}
