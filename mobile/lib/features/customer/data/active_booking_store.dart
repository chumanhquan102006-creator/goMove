import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A local navigation hint, never proof that the current user owns a Booking.
/// Call the authorized Backend GET before displaying any Booking details.
class ActiveBookingRecord {
  final String customerPublicId;
  final String bookingPublicId;

  const ActiveBookingRecord({
    required this.customerPublicId,
    required this.bookingPublicId,
  });
}

abstract class ActiveBookingStore {
  Future<ActiveBookingRecord?> read(String customerPublicId);
  Future<void> write(String customerPublicId, ActiveBookingRecord record);
  Future<void> clear(String customerPublicId);
}

class SecureActiveBookingStore implements ActiveBookingStore {
  static final RegExp _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  static String keyFor(String customerPublicId) {
    if (!_uuid.hasMatch(customerPublicId)) {
      throw const FormatException('Invalid Customer public UUID');
    }
    return 'customer_active_booking_v1_$customerPublicId';
  }

  final FlutterSecureStorage _storage;

  SecureActiveBookingStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  @override
  Future<ActiveBookingRecord?> read(String customerPublicId) async {
    final raw = await _storage.read(key: keyFor(customerPublicId));
    if (raw == null) return null;

    final dynamic decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic> ||
        decoded['customerPublicId'] != customerPublicId ||
        decoded['bookingPublicId'] is! String ||
        !_uuid.hasMatch(decoded['bookingPublicId'] as String)) {
      throw const FormatException('Invalid Customer Booking reference');
    }
    return ActiveBookingRecord(
      customerPublicId: customerPublicId,
      bookingPublicId: decoded['bookingPublicId'] as String,
    );
  }

  @override
  Future<void> write(
      String customerPublicId, ActiveBookingRecord record) async {
    final key = keyFor(customerPublicId);
    if (record.customerPublicId != customerPublicId ||
        !_uuid.hasMatch(record.bookingPublicId)) {
      throw const FormatException('Invalid Customer Booking reference');
    }
    await _storage.write(
      key: key,
      value: jsonEncode({
        'customerPublicId': record.customerPublicId,
        'bookingPublicId': record.bookingPublicId,
      }),
    );
  }

  @override
  Future<void> clear(String customerPublicId) =>
      _storage.delete(key: keyFor(customerPublicId));
}
