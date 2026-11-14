import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../vision/vision.dart';
import 'app_model.dart';
import 'camera_pane.dart';
import 'classsweep_app.dart';

class PhotoPage extends StatefulWidget {
  const PhotoPage({super.key, required this.model, this.calibration = false});
  final AppModel model;
  final bool calibration;
  @override
  State<PhotoPage> createState() => _PhotoPageState();
}

class _PhotoPageState extends State<PhotoPage> {
  final _camera = GlobalKey<CameraPaneState>();
  final _room = TextEditingController(), _password = TextEditingController();
  Uint8List? _photo;
  bool _busy = false, _consent = false, _done = false;
  int _captureGeneration = 0;
  String? _error;
  @override
  void dispose() {
    _photo = null;
    _room.dispose();
    _password.dispose();
    ++_captureGeneration;
    super.dispose();
  }

  void _interrupted() {
    ++_captureGeneration;
    if (mounted && !_done) {
      setState(() {
        _photo = null;
        _error = 'Capture paused. Return to the app and take a fresh photo.';
      });
    }
  }

  Future<void> _capture() async {
    final generation = ++_captureGeneration;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final bytes = await _camera.currentState!.takePhoto();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) {
        throw const FormatException(
          'Could not read the captured photo. Please retry.',
        );
      }
      var image = img.bakeOrientation(decoded);
      if (image.width > 1600 || image.height > 1600) {
        image = img.copyResize(
          image,
          width: image.width >= image.height ? 1600 : null,
          height: image.height > image.width ? 1600 : null,
        );
      }
      final jpeg = Uint8List.fromList(img.encodeJpg(image, quality: 90));
      if (jpeg.length > 5 * 1024 * 1024) {
        throw StateError('Photo is too large. Please take another photo.');
      }
      if (mounted && generation == _captureGeneration) {
        setState(() => _photo = jpeg);
      }
    } catch (e) {
      if (mounted) setState(() => _error = cameraError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send() async {
    if (_photo == null || _busy) return;
    if (widget.calibration &&
        (_room.text.trim().isEmpty || _password.text.isEmpty)) {
      setState(
        () => _error =
            'Enter a classroom name and the instructor admin password.',
      );
      return;
    }
    if (!widget.calibration && !_consent) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    ClassSweepVision? vision;
    try {
      if (widget.calibration) {
        vision = ClassSweepVision();
        await vision.start();
        final scene = await vision.enrollScene(_photo!);
        final json = scene.toJson();
        final view = {
          for (final key in [
            'id',
            'width',
            'height',
            'keypoints',
            'descriptors',
          ])
            key: json[key],
        };
        await widget.model.api.calibrate(_password.text, {
          'name': _room.text.trim(),
          'views': [view],
        });
      } else {
        await widget.model.api.uploadEnrollment(_photo!, widget.model.deviceId);
        await widget.model.refresh();
      }
      if (mounted) {
        setState(() {
          _done = true;
          _photo = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      await vision?.dispose();
      _password.clear();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(
        title: Text(
          widget.calibration ? 'Classroom calibration' : 'One-time enrollment',
        ),
      ),
      body: PageBody(
        children: _done
            ? [
                const SizedBox(height: 30),
                const Icon(Icons.task_alt_rounded, size: 72, color: teal),
                SectionTitle(
                  widget.calibration
                      ? 'Classroom reference saved'
                      : 'Ready for instructor review',
                  widget.calibration
                      ? 'Processed room features were accepted by the server. You can now create a session in the web admin dashboard.'
                      : 'Your photo was uploaded. Refresh your enrollment status after your instructor approves it.',
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Done'),
                ),
              ]
            : [
                SectionTitle(
                  widget.calibration
                      ? 'Anchor the classroom'
                      : 'Let your instructor verify you',
                  widget.calibration
                      ? 'Use the rear camera to include mostly flat board frames, posters and wall textures. Avoid nearby people and objects at mixed depths.'
                      : 'Use the front camera in even light. Keep one unobstructed face centered in the frame.',
                ),
                if (_photo == null)
                  CameraPane(
                    key: _camera,
                    lens: widget.calibration
                        ? CameraLensDirection.back
                        : CameraLensDirection.front,
                    onInterrupted: _interrupted,
                  )
                else
                  ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: Image.memory(
                      _photo!,
                      height: 340,
                      fit: BoxFit.contain,
                    ),
                  ),
                if (_error != null) ErrorNotice(_error!),
                if (_photo == null)
                  FilledButton.icon(
                    onPressed: _busy ? null : _capture,
                    icon: const Icon(Icons.camera_alt_outlined),
                    label: Text(_busy ? 'Preparing photo…' : 'Take photo'),
                  ),
                if (_photo != null)
                  OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            _photo = null;
                            _error = null;
                          }),
                    icon: const Icon(Icons.replay),
                    label: const Text('Retake'),
                  ),
                if (widget.calibration) ...[
                  TextField(
                    controller: _room,
                    enabled: !_busy,
                    maxLength: 100,
                    decoration: const InputDecoration(
                      labelText: 'Classroom name',
                    ),
                  ),
                  TextField(
                    controller: _password,
                    enabled: !_busy,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: 'Admin password',
                      helperText: 'Used for this upload only; never saved.',
                    ),
                  ),
                  const InfoCard(
                    icon: Icons.hub_outlined,
                    title: 'Only room features leave this phone',
                    body: 'The snapshot becomes ORB feature points and descriptors locally. Only these processed descriptors are uploaded. Create and review attendance sessions in the web dashboard.',
                  ),
                ] else
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _consent,
                    onChanged: _busy
                        ? null
                        : (v) => setState(() => _consent = v ?? false),
                    title: const Text(
                      'I consent to this one-time photo upload.',
                    ),
                    subtitle: const Text(
                      'My instructor can review the photo. The exact approved image is used to create my encrypted local face template. Temporary capture files are deleted.',
                    ),
                  ),
                if (_photo != null)
                  FilledButton.icon(
                    onPressed: _busy || (!widget.calibration && !_consent)
                        ? null
                        : _send,
                    icon: Icon(
                      widget.calibration
                          ? Icons.cloud_upload_outlined
                          : Icons.send_outlined,
                    ),
                    label: Text(
                      _busy
                          ? 'Processing & uploading…'
                          : widget.calibration
                          ? 'Save classroom reference'
                          : 'Upload for review',
                    ),
                  ),
              ],
      ),
    ),
  );
}
