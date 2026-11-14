# First test: Android phone + Linux laptop

Use your own account and images for the first trial. Real classroom evaluation comes after basic device checks.

## 1. Install server dependencies

From the repository root:

```bash
./scripts/setup_server.sh
python3 scripts/run_server.py
```

The first launch generates a random administrator password in `data/admin-password.txt`, readable only by your Linux user. The username is `admin`. Open <http://127.0.0.1:8000/admin> on the laptop. Runtime files under `data/` are ignored by Git.

## 2. Connect the phone

Enable Android Developer options and USB debugging, connect the phone by USB, and accept the phone's authorization prompt:

```bash
adb devices
adb reverse tcp:8000 tcp:8000
```

Keep the cable connected. In ClassSweep, use `http://127.0.0.1:8000` as the server address. No router configuration is required.

For a Wi-Fi-only demonstration, start `python3 scripts/run_server.py --lan`, put both devices on the same trusted network, and enter `http://LAPTOP_LAN_IP:8000` on the phone. A guest network may prevent devices communicating. Cleartext LAN traffic is not appropriate for real students' enrollment data.

## 3. Build and install

Flutter and Android SDK/build tools must be installed. The repository's pinned dependencies and model manifest are used by:

```bash
./scripts/build_android.sh
adb install -r mobile/build/app/outputs/flutter-apk/app-debug.apk
```

The first build compiles OpenCV and may take several minutes. Native builds are capped at three workers to avoid overwhelming the laptop. The supplied build targets 64-bit ARM Android phones. An older 32-bit phone needs a separate `--target-platform android-arm` build.

## 4. Prepare the room

1. In the app, open instructor calibration, enter the server's administrator password, and capture a textured, mostly flat board region with stable surroundings. Only extracted reference features are sent to the server.
2. Register a student account, capture and submit an enrollment photograph, and approve it in the laptop dashboard after checking the person.
3. Refresh the app's enrollment status and install the approved local face reference.
4. In the dashboard, create a short attendance session. Write its two fresh four-digit codes far apart on the board, clearly and large enough for the phone to read. Avoid other four-digit numbers in the captured region.
5. Start attendance and follow the camera instructions: scan the codes, complete the pan/pause/return movement, verify the face, and recheck the board.
6. Check the attendance record on the laptop and export CSV.

Use an empty classroom or your own room initially. The classroom reference needs texture; a blank whiteboard alone is unsuitable. One reference view is not guaranteed to match every seat. Recalibrate and use nearby seating for the first functional trial.

## What to report from your phone

- Android version and phone model.
- Whether both cameras open and switch successfully.
- Which stage fails and the displayed message or diagnostic score.
- Whether handwritten codes are readable at realistic distances.
- Whether the turn instruction agrees with the actual camera direction.
- Whether a genuine attempt succeeds repeatedly and a different person's face is rejected.
- Approximate completion time and any freezing, heat, or unexpected battery drain.

Do not send classmates' images or raw face templates when reporting problems. A build and synthetic tests do not substitute for physical-device validation of camera orientation, lighting, sensor timing, handwriting, and face-verification thresholds.
