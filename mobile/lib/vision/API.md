# ClassSweep on-device vision API

Import `package:classsweep/vision/vision.dart`. `ClassSweepVision.start()` loads bundled YuNet and SFace models to private temporary files and starts timestamped gyro sampling. Call `dispose()` when leaving capture.

Planned stable facade (implementation follows in this directory):

- `processRearFrame(CameraImage image, {required int sensorOrientation, required DeviceOrientation deviceOrientation, DateTime? timestamp})` → `RearFrameResult` with `codes`, `stableCode`, `motion`, `sceneMatch`. Rear camera assumed. Await one frame at a time; throttle in UI.
- `enrollScene(Uint8List jpeg)` → serialized `SceneReference`; `setSceneReference(SceneReference)` installs local/approved downloaded reference. Serialization via `toJson` / `fromJson`. Capture must show classroom texture, not only a blank board.
- `enrollFace(Uint8List jpeg)` → `FaceReference` (SFace embedding); `setFaceReference(FaceReference)` installs it.
- `beginLiveness()` → ordered random head-turn challenge; `processSelfieFrame(...)` → `SelfieFrameResult` with cosine similarity, ML Kit yaw, and challenge progress. Front camera assumed; input pixels must be unmirrored.
- `resetRearSession()` clears motion/voting history when switching cameras or starting a new attempt.

Dependencies supplied by parent: opencv_dart 2.2.x, camera, google_mlkit_face_detection, google_mlkit_text_recognition, sensors_plus, path_provider. Assets: `assets/models/face_detection_yunet_2023mar.onnx`, `assets/models/face_recognition_sface_2021dec_int8.onnx`.

No networking, training, server inference or automatic approval. Missing face/reference/motion/text produces absent or failed evidence. Thresholds are experimental, require physical-device calibration, and head motion alone is not secure presentation-attack detection. Detailed coordinate and lifecycle contract will be updated with implementation.
