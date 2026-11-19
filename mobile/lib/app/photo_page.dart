import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';

import '../vision/vision.dart';
import 'app_model.dart';
import 'capture_screen.dart';
import 'classsweep_app.dart';

class PhotoPage extends StatefulWidget {
  const PhotoPage({super.key, required this.model, this.calibration = false});
  final AppModel model;
  final bool calibration;

  @override
  State<PhotoPage> createState() => _PhotoPageState();
}

class _PhotoPageState extends State<PhotoPage> {
  final _room = TextEditingController();
  Uint8List? _photo;
  FaceCapture? _faces;
  bool _busy = false, _consent = false, _done = false;
  String? _error;

  @override
  void dispose() {
    _room.dispose();
    super.dispose();
  }

  Future<void> _openCamera() async {
    if (widget.calibration) {
      final photo = await Navigator.push<Uint8List>(
        context,
        MaterialPageRoute(builder: (_) => const ClassroomCamera()),
      );
      if (mounted && photo != null) {
        setState(() {
          _photo = photo;
          _error = null;
        });
      }
    } else {
      final faces = await Navigator.push<FaceCapture>(
        context,
        MaterialPageRoute(builder: (_) => const GuidedFaceCamera()),
      );
      if (mounted && faces != null) {
        setState(() {
          _faces = faces;
          _photo = faces.photos.first;
          _error = null;
        });
      }
    }
  }

  Future<void> _send() async {
    final photo = _photo;
    if (photo == null || _busy || (!widget.calibration && !_consent)) return;
    final name = _room.text.trim();
    if (widget.calibration && name.isEmpty) {
      setState(() => _error = 'Enter a classroom name.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    ClassSweepVision? vision;
    try {
      if (widget.calibration) {
        vision = ClassSweepVision();
        await vision.start();
        final scene = await vision.enrollScene(photo);
        await widget.model.api.calibrate({
          'name': name,
          'views': [scene.toJson()],
        });
      } else {
        final model = widget.model;
        final scope = model.faceScopeFor(sha256.convert(photo).toString());
        await model.store.saveEnrollmentAngles(
          scope,
          _faces!.reference.toJson(),
        );
        await model.api.uploadEnrollment(photo, model.deviceId);
        await model.refresh();
      }
      if (mounted) {
        setState(() {
          _done = true;
          _photo = null;
          _faces = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = friendlyError(error));
    } finally {
      await vision?.dispose();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final calibration = widget.calibration;
    final photo = _photo;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            calibration ? 'Classroom calibration' : 'Face enrollment',
          ),
        ),
        body: PageBody(
          children: _done
              ? [
                  const SizedBox(height: 18),
                  const Icon(Icons.check_circle_outline, color: teal, size: 56),
                  SectionTitle(
                    calibration ? 'Classroom saved' : 'Awaiting review',
                    '',
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Done'),
                  ),
                ]
              : [
                  SectionTitle(
                    calibration
                        ? 'Classroom reference'
                        : 'Set up your face check',
                    calibration
                        ? 'Frame the board and its surroundings.'
                        : 'Capture three angles in even light.',
                  ),
                  if (calibration)
                    TextField(
                      controller: _room,
                      enabled: !_busy,
                      maxLength: 100,
                      decoration: const InputDecoration(
                        labelText: 'Classroom name',
                      ),
                    ),
                  if (photo != null)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: Image.memory(
                        photo,
                        height: 210,
                        fit: BoxFit.contain,
                      ),
                    ),
                  if (!calibration)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _consent,
                      onChanged: _busy
                          ? null
                          : (v) => setState(() => _consent = v ?? false),
                      title: const Text('Share my front photo for review'),
                      subtitle: const Text(
                        'The other angles stay on this phone.',
                      ),
                    ),
                  if (_error != null) ErrorNotice(_error!),
                  if (photo == null)
                    FilledButton.icon(
                      onPressed: _busy ? null : _openCamera,
                      icon: const Icon(Icons.camera_alt_outlined),
                      label: const Text('Open camera'),
                    )
                  else ...[
                    FilledButton(
                      onPressed: _busy || (!calibration && !_consent)
                          ? null
                          : _send,
                      child: Text(
                        _busy
                            ? 'Saving…'
                            : calibration
                            ? 'Save classroom reference'
                            : 'Submit for review',
                      ),
                    ),
                    OutlinedButton(
                      onPressed: _busy ? null : _openCamera,
                      child: const Text('Retake'),
                    ),
                  ],
                ],
        ),
      ),
    );
  }
}
