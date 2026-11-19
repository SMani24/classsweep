import 'package:classsweep/location/location.dart';
import 'package:classsweep/network/attendance_location.dart';
import 'package:flutter_test/flutter_test.dart';

class CountingProvider implements LocationProvider {
  int calls = 0;
  bool fail = false;
  final DateTime now;
  CountingProvider(this.now);
  @override
  Future<LocationSample> currentPosition() async {
    calls++;
    if (fail) throw const GpsFailure('permission_denied', 'Location denied');
    return LocationSample(
      latitude: 35.7,
      longitude: 51.4,
      accuracyM: 10,
      capturedAt: now.millisecondsSinceEpoch / 1000,
    );
  }
}

void main() {
  final now = DateTime.utc(2026, 11, 19);
  final enabled = {
    'enabled': true,
    'latitude': 35.7,
    'longitude': 51.4,
    'accuracy_m': 10.0,
    'radius_m': 100.0,
    'captured_at': now.millisecondsSinceEpoch / 1000,
  };
  Map<String, dynamic> session(Object? policy) => {
    'id': 'session-1',
    'classroom_reference_id': 'room-1',
    'gps': policy,
  };
  Future<PreparedLocation> run(
    Future<Map<String, dynamic>> Function() refresh,
    CountingProvider source,
  ) => prepareAttendanceLocation(
    refreshSession: refresh,
    sessionId: 'session-1',
    classroomReferenceId: 'room-1',
    verifier: LocationVerifier(provider: source, now: () => now),
  );

  test('live disabled session never requests a position even when provider would fail', () async {
    final provider = CountingProvider(now)..fail = true;
    final value = await run(() async => session({'enabled': false}), provider);
    expect(value.report, isNull);
    expect(value.policy.enabled, isFalse);
    expect(provider.calls, 0);
  });
  test('enabled session returns only processed distance and accuracy plus capture time', () async {
    final provider = CountingProvider(now);
    final value = await run(() async => session(enabled), provider);
    expect(provider.calls, 1);
    expect(value.report!.distanceM, 0);
    expect(value.report!.toJson().keys.toSet(), {
      'distance_m',
      'accuracy_m',
      'captured_at',
    });
  });
  test(
    'permission failure is bypassed only after explicit live disable',
    () async {
      final provider = CountingProvider(now)..fail = true;
      var refreshes = 0;
      final value = await run(
        () async => session(++refreshes == 1 ? enabled : {'enabled': false}),
        provider,
      );
      expect(value.policy.enabled, isFalse);
      expect(value.report, isNull);
      expect(refreshes, 2);
      expect(provider.calls, 1);
    },
  );
  test(
    'failed capture with unchanged enabled policy remains a failure',
    () async {
      final provider = CountingProvider(now)..fail = true;
      await expectLater(
        run(() async => session(enabled), provider),
        throwsA(
          isA<GpsFailure>().having((e) => e.code, 'code', 'permission_denied'),
        ),
      );
    },
  );
  test('missing policy, different session or different classroom cannot silently pass', () async {
    final provider = CountingProvider(now);
    for (final payload in [
      session(null),
      {...session(enabled), 'id': 'other'},
      {...session(enabled), 'classroom_reference_id': 'other'},
    ]) {
      await expectLater(
        run(() async => payload, provider),
        throwsA(isA<GpsFailure>()),
      );
    }
    expect(provider.calls, 0);
  });
}
