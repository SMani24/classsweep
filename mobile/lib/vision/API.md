# ClassSweep on-device vision API

Import `package:classsweep/vision/vision.dart` (exports evidence/reference types).

```dart
final vision = ClassSweepVision(); // Western four-digit codes; cosine threshold .45
await vision.start();
// Approved JPEG bytes, fetched by parent. Enrollment auto installs the template.
final face = await vision.enrollFace(approvedBytes);
// Persist face.toJson() privately; restore using FaceReference.fromJson(json).
vision.setFaceReference(face);
// Downloaded classroom.views[n] object, encoded as UTF8 JSON:
vision.setSceneReferenceBytes(viewBytes);
vision.beginSweep(); // random left/right; or direction: 'left'/'right'
final rear = await vision.processRearFrame(cameraImage,
  sensorOrientation: camera.description.sensorOrientation,
  deviceOrientation: camera.value.deviceOrientation);
// rear.codes: List<String> current frame; rear.stableCodes: 3 votes in 3s.
// rear.sceneMatch: hasReference, passed, matches, inliers, inlierRatio.
// rear.ocrFresh/sceneFresh and ocrTimestamp/sceneTimestamp distinguish cached results.
// rear.motion: timestamp, flowX/flowY (fraction of image/sec), tracks,
//              gyroYaw (rad/sec, nullable), valid.
// rear.sweep: phase, direction, instruction, correlation, samples, passed.
vision.beginLiveness(direction: attempt.direction); // server decides subject left/right
final selfie = await vision.processSelfieFrame(cameraImage,
  sensorOrientation: camera.description.sensorOrientation,
  deviceOrientation: camera.value.deviceOrientation);
// selfie.faceCount (ML Kit), similarity (nullable SFace cosine), headYaw
// (nullable ML Kit degrees), identityMatches, liveness (nullable until begun).
// selfie.liveness: phase, direction, passed.
await vision.dispose();
```

Each instance is single-use: start once, dispose once. Await all work before disposal. Await one operation at a time; overlapping processing throws rather than silently inventing evidence. Parent owns camera stream/throttle, camera permission, network and UI. Both camera input streams must be raw, unmirrored pixels. Device orientation must describe the actual device, not a locked preview. Android sensor/device rotation uses standard camera compensation; iOS BGRA is supported but device-specific stream orientation must be physically verified. No camera/audio/network control in this module.

Use capture receipt timestamps consistently. Default uses a monotonic clock anchored to DateTime at start. Optional `timestamp` must use the same wall-time origin; do not pass Android sensor uptime. sensors_plus event timestamps retain their relative timing, mapped to the monotonic receipt clock. Gyro absent/stale (>150ms), insufficient tracks, frame gaps >600ms, or changing orientation invalidates motion evidence. A gap >600ms restarts the sweep. Pause app => end attempt and reset capture. An orientation change invalidates that frame; hold one orientation throughout sweep.

## Instructor processed reference distribution

`await vision.enrollScene(jpegBytes)` returns `SceneReference` and installs it. Photos decode locally and are not transmitted. `vision.exportSceneReferenceBytes()` gives UTF8 JSON for **one view**, with exact fields `{id,width,height,keypoints:[[x,y]],descriptors:[[32 integer bytes]]}`. `.toJson()` is equivalent. Parent wraps instructor upload as `{name,views:[reference.toJson()]}`. Student unwraps server views and installs a selected view via `setSceneReference` or `setSceneReferenceBytes`. One active view per instance; choose a view in UI before scanning. Coordinates/descriptors use ORB nFeatures=800, WTA_K=2 and image resized to longest side <=960. Server must distribute compatible ORB descriptors, not SIFT/other features. Blank/low-texture images fail enrollment. Missing reference yields `hasReference=false, passed=false`, never a simulated match. References are local data; authenticity/version pinning belongs to parent/network.

## Pass evidence and server mapping

Rear evidence is independent: require expected two stable codes, `sceneMatch.passed` and `sweep.passed` for initial scan. After front challenge, switch rear and call `resetRearSession()` to discard old OCR/flow before fresh room recheck; use current `codes` plus fresh scene match for the expected-code policy. Do not reuse an earlier rear result. Recheck need not complete a second sweep unless product policy requires it. OCR and scene matching run at most every 300ms; flow runs every processed frame. `ocrFresh` and `sceneFresh` mark new observations; timestamps remain unchanged for cached results. Cached OCR never adds votes. Only use fresh scene/OCR observations for recheck, and resetRearSession before camera switch. Results do not automatically submit attendance.

Selfie cosine similarity: higher is better; server `match_distance = 1 - similarity` (clamp tiny floating error to [0,2] if needed). Head challenge requires center <=8°, prescribed subject turn >=18°, return center <=8°, each held >=300ms, total <=15sec. Accepted frames require exactly one face and SFace identity match; identity loss resets all challenge steps. Timestamp gaps >700ms reset the entire head sequence. `liveness.passed` is terminal for this challenge; parent must record the completion result immediately and begin a new challenge for another attempt. Parent aggregates actual `max_yaw_degrees`, final `return_yaw_degrees` and elapsed `duration_ms`. It must not invent metrics. `beginLiveness(direction:...)` supports the server challenge explicitly. This is motion evidence, not a secure presentation-attack detector.

Sweep: random first pan, hold still >=500ms, opposite pan >=700ms (first pan >=700ms), >=12 tracked samples and signed Pearson flow/gyro correlation >=.65, max20sec. Flow uses goodFeaturesToTrack + pyramidal LK, status/error filtering, median displacement and median-absolute-deviation rejection. Gyro maps to screen-up axis. Positive image x flow and positive screen-up gyro correspond to camera left pan; verify sign on target physical device. Rotation about the optical axis and pure translation are not accepted as yaw. Dwell requires consecutive valid frames; incomplete evidence cannot pass. Correlation values are measured, not default pass values.

ORB pass requires >=16 unique ratio-filtered Hamming matches (ratio .75, distance <=64), RANSAC homography >=12 inliers and inlier ratio >=.45. Coordinates checked against reference bounds. Natural classroom texture can still be reproduced in photos/screens: this is experimental scene consistency, not proof of physical presence. SFace cosine .45, all motion, geometric and head thresholds are experimental; calibrate false accept/reject rates on actual phones and classroom captures before production.

## Platform / resource notes

Required packages: opencv_dart/dartcv4 2.2.2, camera 0.12.2, google_mlkit_face_detection/text_recognition 1.0.3, sensors_plus 7.1.1, path_provider. Models loaded from `assets/models/face_detection_yunet_2023mar.onnx` and `assets/models/face_recognition_sface_2021dec_int8.onnx` into a private temp directory; no downloads in this module. Parent supplies asset declarations and dartcv4 native modules imgproc/imgcodecs/calib3d/features2d/flann/dnn/objdetect/video.

Android NV21 or planar/strided YUV420 and BGRA are copied to correct BGR, rotated upright, then reduced to <=960 pixels longest side for OpenCV. ML Kit consumes the original copied camera bytes: Android NV21 (YUV420 repacked with row/pixel strides respected), or optional packed BGRA, with the same rotation metadata. No live frame is encoded to JPEG or written to disk. Native OpenCV calls currently run synchronously: use a low/moderate camera resolution, await frames and measure sustainable rate (target >=3 processed frames/sec for dwell continuity). Temporary model copies are deleted on dispose; native matrices/vectors are explicitly released. Dispose on lifecycle exit. Parent handles durable private face-template storage and source-image hash binding.
