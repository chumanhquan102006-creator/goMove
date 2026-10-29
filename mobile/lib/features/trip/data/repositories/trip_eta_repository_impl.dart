import 'package:dio/dio.dart';

import '../../../../core/constants/api_endpoints.dart';
import '../../../../core/network/api_client.dart';
import '../../../../core/network/auth_interceptor.dart';
import '../../domain/models/trip_eta.dart';
import '../../domain/repositories/trip_eta_repository.dart';

class TripEtaRepositoryImpl implements TripEtaRepository {
  final ApiClient _client;
  const TripEtaRepositoryImpl(this._client);

  @override
  Future<TripEta> booking(String bookingPublicId, int sessionGeneration) async {
    final response = await _client.get<Map<String, dynamic>>(
      ApiEndpoints.bookingEta(bookingPublicId),
      options: Options(extra: {
        AuthInterceptor.sessionGenerationExtraKey: sessionGeneration,
      }),
    );
    final envelope = response.data;
    if (envelope?['success'] != true || envelope?['data'] is! Map) {
      throw const FormatException('Phản hồi ETA không hợp lệ');
    }
    final eta =
        TripEta.fromJson(Map<String, dynamic>.from(envelope!['data'] as Map));
    if (eta.bookingPublicId != bookingPublicId) {
      throw const FormatException('ETA không khớp Booking');
    }
    return eta;
  }
}
