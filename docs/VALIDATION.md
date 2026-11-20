# Validation status

The user reported a successful Android check-in before the 1.3.0 update and intermittent connectivity on the tablet hotspot. The phone-side code override and camera zoom in 1.3.0 still need a physical rehearsal. iOS is deferred.

## Verified locally

- Flutter 3.47.9 / Dart 3.13.7: static analysis reports no issues.
- 71 Flutter tests pass: OCR voting, movement/head challenge sequencing and failure cases, reference validation, actual native YuNet/SFace execution, native ORB matching, native optical flow, HTTP reference binding, sign-in/registration layout at 320px and 390px widths, Wi-Fi settings, local hostname acceptance, and credential-free connection probes; optional GPS distance, freshness, accuracy, permissions, coordinate-free summaries, live disable, and narrow-screen instructor controls, sequential board codes the password suggestion, instructor phone custom codes with leading zeroes, and confirmed session close.
- 38 Python server tests pass. Coverage includes enrollment approval/purge, exact reference hash, authentication, invalid uploads, device/reference/direction mismatch, ownership, expiry, replay, atomic duplicate prevention, room-version pinning, admin forms/revocation, LAN address selection excluding virtual networks, local hostname validation and launcher cleanup; GPS policy validation, distance/accuracy/freshness boundaries, live disable during an attempt, summary-only storage/exports, and migration from the pre-GPS database schema, instructor sign-in and role isolation, and closing and reusing a test code pair.
- LAN verification: `laptop.local` resolves through Avahi to the selected Wi-Fi IPv4 address on the laptop, and `/health` responds through both hostname and IP. A separate launcher was stopped with SIGTERM; its child server port closed. The phone confirmed the numeric health URL once. The follow-up laptop probes passed for both numeric IP and hostname, while phone-side instability was not reproduced. See the [hotspot investigation](ENGINEERING_HANDOFF.md#tablet-hotspot-investigation-and-presentation-runbook).
- The Linux server starts through the supplied helper; health and authenticated dashboard requests succeed. The existing local database was backed up privately, upgraded additively for GPS, and verified to retain its original record counts and pass SQLite integrity checks. Its generated administrator password file has owner-only permissions.
- Android debug APK builds successfully. Its signature verifies; package inspection confirms Android 7.0+ (API 24), ARM64-only native libraries, both original model checksums and upstream license files, foreground coarse/fine location permissions, and no background-location permission, microphone permission or private database/password files. The current debug build is version 1.3.0 (5) and uses the same signing certificate as 1.2.0.
- Source publication audit excludes runtime data, enrollment images, credentials, downloaded model weights and APKs. Public source contains only synthetic test data.

Python tests inject local check outcomes to test the protocol. They do not establish that a person was physically present. Native smoke tests establish model/runtime execution, not face-verification accuracy.

The local machine encountered unreliable Google Maven downloads. Official artifacts were downloaded into a private local cache for packaging, without changing upstream library code. That cache and recovery logs are ignored by Git; the public project uses standard upstream repositories. The GitHub workflow independently runs the source checks and Android build. A debug APK is intended for device testing, not an app-store release.

## Physical testing still required

- Camera permissions, correct image orientation, lens switching and lifecycle handling during the new camera flows.
- Repeat three-pose enrollment, automatic preparation after approval, and the sequential scan from a last-row seat. Confirm that rear zoom adjusts the digit view, locks during the measured pan, and returns after the selfie camera.
- Actual location permission prompts, time-to-fix and indoor accuracy, nearby/outside-radius check-ins, and retrying after the instructor disables GPS. GPS-off sessions must also work with Location disabled.
- Sustained processing speed, heat and gyro/camera timing.
- Handwritten code recognition at classroom distances and under glare.
- Classroom matching across seating positions; the first calibration UI captures one view.
- Genuine-person acceptance, different-person rejection, and simple screen/photo replay trials.
- Threshold adjustment based on measured false accepts and false rejects.

See [PHONE_TEST.md](PHONE_TEST.md) for the tablet hotspot rehearsal. Do not use the prototype as the only attendance method before those checks.
