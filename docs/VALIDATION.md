# Validation status

This prototype has not yet been run on a physical Android phone. iOS is deferred.

## Verified locally

- Flutter 3.47.9 / Dart 3.13.7: static analysis reports no issues.
- 16 Flutter tests pass: OCR voting, movement/head challenge sequencing and failure cases, reference validation, actual native YuNet/SFace execution, native ORB matching, native optical flow, HTTP reference binding, and sign-in/registration layout at 320px and 390px widths.
- 11 Python server tests pass: enrollment approval/purge, exact reference hash, authentication, invalid uploads, device/reference/direction mismatch, ownership, expiry, replay, atomic duplicate prevention, room-version pinning, and admin forms/revocation.
- The Linux server starts through the supplied helper; health and authenticated dashboard requests succeed. Its generated administrator password file has owner-only permissions.
- Android debug APK builds successfully. Its signature verifies; package inspection confirms Android 7.0+ (API 24), ARM64-only native libraries, both original model checksums and upstream license files, and no microphone permission or private database/password files.
- Source publication audit excludes runtime data, enrollment images, credentials, downloaded model weights and APKs. Public source contains only synthetic test data.

Python tests inject local check outcomes to test the protocol. They do not establish that a person was physically present. Native smoke tests establish model/runtime execution, not face-verification accuracy.

The local machine encountered unreliable Google Maven downloads. Official artifacts were downloaded into a private local cache for packaging, without changing upstream library code. That cache and recovery logs are ignored by Git; the public project uses standard upstream repositories. The GitHub workflow independently runs the source checks and Android build. A debug APK is intended for device testing, not an app-store release.

## Physical testing still required

- Camera permissions, correct image orientation, lens switching and lifecycle handling on the actual phone.
- Sustained processing speed, heat and gyro/camera timing.
- Handwritten code recognition at classroom distances and under glare.
- Classroom matching across seating positions; the first calibration UI captures one view.
- Genuine-person acceptance, different-person rejection, and simple screen/photo replay trials.
- Threshold adjustment based on measured false accepts and false rejects.

See [PHONE_TEST.md](PHONE_TEST.md) for the first trial. Do not use the prototype as the only attendance method before those checks.
