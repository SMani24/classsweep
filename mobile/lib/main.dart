import 'dart:io';

import 'package:camera_android/camera_android.dart';
import 'package:flutter/material.dart';

import 'app/classsweep_app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isAndroid) AndroidCamera.registerWith();
  runApp(const ClassSweepApp());
}
