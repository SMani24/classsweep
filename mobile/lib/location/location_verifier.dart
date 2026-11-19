import 'dart:async';

import 'geolocator_provider.dart';
import 'gps_policy.dart';
import 'location_provider.dart';

/// Inject a provider and clock to verify deterministically without device GPS.
class LocationVerifier {
  LocationVerifier({
    LocationProvider? provider,
    DateTime Function()? now,
    this.rejectMocked = true,
  }) : _provider = provider ?? const GeolocatorProvider(),
       _now = now ?? DateTime.now;

  final LocationProvider _provider;
  final DateTime Function() _now;

  /// OS mock indicators are best effort and do not prove physical presence.
  final bool rejectMocked;

  Future<LocationSample> _capture(double radius) async {
    final LocationSample sample;
    try {
      sample = await _provider.currentPosition();
    } on TimeoutException {
      throw const GpsFailure(
        'timeout',
        'Finding your location took too long. Move near a window or outdoors and retry.',
      );
    }
    validateSample(
      sample,
      radiusM: radius,
      now: _now(),
      rejectMocked: rejectMocked,
    );
    return sample;
  }

  /// Returns null without sampling or requesting permissions when disabled.
  /// Throws [GpsFailure] for poor/stale/invalid samples or outside the radius.
  Future<LocationReport?> check(GpsPolicy policy) async {
    if (!policy.enabled) return null;
    final sample = await _capture(policy.radiusM);
    final distance = haversineDistanceM(
      policy.latitude!,
      policy.longitude!,
      sample.latitude,
      sample.longitude,
    );
    if (distance > policy.radiusM) {
      throw GpsFailure(
        'outside_radius',
        'You are about ${distance.round()} m from the session center. Move within ${policy.radiusM.round()} m and retry.',
      );
    }
    return LocationReport(
      distanceM: distance,
      accuracyM: sample.accuracyM,
      capturedAt: sample.capturedAt,
    );
  }

  /// Always requests a current position, never a stored center or last-known fix.
  Future<GpsPolicy> captureInstructor([
    double radius = GpsPolicy.defaultRadiusM,
  ]) async {
    validateRadius(radius);
    final sample = await _capture(radius);
    return GpsPolicy.fromJson({
      'enabled': true,
      'latitude': sample.latitude,
      'longitude': sample.longitude,
      'accuracy_m': sample.accuracyM,
      'captured_at': sample.capturedAt,
      'radius_m': radius,
    });
  }
}
