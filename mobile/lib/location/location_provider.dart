/// A single foreground capture. Implementations must not start subscriptions.
abstract interface class LocationProvider {
  Future<LocationSample> currentPosition();
}

/// Local only: deliberately has no JSON serializer for raw device coordinates.
class LocationSample {
  const LocationSample({
    required this.latitude,
    required this.longitude,
    required this.accuracyM,
    required this.capturedAt,
    this.isMocked = false,
  });

  final double latitude;
  final double longitude;
  final double accuracyM;

  /// Unix seconds, using the provider's sample time, not request completion time.
  final double capturedAt;
  final bool isMocked;
}

class GpsFailure implements Exception {
  const GpsFailure(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message;
}
