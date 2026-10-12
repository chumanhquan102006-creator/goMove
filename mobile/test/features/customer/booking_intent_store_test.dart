import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gomove_mobile/core/constants/storage_keys.dart';
import 'package:gomove_mobile/core/storage/secure_storage_service.dart';
import 'package:gomove_mobile/features/customer/data/booking_intent_store.dart';
import 'package:gomove_mobile/features/customer/domain/models/booking_intent.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements FlutterSecureStorage {}

void main() {
  const a = 'customer-a';
  const b = 'customer-b';
  const quote = 'quote-1';
  late MockStorage storage;
  late Map<String, String> values;
  late SecureBookingIntentStore intents;

  setUp(() {
    storage = MockStorage();
    values = {};
    when(() => storage.read(key: any(named: 'key'))).thenAnswer(
        (call) async => values[call.namedArguments[#key] as String]);
    when(() => storage.write(
            key: any(named: 'key'), value: any(named: 'value')))
        .thenAnswer((call) async {
      values[call.namedArguments[#key] as String] =
          call.namedArguments[#value] as String;
    });
    when(() => storage.delete(key: any(named: 'key'))).thenAnswer((call) async {
      values.remove(call.namedArguments[#key] as String);
    });
    intents = SecureBookingIntentStore(storage: storage);
  });

  test('Legacy intent migrates only for its owner without changing key',
      () async {
    values[SecureBookingIntentStore.legacyKey] = jsonEncode(
        const BookingIntent(
                customerPublicId: a,
                quotePublicId: quote,
                idempotencyKey: 'original-key')
            .toJson());

    expect(await intents.read(b), isNull);
    expect(values.containsKey(SecureBookingIntentStore.legacyKey), isTrue);
    await intents.write(const BookingIntent(
        customerPublicId: b,
        quotePublicId: quote,
        idempotencyKey: 'key-b'));
    expect((await intents.read(b))?.idempotencyKey, 'key-b');
    await intents.clear(b);
    expect(values.containsKey(SecureBookingIntentStore.legacyKey), isTrue);
    final recovered = await intents.read(a);
    expect(recovered?.idempotencyKey, 'original-key');
    expect(values.containsKey(SecureBookingIntentStore.legacyKey), isFalse);
    expect(values[SecureBookingIntentStore.keyFor(a)], isNotNull);
    expect(await intents.read(b), isNull);
  });

  test('Different accounts keep separate intents; B clear cannot delete A',
      () async {
    await intents.write(const BookingIntent(
        customerPublicId: a,
        quotePublicId: quote,
        idempotencyKey: 'key-a'));
    await intents.write(const BookingIntent(
        customerPublicId: b,
        quotePublicId: quote,
        idempotencyKey: 'key-b'));
    await intents.clear(b);
    expect((await intents.read(a))?.idempotencyKey, 'key-a');
    expect(await intents.read(b), isNull);
    await expectLater(
        intents.write(const BookingIntent(
            customerPublicId: a,
            quotePublicId: quote,
            idempotencyKey: 'new-key')),
        throwsStateError);
    expect((await intents.read(a))?.idempotencyKey, 'key-a');
  });

  test('Auth cleanup removes only session keys, not unresolved intents',
      () async {
    final auth = SecureStorageServiceImpl(storage: storage);
    await auth.saveTokens(accessToken: 'access', refreshToken: 'refresh');
    await auth.saveUserPublicId(a);
    await intents.write(const BookingIntent(
        customerPublicId: a,
        quotePublicId: quote,
        idempotencyKey: 'key-a'));
    await auth.clearAll();
    expect(values[StorageKeys.accessToken], isNull);
    expect(values[StorageKeys.refreshToken], isNull);
    expect(values[StorageKeys.userPublicId], isNull);
    expect((await intents.read(a))?.idempotencyKey, 'key-a');
  });
}
