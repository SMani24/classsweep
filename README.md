# ClassSweep

Android classroom attendance using **on-device computer vision** and a Linux laptop server. Built as an Introduction to Computer Vision course prototype.

Students scan fresh handwritten codes on opposite sides of the board, follow a short camera-motion challenge, verify their face against a human-approved enrollment reference, and recheck the board. No markers or projector are needed.

## What is included

- Flutter Android app with registration, enrollment, instructor room calibration, and guided attendance.
- Local YuNet/SFace face verification, ML Kit OCR and head-pose checks, OpenCV natural-feature matching and optical flow, and gyroscope consistency.
- FastAPI/SQLite server with an instructor dashboard, image review, expiring attendance sessions, duplicate/replay checks, and CSV export.
- Reproducible model downloads with pinned upstream commit and SHA-256 verification.
- Automated API, challenge-logic, and native-model smoke tests.

**Android is the current target. iOS is deferred; no iOS build or device validation is claimed.**

Local verification passes 11 server tests and 16 app/native tests, with clean static analysis and a signed debug APK. [Validation status](docs/VALIDATION.md) distinguishes these checks from the physical-phone evaluation still needed.

## Quick start

On Linux, from the repository root:

```bash
./scripts/setup_server.sh
python3 scripts/run_server.py
```

Open [the instructor dashboard](http://127.0.0.1:8000/admin). Username: `admin`. The first launch creates a random password in the private, Git-ignored `data/admin-password.txt` file.

Build and install on a USB-connected Android phone with debugging enabled:

```bash
./scripts/build_android.sh
adb reverse tcp:8000 tcp:8000
adb install -r mobile/build/app/outputs/flutter-apk/app-debug.apk
```

Use `http://127.0.0.1:8000` in the phone app. Follow the [phone test guide](docs/PHONE_TEST.md) for calibration, enrollment approval, and your first attendance session. Flutter and the Android SDK must be installed. The first native OpenCV build takes several minutes; the default APK targets 64-bit ARM phones.

## First demonstration

1. Calibrate a distinctive, mostly flat board region from the app's instructor screen.
2. Register a student account and submit an enrollment photo.
3. Approve the exact photo in the laptop dashboard and install its local template on the phone.
4. Create a session in the dashboard and write its two codes on opposite sides of the board.
5. Follow the app's camera instructions, then check the attendance record and CSV on the laptop.

The initial calibration UI uploads one reference view. Its reliability across different seats must be evaluated. Use textured surroundings, avoid people, and start with nearby seating.

## Privacy and scope

Enrollment is a **one-time image-upload exception** for human review. Routine attendance images, face embeddings, and raw motion traces stay on the phone. Classroom reference descriptors are processed locally before upload. Approved enrollment images can be purged after the phone acknowledges template installation.

For personal testing, use USB forwarding. LAN HTTP is available with `python3 scripts/run_server.py --lan`, but does not encrypt traffic. Use HTTPS before collecting real students' data over shared networks.

This is an educational attendance aid. Checks deter casual sharing and replay; they do not establish tamper-proof physical presence. The server trusts the app's reported checks. Device-specific camera orientation, handwriting readability, sensor timing, and verification thresholds require physical-phone testing. Always provide a manual attendance alternative.

Read [data handling](docs/PRIVACY.md), [the API contract](server/API.md), and [server setup](server/README.md).

## Development checks

```bash
.venv/bin/python -m pytest server/tests -q
cd mobile
flutter analyze
flutter test
flutter build apk --debug --target-platform android-arm64
```

Download the model assets first with `python3 scripts/fetch_models.py` from the root. Model binaries, runtime databases, enrollment images, credentials, and APKs are excluded from source control.

## Attribution

Application code: MIT. Pretrained YuNet and SFace models come from [OpenCV Zoo](https://github.com/opencv/opencv_zoo); their separate license texts are retained under `mobile/assets/models/`. Google ML Kit provides on-device text/face detection; Flutter wrappers and OpenCV Dart bindings are community maintained. No model training or original-model authorship is claimed.
