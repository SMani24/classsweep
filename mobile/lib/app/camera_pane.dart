import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// One camera owner shared by enrollment, calibration and attendance.
/// Frames are local, dropped while busy and never queued or uploaded here.
class CameraPane extends StatefulWidget {
  const CameraPane({
    super.key,
    required this.lens,
    this.onFrame,
    this.onInterrupted,
  });
  final CameraLensDirection lens;
  final Future<void> Function(
    CameraImage,
    CameraDescription,
    DeviceOrientation,
  )?
  onFrame;
  final VoidCallback? onInterrupted;
  @override
  State<CameraPane> createState() => CameraPaneState();
}

class CameraPaneState extends State<CameraPane> with WidgetsBindingObserver {
  CameraController? _camera;
  Future<void> _operations = Future.value();
  Future<void>? _processing;
  String? _error;
  bool _active = true, _disposed = false, _taking = false;
  int _generation = 0;
  DateTime _lastFrame = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _queueOpen();
  }

  @override
  void didUpdateWidget(CameraPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lens != widget.lens ||
        (oldWidget.onFrame == null) != (widget.onFrame == null)) {
      _queueOpen();
    }
  }

  void _queueOpen() {
    final generation = ++_generation;
    _operations = _operations.catchError((_) {}).then((_) async {
      await _release();
      if (_disposed || !_active || generation != _generation) return;
      if (mounted) setState(() => _error = null);
      try {
        final cameras = await availableCameras();
        final matching = cameras.where((c) => c.lensDirection == widget.lens);
        if (matching.isEmpty) {
          throw CameraException(
            'NoCamera',
            'This device does not have the required camera.',
          );
        }
        final controller = CameraController(
          matching.first,
          ResolutionPreset.medium,
          enableAudio: false,
          imageFormatGroup: Platform.isAndroid
              ? ImageFormatGroup.nv21
              : ImageFormatGroup.bgra8888,
        );
        _camera = controller;
        await controller.initialize();
        if (_disposed || !_active || generation != _generation) {
          await _release();
          return;
        }
        await controller.lockCaptureOrientation(DeviceOrientation.portraitUp);
        if (widget.onFrame != null) {
          await controller.startImageStream((image) {
            if (_disposed ||
                !_active ||
                generation != _generation ||
                _processing != null ||
                _taking) {
              return;
            }
            final now = DateTime.now();
            if (now.difference(_lastFrame).inMilliseconds < 120) return;
            _lastFrame = now;
            _processing = _processFrame(image, controller, generation);
          });
        }
        if (mounted) setState(() {});
      } catch (error) {
        await _release();
        if (mounted && !_disposed && generation == _generation) {
          setState(() => _error = cameraError(error));
        }
      }
    });
  }

  Future<void> _processFrame(
    CameraImage image,
    CameraController controller,
    int generation,
  ) async {
    try {
      await widget.onFrame?.call(
        image,
        controller.description,
        controller.value.deviceOrientation,
      );
    } catch (error) {
      if (mounted && !_disposed && generation == _generation) {
        setState(() => _error = cameraError(error));
      }
    } finally {
      _processing = null;
    }
  }

  Future<void> _release() async {
    final controller = _camera;
    _camera = null;
    if (controller == null) return;
    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    } catch (_) {}
    try {
      await _processing;
    } catch (_) {}
    try {
      await controller.dispose();
    } catch (_) {}
  }

  /// Read a single JPEG into memory and always remove the plugin's temporary file.
  Future<Uint8List> takePhoto() async {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized || !_active || _taking) {
      throw StateError('Camera is not ready. Allow camera access and retry.');
    }
    _taking = true;
    XFile? photo;
    try {
      if (camera.value.isStreamingImages) await camera.stopImageStream();
      await _processing;
      photo = await camera.takePicture();
      return await photo.readAsBytes();
    } finally {
      if (photo != null) {
        final file = File(photo.path);
        if (await file.exists()) await file.delete();
      }
      _taking = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      if (!_active) return;
      _active = false;
      ++_generation;
      widget.onInterrupted?.call();
      _operations = _operations.catchError((_) {}).then((_) => _release());
      if (mounted) setState(() {});
    } else {
      _active = true;
      _queueOpen();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    WidgetsBinding.instance.removeObserver(this);
    _operations = _operations.catchError((_) {}).then((_) => _release());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final camera = _camera;
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: ColoredBox(
        color: const Color(0xff102c3a),
        child: SizedBox(
          height: 340,
          width: double.infinity,
          child: _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.no_photography_outlined,
                          color: Colors.white,
                          size: 40,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _error!,
                          style: const TextStyle(color: Colors.white),
                          textAlign: TextAlign.center,
                        ),
                        TextButton(
                          onPressed: _queueOpen,
                          child: const Text('Retry camera'),
                        ),
                      ],
                    ),
                  ),
                )
              : !_active
              ? const Center(
                  child: Text(
                    'Camera paused',
                    style: TextStyle(color: Colors.white),
                  ),
                )
              : camera == null || !camera.value.isInitialized
              ? const Center(
                  child: CircularProgressIndicator(color: Colors.white),
                )
              : Stack(
                  fit: StackFit.expand,
                  children: [
                    Center(
                      child: AspectRatio(
                        aspectRatio: camera.value.aspectRatio > 1
                            ? 1 / camera.value.aspectRatio
                            : camera.value.aspectRatio,
                        child: CameraPreview(camera),
                      ),
                    ),
                    IgnorePointer(
                      child: Container(
                        margin: const EdgeInsets.all(36),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(
                            widget.lens == CameraLensDirection.front ? 100 : 18,
                          ),
                          border: Border.all(color: Colors.white54, width: 2),
                        ),
                      ),
                    ),
                    const Positioned(
                      left: 14,
                      top: 14,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.all(Radius.circular(16)),
                        ),
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          child: Text(
                            'ON DEVICE',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              letterSpacing: 1.4,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

String cameraError(Object error) {
  if (error is CameraException) {
    if (error.code.toLowerCase().contains('access')) {
      return 'Camera permission is required. Allow camera access in Android Settings, then retry.';
    }
    return error.description ??
        'Camera unavailable. Close other camera apps and retry.';
  }
  return error.toString().replaceFirst('Bad state: ', '');
}
