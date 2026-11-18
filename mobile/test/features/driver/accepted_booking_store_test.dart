import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gomove_mobile/features/driver/data/accepted_booking_store.dart';
import 'package:gomove_mobile/features/driver/domain/models/driver_models.dart';
import 'package:mocktail/mocktail.dart';

class _Storage extends Mock implements FlutterSecureStorage {}

void main() {
  const userA = 'user-A';
  const userB = 'user-B';
  final offer = DriverOffer(
      offerPublicId: 'offer-1',
      bookingPublicId: 'booking-1',
      pickupLatitude: 0,
      pickupLongitude: 0,
      dropoffLatitude: 1,
      dropoffLongitude: 1,
      vehicleType: 'MOTORBIKE',
      currency: 'VND',
      finalFare: '17460.00',
      expiresAt: DateTime.utc(2026, 11, 17));
  late _Storage storage;
  late Map<String, String> values;
  late SecureAcceptedBookingStore store;

  setUp(() {
    storage = _Storage();
    values = {};
    when(() => storage.read(key: any(named: 'key'))).thenAnswer(
        (call) async => values[call.namedArguments[#key] as String]);
    when(() =>
            storage.write(key: any(named: 'key'), value: any(named: 'value')))
        .thenAnswer((call) async {
      values[call.namedArguments[#key] as String] =
          call.namedArguments[#value] as String;
    });
    when(() => storage.delete(key: any(named: 'key'))).thenAnswer((call) async {
      values.remove(call.namedArguments[#key] as String);
    });
    store = SecureAcceptedBookingStore(storage: storage);
  });

  test('Pending intent survives a new store and remains account-scoped',
      () async {
    await store.write(userA,
        AcceptedBookingRecord('driver-1', offer, pendingAcceptance: true));

    final restarted = SecureAcceptedBookingStore(storage: storage);
    final saved = await restarted.read(userA);

    expect(saved?.pendingAcceptance, isTrue);
    expect(saved?.driverPublicId, 'driver-1');
    expect(saved?.offer.bookingPublicId, 'booking-1');
    expect(saved?.offer.finalFare, '17460.00');
    expect(await restarted.read(userB), isNull);
  });

  test('Confirmation promotes the same key without duplicating the trip',
      () async {
    await store.write(userA,
        AcceptedBookingRecord('driver-1', offer, pendingAcceptance: true));
    await store.write(userA, AcceptedBookingRecord('driver-1', offer));

    expect(values, hasLength(1));
    expect((await store.read(userA))?.pendingAcceptance, isFalse);
    expect((await store.read(userA))?.offer.bookingPublicId, 'booking-1');
  });

  test('Legacy accepted records remain compatible without rewriting storage',
      () async {
    final legacy = jsonEncode({
      'userPublicId': userA,
      'driverPublicId': 'driver-1',
      'offer': offer.toJson(),
    });
    values[SecureAcceptedBookingStore.keyFor(userA)] = legacy;

    expect((await store.read(userA))?.pendingAcceptance, isFalse);
    expect(values[SecureAcceptedBookingStore.keyFor(userA)], legacy);
  });

  test('Owner mismatch is rejected without overwriting either account',
      () async {
    await store.write(userA,
        AcceptedBookingRecord('driver-1', offer, pendingAcceptance: true));
    values[SecureAcceptedBookingStore.keyFor(userB)] =
        values[SecureAcceptedBookingStore.keyFor(userA)]!;
    final before = Map<String, String>.from(values);

    await expectLater(store.read(userB), throwsFormatException);

    expect(values, before);
  });

  for (final malformed in [null, 'true', 1]) {
    test('Invalid pending phase $malformed is rejected without deleting intent',
        () async {
      final raw = jsonEncode({
        'userPublicId': userA,
        'driverPublicId': 'driver-1',
        'offer': offer.toJson(),
        'pendingAcceptance': malformed,
      });
      values[SecureAcceptedBookingStore.keyFor(userA)] = raw;

      await expectLater(store.read(userA), throwsFormatException);

      expect(values[SecureAcceptedBookingStore.keyFor(userA)], raw);
    });
  }

  test('Resolving one account preserves the other account handoff', () async {
    await store.write(userA,
        AcceptedBookingRecord('driver-1', offer, pendingAcceptance: true));
    await store.write(userB, AcceptedBookingRecord('driver-2', offer));

    await store.clear(userA);

    expect(await store.read(userA), isNull);
    expect((await store.read(userB))?.driverPublicId, 'driver-2');
    expect((await store.read(userB))?.pendingAcceptance, isFalse);
  });
}
