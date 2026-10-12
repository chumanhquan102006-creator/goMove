import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../domain/models/booking_intent.dart';

abstract class BookingIntentStore {
  Future<BookingIntent?> read(String customerPublicId);
  Future<void> write(BookingIntent intent);
  Future<void> clear(String customerPublicId);
}

class SecureBookingIntentStore implements BookingIntentStore {
  static const legacyKey = 'pending_booking_intent_v1';
  static String keyFor(String customerPublicId) =>
      'pending_booking_intent_v2_$customerPublicId';
  final FlutterSecureStorage _storage;

  SecureBookingIntentStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
                aOptions: AndroidOptions(encryptedSharedPreferences: true));

  @override
  Future<BookingIntent?> read(String customerPublicId) async {
    final raw = await _storage.read(key: keyFor(customerPublicId));
    final scoped = raw == null ? null : _decode(raw);
    if (scoped != null && scoped.customerPublicId != customerPublicId) {
      throw StateError('Booking intent ownership mismatch');
    }

    final oldRaw = await _storage.read(key: legacyKey);
    if (oldRaw == null) return scoped;
    final legacy = _decode(oldRaw);
    if (legacy.customerPublicId != customerPublicId) return scoped;
    if (scoped != null && !_sameIntent(scoped, legacy)) {
      throw StateError('Conflicting unresolved Booking intents');
    }
    // Write first, delete second: an interrupted migration can be retried safely.
    if (scoped == null) {
      await _storage.write(key: keyFor(customerPublicId), value: oldRaw);
    }
    await _storage.delete(key: legacyKey);
    return scoped ?? legacy;
  }

  @override
  Future<void> write(BookingIntent intent) async {
    final existing = await read(intent.customerPublicId);
    if (existing != null && !_sameIntent(existing, intent)) {
      throw StateError('Unresolved Booking intent cannot be replaced');
    }
    await _storage.write(
        key: keyFor(intent.customerPublicId), value: jsonEncode(intent.toJson()));
  }

  @override
  Future<void> clear(String customerPublicId) async {
    await read(customerPublicId);
    await _storage.delete(key: keyFor(customerPublicId));
  }

  BookingIntent _decode(String raw) =>
      BookingIntent.fromJson(jsonDecode(raw) as Map<String, dynamic>);

  bool _sameIntent(BookingIntent left, BookingIntent right) =>
      left.customerPublicId == right.customerPublicId &&
      left.quotePublicId == right.quotePublicId &&
      left.idempotencyKey == right.idempotencyKey;
}
