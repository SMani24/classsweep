import 'dart:async';
import 'dart:math';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../vision/vision.dart';
import '../location/location.dart';
import '../network/attendance_location.dart';
import 'app_model.dart';
import 'camera_pane.dart';
import 'capture_screen.dart';
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
  final _camera = GlobalKey<CameraPaneState>();
  double _rearZoom = 1;
  late final Future<void> _initialization;
  Future<void>? _frameTask;
  CaptureStage _stage = CaptureStage.preparing;
  String? _error;
  Map<String, dynamic>? _attempt;
  BoardCodeScan _codes = BoardCodeScan();
  final LocationVerifier _locationVerifier = LocationVerifier();
  GpsPolicy? _gpsPolicy;
  String? _gpsResult;
  bool _checkingLocation = false, _selectingPan = false;
  RearFrameResult? _rear;
  SelfieFrameResult? _selfie;
  SceneMatch? _scanRoom, _recheckRoom;
  DateTime? _started, _faceStarted, _recheckSceneAt, _recheckCodeAt;
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
          DateTime.now().difference(_started!).inSeconds > 65) {
        _fail('Board scan timed out. Check the codes, then try again.');
      } else if (_stage == CaptureStage.face &&
          _faceStarted != null &&
          DateTime.now().difference(_faceStarted!).inSeconds > 42) {
        _faceFailed();
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
      await widget.model.ensureFace();
      if (!mounted) return;
      final reference = widget.model.faceReference;
      if (reference == null) {
        throw StateError(
          widget.model.facePreparationError ??
              'Your face setup is still preparing.',
        );
      }
      final vision = ClassSweepVision();
      _vision = vision;
      await vision.start();
      vision.setFaceReference(reference);
      if (widget.session != null) {
        final currentSession = await widget.model.api.session(
          widget.session!['id'] as String,
        );
        _gpsPolicy = GpsPolicy.fromJson(currentSession['gps']);
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
    _codes = BoardCodeScan();
    _rear = null;
    _selfie = null;
    _scanRoom = null;
    _recheckSceneAt = null;
    _recheckCodeAt = null;
    _recheckRoom = null;
    _attempt = null;
    _completedFace = null;
    _maxYaw = 0;
    _vision!.resetRearSession();
    _sweep = null;
    _started = DateTime.now();
    ++_generation;
    setState(() {
      _stage = CaptureStage.scan;
      _error = null;
    });
  }

  Future<void> _selectPan(String direction) async {
    if (_sweep != null || _codes.first == null || _selectingPan) return;
    _selectingPan = true;
    final generation = _generation;
    try {
      await _camera.currentState?.zoomPending;
      await _frameTask;
      if (!mounted ||
          generation != _generation ||
          _stage != CaptureStage.scan) {
        return;
      }
      setState(() => _sweep = _vision!.beginSweep(direction: direction));
    } finally {
      _selectingPan = false;
    }
  }

  bool get _canAdjustZoom {
    if (_stage == CaptureStage.recheck) return true;
    if (_stage != CaptureStage.scan || _selectingPan) return false;
    final phase = _sweep?.phase;
    return phase == null ||
        phase == SweepPhase.complete ||
        (phase == SweepPhase.pause && _codes.second == null);
  }

  void _zoomChanged(double level) {
    if (_stage != CaptureStage.scan && _stage != CaptureStage.recheck) return;
    _vision!.resetRearFrameHistory();
    _rear = null;
    _recheckSceneAt = null;
    _recheckCodeAt = null;
    _recheckRoom = null;
    _rearZoom = level;
    setState(() {});
  }

  String get _faceStatus {
    final result = _selfie;
    if (result == null) return 'Center your face';
    if (result.faceCount == 0) {
      return 'No face visible. Move closer in even light.';
    }
    if (result.faceCount > 1) return 'Keep only one face in view.';
    if (result.similarity == null) {
      return 'Face found. Improve the light or turn less.';
    }
    if (!result.identityMatches) {
      return 'Face found, but it did not match your enrollment.';
    }
    if (result.headYaw == null) return 'Hold your head upright.';
    return 'Face matches';
  }

  void _faceFailed() => _fail('Face check timed out. $_faceStatus');

  bool get _canRetryFace =>
      _stage == CaptureStage.failed &&
      _attempt != null &&
      _faceStarted != null &&
      _completedFace == null &&
      (_attempt!['expires_at'] as num) >
          DateTime.now().millisecondsSinceEpoch / 1000;

  Future<void> _retryFace() async {
    if (!_canRetryFace) return;
    await _frameTask;
    if (!mounted || !_canRetryFace) return;
    _vision!.beginLiveness(direction: _attempt!['direction'] as String);
    _faceStarted = DateTime.now();
    _maxYaw = 0;
    _selfie = null;
    ++_generation;
    setState(() {
      _error = null;
      _stage = CaptureStage.face;
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
          _faceFailed();
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
          allowSweepPause: _codes.second != null,
        );
        if (!mounted || generation != _generation || stage != _stage) return;
        _rear = result;
        if (stage == CaptureStage.scan) {
          if (_sweep != null) _sweep = result.sweep;
          if (_sweep?.phase == SweepPhase.failed) {
            _fail('Sweep timed out. Pan slowly toward the other code.');
            return;
          }
          if (result.ocrFresh) {
            _codes.observe(
              visible: result.codes,
              stable: result.stableCodes,
              seekingSecond: _sweep?.phase == SweepPhase.pause,
            );
          }
          if (result.sceneFresh && result.sceneMatch.passed) {
            _scanRoom = result.sceneMatch;
          }
          setState(() {});
        } else if (stage == CaptureStage.recheck) {
          final now = DateTime.now();
          if (result.sceneFresh && result.sceneMatch.passed) {
            _recheckRoom = result.sceneMatch;
            _recheckSceneAt = now;
          }
          if (result.ocrFresh &&
              result.stableCodes.any(
                (code) => _codes.contains(code) && result.codes.contains(code),
              )) {
            _recheckCodeAt = now;
          }
          bool recent(DateTime? time) =>
              time != null &&
              now.difference(time) <= const Duration(seconds: 3);
          if (recent(_recheckSceneAt) && recent(_recheckCodeAt)) {
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
      _codes.second != null &&
      _sweep?.passed == true &&
      _scanRoom?.passed == true;

  Future<void> _beginFace() async {
    if (!_scanReady) return;
    final generation = ++_generation;
    setState(() => _stage = CaptureStage.connecting);
    try {
      await _frameTask;
      final codes = [_codes.first!, _codes.second!];
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
    setState(() {
      _stage = CaptureStage.submitting;
      _error = null;
      _checkingLocation = true;
    });
    try {
      await _frameTask;
      if (!mounted || generation != _generation) return;
      // Always refresh: the instructor may have disabled GPS during this attempt.
      final prepared = await prepareAttendanceLocation(
        refreshSession: () =>
            widget.model.api.session(widget.session!['id'] as String),
        sessionId: widget.session!['id'] as String,
        classroomReferenceId: _attempt!['classroom_reference_id'] as String,
        verifier: _locationVerifier,
      );
      _gpsPolicy = prepared.policy;
      final location = prepared.report;
      if (!mounted || generation != _generation) return;
      setState(() => _checkingLocation = false);
      final face = _completedFace!;
      final result = await widget.model.api.submit({
        'attempt_id': _attempt!['attempt_id'],
        'device_id': widget.model.deviceId,
        'reference_sha256': widget.model.user!.referenceHash,
        'classroom_reference_id': _attempt!['classroom_reference_id'],
        'direction': _attempt!['direction'],
        if (location != null) 'location': location.toJson(),
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
        setState(() {
          _stage = CaptureStage.done;
          _gpsResult = result['gps_status'] == 'passed'
              ? 'GPS passed · ${(result['location']['distance_m'] as num).toStringAsFixed(0)} m from the session center'
              : 'GPS was not required for this attendance.';
        });
      }
    } on GpsFailure catch (error) {
      if (mounted && generation == _generation) {
        // Local GPS failures have not consumed the server attempt. Retry only
        // the location step while the existing camera challenge remains valid.
        setState(() {
          _stage = CaptureStage.review;
          _checkingLocation = false;
          _error = friendlyError(error);
        });
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
    CaptureStage.scan => switch (_sweep?.phase) {
      null =>
        _codes.first == null ? 'Aim at one code' : 'Where is the second code?',
      SweepPhase.first => 'Pan ${_sweep!.direction}',
      SweepPhase.pause =>
        _codes.second == null ? 'Aim at the second code' : 'Hold still',
      SweepPhase.reverse => 'Pan back toward the first code',
      SweepPhase.complete =>
        _scanRoom == null
            ? 'Show the calibrated board area'
            : 'Board scan complete',
      SweepPhase.failed => 'Try the board scan again',
    },
    CaptureStage.face => switch (_selfie?.liveness?.phase ?? HeadPhase.center) {
      HeadPhase.center => 'Look straight at the phone',
      HeadPhase.turn => 'Turn slightly to your ${_attempt!['direction']}',
      HeadPhase.returnCenter => 'Look straight ahead again',
      _ => 'Keep your face visible',
    },
    CaptureStage.recheck => 'Show the board and a code again',
    _ => 'Check in with your classroom',
  };

  Widget _diagnostics(bool face) => ExpansionTile(
    title: const Text('Device test details', style: TextStyle(fontSize: 13)),
    visualDensity: VisualDensity.compact,
    children: [
      Text(
        face
            ? 'Faces: ${_selfie?.faceCount ?? 0} · Similarity: ${_selfie?.similarity?.toStringAsFixed(3) ?? '—'}\n'
                  'Head angle: ${_selfie?.headYaw?.toStringAsFixed(1) ?? '—'}° · Track: ${_selfie?.trackedFace ?? '—'}'
            : 'Tracks: ${_rear?.motion.tracks ?? 0} · Gyro: ${_rear?.motion.gyroYaw?.toStringAsFixed(3) ?? '—'}\n'
                  'Motion: ${_sweep?.correlation.toStringAsFixed(3) ?? '—'} · Room: ${_rear?.sceneMatch.matches ?? 0}\n'
                  '${_vision?.sensorError ?? ''}',
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final stage = _stage;
    if (_capturing) {
      final scanning = stage == CaptureStage.scan;
      final face = stage == CaptureStage.face;
      final phase = _sweep?.phase;
      final direction = _sweep?.direction;
      final arrow = switch (phase) {
        SweepPhase.first =>
          direction == 'left'
              ? Icons.arrow_back_rounded
              : Icons.arrow_forward_rounded,
        SweepPhase.reverse =>
          direction == 'left'
              ? Icons.arrow_forward_rounded
              : Icons.arrow_back_rounded,
        SweepPhase.pause =>
          _codes.second == null
              ? Icons.center_focus_strong
              : Icons.pause_rounded,
        SweepPhase.complete => Icons.check_circle_outline,
        _ => Icons.document_scanner_outlined,
      };
      return Scaffold(
        appBar: AppBar(title: Text(face ? 'Face check' : 'Board scan')),
        body: SafeArea(
          child: Column(
            children: [
              LinearProgressIndicator(
                value: scanning
                    ? (_codes.first == null
                          ? .08
                          : _codes.second == null
                          ? .20
                          : .35)
                    : face
                    ? .60
                    : .84,
              ),
              Expanded(
                child: CameraPane(
                  key: _camera,
                  lens: face
                      ? CameraLensDirection.front
                      : CameraLensDirection.back,
                  height: double.infinity,
                  allowZoom: _canAdjustZoom,
                  initialZoom: face ? 1 : _rearZoom,
                  onZoomChanged: face ? null : _zoomChanged,
                  guide: face
                      ? FaceGuide(ready: _selfie?.identityMatches == true)
                      : null,
                  onFrame: _onFrame,
                  onInterrupted: () {
                    if (_active) {
                      _fail('Camera paused. Try the check-in again.');
                    }
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (scanning)
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        child: Icon(
                          arrow,
                          key: ValueKey(arrow),
                          size: 42,
                          color: teal,
                        ),
                      ),
                    Text(
                      _instruction,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    if (scanning)
                      Wrap(
                        spacing: 8,
                        alignment: WrapAlignment.center,
                        children: [
                          Chip(
                            avatar: Icon(
                              _codes.first == null
                                  ? Icons.looks_one_outlined
                                  : Icons.check,
                              size: 17,
                            ),
                            label: Text(_codes.first ?? 'First code'),
                          ),
                          Chip(
                            avatar: Icon(
                              _codes.second == null
                                  ? Icons.looks_two_outlined
                                  : Icons.check,
                              size: 17,
                            ),
                            label: Text(_codes.second ?? 'Second code'),
                          ),
                        ],
                      ),
                    if (scanning && _codes.first != null && _sweep == null)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          OutlinedButton.icon(
                            onPressed: () => _selectPan('left'),
                            icon: const Icon(Icons.arrow_back),
                            label: const Text('Left'),
                          ),
                          const SizedBox(width: 12),
                          OutlinedButton.icon(
                            onPressed: () => _selectPan('right'),
                            icon: const Icon(Icons.arrow_forward),
                            label: const Text('Right'),
                          ),
                        ],
                      ),
                    if (scanning && _scanReady)
                      FilledButton(
                        onPressed: _beginFace,
                        child: const Text('Continue to face check'),
                      ),
                    if (face) Text(_faceStatus, textAlign: TextAlign.center),
                    _diagnostics(face),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }
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
                  : _checkingLocation
                  ? 'Checking the session’s location requirement'
                  : 'Recording attendance',
              '',
            ),
          ],
          if (stage == CaptureStage.ready) ...[
            const SectionTitle(
              'Ready to check in',
              'Scan two codes, then verify your face.',
            ),
            if (_gpsPolicy?.enabled == true)
              const InfoCard(
                icon: Icons.location_on_outlined,
                title: 'GPS required',
                body: 'Allow location when you submit.',
              ),
            FilledButton.icon(
              onPressed: _start,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Start camera checks'),
            ),
          ],
          if (stage == CaptureStage.review) ...[
            const Icon(Icons.fact_check_outlined, size: 64, color: teal),
            const SectionTitle('All camera checks completed', ''),
            FilledButton(
              onPressed: _submit,
              child: const Text('Record my attendance'),
            ),
          ],
          if (stage == CaptureStage.done) ...[
            const Icon(Icons.task_alt_rounded, size: 80, color: teal),
            const SectionTitle('Attendance recorded', ''),
            if (_gpsResult != null) Text(_gpsResult!),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ],
          if (_error != null) ...[
            ErrorNotice(_error!),
            if (_selfie != null || _rear != null)
              _diagnostics(_faceStarted != null),
            if (_canRetryFace)
              OutlinedButton(
                onPressed: _retryFace,
                child: const Text('Retry face check'),
              ),
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
