import 'package:dio/dio.dart';

import '../../../../core/constants/api_endpoints.dart';
import '../../../../core/network/api_client.dart';
import '../../../../core/network/auth_interceptor.dart';
import '../../domain/models/place_search_result.dart';
import '../../domain/models/quote.dart';
import '../../domain/repositories/geocoding_repository.dart';

class GeocodingRepositoryImpl implements GeocodingRepository {
  final ApiClient _client;
  const GeocodingRepositoryImpl(this._client);

  Options? _session(int? generation) => generation == null
      ? null
      : Options(extra: {
          AuthInterceptor.sessionGenerationExtraKey: generation,
        });

  dynamic _data(Map<String, dynamic>? response) {
    if (response?['success'] != true || !response!.containsKey('data')) {
      throw const FormatException('Phản hồi địa điểm không hợp lệ');
    }
    return response['data'];
  }

  @override
  Future<List<PlaceSearchResult>> search(String query,
      {int? sessionGeneration}) async {
    final normalized = query.trim();
    if (normalized.runes.length < 3 || normalized.runes.length > 100) {
      throw const FormatException('Nhập từ 3 đến 100 ký tự để tìm địa điểm');
    }
    final response = await _client.get<Map<String, dynamic>>(
        ApiEndpoints.locationSearch,
        queryParameters: {'q': normalized},
        options: _session(sessionGeneration));
    final data = _data(response.data);
    if (data is! List) {
      throw const FormatException('Danh sách địa điểm không hợp lệ');
    }
    final results = <PlaceSearchResult>[];
    for (final entry in data.take(5)) {
      if (entry is! Map) continue;
      try {
        results
            .add(PlaceSearchResult.fromJson(Map<String, dynamic>.from(entry)));
      } on FormatException {
        // A malformed suggestion is never shown or used as a Quote coordinate.
      }
    }
    return results;
  }

  @override
  Future<PlaceSearchResult?> reverse(Coordinates point,
      {int? sessionGeneration}) async {
    if (!point.isValid) {
      throw const FormatException('Tọa độ địa điểm không hợp lệ');
    }
    final response =
        await _client.get<Map<String, dynamic>>(ApiEndpoints.locationReverse,
            queryParameters: {
              'latitude': point.latitude,
              'longitude': point.longitude,
            },
            options: _session(sessionGeneration));
    final data = _data(response.data);
    if (data == null) return null;
    if (data is! Map) {
      throw const FormatException('Địa chỉ không hợp lệ');
    }
    final result = PlaceSearchResult.fromJson(Map<String, dynamic>.from(data));
    if (result.coordinates.latitude != point.latitude ||
        result.coordinates.longitude != point.longitude) {
      throw const FormatException('Địa chỉ không khớp tọa độ đã chọn');
    }
    return result;
  }
}
