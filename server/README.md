# ClassSweep local server

From the repository root:

```bash
./scripts/setup_server.sh
python3 scripts/run_server.py
```

The instructor dashboard is at `http://127.0.0.1:8000/admin`. Username: `admin`. The startup helper generates and stores a random password in the Git-ignored `data/admin-password.txt`, with owner-only permissions. It also places the SQLite database under `data/`. Do not publish this directory.

Use `adb reverse tcp:8000 tcp:8000` for a USB-connected Android phone. For a trusted-network demonstration, `python3 scripts/run_server.py --lan` listens on all local interfaces; set the phone's server address to the laptop's LAN IP. HTTP is unencrypted. Use HTTPS for real student data over a shared network.

For manual startup, set `CLASSSWEEP_ADMIN_PASSWORD` and `CLASSSWEEP_DATA_DIR`, then run `python -m uvicorn classsweep.app:create_app --factory` from this directory inside the root virtual environment. There is no default administrator password. Optional CORS origins are configured using a comma-separated `CLASSSWEEP_CORS_ORIGINS`; the Android app does not need CORS.

## Workflow

1. Use the phone's instructor calibration screen to upload processed classroom descriptors.
2. Students register and submit an enrollment photograph for review.
3. Review and approve each image against an independent identity reference.
4. Students prepare the approved local face template. The app acknowledges successful storage.
5. You can then use **Purge image** to remove the enrollment image while preserving approval. **Revoke enrollment** is a different action and prevents further attendance until a new capture is approved.
6. Create an attendance session and write its two codes on opposite sides of the board.
7. Students complete the local checks and submit outcomes; export results from the dashboard's CSV link.

Close the private browser window after admin use: browsers may cache HTTP Basic credentials. Server storage contains personal information; keep it on your own laptop and remove it according to your class retention policy. SQLite deletion is logical deletion, not a forensic secure erase of database pages or backups.

See [API.md](API.md) for the mobile contract. The server validates authentication, approval, reference/device bindings, session expiry, schema and duplicate submissions. It trusts the phone's reported vision results; it does not run server-side face recognition.

## Tests

```bash
../.venv/bin/python -m pytest tests -q
```

Tests use synthetic images and temporary databases, not real student data.
