# Optional GPS verification

GPS is an extra location-consistency check, alongside the existing camera checks. It is off by default. It can reject genuine users indoors, so the instructor can disable it without weakening the camera requirements.

## Instructor setup on the phone

Open **Settings → Instructor attendance & GPS**, or **Instructor · Attendance settings** from the sign-in screen. Enter the administrator password, session title and duration. Calibrate the classroom first if no room reference exists.

- Leave **Require GPS** off to use only the camera checks. The app does not request a location or location permission for that session.
- Turn it on to use the instructor phone's current position as the session center.
- Set the accepted radius: **100 metres by default**, adjustable from **25 to 1,000 metres**.
- Create the session while physically at the classroom. The app requests a fresh foreground position and shows the generated board codes after the server accepts it.

The instructor's coordinates, accuracy, reading time and radius form the session policy stored on the laptop. Student phones download this center to calculate their distance locally. Treat the classroom center as shared class information.

## Student behavior

The session card says whether GPS is required. After the camera checks, submitting attendance refreshes the live policy. If GPS is on, the app requests a current position and compares it locally with the session center. Student latitude and longitude are not uploaded or logged. Only distance, reported accuracy and capture time are submitted; retained results contain status and, when passed, distance and accuracy.

The phone must have Location enabled and allow foreground location access. Grant precise location if Android offers a choice. Poor precision, denied permission, disabled services or a timeout produces an explanation and a retry rather than an automatic pass. Nothing tracks the student in the background.

## Accuracy and radius

Both instructor and student readings must:

- Be no more than 60 seconds old, or 15 seconds ahead of the server clock.
- Have reported horizontal accuracy no worse than the smaller of half the radius and 100 metres.

For a 100m radius, each reading must report accuracy of 50m or better. The student's estimated distance must be within the configured radius. A poor reading does not enlarge the radius automatically. These are practical thresholds, not a statistical guarantee of a student's true physical position. Distance uses the haversine formula on the phone.

## Disable when reception is poor

Open the phone's instructor page, load sessions, and tap **Disable GPS** for an open session. The laptop dashboard also provides the action. Disabling takes effect for students already attempting attendance; their remaining camera checks are still required. GPS cannot be enabled again or moved on an existing session. Create a new session to choose a different center or radius.

The original instructor policy remains in the private session record, while disabled student-facing policy responses hide the center. Reports submitted after disabling do not retain student location summaries. Previously recorded successful GPS summaries remain in their attendance records.

## First tests

1. Create a session with GPS off. Deny the app's location permission or turn Location off. Camera-only attendance must still work.
2. Near a window or outdoors, enable GPS and create a session with a 100m radius. Confirm the instructor reading is accurate enough.
3. Try a student check-in nearby and inspect distance/accuracy and the GPS result in history/CSV.
4. Try denying permission or disabling Location during a GPS-required session: attendance must not silently pass.
5. Disable GPS from the instructor page for that same open session. Retry submission; location is no longer required.
6. In a separate test, verify a location beyond the radius is rejected. Avoid testing dangerous or inconvenient travel simply to reach a boundary; deterministic distance tests cover the mathematics.

GPS can be faked on a modified device, and the server trusts the phone's processed distance just as it trusts local vision results. The feature is intended to deter casual remote check-in, not prove exact location. Use a manual attendance alternative for accessibility and device failures.
