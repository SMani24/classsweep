# First test: Android phone + Linux laptop

Use your own account and images for the first trial. Real classroom evaluation comes after basic device checks.

## 1. Install server dependencies

From the repository root:

```bash
./scripts/setup_server.sh
python3 scripts/run_server.py
```

The first launch generates a random administrator password in `data/admin-password.txt`, readable only by your Linux user. The username is `admin`. Open <http://laptop.local:8000/admin> (or the IP fallback printed by the launcher) on the laptop. Runtime files under `data/` are ignored by Git.

## 2. Connect over Wi-Fi — no cable needed

Put the phone and laptop on the same Wi-Fi. The launcher advertises `laptop.local` while it runs. In the app's **Connection & privacy** settings, enter `http://laptop.local:8000`, tap **Test connection**, then **Save server**. The new app uses this address by default; an existing saved address is not silently replaced.

First open `http://laptop.local:8000/health` in the phone's browser: it should show `status: ok` and `service: classsweep`. If the name does not resolve, use the **IP fallback** printed by the laptop, such as `http://192.168.1.20:8000`. No router configuration is normally required. See [WIFI.md](WIFI.md) for older Android devices, guest-network isolation, VPNs, firewall checks and optional USB mode.

Keep the laptop awake and the server running. Restart the server after changing Wi-Fi networks or the laptop's IP address. LAN HTTP does not encrypt traffic; use a trusted local network for your own prototype testing.

## 3. Build and install

If you already have the supplied `ClassSweep-debug.apk`, copy it to your phone, open it, allow installation from the chosen source if Android asks, and skip the build. Update the existing app rather than uninstalling it. USB is optional for transferring or installing the APK. It is an ARM64 debug package for Android 7.0 or newer.

Flutter and Android SDK/build tools must be installed. The repository's pinned dependencies and model manifest are used by:

```bash
./scripts/build_android.sh
# Copy ~/apks/ClassSweep-debug.apk to your phone and open it to install.
```

The first build compiles OpenCV and may take several minutes. Native builds are capped at three workers to avoid overwhelming the laptop. The supplied build targets 64-bit ARM Android phones. An older 32-bit phone needs a separate `--target-platform android-arm` build.

Successful builds replace `~/apks/ClassSweep-debug.apk` with the latest version. You can copy that same file to the phone after each edit. Override the destination with `CLASSSWEEP_APK_DIR` if needed.

## 4. Rehearse with two phones

1. On the instructor phone, open **Instructor sign-in** and enter the server's administrator password. Relaunch the app once to verify that the sign-in is remembered.
2. Open **Classroom calibration → Open camera**. Frame a textured, mostly flat board area. Take a photo, tap **Use photo**, and save the classroom reference.
3. On the student phone, register and tap **Enroll my face**. Follow the front, left and right prompts. Review the photos and submit the front photo for approval. Approve it in the laptop dashboard and wait for **Ready to check in** on the phone.
4. Create a session in **Attendance sessions** on the instructor phone or on the laptop dashboard. Open **Override board codes for testing** if you already have two paper codes. Close the old session before reusing them. Leave GPS off for the first trial.
5. Tap **Start check-in**. Hold one code in view until it is recognized. Choose the side where the other code is posted, follow the pan arrow, hold on the second code and pan back when prompted.
6. Follow the selfie prompts, then show the calibrated board and a code again. Use the rear camera’s **+ / −** buttons to frame distant digits while aiming. Zoom locks during the measured pan and hold. Tap **Record my attendance** and check **My attendance** and the laptop session's result count.

Use an empty classroom or your own room initially. Include texture in the reference and start near the calibration viewpoint. One reference view may not match every seat.

## What to report from your phone

- Android version and phone model.
- Whether both cameras open and switch successfully.
- Which stage fails and the displayed message or diagnostic score.
- Whether handwritten codes are readable at realistic distances.
- Whether the turn instruction agrees with the actual camera direction.
- Whether a genuine attempt succeeds repeatedly and a different person's face is rejected.
- Approximate completion time and any freezing, heat, or unexpected battery drain.

Do not send classmates' images or raw face templates when reporting problems. A build and synthetic tests do not substitute for physical-device validation of camera orientation, lighting, sensor timing, handwriting, and face-verification thresholds.

## Optional GPS trial

Finish one camera-only check-in first. Then use the phone’s instructor attendance settings to create a GPS-required session, initially with the default 100m radius near a window or outdoors. Test permission denial, poor accuracy and the instructor’s live Disable GPS action. See [GPS.md](GPS.md) for acceptance rules and privacy.
