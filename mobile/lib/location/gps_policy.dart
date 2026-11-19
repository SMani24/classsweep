import 'dart:math' as math;

import 'location_provider.dart';

/// Immutable server policy. A disabled policy contains no retained center.
class GpsPolicy {
  const GpsPolicy.disabled()
    : enabled = false,
      latitude = null,
      longitude = null,
      accuracyM = null,
      capturedAt = null,
      radiusM = defaultRadiusM;

  const GpsPolicy._({
    required this.latitude,
    required this.longitude,
    required this.accuracyM,
    required this.capturedAt,
    required this.radiusM,
  }) : enabled = true;

  static const double defaultRadiusM = 100;
  final bool enabled;
  final double? latitude, longitude, accuracyM, capturedAt;
  final double radiusM;
  double get maximumAccuracyM => math.min(radiusM / 2, 100);

  /// Malformed or absent policies fail closed, instead of silently disabling.
  /// Disabled policies ignore surplus fields and serialize as {enabled:false}.
  /// Enabled radius defaults to 100m, matching the server contract.
  factory GpsPolicy.fromJson(Object? json) {
    if (json is! Map || json['enabled'] is! bool) {
      throw const GpsFailure(
        'invalid_policy',
        'The session GPS policy is unreadable. Refresh the session.',
      );
    }
    if (json['enabled'] == false) return const GpsPolicy.disabled();
    double number(String key) {
      final value = json[key];
      if (value is! num || !value.isFinite) {
        throw const GpsFailure(
          'invalid_policy',
          'The session GPS policy is unreadable. Refresh the session.',
        );
      }
      return value.toDouble();
    }

    final radius = json.containsKey('radius_m')
        ? number('radius_m')
        : defaultRadiusM;
    validateRadius(radius);
    final lat = number('latitude'), lon = number('longitude');
    validateCoordinates(lat, lon);
    final accuracy = number('accuracy_m'), captured = number('captured_at');
    if (accuracy < 0 || accuracy > math.min(radius / 2, 100) || captured <= 0) {
      throw const GpsFailure(
        'invalid_policy',
        'The session GPS center is invalid. Ask the instructor to create a new session.',
      );
    }
    return GpsPolicy._(
      latitude: lat,
      longitude: lon,
      accuracyM: accuracy,
      capturedAt: captured,
      radiusM: radius,
    );
  }

  Map<String, dynamic> toJson() => !enabled
      ? {'enabled': false}
      : {
          'enabled': true,
          'latitude': latitude,
          'longitude': longitude,
          'accuracy_m': accuracyM,
          'captured_at': capturedAt,
          'radius_m': radiusM,
        };
}

void validateRadius(double radius) {
  if (!radius.isFinite || radius < 25 || radius > 1000) {
    throw const GpsFailure(
      'invalid_radius',
      'Choose a GPS radius between 25 and 1000 meters.',
    );
  }
}

void validateCoordinates(double latitude, double longitude) {
  if (!latitude.isFinite ||
      !longitude.isFinite ||
      latitude < -90 ||
      latitude > 90 ||
      longitude < -180 ||
      longitude > 180) {
    throw const GpsFailure(
      'invalid_coordinates',
      'The location coordinates are invalid. Try capturing your location again.',
    );
  }
}

/// Great-circle distance, including across the antimeridian. Inputs are degrees.
double haversineDistanceM(double lat1, double lon1, double lat2, double lon2) {
  validateCoordinates(lat1, lon1);
  validateCoordinates(lat2, lon2);
  const radians = math.pi / 180;
  final dLat = (lat2 - lat1) * radians, dLon = (lon2 - lon1) * radians;
  final a =
      math.pow(math.sin(dLat / 2), 2) +
      math.cos(lat1 * radians) *
          math.cos(lat2 * radians) *
          math.pow(math.sin(dLon / 2), 2);
  return 6371000 * 2 * math.asin(math.sqrt(a.clamp(0.0, 1.0)));
}

/// Pure sample validation. The clock is supplied by the caller for testability.
void validateSample(
  LocationSample sample, {
  required double radiusM,
  required DateTime now,
  bool rejectMocked = true,
}) {
  validateRadius(radiusM);
  validateCoordinates(sample.latitude, sample.longitude);
  if (!sample.accuracyM.isFinite ||
      sample.accuracyM < 0 ||
      sample.accuracyM > math.min(radiusM / 2, 100)) {
    throw const GpsFailure(
      'poor_accuracy',
      'Location accuracy is too low for this radius. Move near a window or outdoors and retry. The instructor can disable GPS or create a session with a wider radius.',
    );
  }
  if (!sample.capturedAt.isFinite || sample.capturedAt <= 0) {
    throw const GpsFailure(
      'invalid_timestamp',
      'The location timestamp is invalid. Check your phone clock and retry.',
    );
  }
  final age = now.millisecondsSinceEpoch / 1000 - sample.capturedAt;
  if (age > 60) {
    throw const GpsFailure(
      'stale_location',
      'The phone returned an old location. Try again for a fresh location.',
    );
  }
  if (age < -15) {
    throw const GpsFailure(
      'future_location',
      'The location time is ahead of your phone clock. Enable automatic date and time, then retry.',
    );
  }
  if (rejectMocked && sample.isMocked) {
    throw const GpsFailure(
      'mocked_location',
      'The phone reported a simulated location. Turn off mock location and retry.',
    );
  }
}

/// Privacy boundary: serializes only the attendance summary, never coordinates.
class LocationReport {
  const LocationReport({
    required this.distanceM,
    required this.accuracyM,
    required this.capturedAt,
  });
  final double distanceM, accuracyM, capturedAt;
  Map<String, dynamic> toJson() => {
    'distance_m': distanceM,
    'accuracy_m': accuracyM,
    'captured_at': capturedAt,
  };
}
