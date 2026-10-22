import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import '../../domain/models/driver_models.dart';

enum DriverLocationProblem { disabled, denied, deniedForever }

class DriverLocationException implements Exception {
  final DriverLocationProblem problem;
  const DriverLocationException(this.problem);
}

abstract class DriverLocationSource {
  Future<DriverCoordinates> current();
  Future<void> openSettings(DriverLocationProblem? problem);
}

abstract class DeviceLocationProvider {
  Future<bool> servicesEnabled();
  Future<LocationPermission> checkPermission();
  Future<LocationPermission> requestPermission();
  Future<DriverCoordinates> currentCoordinates();
  Future<void> openAppSettings();
  Future<void> openLocationSettings();
}

class GeolocatorDeviceLocationProvider implements DeviceLocationProvider {
  @override
  Future<bool> servicesEnabled() => Geolocator.isLocationServiceEnabled();
  @override
  Future<LocationPermission> checkPermission() => Geolocator.checkPermission();
  @override
  Future<LocationPermission> requestPermission() =>
      Geolocator.requestPermission();
  @override
  Future<DriverCoordinates> currentCoordinates() async {
    final accuracy = await Geolocator.getLocationAccuracy();
    final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 7)));
    if (kDebugMode) {
      debugPrint('GoMoveGPS source=geolocator result=sampled '
          'lat=${position.latitude} lon=${position.longitude} '
          'sampledAt=${position.timestamp.toUtc().toIso8601String()} '
          'ageMs=${DateTime.now().toUtc().difference(position.timestamp.toUtc()).inMilliseconds} '
          'accuracy=${position.accuracy}');
    }
    return DriverCoordinates(position.latitude, position.longitude,
        accuracy: position.accuracy,
        bearing: position.heading,
        sampledAt: position.timestamp,
        approximate: accuracy == LocationAccuracyStatus.reduced);
  }

  @override
  Future<void> openAppSettings() async {
    await Geolocator.openAppSettings();
  }

  @override
  Future<void> openLocationSettings() async {
    await Geolocator.openLocationSettings();
  }
}

class GeolocatorDriverLocationSource implements DriverLocationSource {
  final DeviceLocationProvider _provider;
  GeolocatorDriverLocationSource({DeviceLocationProvider? provider})
      : _provider = provider ?? GeolocatorDeviceLocationProvider();

  @override
  Future<DriverCoordinates> current() async {
    if (!await _provider.servicesEnabled()) {
      throw const DriverLocationException(DriverLocationProblem.disabled);
    }
    var permission = await _provider.checkPermission();
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.unableToDetermine) {
      permission = await _provider.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) {
      throw const DriverLocationException(DriverLocationProblem.deniedForever);
    }
    if (permission != LocationPermission.whileInUse &&
        permission != LocationPermission.always) {
      throw const DriverLocationException(DriverLocationProblem.denied);
    }
    return _provider.currentCoordinates();
  }

  @override
  Future<void> openSettings(DriverLocationProblem? problem) async {
    if (problem == DriverLocationProblem.disabled) {
      await _provider.openLocationSettings();
    } else {
      await _provider.openAppSettings();
    }
  }
}
