import 'dart:async';

import 'package:geolocator/geolocator.dart';

import 'location_provider.dart';

/// One foreground request. No position streams, background settings or cache.
class GeolocatorProvider implements LocationProvider {
  const GeolocatorProvider();
  static const timeLimit = Duration(seconds: 20);

  @override
  Future<LocationSample> currentPosition() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw const GpsFailure(
          'services_disabled',
          'Location services are off. Turn on Location in your phone settings, then retry.',
        );
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.deniedForever) {
        throw const GpsFailure(
          'permission_denied_forever',
          'Location permission is blocked. Open your phone settings, allow location for ClassSweep while using the app, then retry.',
        );
      }
      if (permission != LocationPermission.whileInUse &&
          permission != LocationPermission.always) {
        throw const GpsFailure(
          'permission_denied',
          'Location permission was not granted. Allow location while using ClassSweep to use GPS, then retry.',
        );
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: timeLimit,
        ),
      );
      return LocationSample(
        latitude: position.latitude,
        longitude: position.longitude,
        accuracyM: position.accuracy,
        capturedAt: position.timestamp.millisecondsSinceEpoch / 1000,
        isMocked: position.isMocked,
      );
    } on GpsFailure {
      rethrow;
    } on TimeoutException {
      throw const GpsFailure(
        'timeout',
        'Finding your location took too long. Move near a window or outdoors and retry.',
      );
    } on LocationServiceDisabledException {
      throw const GpsFailure(
        'services_disabled',
        'Location services are off. Turn on Location in your phone settings, then retry.',
      );
    } on PermissionDeniedException {
      throw const GpsFailure(
        'permission_denied',
        'Location permission was not granted. Allow location in your phone settings, then retry.',
      );
    } catch (_) {
      throw const GpsFailure(
        'unavailable',
        'Your phone could not get a location. Check location services and app permissions, then retry.',
      );
    }
  }
}
