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
    this.height = 340,
    this.guide,
    this.initialZoom = 1,
    this.allowZoom = false,
    this.onZoomChanged,
  });
  final CameraLensDirection lens;
  final double height;
  final Widget? guide;
  final double initialZoom;
  final bool allowZoom;
  final ValueChanged<double>? onZoomChanged;
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
  Future<void>? _processing, _zoomTask;
  double _minZoom = 1, _maxZoom = 1, _zoom = 1;
  String? _zoomError;
  Future<void>? get zoomPending => _zoomTask;
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
      if (mounted) {
        setState(() {
          _error = _zoomError = null;
          _minZoom = _maxZoom = _zoom = 1;
        });
      }
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
        if (widget.onZoomChanged != null) {
          await _initializeZoom(controller);
        }
        if (_disposed || !_active || generation != _generation) {
          await _release();
          return;
        }
        if (widget.onFrame != null) {
          await controller.startImageStream((image) {
            if (_disposed ||
                !_active ||
                generation != _generation ||
                _processing != null ||
                _zoomTask != null ||
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

  Future<void> _initializeZoom(CameraController controller) async {
    try {
      final min = await controller.getMinZoomLevel();
      final max = await controller.getMaxZoomLevel();
      if (!min.isFinite || !max.isFinite || min <= 0 || max <= min) return;
      final zoom = widget.initialZoom.clamp(min, max).toDouble();
      if (zoom != 1) await controller.setZoomLevel(zoom);
      _minZoom = min;
      _maxZoom = max;
      _zoom = zoom;
    } on CameraException {
      // Some devices implement preview but do not expose camera zoom.
    } on PlatformException {
      // Leave the camera usable when the platform does not support zoom.
    }
  }

  void _adjustZoom(double delta) {
    final controller = _camera;
    if (!widget.allowZoom ||
        _zoomTask != null ||
        controller == null ||
        !_active) {
      return;
    }
    final next = (_zoom + delta).clamp(_minZoom, _maxZoom).toDouble();
    if (next == _zoom) return;
    final generation = _generation;
    setState(() {
      _zoomError = null;
      _zoomTask = _applyZoom(controller, next, generation);
    });
  }

  Future<void> _applyZoom(
    CameraController controller,
    double next,
    int generation,
  ) async {
    bool current() =>
        mounted && !_disposed && _active && generation == _generation;
    try {
      // Drop incoming frames and finish the current inference before changing the crop.
      await _processing;
      if (!current()) return;
      await controller.setZoomLevel(next);
      await Future<void>.delayed(const Duration(milliseconds: 240));
      if (!current()) return;
      _zoom = next;
      widget.onZoomChanged?.call(next);
    } catch (_) {
      if (current()) _zoomError = 'Could not change zoom.';
    } finally {
      _zoomTask = null;
      if (current()) setState(() {});
    }
  }

  Widget _zoomControls() {
    final step = _maxZoom - _minZoom <= 4 ? .5 : 1.0;
    final enabled = widget.allowZoom && _zoomTask == null;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Zoom out',
            color: Colors.white,
            disabledColor: Colors.white38,
            onPressed: enabled && _zoom > _minZoom
                ? () => _adjustZoom(-step)
                : null,
            icon: const Icon(Icons.remove),
          ),
          Semantics(
            liveRegion: true,
            child: Text(
              '${_zoom.toStringAsFixed(1)}×',
              style: const TextStyle(color: Colors.white),
            ),
          ),
          IconButton(
            tooltip: 'Zoom in',
            color: Colors.white,
            disabledColor: Colors.white38,
            onPressed: enabled && _zoom < _maxZoom
                ? () => _adjustZoom(step)
                : null,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
    );
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
    await _zoomTask;
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
    // Permission dialogs may briefly mark the foreground app inactive.
    if (state == AppLifecycleState.inactive) return;
    if (state != AppLifecycleState.resumed) {
      if (!_active) return;
      _active = false;
      ++_generation;
      widget.onInterrupted?.call();
      _operations = _operations.catchError((_) {}).then((_) => _release());
      if (mounted) setState(() {});
    } else if (!_active) {
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
          height: widget.height,
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
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            CameraPreview(camera),
                            if (widget.guide != null)
                              IgnorePointer(child: widget.guide!),
                          ],
                        ),
                      ),
                    ),
                    if (widget.onZoomChanged != null && _maxZoom > _minZoom)
                      Positioned(
                        bottom: 10,
                        left: 0,
                        right: 0,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_zoomError != null)
                              Text(
                                _zoomError!,
                                style: const TextStyle(color: Colors.white),
                              ),
                            _zoomControls(),
                          ],
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
