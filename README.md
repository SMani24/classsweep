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

Local verification passes 17 server tests and 19 app/native tests, with clean static analysis and a signed debug APK. [Validation status](docs/VALIDATION.md) distinguishes these checks from the physical-phone evaluation still needed.

## Quick start

On Linux, from the repository root:

```bash
./scripts/setup_server.sh
python3 scripts/run_server.py
```

Keep the phone and laptop on the same Wi-Fi. Open [the instructor dashboard](http://laptop.local:8000/admin). Username: `admin`. The first launch creates a random password in the private, Git-ignored `data/admin-password.txt` file.

Build the APK, then copy it to your phone and open it to install:

```bash
./scripts/build_android.sh
# Copy ~/apks/ClassSweep-debug.apk to your phone and install it.
```

Use `http://laptop.local:8000` in the phone app and tap **Test connection** in settings. The launcher advertises that name using Avahi and prints a numeric IP fallback. No USB cable is needed during use. Existing saved addresses are preserved; change them in settings if needed. Follow the [phone test guide](docs/PHONE_TEST.md) for calibration, enrollment approval, and your first attendance session. Flutter and the Android SDK must be installed. The first native OpenCV build takes several minutes; the default APK targets 64-bit ARM phones.

Each successful build updates `~/apks/ClassSweep-debug.apk`, alongside your other APKs. Set `CLASSSWEEP_APK_DIR` to use a different destination.

## First demonstration

1. Calibrate a distinctive, mostly flat board region from the app's instructor screen.
2. Register a student account and submit an enrollment photo.
3. Approve the exact photo in the laptop dashboard and install its local template on the phone.
4. Create a session in the dashboard and write its two codes on opposite sides of the board.
5. Follow the app's camera instructions, then check the attendance record and CSV on the laptop.

The initial calibration UI uploads one reference view. Its reliability across different seats must be evaluated. Use textured surroundings, avoid people, and start with nearby seating.

## Privacy and scope

Enrollment is a **one-time image-upload exception** for human review. Routine attendance images, face embeddings, and raw motion traces stay on the phone. Classroom reference descriptors are processed locally before upload. Approved enrollment images can be purged after the phone acknowledges template installation.

Wi-Fi is the default. The launcher binds to the selected Wi-Fi/Ethernet IP and advertises a temporary `.local` alias without changing the laptop’s system hostname. Local HTTP does not encrypt traffic. Use HTTPS before collecting real students' data over shared networks.

This is an educational attendance aid. Checks deter casual sharing and replay; they do not establish tamper-proof physical presence. The server trusts the app's reported checks. Device-specific camera orientation, handwriting readability, sensor timing, and verification thresholds require physical-phone testing. Always provide a manual attendance alternative.

See [Wi-Fi setup and troubleshooting](docs/WIFI.md). Optional USB forwarding remains available with `--local-only`.

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
