import '../location/location.dart';

class PreparedLocation {
  const PreparedLocation(this.policy, this.report);
  final GpsPolicy policy;
  final LocationReport? report;
}

/// Refresh the live policy before requesting any student location.
/// Only an explicit instructor disable can bypass a failed location check.
Future<PreparedLocation> prepareAttendanceLocation({
  required Future<Map<String, dynamic>> Function() refreshSession,
  required String sessionId,
  required String classroomReferenceId,
  required LocationVerifier verifier,
}) async {
  Future<GpsPolicy> refresh() async {
    final session = await refreshSession();
    if (session['id'] != sessionId ||
        session['classroom_reference_id'] != classroomReferenceId) {
      throw const GpsFailure(
        'session_changed',
        'The session changed. Refresh and start a new check-in.',
      );
    }
    return GpsPolicy.fromJson(session['gps']);
  }

  final policy = await refresh();
  try {
    return PreparedLocation(policy, await verifier.check(policy));
  } on GpsFailure {
    final latest = await refresh();
    if (latest.enabled) rethrow;
    return PreparedLocation(latest, null);
  }
}
