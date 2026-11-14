import 'dart:async';
import 'dart:math';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../vision/vision.dart';
import 'app_model.dart';
import 'camera_pane.dart';
import 'classsweep_app.dart';

enum CaptureStage {
  preparing,
  ready,
  scan,
  connecting,
  face,
  recheck,
  review,
  submitting,
  done,
  failed,
}

class AttendancePage extends StatefulWidget {
  const AttendancePage({super.key, required this.model, this.session});
  final AppModel model;
  final Map<String, dynamic>? session;
  @override
  State<AttendancePage> createState() => _AttendancePageState();
}

class _AttendancePageState extends State<AttendancePage> {
  ClassSweepVision? _vision;
  late final Future<void> _initialization;
  Future<void>? _frameTask;
  CaptureStage _stage = CaptureStage.preparing;
  String? _error;
  Map<String, dynamic>? _attempt;
  final Map<String, DateTime> _codes = {};
  RearFrameResult? _rear;
  SelfieFrameResult? _selfie;
  SceneMatch? _scanRoom, _recheckRoom;
  DateTime? _scanRoomAt, _started, _faceStarted;
  SweepProgress? _sweep;
  SelfieFrameResult? _completedFace;
  double _maxYaw = 0;
  int _generation = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _initialization = _prepare();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_attempt != null &&
          _active &&
          DateTime.now().millisecondsSinceEpoch / 1000 >=
              (_attempt!['expires_at'] as num)) {
        _fail('This attempt expired. Go back and start a fresh check-in.');
      } else if (_stage == CaptureStage.scan &&
          _started != null &&
          DateTime.now().difference(_started!).inSeconds > 25) {
        _fail(
          'The scan timed out. Start again, pan slowly, pause, then return. Make sure both codes are readable.',
        );
      } else if (_stage == CaptureStage.face &&
          _faceStarted != null &&
          DateTime.now().difference(_faceStarted!).inSeconds > 18) {
        _fail(
          'The face challenge timed out. Start again in even light with your face clearly visible.',
        );
      }
    });
  }

  bool get _active => {
    CaptureStage.scan,
    CaptureStage.connecting,
    CaptureStage.face,
    CaptureStage.recheck,
    CaptureStage.review,
  }.contains(_stage);
  bool get _capturing => {
    CaptureStage.scan,
    CaptureStage.face,
    CaptureStage.recheck,
  }.contains(_stage);

  Future<void> _prepare() async {
    try {
      final user = await widget.model.verifyAccount();
      if (!user.approved) {
        throw StateError(
          'Your enrollment needs instructor approval before continuing.',
        );
      }
      final scope = widget.model.faceScope;
      final vision = ClassSweepVision();
      _vision = vision;
      await vision.start();
      final stored = await widget.model.store.loadFace(scope);
      if (stored != null) {
        vision.setFaceReference(FaceReference.fromJson(stored));
      } else {
        final image = await widget.model.api.approvedReference(
          expectedHash: user.referenceHash!,
          deviceId: widget.model.deviceId,
        );
        final face = await vision.enrollFace(image);
        await widget.model.store.saveFace(scope: scope, face: face.toJson());
      }
      // Acknowledge only after durable storage; admin can then purge the image.
      await widget.model.api.templateReady(
        widget.model.deviceId,
        user.referenceHash!,
      );
      if (widget.session != null) {
        final room = await widget.model.api.classroom(
          widget.session!['classroom_reference_id'] as String,
        );
        final views = room['views'] as List;
        if (views.isEmpty) {
          throw StateError(
            'The instructor must calibrate the classroom first.',
          );
        }
        vision.setSceneReference(
          SceneReference.fromJson(
            Map<String, dynamic>.from(views.first as Map),
          ),
        );
      }
      if (mounted) setState(() => _stage = CaptureStage.ready);
    } catch (error) {
      if (mounted) _fail(friendlyError(error));
    }
  }

  void _fail(String message) {
    ++_generation;
    if (mounted) {
      setState(() {
        _error = message;
        _stage = CaptureStage.failed;
      });
    }
  }

  void _start() {
    _codes.clear();
    _rear = null;
    _selfie = null;
    _scanRoom = null;
    _scanRoomAt = null;
    _recheckRoom = null;
    _attempt = null;
    _completedFace = null;
    _maxYaw = 0;
    _sweep = _vision!.beginSweep();
    _started = DateTime.now();
    ++_generation;
    setState(() {
      _stage = CaptureStage.scan;
      _error = null;
    });
  }

  Future<void> _onFrame(
    CameraImage image,
    CameraDescription description,
    DeviceOrientation orientation,
  ) {
    final task = _consume(image, description, orientation);
    _frameTask = task;
    return task.whenComplete(() {
      if (identical(_frameTask, task)) _frameTask = null;
    });
  }

  Future<void> _consume(
    CameraImage image,
    CameraDescription description,
    DeviceOrientation orientation,
  ) async {
    final generation = _generation, stage = _stage;
    if (!_capturing) return;
    try {
      if (stage == CaptureStage.face) {
        final result = await _vision!.processSelfieFrame(
          image,
          sensorOrientation: description.sensorOrientation,
          deviceOrientation: orientation,
        );
        if (!mounted || generation != _generation || stage != _stage) return;
        _selfie = result;
        if (result.identityMatches && result.headYaw != null) {
          _maxYaw = max(_maxYaw, result.headYaw!.abs());
        }
        if (result.liveness?.phase == HeadPhase.failed) {
          _fail(
            'The face challenge timed out. Start again and follow the head movement instructions.',
          );
          return;
        }
        if (result.liveness?.passed == true &&
            result.identityMatches &&
            result.faceCount == 1) {
          _completedFace = result;
          // The previous operation has returned; clear stale rear evidence before switching.
          _vision!.resetRearSession();
          ++_generation;
          setState(() => _stage = CaptureStage.recheck);
        } else {
          setState(() {});
        }
      } else {
        final result = await _vision!.processRearFrame(
          image,
          sensorOrientation: description.sensorOrientation,
          deviceOrientation: orientation,
        );
        if (!mounted || generation != _generation || stage != _stage) return;
        _rear = result;
        if (stage == CaptureStage.scan) {
          _sweep = result.sweep;
          if (result.sweep.phase == SweepPhase.failed) {
            _fail(
              'The movement challenge timed out. Retry with a slow pan, a pause, and a return pan.',
            );
            return;
          }
          if (result.ocrFresh) {
            for (final code in result.stableCodes) {
              _codes[code] = result.ocrTimestamp;
            }
          }
          if (result.sceneFresh && result.sceneMatch.passed) {
            _scanRoom = result.sceneMatch;
            _scanRoomAt = DateTime.now();
          }
          setState(() {});
        } else if (stage == CaptureStage.recheck) {
          final expected = _codes.keys.toSet();
          final fresh = result.ocrFresh && result.sceneFresh;
          if (fresh &&
              result.sceneMatch.passed &&
              result.stableCodes.any(expected.contains)) {
            _recheckRoom = result.sceneMatch;
            ++_generation;
            setState(() => _stage = CaptureStage.review);
          } else {
            setState(() {});
          }
        }
      }
    } catch (error) {
      if (mounted && generation == _generation) _fail(friendlyError(error));
    }
  }

  bool get _scanReady =>
      _codes.length == 2 &&
      _sweep?.passed == true &&
      _scanRoom?.passed == true &&
      _scanRoomAt != null &&
      DateTime.now().difference(_scanRoomAt!).inSeconds <= 3;

  Future<void> _beginFace() async {
    if (!_scanReady) return;
    final generation = ++_generation;
    setState(() => _stage = CaptureStage.connecting);
    try {
      await _frameTask;
      final codes = _codes.keys.toList()..sort();
      final attempt = await widget.model.api.beginAttempt({
        'session_id': widget.session!['id'],
        'code_a': codes[0],
        'code_b': codes[1],
        'device_id': widget.model.deviceId,
        'reference_sha256': widget.model.user!.referenceHash,
      });
      if (!mounted || generation != _generation) return;
      if (attempt['session_id'] != widget.session!['id'] ||
          attempt['classroom_reference_id'] !=
              widget.session!['classroom_reference_id'] ||
          !['left', 'right'].contains(attempt['direction'])) {
        throw StateError(
          'The server challenge does not match the selected class. Refresh and retry.',
        );
      }
      _attempt = attempt;
      _vision!.beginLiveness(direction: attempt['direction'] as String);
      _faceStarted = DateTime.now();
      setState(() => _stage = CaptureStage.face);
    } catch (error) {
      if (mounted && generation == _generation) _fail(friendlyError(error));
    }
  }

  Future<void> _submit() async {
    if (_stage != CaptureStage.review ||
        _attempt == null ||
        _completedFace?.liveness?.passed != true ||
        _scanRoom?.passed != true ||
        _recheckRoom?.passed != true ||
        _sweep?.passed != true) {
      return;
    }
    final generation = ++_generation;
    setState(() => _stage = CaptureStage.submitting);
    try {
      await _frameTask;
      final face = _completedFace!;
      await widget.model.api.submit({
        'attempt_id': _attempt!['attempt_id'],
        'device_id': widget.model.deviceId,
        'reference_sha256': widget.model.user!.referenceHash,
        'classroom_reference_id': _attempt!['classroom_reference_id'],
        'direction': _attempt!['direction'],
        'checks': {
          'face_match': face.identityMatches,
          'single_face': face.faceCount == 1,
          'turn_completed': face.liveness!.passed,
          'returned_to_center': face.liveness!.passed,
          'continuous_face': face.liveness!.passed,
          'liveness_passed': face.liveness!.passed,
          'room_match': _scanRoom!.passed,
          'rear_camera_scan': _sweep!.passed,
          'rear_camera_recheck': _recheckRoom!.passed,
          'motion_correlated': _sweep!.correlation >= .65,
        },
        'metrics': {
          'match_distance': (1 - face.similarity!).clamp(0.0, 2.0),
          'max_yaw_degrees': _maxYaw,
          'return_yaw_degrees': face.headYaw!,
          'duration_ms': DateTime.now()
              .difference(_faceStarted!)
              .inMilliseconds
              .toDouble(),
          'room_good_matches': _scanRoom!.matches,
          'room_inlier_ratio': _scanRoom!.inlierRatio,
          'room_recheck_good_matches': _recheckRoom!.matches,
          'room_recheck_inlier_ratio': _recheckRoom!.inlierRatio,
          'motion_correlation': _sweep!.correlation,
        },
      });
      if (mounted && generation == _generation) {
        setState(() => _stage = CaptureStage.done);
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        _fail(
          '${friendlyError(error)} If the connection was interrupted, check My attendance before retrying.',
        );
      }
    }
  }

  Future<void> _cleanup() async {
    await _initialization;
    try {
      await _frameTask;
    } catch (_) {
      /* Processing errors already appear in UI. */
    }
    await _vision?.dispose();
  }

  @override
  void dispose() {
    ++_generation;
    _timer?.cancel();
    unawaited(_cleanup());
    super.dispose();
  }

  String get _instruction => switch (_stage) {
    CaptureStage.scan => _sweep?.instruction ?? 'Aim at the first code',
    CaptureStage.face => switch (_selfie?.liveness?.phase ?? HeadPhase.center) {
      HeadPhase.center => 'Look straight at the phone',
      HeadPhase.turn => 'Turn your head ${_attempt!['direction']}',
      HeadPhase.returnCenter => 'Look straight ahead again',
      _ => 'Keep your face visible',
    },
    CaptureStage.recheck => 'Show either board code again',
    _ => 'Check in with your classroom',
  };

  @override
  Widget build(BuildContext context) {
    final stage = _stage;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.session?['title'] as String? ?? 'Prepare face reference',
        ),
      ),
      body: PageBody(
        children: [
          if (stage == CaptureStage.preparing ||
              stage == CaptureStage.connecting ||
              stage == CaptureStage.submitting) ...[
            const SizedBox(height: 60),
            const Center(child: CircularProgressIndicator()),
            SectionTitle(
              stage == CaptureStage.preparing
                  ? 'Preparing local checks'
                  : stage == CaptureStage.connecting
                  ? 'Requesting a fresh challenge'
                  : 'Recording attendance',
              'Keep the app open. Camera frames stay on this phone.',
            ),
          ],
          if (stage == CaptureStage.ready) ...[
            const Icon(Icons.verified_user_outlined, size: 64, color: teal),
            const SectionTitle(
              'Your face reference is ready',
              'The approved enrollment image has been converted into a privately stored local template.',
            ),
            if (widget.session != null) ...[
              const InfoCard(
                icon: Icons.swipe_outlined,
                title: 'Scan, pause, and return',
                body: 'Hold the phone upright. Find both handwritten codes while following the pan and pause instructions. Include the board surroundings. Then complete a face check and show the board again.',
              ),
              FilledButton.icon(
                onPressed: _start,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Start camera checks'),
              ),
            ] else
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Done'),
              ),
          ],
          if (_capturing) ...[
            LinearProgressIndicator(
              value: stage == CaptureStage.scan
                  ? .2
                  : stage == CaptureStage.face
                  ? .5
                  : .8,
            ),
            SectionTitle(
              _instruction,
              stage == CaptureStage.face
                  ? 'Keep one face in view and move your head slowly.'
                  : stage == CaptureStage.scan
                  ? 'Read both codes while following the movement instructions.'
                  : 'A fresh code and classroom match finish the camera checks.',
            ),
            CameraPane(
              key: const ValueKey('attendance-camera'),
              lens: stage == CaptureStage.face
                  ? CameraLensDirection.front
                  : CameraLensDirection.back,
              onFrame: _onFrame,
              onInterrupted: () {
                if (_active) {
                  _fail(
                    'Camera capture was interrupted. Go back and start a fresh check-in.',
                  );
                }
              },
            ),
            if (stage == CaptureStage.scan) ...[
              Text(
                'Codes found: ${_codes.keys.join(' · ')}${_codes.isEmpty ? 'none yet' : ''}',
              ),
              if (_codes.length > 2)
                const ErrorNotice(
                  'More than two four-digit numbers were detected. Go back, clear unrelated numbers from the view, and start again.',
                ),
              Text(
                'Classroom: ${_scanRoom?.passed == true ? 'matched' : 'looking for reference features'} · Movement: ${_sweep?.passed == true ? 'complete' : 'in progress'}',
              ),
              FilledButton(
                onPressed: _scanReady ? _beginFace : null,
                child: const Text('Continue to face check'),
              ),
            ],
            if (stage == CaptureStage.face && _selfie != null)
              Text(
                _selfie!.faceCount != 1
                    ? 'Keep exactly one face visible.'
                    : !_selfie!.identityMatches
                    ? 'Face does not yet match the approved reference. Face the camera in even light.'
                    : 'Face matches. Follow the head instruction.',
              ),
            ExpansionTile(
              title: const Text('Device test details'),
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    stage == CaptureStage.face
                        ? 'Face similarity: ${_selfie?.similarity?.toStringAsFixed(3) ?? 'unavailable'}\nHead angle: ${_selfie?.headYaw?.toStringAsFixed(1) ?? 'unavailable'}°'
                        : 'Tracked points: ${_rear?.motion.tracks ?? 0}\nGyro: ${_rear?.motion.gyroYaw?.toStringAsFixed(3) ?? 'unavailable'}\nMotion correlation: ${_sweep?.correlation.toStringAsFixed(3) ?? 'unavailable'}\nRoom matches: ${_rear?.sceneMatch.matches ?? 0}\n${_vision?.sensorError ?? ''}',
                  ),
                ),
              ],
            ),
          ],
          if (stage == CaptureStage.review) ...[
            const Icon(Icons.fact_check_outlined, size: 64, color: teal),
            const SectionTitle(
              'All camera checks completed',
              'Your phone has matched the board, movement and enrolled face. Submit the processed results to record attendance.',
            ),
            FilledButton(
              onPressed: _submit,
              child: const Text('Record my attendance'),
            ),
          ],
          if (stage == CaptureStage.done) ...[
            const Icon(Icons.task_alt_rounded, size: 80, color: teal),
            const SectionTitle(
              'Attendance recorded',
              'The server accepted your completed check-in.',
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ],
          if (_error != null) ...[
            ErrorNotice(_error!),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Back to dashboard'),
            ),
          ],
        ],
      ),
    );
  }
}
