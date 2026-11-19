import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

import '../vision/vision.dart';
import 'camera_pane.dart';

class FaceGuide extends StatelessWidget {
  const FaceGuide({super.key, this.ready = false});
  final bool ready;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _FaceGuidePainter(ready));
}

class _FaceGuidePainter extends CustomPainter {
  const _FaceGuidePainter(this.ready);
  final bool ready;

  @override
  void paint(Canvas canvas, Size size) {
    final oval = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: size.width * .70,
      height: size.height * .72,
    );
    final shade = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addOval(oval);
    canvas.drawPath(shade, Paint()..color = Colors.black38);
    canvas.drawOval(
      oval,
      Paint()
        ..color = ready ? const Color(0xff87edcf) : Colors.white70
        ..strokeWidth = ready ? 3 : 2
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_FaceGuidePainter oldDelegate) =>
      ready != oldDelegate.ready;
}

class ClassroomCamera extends StatefulWidget {
  const ClassroomCamera({super.key});

  @override
  State<ClassroomCamera> createState() => _ClassroomCameraState();
}

class _ClassroomCameraState extends State<ClassroomCamera> {
  final _camera = GlobalKey<CameraPaneState>();
  Uint8List? _photo;
  String? _error;
  bool _busy = false;

  Future<void> _capture() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final bytes = await _camera.currentState!.takePhoto();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) {
        throw const FormatException('Could not read the photo');
      }
      var image = img.bakeOrientation(decoded);
      if (image.width > 1600 || image.height > 1600) {
        image = img.copyResize(
          image,
          width: image.width >= image.height ? 1600 : null,
          height: image.height > image.width ? 1600 : null,
        );
      }
      if (mounted) setState(() => _photo = img.encodeJpg(image, quality: 90));
    } catch (error) {
      if (mounted) setState(() => _error = cameraError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _CameraScreen(
    title: _photo == null ? 'Frame the classroom' : 'Review photo',
    preview: _photo == null
        ? CameraPane(
            key: _camera,
            lens: CameraLensDirection.back,
            height: double.infinity,
          )
        : Image.memory(_photo!, fit: BoxFit.contain),
    controls: [
      if (_error != null) Text(_error!, textAlign: TextAlign.center),
      if (_photo == null) ...[
        const Text(
          'Include the board and surrounding details.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        Semantics(
          button: true,
          child: IconButton.filled(
            tooltip: 'Take photo',
            iconSize: 38,
            padding: const EdgeInsets.all(16),
            style: IconButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: const Color(0xff102e3e),
            ),
            onPressed: _busy ? null : _capture,
            icon: _busy
                ? const SizedBox.square(
                    dimension: 38,
                    child: CircularProgressIndicator(),
                  )
                : const Icon(Icons.camera_alt_outlined),
          ),
        ),
      ] else
        _ReviewButtons(
          onRetake: () => setState(() {
            _photo = null;
            _error = null;
          }),
          onUse: () => Navigator.pop(context, _photo),
          useLabel: 'Use photo',
        ),
    ],
  );
}

class FaceCapture {
  const FaceCapture(this.photos, this.reference);
  final List<Uint8List> photos;
  final FaceReference reference;
}

class GuidedFaceCamera extends StatefulWidget {
  const GuidedFaceCamera({super.key});

  @override
  State<GuidedFaceCamera> createState() => _GuidedFaceCameraState();
}

class _GuidedFaceCameraState extends State<GuidedFaceCamera> {
  static const _poses = [
    'Look straight ahead',
    'Turn slightly left',
    'Turn slightly right',
  ];
  static const _icons = [
    Icons.face_outlined,
    Icons.arrow_back,
    Icons.arrow_forward,
  ];
  final _vision = ClassSweepVision();
  final _photos = <Uint8List>[];
  final _samples = <FaceReference>[];
  late final Future<void> _started;
  Future<void>? _frame;
  DateTime? _held, _last;
  String _message = 'Position your face in the oval';
  String? _error;
  bool _ready = false, _aligned = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _started = _initialize();
  }

  Future<void> _initialize() async {
    try {
      await _vision.start();
      if (mounted) setState(() => _ready = true);
    } catch (error) {
      if (mounted) setState(() => _error = cameraError(error));
    }
  }

  Future<void> _onFrame(
    CameraImage image,
    CameraDescription camera,
    DeviceOrientation orientation,
  ) {
    final task = _consume(image, camera, orientation);
    _frame = task;
    return task.whenComplete(() {
      if (identical(_frame, task)) _frame = null;
    });
  }

  Future<void> _consume(
    CameraImage image,
    CameraDescription camera,
    DeviceOrientation orientation,
  ) async {
    final pose = _photos.length;
    if (!_ready || pose >= _poses.length) return;
    final generation = _generation;
    final now = DateTime.now();
    if (_last != null && now.difference(_last!).inMilliseconds > 1100) {
      _held = null;
    }
    _last = now;
    try {
      final frame = await _vision.enrollmentFrame(
        image,
        sensorOrientation: camera.sensorOrientation,
        deviceOrientation: orientation,
        pose: pose,
        capture: _held != null && now.difference(_held!).inMilliseconds >= 550,
        frontal: _samples.firstOrNull,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _aligned = frame.inPosition;
        _message = frame.message;
        _error = null;
        if (frame.inPosition) {
          _held ??= now;
        } else {
          _held = null;
        }
        if (frame.photo != null && frame.sample != null) {
          _photos.add(frame.photo!);
          _samples.add(frame.sample!);
          _held = null;
          _aligned = false;
          if (_photos.length < _poses.length) _message = _poses[_photos.length];
        }
      });
    } catch (error) {
      if (mounted && _error == null) {
        setState(() => _error = cameraError(error));
      }
    }
  }

  void _reset() {
    _generation++;
    setState(() {
      _photos.clear();
      _samples.clear();
      _held = null;
      _last = null;
      _error = null;
      _aligned = false;
      _message = 'Position your face in the oval';
    });
  }

  Future<void> _disposeVision() async {
    await _started;
    await _frame;
    await _vision.dispose();
  }

  @override
  void dispose() {
    _generation++;
    unawaited(_disposeVision());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final index = _photos.length;
    final review = index == _poses.length;
    return _CameraScreen(
      title: review ? 'Review your photos' : 'Face setup',
      preview: review
          ? Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  for (var i = 0; i < _photos.length; i++)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: Image.memory(
                                _photos[i],
                                fit: BoxFit.contain,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(['Front', 'Left', 'Right'][i]),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            )
          : _ready
          ? CameraPane(
              lens: CameraLensDirection.front,
              height: double.infinity,
              guide: FaceGuide(ready: _aligned),
              onFrame: _onFrame,
              onInterrupted: _reset,
            )
          : Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : Text(_error!),
            ),
      controls: review
          ? [
              const Text(
                'Your instructor receives only the front photo.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              _ReviewButtons(
                onRetake: _reset,
                onUse: () => Navigator.pop(
                  context,
                  FaceCapture(
                    List.of(_photos),
                    _samples.first.withProfiles(_samples.skip(1).toList()),
                  ),
                ),
                useLabel: 'Use photos',
              ),
            ]
          : [
              LinearProgressIndicator(value: index / _poses.length),
              const SizedBox(height: 12),
              Icon(_icons[index], color: const Color(0xff87edcf)),
              const SizedBox(height: 4),
              Text(
                _poses[index],
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 20,
                ),
              ),
              Text(_error ?? _message, textAlign: TextAlign.center),
            ],
    );
  }
}

class _ReviewButtons extends StatelessWidget {
  const _ReviewButtons({
    required this.onRetake,
    required this.onUse,
    required this.useLabel,
  });
  final VoidCallback onRetake, onUse;
  final String useLabel;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 12,
    runSpacing: 8,
    alignment: WrapAlignment.center,
    children: [
      OutlinedButton(
        style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
        onPressed: onRetake,
        child: const Text('Retake'),
      ),
      FilledButton(onPressed: onUse, child: Text(useLabel)),
    ],
  );
}

class _CameraScreen extends StatelessWidget {
  const _CameraScreen({
    required this.title,
    required this.preview,
    required this.controls,
  });
  final String title;
  final Widget preview;
  final List<Widget> controls;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xff10242f),
    appBar: AppBar(
      title: Text(title),
      backgroundColor: const Color(0xff10242f),
      foregroundColor: Colors.white,
    ),
    body: SafeArea(
      child: DefaultTextStyle.merge(
        style: const TextStyle(color: Colors.white),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: preview),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
              child: Column(mainAxisSize: MainAxisSize.min, children: controls),
            ),
          ],
        ),
      ),
    ),
  );
}
