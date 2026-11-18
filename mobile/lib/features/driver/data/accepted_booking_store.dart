import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../domain/models/driver_models.dart';

class AcceptedBookingRecord {
  final String driverPublicId;
  final DriverOffer offer;
  final bool pendingAcceptance;
  const AcceptedBookingRecord(this.driverPublicId, this.offer,
      {this.pendingAcceptance = false});
}

abstract class AcceptedBookingStore {
  Future<AcceptedBookingRecord?> read(String userPublicId);
  Future<void> write(String userPublicId, AcceptedBookingRecord record);
  Future<void> clear(String userPublicId);
}

class SecureAcceptedBookingStore implements AcceptedBookingStore {
  final FlutterSecureStorage _storage;
  SecureAcceptedBookingStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
                aOptions: AndroidOptions(encryptedSharedPreferences: true));

  static String keyFor(String userPublicId) =>
      'driver_accepted_booking_v1_$userPublicId';

  @override
  Future<AcceptedBookingRecord?> read(String userPublicId) async {
    final raw = await _storage.read(key: keyFor(userPublicId));
    if (raw == null) return null;
    final value = jsonDecode(raw) as Map<String, dynamic>;
    if (value['userPublicId'] != userPublicId) {
      throw const FormatException('Booking không thuộc tài khoản này');
    }
    final pending = value.containsKey('pendingAcceptance')
        ? value['pendingAcceptance']
        : false;
    if (pending is! bool) {
      throw const FormatException('Trạng thái bàn giao không hợp lệ');
    }
    return AcceptedBookingRecord(value['driverPublicId'] as String,
        DriverOffer.fromJson(value['offer'] as Map<String, dynamic>),
        pendingAcceptance: pending);
  }

  @override
  Future<void> write(String userPublicId, AcceptedBookingRecord record) =>
      _storage.write(
          key: keyFor(userPublicId),
          value: jsonEncode({
            'userPublicId': userPublicId,
            'driverPublicId': record.driverPublicId,
            'pendingAcceptance': record.pendingAcceptance,
            'offer': record.offer.toJson(),
          }));

  @override
  Future<void> clear(String userPublicId) =>
      _storage.delete(key: keyFor(userPublicId));
}
