import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;

int frameRotation(int sensor, DeviceOrientation device, {bool front = false}) {
  final degrees = switch (device) {
    DeviceOrientation.portraitUp => 0,
    DeviceOrientation.landscapeLeft => 90,
    DeviceOrientation.portraitDown => 180,
    DeviceOrientation.landscapeRight => 270,
  };
  return (sensor + (front ? degrees : -degrees) + 360) % 360;
}

/// Copies strided camera buffers. Returned BGR Mat belongs to caller.
cv.Mat cameraBgr(CameraImage image, int rotation) {
  if (![0, 90, 180, 270].contains(rotation)) {
    throw ArgumentError('Rotation must be a multiple of 90');
  }
  final w = image.width, h = image.height;
  cv.Mat bgr;
  if (image.format.group == ImageFormatGroup.bgra8888) {
    final p = image.planes.single;
    final packed = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      packed.setRange(y * w * 4, (y + 1) * w * 4, p.bytes, y * p.bytesPerRow);
    }
    final raw = cv.Mat.fromList(h, w, cv.MatType.CV_8UC4, packed);
    try {
      bgr = cv.cvtColor(raw, cv.COLOR_BGRA2BGR);
    } finally {
      raw.dispose();
    }
  } else {
    final nv21 = packNv21(image);
    final raw = cv.Mat.fromList(h + h ~/ 2, w, cv.MatType.CV_8UC1, nv21);
    try {
      bgr = cv.cvtColor(raw, cv.COLOR_YUV2BGR_NV21);
    } finally {
      raw.dispose();
    }
  }
  if (rotation == 0) return bgr;
  try {
    return cv.rotate(bgr, switch (rotation) {
      90 => cv.ROTATE_90_CLOCKWISE,
      180 => cv.ROTATE_180,
      _ => cv.ROTATE_90_COUNTERCLOCKWISE,
    });
  } finally {
    bgr.dispose();
  }
}

Uint8List packNv21(CameraImage image) {
  final w = image.width, h = image.height;
  if (w.isOdd || h.isOdd) {
    throw const FormatException('Even YUV dimensions required');
  }
  final out = Uint8List(w * h * 3 ~/ 2);
  if (image.planes.length == 1 && image.format.group == ImageFormatGroup.nv21) {
    final p = image.planes.single;
    for (var y = 0; y < h; y++) {
      out.setRange(y * w, (y + 1) * w, p.bytes, y * p.bytesPerRow);
    }
    for (var y = 0; y < h ~/ 2; y++) {
      out.setRange(
        w * h + y * w,
        w * h + (y + 1) * w,
        p.bytes,
        h * p.bytesPerRow + y * p.bytesPerRow,
      );
    }
    return out;
  }
  if (image.format.group != ImageFormatGroup.yuv420 ||
      image.planes.length != 3) {
    throw UnsupportedError('Expected YUV420/NV21/BGRA camera frame');
  }
  final yp = image.planes[0], u = image.planes[1], v = image.planes[2];
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      out[y * w + x] =
          yp.bytes[y * yp.bytesPerRow + x * (yp.bytesPerPixel ?? 1)];
    }
  }
  for (var y = 0; y < h ~/ 2; y++) {
    for (var x = 0; x < w ~/ 2; x++) {
      final i = w * h + y * w + x * 2;
      out[i] = v.bytes[y * v.bytesPerRow + x * (v.bytesPerPixel ?? 1)];
      out[i + 1] = u.bytes[y * u.bytesPerRow + x * (u.bytesPerPixel ?? 1)];
    }
  }
  return out;
}
