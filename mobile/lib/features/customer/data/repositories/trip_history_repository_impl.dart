import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../../core/constants/api_endpoints.dart';
import '../../../../core/network/api_client.dart';
import '../../../../core/network/auth_interceptor.dart';
import '../../domain/models/booking.dart';
import '../../domain/models/trip_history.dart';
import '../../domain/repositories/trip_history_repository.dart';
import '../models/customer_models.dart';

class TripHistoryRepositoryImpl implements TripHistoryRepository {
  final ApiClient _client;
  const TripHistoryRepositoryImpl(this._client);

  Options _session(int generation) => Options(
      responseType: ResponseType.plain,
      extra: {AuthInterceptor.sessionGenerationExtraKey: generation});

  // Preserve the exact NUMERIC value before Dart's JSON decoder converts it to double.
  Map<String, dynamic> _payload(String? raw) {
    if (raw == null) throw const FormatException('Phản hồi lịch sử trống');
    final quoted = raw.replaceAllMapped(
        RegExp(
            r'("finalFare"\s*:\s*)(-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?)'),
        (match) => '${match.group(1)}"${match.group(2)}"');
    final envelope = jsonDecode(quoted);
    if (envelope is! Map<String, dynamic> ||
        envelope['success'] != true ||
        envelope['data'] is! Map<String, dynamic>) {
      throw const FormatException('Phản hồi lịch sử không hợp lệ');
    }
    return envelope['data'] as Map<String, dynamic>;
  }

  @override
  Future<HistoryPage> page(int page, int size, int sessionGeneration) async {
    final response = await _client.get<String>(ApiEndpoints.bookingHistory,
        queryParameters: {'page': page, 'size': size},
        options: _session(sessionGeneration));
    final parsed = HistoryPage.fromJson(_payload(response.data));
    if (parsed.page != page || parsed.size != size) {
      throw const FormatException('Trang lịch sử không khớp yêu cầu');
    }
    return parsed;
  }

  @override
  Future<Booking> detail(String bookingPublicId, int sessionGeneration) async {
    final response = await _client.get<String>(
        ApiEndpoints.booking(bookingPublicId),
        options: _session(sessionGeneration));
    final detail = CustomerModels.booking(_payload(response.data));
    if (detail.publicId != bookingPublicId ||
        detail.status != 'COMPLETED' ||
        detail.pickup == null ||
        !detail.pickup!.isValid ||
        detail.dropoff == null ||
        !detail.dropoff!.isValid ||
        detail.tripCompletedAt == null) {
      throw const FormatException('Chi tiết chuyến không hợp lệ');
    }
    return detail;
  }
}
