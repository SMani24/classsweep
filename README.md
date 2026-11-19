# ClassSweep

Android classroom attendance using **on-device computer vision** and a Linux laptop server. Built as an Introduction to Computer Vision course prototype.

Students scan one board code at a time during a guided camera sweep, verify their face against a human-approved enrollment reference, and recheck the board. No markers or projector are needed.

## What is included

- Flutter Android app with registration, enrollment, instructor room calibration, and guided attendance.
- Local YuNet/SFace face verification, ML Kit OCR and head-pose checks, OpenCV natural-feature matching and optical flow, and gyroscope consistency.
- FastAPI/SQLite server with an instructor dashboard, image review, expiring attendance sessions, duplicate/replay checks, and CSV export.
- Optional GPS radius check configured from the instructor phone, with an off switch for poor reception. Student coordinates stay on the phone.
- Reproducible model downloads with pinned upstream commit and SHA-256 verification.
- Automated API, challenge-logic, and native-model smoke tests.

**Android is the current target. iOS is deferred; no iOS build or device validation is claimed.**

[Validation status](docs/VALIDATION.md) records the automated checks, Android build and physical phone tests.

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

1. On the instructor phone, choose **Instructor sign-in** and enter the dashboard password. ClassSweep saves the session. Open **Classroom calibration** and capture a textured board region in the dedicated camera.
2. On the student phone, create an account and follow the three-pose face setup. The front photo goes to the instructor for review. The side templates stay on the phone.
3. Approve the photo in the laptop dashboard. The student's face reference prepares automatically after approval.
4. Create a session and write its codes on opposite sides of the board. For a rehearsal with the same paper codes, open **Override board codes for testing** on the laptop. Close the previous session before reusing its codes.
5. Follow the on-screen arrows to scan the two codes separately, do the face turn, and recheck the board. Verify the result in the laptop dashboard.

The initial calibration UI uploads one reference view. Its reliability across different seats must be evaluated. Use textured surroundings, avoid people, and start with nearby seating.

## Privacy and scope

Enrollment is a **one-time image-upload exception** for human review. Routine attendance images, face embeddings, and raw motion traces stay on the phone. Classroom reference descriptors are processed locally before upload. Approved enrollment images can be purged after the phone acknowledges template installation.

Wi-Fi is the default. The launcher binds to the selected Wi-Fi/Ethernet IP and advertises a temporary `.local` alias without changing the laptop’s system hostname. Local HTTP does not encrypt traffic. Use HTTPS before collecting real students' data over shared networks.

This is an educational attendance aid. Checks deter casual sharing and replay; they do not establish tamper-proof physical presence. The server trusts the app's reported checks. Device-specific camera orientation, handwriting readability, sensor timing, and verification thresholds require physical-phone testing. Always provide a manual attendance alternative.

See [optional GPS setup and tests](docs/GPS.md), and [Wi-Fi setup and troubleshooting](docs/WIFI.md). Optional USB forwarding remains available with `--local-only`.

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
