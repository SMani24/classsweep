import 'dart:async';

import 'package:classsweep/location/location.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

class FakeGeolocator extends GeolocatorPlatform {
  bool services = true;
  LocationPermission permission = LocationPermission.whileInUse;
  LocationPermission requested = LocationPermission.whileInUse;
  int serviceChecks = 0,
      permissionChecks = 0,
      permissionRequests = 0,
      captures = 0;
  LocationSettings? settings;
  Object? error;

  @override
  Future<bool> isLocationServiceEnabled() async {
    serviceChecks++;
    return services;
  }

  @override
  Future<LocationPermission> checkPermission() async {
    permissionChecks++;
    return permission;
  }

  @override
  Future<LocationPermission> requestPermission() async {
    permissionRequests++;
    return requested;
  }

  @override
  Future<Position> getCurrentPosition({
    LocationSettings? locationSettings,
  }) async {
    captures++;
    settings = locationSettings;
    if (error != null) throw error!;
    return Position(
      latitude: 1,
      longitude: 2,
      accuracy: 3,
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        1800000000123,
        isUtc: true,
      ),
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
      isMocked: true,
    );
  }
}

void main() {
  late GeolocatorPlatform original;
  late FakeGeolocator platform;
  setUp(() {
    original = GeolocatorPlatform.instance;
    platform = FakeGeolocator();
    GeolocatorPlatform.instance = platform;
  });
  tearDown(() => GeolocatorPlatform.instance = original);
  Matcher failure(String code) =>
      isA<GpsFailure>().having((e) => e.code, 'code', code);

  test('single current foreground fix uses high accuracy, 20s limit and provider timestamp', () async {
    final sample = await const GeolocatorProvider().currentPosition();
    expect(platform.captures, 1);
    expect(platform.permissionRequests, 0);
    expect(platform.settings!.accuracy, LocationAccuracy.high);
    expect(platform.settings!.timeLimit, const Duration(seconds: 20));
    expect(sample.latitude, 1);
    expect(sample.longitude, 2);
    expect(sample.accuracyM, 3);
    expect(sample.capturedAt, 1800000000.123);
    expect(sample.isMocked, isTrue);
  });

  test(
    'disabled policy never reaches geolocator service or permission APIs',
    () async {
      expect(
        await LocationVerifier().check(const GpsPolicy.disabled()),
        isNull,
      );
      expect(platform.serviceChecks, 0);
      expect(platform.permissionChecks, 0);
      expect(platform.permissionRequests, 0);
      expect(platform.captures, 0);
    },
  );

  test(
    'services off returns readable error before permission request',
    () async {
      platform.services = false;
      await expectLater(
        const GeolocatorProvider().currentPosition(),
        throwsA(failure('services_disabled')),
      );
      expect(platform.permissionChecks, 0);
      expect(platform.permissionRequests, 0);
      expect(platform.captures, 0);
    },
  );

  test(
    'denied permission requested once then captures only when granted',
    () async {
      platform.permission = LocationPermission.denied;
      await const GeolocatorProvider().currentPosition();
      expect(platform.permissionRequests, 1);
      expect(platform.captures, 1);
    },
  );

  for (final denied in [
    LocationPermission.denied,
    LocationPermission.deniedForever,
  ]) {
    test('request result $denied prevents capture', () async {
      platform.permission = LocationPermission.denied;
      platform.requested = denied;
      await expectLater(
        const GeolocatorProvider().currentPosition(),
        throwsA(
          failure(
            denied == LocationPermission.deniedForever
                ? 'permission_denied_forever'
                : 'permission_denied',
          ),
        ),
      );
      expect(platform.permissionRequests, 1);
      expect(platform.captures, 0);
    });
  }

  test('permanently denied never repeats the permission prompt', () async {
    platform.permission = LocationPermission.deniedForever;
    await expectLater(
      const GeolocatorProvider().currentPosition(),
      throwsA(failure('permission_denied_forever')),
    );
    expect(platform.permissionRequests, 0);
    expect(platform.captures, 0);
  });

  test(
    'position timeout and unexpected device errors become friendly failures',
    () async {
      platform.error = TimeoutException('not for display');
      await expectLater(
        const GeolocatorProvider().currentPosition(),
        throwsA(failure('timeout')),
      );
      platform.error = StateError('raw platform detail');
      await expectLater(
        const GeolocatorProvider().currentPosition(),
        throwsA(failure('unavailable')),
      );
    },
  );
}
