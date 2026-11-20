# Android delivery

After Android app edits, rebuild and refresh `$HOME/apks/ClassSweep-debug.apk` so the user can copy the latest APK to their phone. Use `scripts/build_android.sh`; it handles this copy automatically after a successful build. If another build method is needed, copy the verified resulting APK to that same destination. `CLASSSWEEP_APK_DIR` can override the destination.

Never commit APK binaries, enrollment images, credentials, face templates, or runtime databases.

# Local network use

Wi-Fi is the default. The server launcher publishes `laptop.local` while running and prints its numeric IP fallback. Keep USB forwarding optional (`--local-only`); do not require a connected cable for normal use. See `docs/WIFI.md`. Do not change the system hostname, other apps' Avahi publishers, or firewall rules as part of ordinary app updates.

# Project map

Read [the ClassSweep engineering handoff](docs/ENGINEERING_HANDOFF.md) before changing the capture pipeline, session protocol, local storage, or Wi-Fi behavior. It maps implementation files, thresholds, field notes, tests, and remaining verification.
