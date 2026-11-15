# Android delivery

After Android app edits, rebuild and refresh `$HOME/apks/ClassSweep-debug.apk` so the user can copy the latest APK to their phone. Use `scripts/build_android.sh`; it handles this copy automatically after a successful build. If another build method is needed, copy the verified resulting APK to that same destination. `CLASSSWEEP_APK_DIR` can override the destination.

Never commit APK binaries, enrollment images, credentials, face templates, or runtime databases.
