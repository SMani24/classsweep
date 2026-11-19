/// Foreground GPS API. No streams, background tracking, or network requests.
///
/// Attendance: `await LocationVerifier().check(GpsPolicy.fromJson(session['gps']))`.
/// Disabled returns null without accessing location services or permissions.
/// Send only the returned `LocationReport.toJson()` as `location`; raw student
/// coordinates never belong in a request. Catch [GpsFailure] for readable errors.
///
/// Instructor: `await LocationVerifier().captureInstructor(radius)` captures a
/// new center on each call. Send its `toJson()` as `gps` at session creation.
/// A center's timestamp describes its initial capture; only new device samples
/// must be fresh. Existing session centers do not expire after 60 seconds.
library;

export 'gps_policy.dart';
export 'location_provider.dart';
export 'location_verifier.dart';
export 'geolocator_provider.dart';
