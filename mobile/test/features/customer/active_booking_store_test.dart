import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gomove_mobile/core/storage/secure_storage_service.dart';
import 'package:gomove_mobile/features/customer/data/active_booking_store.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements FlutterSecureStorage {}

void main() {
  const customerA = '550e8400-e29b-41d4-a716-446655440001';
  const customerB = '550e8400-e29b-41d4-a716-446655440002';
  const bookingA = '550e8400-e29b-41d4-a716-446655440005';
  const bookingB = '550e8400-e29b-41d4-a716-446655440003';
  const newerBookingA = '550e8400-e29b-41d4-a716-446655440004';
  late MockStorage storage;
  late Map<String, String> values;
  late SecureActiveBookingStore bookings;

  setUp(() {
    storage = MockStorage();
    values = {};
    when(() => storage.read(key: any(named: 'key'))).thenAnswer(
      (call) async => values[call.namedArguments[#key] as String],
    );
    when(() => storage.write(
          key: any(named: 'key'),
          value: any(named: 'value'),
        )).thenAnswer((call) async {
      values[call.namedArguments[#key] as String] =
          call.namedArguments[#value] as String;
    });
    when(() => storage.delete(key: any(named: 'key'))).thenAnswer((call) async {
      values.remove(call.namedArguments[#key] as String);
    });
    bookings = SecureActiveBookingStore(storage: storage);
  });

  test('Confirmed Booking reference survives a new store instance', () async {
    await bookings.write(
      customerA,
      const ActiveBookingRecord(
        customerPublicId: customerA,
        bookingPublicId: bookingA,
      ),
    );

    final restarted = SecureActiveBookingStore(storage: storage);
    expect((await restarted.read(customerA))?.bookingPublicId, bookingA);
    expect(await restarted.read(customerB), isNull);
  });

  test('Each account retains its own latest confirmed Booking', () async {
    await bookings.write(
      customerA,
      const ActiveBookingRecord(
        customerPublicId: customerA,
        bookingPublicId: bookingA,
      ),
    );
    await bookings.write(
      customerB,
      const ActiveBookingRecord(
        customerPublicId: customerB,
        bookingPublicId: bookingB,
      ),
    );
    await bookings.write(
      customerA,
      const ActiveBookingRecord(
        customerPublicId: customerA,
        bookingPublicId: newerBookingA,
      ),
    );

    expect((await bookings.read(customerA))?.bookingPublicId, newerBookingA);
    expect((await bookings.read(customerB))?.bookingPublicId, bookingB);
    await bookings.clear(customerB);
    expect((await bookings.read(customerA))?.bookingPublicId, newerBookingA);
    expect(await bookings.read(customerB), isNull);
  });

  test('Owner mismatch and invalid UUID are rejected without overwrite',
      () async {
    await bookings.write(
      customerA,
      const ActiveBookingRecord(
        customerPublicId: customerA,
        bookingPublicId: bookingA,
      ),
    );

    await expectLater(
      bookings.write(
        customerA,
        const ActiveBookingRecord(
          customerPublicId: customerB,
          bookingPublicId: bookingB,
        ),
      ),
      throwsFormatException,
    );
    await expectLater(
      bookings.write(
        customerA,
        const ActiveBookingRecord(
          customerPublicId: customerA,
          bookingPublicId: 'not-a-uuid',
        ),
      ),
      throwsFormatException,
    );
    expect((await bookings.read(customerA))?.bookingPublicId, bookingA);
    expect(await bookings.read(customerB), isNull);
  });

  test('Tampered owner or Booking UUID is not returned', () async {
    values[SecureActiveBookingStore.keyFor(customerA)] = jsonEncode({
      'customerPublicId': customerB,
      'bookingPublicId': bookingB,
    });
    await expectLater(bookings.read(customerA), throwsFormatException);
    values[SecureActiveBookingStore.keyFor(customerA)] = jsonEncode({
      'customerPublicId': customerA,
      'bookingPublicId': 'not-a-uuid',
    });
    await expectLater(bookings.read(customerA), throwsFormatException);
  });

  test('Auth logout clears tokens, not the account-scoped Booking hint',
      () async {
    final auth = SecureStorageServiceImpl(storage: storage);
    await auth.saveTokens(
      accessToken: 'access',
      refreshToken: 'refresh',
      userPublicId: customerA,
    );
    await bookings.write(
      customerA,
      const ActiveBookingRecord(
        customerPublicId: customerA,
        bookingPublicId: bookingA,
      ),
    );
    await auth.clearAll();

    expect(await auth.getAccessToken(), isNull);
    expect((await bookings.read(customerA))?.bookingPublicId, bookingA);
    expect(await bookings.read(customerB), isNull);
  });
}
