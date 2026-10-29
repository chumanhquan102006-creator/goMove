import 'package:flutter_test/flutter_test.dart';
import 'package:gomove_mobile/features/customer/presentation/formatters.dart';
import 'package:gomove_mobile/features/trip/domain/models/trip_eta.dart';

Map<String, dynamic> etaJson({
  String status = 'DRIVER_ACCEPTED',
  String phase = 'PICKUP',
  String availability = 'AVAILABLE',
  Object? distanceMeters = 950.2,
  Object? durationSeconds = 240.1,
}) =>
    {
      'bookingPublicId': 'booking-1',
      'status': status,
      'phase': phase,
      'availability': availability,
      'reason': availability == 'AVAILABLE' ? null : 'GPS_STALE',
      'distanceMeters': availability == 'AVAILABLE' ? distanceMeters : null,
      'durationSeconds': availability == 'AVAILABLE' ? durationSeconds : null,
      'calculatedAt':
          availability == 'AVAILABLE' ? '2026-10-28T10:00:00Z' : null,
      'locationUpdatedAt':
          availability == 'AVAILABLE' ? '2026-10-28T09:59:59Z' : null,
      'expiresAt': availability == 'AVAILABLE' ? '2026-10-28T10:00:30Z' : null,
      'servedAt': '2026-10-28T10:00:00Z',
    };

void main() {
  test('Parses available pickup ETA and rejects phase/status/expiry mismatch',
      () {
    final eta = TripEta.fromJson(etaJson());
    expect(eta.distanceMeters, 950.2);
    expect(eta.durationSeconds, 240.1);
    expect(eta.isAvailableFor('booking-1', 'DRIVER_ACCEPTED'), isTrue);
    expect(eta.remainingAfter(const Duration(seconds: 29)),
        const Duration(seconds: 1));
    expect(eta.remainingAfter(const Duration(seconds: 30)), isNull);
    expect(eta.isAvailableFor('booking-2', 'DRIVER_ACCEPTED'), isFalse);
    expect(eta.isAvailableFor('booking-1', 'IN_PROGRESS'), isFalse);

    final destination =
        TripEta.fromJson(etaJson(status: 'IN_PROGRESS', phase: 'DESTINATION'));
    expect(destination.isAvailableFor('booking-1', 'IN_PROGRESS'), isTrue);
  });

  test('Unavailable response is neutral and malformed quantities fail', () {
    final unavailable =
        TripEta.fromJson(etaJson(availability: 'UNAVAILABLE', phase: 'PICKUP'));
    expect(unavailable.reason, 'GPS_STALE');
    expect(unavailable.isAvailableFor('booking-1', 'DRIVER_ACCEPTED'), isFalse);
    expect(unavailable.remainingAfter(Duration.zero), isNull);
    expect(() => TripEta.fromJson(etaJson(distanceMeters: -1)),
        throwsA(isA<FormatException>()));
    expect(() => TripEta.fromJson(etaJson(durationSeconds: double.infinity)),
        throwsA(isA<FormatException>()));
    expect(() => TripEta.fromJson(etaJson(phase: 'NONE')),
        throwsA(isA<FormatException>()));
    final missingServedAt = etaJson()..remove('servedAt');
    expect(() => TripEta.fromJson(missingServedAt),
        throwsA(isA<FormatException>()));
    final expiredAtServe = etaJson()..['servedAt'] = '2026-10-28T10:00:30Z';
    expect(() => TripEta.fromJson(expiredAtServe),
        throwsA(isA<FormatException>()));
  });

  test('Cached ETA uses server residual TTL, independent of device clock', () {
    final cached = etaJson()..['servedAt'] = '2026-10-28T10:00:20Z';
    final eta = TripEta.fromJson(cached);
    expect(eta.remainingAfter(Duration.zero), const Duration(seconds: 10));
    expect(eta.remainingAfter(const Duration(seconds: 3)),
        const Duration(seconds: 7));
    expect(eta.remainingAfter(const Duration(seconds: 11)), isNull);
  });

  test('Approximate road distance and time use Vietnamese readable units', () {
    expect(roadDistanceLabel(4), 'dưới 10 m');
    expect(roadDistanceLabel(900), '900 m');
    expect(roadDistanceLabel(999), '1 km');
    expect(roadDistanceLabel(3500), '3,5 km');
    expect(roadDistanceLabel(double.nan), 'Chưa rõ');
    expect(roadDurationLabel(45), 'dưới 1 phút');
    expect(roadDurationLabel(240.1), '5 phút');
    expect(roadDurationLabel(double.infinity), 'Chưa rõ');
    // Existing whole-VND fare formatting remains independent of ETA.
    expect(vnd('16500.00'), '16.500 VND');
  });
}
