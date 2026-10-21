import 'dart:convert';
import 'package:dio/dio.dart';
import '../../../../core/constants/api_endpoints.dart';
import '../../../../core/network/api_client.dart';
import '../../../../core/network/auth_interceptor.dart';
import '../../domain/models/trip_models.dart';
import '../../domain/repositories/trip_repository.dart';

class TripRepositoryImpl implements TripRepository {
  final ApiClient _client;
  const TripRepositoryImpl(this._client);

  Options _session(int generation, {bool rawMoney = false}) => Options(
      responseType: rawMoney ? ResponseType.plain : null,
      extra: {AuthInterceptor.sessionGenerationExtraKey: generation});

  Map<String, dynamic> _data(Map<String, dynamic>? envelope) {
    if (envelope?['success'] != true || envelope?['data'] is! Map) {
      throw const FormatException('Phản hồi máy chủ thiếu dữ liệu xác nhận');
    }
    return Map<String, dynamic>.from(envelope!['data'] as Map);
  }

  // BigDecimal is serialized as a JSON number by Spring. Decode only known
  // financial fields as lexical strings so Dart never rounds them via double.
  Map<String, dynamic> _moneyData(String? raw) {
    if (raw == null) throw const FormatException('Phản hồi tiền mặt trống');
    final quoted = raw.replaceAllMapped(
      RegExp(
          r'("(?:amount|cashCollectedAmount|commissionRate|commissionAmount)"\s*:\s*)(-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?)'),
      (match) => '${match.group(1)}"${match.group(2)}"',
    );
    final value = jsonDecode(quoted);
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Phản hồi máy chủ không hợp lệ');
    }
    return _data(value);
  }

  @override
  Future<TrackingSnapshot> tracking(
      String bookingPublicId, int sessionGeneration) async {
    final response = await _client.get<Map<String, dynamic>>(
        ApiEndpoints.bookingTracking(bookingPublicId),
        options: _session(sessionGeneration));
    final value = TrackingSnapshot.fromJson(_data(response.data));
    if (value.bookingPublicId != bookingPublicId) {
      throw const FormatException('Phản hồi tracking không khớp Booking');
    }
    return value;
  }

  @override
  Future<CashPayment> payment(
      String bookingPublicId, int sessionGeneration) async {
    final response = await _client.get<String>(
        ApiEndpoints.bookingPayment(bookingPublicId),
        options: _session(sessionGeneration, rawMoney: true));
    final value = CashPayment.fromJson(_moneyData(response.data));
    if (value.bookingPublicId != bookingPublicId) {
      throw const FormatException('Phản hồi payment không khớp Booking');
    }
    return value;
  }

  @override
  Future<TripTransition> transition(
      String bookingPublicId, TripAction action, int sessionGeneration) async {
    final response = await _client.post<Map<String, dynamic>>(
        ApiEndpoints.driverTripAction(bookingPublicId, action.path),
        options: _session(sessionGeneration));
    final value = TripTransition.fromJson(_data(response.data));
    if (value.bookingPublicId != bookingPublicId ||
        value.status != action.toStatus) {
      throw const FormatException('Phản hồi chuyển trạng thái không khớp');
    }
    return value;
  }

  @override
  Future<CashReceipt> confirmCash(
      String bookingPublicId, int sessionGeneration) async {
    final response = await _client.post<String>(
        ApiEndpoints.confirmTripCash(bookingPublicId),
        options: _session(sessionGeneration, rawMoney: true));
    final value = CashReceipt.fromJson(_moneyData(response.data));
    if (value.bookingPublicId != bookingPublicId ||
        value.paymentStatus != 'PAID' ||
        value.paymentMethod != 'CASH') {
      throw const FormatException('Biên nhận thu tiền mặt không hợp lệ');
    }
    return value;
  }
}
