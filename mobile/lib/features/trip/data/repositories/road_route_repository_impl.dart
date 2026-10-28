import 'package:dio/dio.dart';

import '../../../../core/constants/api_endpoints.dart';
import '../../../../core/network/api_client.dart';
import '../../../../core/network/auth_interceptor.dart';
import '../../domain/models/road_route.dart';
import '../../domain/repositories/road_route_repository.dart';

class RoadRouteRepositoryImpl implements RoadRouteRepository {
  final ApiClient _client;
  const RoadRouteRepositoryImpl(this._client);

  Options _session(int generation) =>
      Options(extra: {AuthInterceptor.sessionGenerationExtraKey: generation});

  RoadRoute _route(Map<String, dynamic>? envelope) {
    if (envelope?['success'] != true || envelope?['data'] is! Map) {
      throw const FormatException('Phản hồi tuyến đường không hợp lệ');
    }
    return RoadRoute.fromJson(
        Map<String, dynamic>.from(envelope!['data'] as Map));
  }

  @override
  Future<RoadRoute> quote(String quotePublicId, int sessionGeneration) async {
    final response = await _client.get<Map<String, dynamic>>(
        ApiEndpoints.quoteRoute(quotePublicId),
        options: _session(sessionGeneration));
    final route = _route(response.data);
    if (route.sourceQuotePublicId != quotePublicId ||
        route.bookingPublicId != null) {
      throw const FormatException('Tuyến đường không khớp báo giá');
    }
    return route;
  }

  @override
  Future<RoadRoute> booking(
      String bookingPublicId, int sessionGeneration) async {
    final response = await _client.get<Map<String, dynamic>>(
        ApiEndpoints.bookingRoute(bookingPublicId),
        options: _session(sessionGeneration));
    final route = _route(response.data);
    if (route.bookingPublicId != bookingPublicId) {
      throw const FormatException('Tuyến đường không khớp Booking');
    }
    return route;
  }
}
