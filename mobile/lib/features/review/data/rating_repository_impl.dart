import 'package:dio/dio.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/auth_interceptor.dart';
import '../domain/rating_models.dart';
import '../domain/rating_repository.dart';

class RatingRepositoryImpl implements RatingRepository {
  final ApiClient client;
  const RatingRepositoryImpl(this.client);

  Options _session(int generation) => Options(extra: {
        AuthInterceptor.sessionGenerationExtraKey: generation,
      });

  Map<String, dynamic> _data(Map<String, dynamic>? response) {
    if (response?['success'] != true || response?['data'] is! Map) {
      throw const FormatException('Phản hồi đánh giá không hợp lệ');
    }
    return Map<String, dynamic>.from(response!['data'] as Map);
  }

  @override
  Future<RatingLookup> lookup(String bookingPublicId, int generation) async {
    final response = await client.get<Map<String, dynamic>>(
        '/bookings/$bookingPublicId/rating',
        options: _session(generation));
    return RatingLookup.fromJson(_data(response.data));
  }

  @override
  Future<TripRating> submit(String bookingPublicId, int stars, String? comment,
      int generation) async {
    final response = await client.post<Map<String, dynamic>>(
        '/bookings/$bookingPublicId/rating',
        data: {'stars': stars, 'comment': comment},
        options: _session(generation));
    return TripRating.fromJson(_data(response.data));
  }
}
