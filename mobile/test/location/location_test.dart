import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:classsweep/location/location.dart';

const epoch = 1800000000.0;
final clock = DateTime.fromMillisecondsSinceEpoch(
  (epoch * 1000).toInt(),
  isUtc: true,
);

Map<String, dynamic> policyJson({
  double latitude = 0,
  double longitude = 0,
  double radius = 100,
}) => {
  'enabled': true,
  'latitude': latitude,
  'longitude': longitude,
  'accuracy_m': 5,
  'captured_at': epoch - 600,
  'radius_m': radius,
};

LocationSample sample({
  double latitude = 0,
  double longitude = 0,
  double accuracy = 5,
  double capturedAt = epoch,
  bool mocked = false,
}) => LocationSample(
  latitude: latitude,
  longitude: longitude,
  accuracyM: accuracy,
  capturedAt: capturedAt,
  isMocked: mocked,
);

class FakeProvider implements LocationProvider {
  FakeProvider(this.value);
  LocationSample value;
  int calls = 0;
  Object? error;
  @override
  Future<LocationSample> currentPosition() async {
    calls++;
    if (error != null) throw error!;
    return value;
  }
}

Matcher failure(String code) =>
    isA<GpsFailure>().having((e) => e.code, 'code', code);

void main() {
  late FakeProvider provider;
  late LocationVerifier verifier;
  setUp(() {
    provider = FakeProvider(sample());
    verifier = LocationVerifier(provider: provider, now: () => clock);
  });

  test(
    'disabled returns null with zero requests, even if the provider would fail',
    () async {
      provider.error = StateError('Location must not be touched');
      final policy = GpsPolicy.fromJson({'enabled': false});
      expect(await verifier.check(policy), isNull);
      expect(provider.calls, 0);
      expect(policy.toJson(), {'enabled': false});
      // Raw surplus data never survives a disabled policy.
      final disabled = GpsPolicy.fromJson({
        'enabled': false,
        'latitude': double.nan,
      });
      expect(await verifier.check(disabled), isNull);
      expect(disabled.latitude, isNull);
      expect(disabled.toJson(), {'enabled': false});
      expect(provider.calls, 0);
    },
  );

  test(
    'same point returns a coordinate-free report with Unix seconds',
    () async {
      final report = await verifier.check(GpsPolicy.fromJson(policyJson()));
      expect(report!.toJson(), {
        'distance_m': 0.0,
        'accuracy_m': 5.0,
        'captured_at': epoch,
      });
      expect(provider.calls, 1);
      // Stored centers may be older than 60 seconds; samples may not.
      expect(GpsPolicy.fromJson(policyJson()).capturedAt, epoch - 600);
    },
  );

  test('nearby point is about 55.6m away', () async {
    provider.value = sample(latitude: 0.0005);
    final report = await verifier.check(GpsPolicy.fromJson(policyJson()));
    expect(report!.distanceM, closeTo(55.59746, 0.001));
  });

  test('point outside radius fails locally', () async {
    provider.value = sample(latitude: 0.001);
    await expectLater(
      verifier.check(GpsPolicy.fromJson(policyJson())),
      throwsA(failure('outside_radius')),
    );
  });

  test('radius boundary is inclusive and accuracy never expands it', () async {
    // Longitude at the equator gives an independently constructed 100m arc.
    final boundaryLon = 100 / 6371000 * 180 / math.pi;
    provider.value = sample(longitude: boundaryLon * (1 - 1e-10), accuracy: 50);
    expect(
      (await verifier.check(GpsPolicy.fromJson(policyJson())))!.distanceM,
      closeTo(100, 1e-6),
    );
    provider.value = sample(longitude: boundaryLon * 1.000001, accuracy: 50);
    await expectLater(
      verifier.check(GpsPolicy.fromJson(policyJson())),
      throwsA(failure('outside_radius')),
    );
    // An exact computed boundary must also pass, without a fuzzy expansion.
    final exact = haversineDistanceM(0, 0, 0, boundaryLon);
    provider.value = sample(longitude: boundaryLon);
    expect(
      await verifier.check(GpsPolicy.fromJson(policyJson(radius: exact))),
      isNotNull,
    );
  });

  test(
    'antimeridian crossing uses short arc and antipodes stay finite',
    () async {
      provider.value = sample(longitude: -179.9998);
      final report = await verifier.check(
        GpsPolicy.fromJson(policyJson(longitude: 179.9998)),
      );
      expect(report!.distanceM, closeTo(44.47797, 0.001));
      expect(
        haversineDistanceM(90, 180, -90, -180),
        closeTo(math.pi * 6371000, 0.001),
      );
    },
  );

  for (final radius in [25.0, 100.0, 1000.0]) {
    test(
      'accuracy at limit is accepted and above limit fails for radius $radius',
      () async {
        final limit = math.min(radius / 2, 100).toDouble();
        provider.value = sample(accuracy: limit);
        expect(
          await verifier.check(GpsPolicy.fromJson(policyJson(radius: radius))),
          isNotNull,
        );
        provider.value = sample(accuracy: limit + 0.01);
        await expectLater(
          verifier.check(GpsPolicy.fromJson(policyJson(radius: radius))),
          throwsA(failure('poor_accuracy')),
        );
      },
    );
  }

  for (final accuracy in [-1.0, double.nan, double.infinity]) {
    test('invalid accuracy $accuracy fails', () async {
      provider.value = sample(accuracy: accuracy);
      await expectLater(
        verifier.check(GpsPolicy.fromJson(policyJson())),
        throwsA(failure('poor_accuracy')),
      );
    });
  }

  test(
    'timestamp accepts exactly 60s old and 15s ahead, rejects beyond',
    () async {
      for (final timestamp in [epoch - 60, epoch + 15]) {
        provider.value = sample(capturedAt: timestamp);
        expect(
          await verifier.check(GpsPolicy.fromJson(policyJson())),
          isNotNull,
        );
      }
      provider.value = sample(capturedAt: epoch - 60.001);
      await expectLater(
        verifier.check(GpsPolicy.fromJson(policyJson())),
        throwsA(failure('stale_location')),
      );
      provider.value = sample(capturedAt: epoch + 15.001);
      await expectLater(
        verifier.check(GpsPolicy.fromJson(policyJson())),
        throwsA(failure('future_location')),
      );
    },
  );

  for (final timestamp in [0.0, -1.0, double.nan, double.infinity]) {
    test('invalid timestamp $timestamp fails', () async {
      provider.value = sample(capturedAt: timestamp);
      await expectLater(
        verifier.check(GpsPolicy.fromJson(policyJson())),
        throwsA(failure('invalid_timestamp')),
      );
    });
  }

  for (final point in [
    [91.0, 0.0],
    [-91.0, 0.0],
    [0.0, 181.0],
    [0.0, -181.0],
    [double.nan, 0.0],
    [0.0, double.infinity],
  ]) {
    test('invalid coordinates $point fail', () async {
      provider.value = sample(latitude: point[0], longitude: point[1]);
      await expectLater(
        verifier.check(GpsPolicy.fromJson(policyJson())),
        throwsA(failure('invalid_coordinates')),
      );
    });
  }

  test('mock flag rejected by default and can be explicitly relaxed', () async {
    provider.value = sample(mocked: true);
    await expectLater(
      verifier.check(GpsPolicy.fromJson(policyJson())),
      throwsA(failure('mocked_location')),
    );
    final relaxed = LocationVerifier(
      provider: provider,
      now: () => clock,
      rejectMocked: false,
    );
    expect(await relaxed.check(GpsPolicy.fromJson(policyJson())), isNotNull);
  });

  test(
    'provider failures retain readable codes and timeouts are normalized',
    () async {
      for (final code in [
        'services_disabled',
        'permission_denied',
        'permission_denied_forever',
      ]) {
        provider.error = GpsFailure(code, 'Enable location and retry.');
        await expectLater(
          verifier.check(GpsPolicy.fromJson(policyJson())),
          throwsA(failure(code)),
        );
      }
      provider.error = TimeoutException('No fix');
      await expectLater(
        verifier.check(GpsPolicy.fromJson(policyJson())),
        throwsA(failure('timeout')),
      );
    },
  );

  test(
    'instructor capture samples afresh, defaults radius, rejects stale fix',
    () async {
      expect((await verifier.captureInstructor()).toJson(), {
        'enabled': true,
        'latitude': 0.0,
        'longitude': 0.0,
        'accuracy_m': 5.0,
        'captured_at': epoch,
        'radius_m': 100.0,
      });
      provider.value = sample(latitude: 1);
      expect((await verifier.captureInstructor(200)).latitude, 1);
      expect(provider.calls, 2);
      provider.value = sample(capturedAt: epoch - 61);
      await expectLater(
        verifier.captureInstructor(),
        throwsA(failure('stale_location')),
      );
      expect(provider.calls, 3);
    },
  );

  test('invalid radius rejected before any capture', () async {
    for (final radius in [24.0, 1001.0, double.nan, double.infinity]) {
      await expectLater(
        verifier.captureInstructor(radius),
        throwsA(failure('invalid_radius')),
      );
    }
    expect(provider.calls, 0);
  });

  test('missing and malformed policies fail closed before sampling', () {
    for (final malformed in <Object?>[
      null,
      [],
      'off',
      {},
      {'enabled': 0},
      {'enabled': 'false'},
      {'enabled': true},
      {...policyJson(), 'latitude': '0'},
      {...policyJson(), 'longitude': null},
      {...policyJson(), 'latitude': 91},
      {...policyJson(), 'longitude': 181},
      {...policyJson(), 'accuracy_m': 51},
      {...policyJson(), 'accuracy_m': -1},
      {...policyJson(), 'captured_at': 0},
      {...policyJson(), 'captured_at': double.infinity},
      {...policyJson(), 'radius_m': 24},
      {...policyJson(), 'radius_m': double.nan},
    ]) {
      expect(
        () => GpsPolicy.fromJson(malformed),
        throwsA(isA<GpsFailure>()),
        reason: '$malformed',
      );
    }
    expect(provider.calls, 0);
  });

  test('enabled policy roundtrip and absent radius default', () {
    final json = policyJson(latitude: -90, longitude: 180);
    expect(GpsPolicy.fromJson(json).toJson(), json);
    json.remove('radius_m');
    expect(GpsPolicy.fromJson(json).radiusM, 100);
  });
}
