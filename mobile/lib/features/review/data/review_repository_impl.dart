import 'package:dio/dio.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/auth_interceptor.dart';
import '../domain/review_models.dart';
import '../domain/review_repository.dart';

class ReviewRepositoryImpl implements ReviewRepository {
  final ApiClient client;
  const ReviewRepositoryImpl(this.client);

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
  Future<DriverReputation> reputation(int generation) async =>
      DriverReputation.fromJson(_data((await client.get<Map<String, dynamic>>(
              '/drivers/me/reputation',
              options: _session(generation)))
          .data));

  @override
  Future<ReviewPage<RewardEvent>> rewards(int page, int generation) async =>
      ReviewPage.fromJson(
          _data((await client.get<Map<String, dynamic>>('/drivers/me/rewards',
                  queryParameters: {'page': page, 'size': 20},
                  options: _session(generation)))
              .data),
          RewardEvent.fromJson);

  @override
  Future<ReviewPage<QualityCase>> myCases(int page, int generation) async =>
      ReviewPage.fromJson(
          _data((await client.get<Map<String, dynamic>>(
                  '/drivers/me/quality-cases',
                  queryParameters: {'page': page, 'size': 20},
                  options: _session(generation)))
              .data),
          QualityCase.fromJson);

  @override
  Future<QualityCase> dispute(
          String publicId, String reason, int generation) async =>
      QualityCase.fromJson(_data((await client.post<Map<String, dynamic>>(
              '/drivers/me/quality-cases/$publicId/dispute',
              data: {'reason': reason},
              options: _session(generation)))
          .data));

  @override
  Future<ReviewPage<QualityCase>> adminCases(
          int page, String? status, int generation) async =>
      ReviewPage.fromJson(
          _data((await client.get<Map<String, dynamic>>('/admin/quality-cases',
                  queryParameters: {
                    'page': page,
                    'size': 20,
                    if (status != null) 'status': status
                  },
                  options: _session(generation)))
              .data),
          QualityCase.fromJson);

  @override
  Future<QualityDetail> adminDetail(String publicId, int generation) async =>
      QualityDetail.fromJson(_data((await client.get<Map<String, dynamic>>(
              '/admin/quality-cases/$publicId',
              options: _session(generation)))
          .data));

  @override
  Future<QualityDetail> adminAction(
          String publicId, String action, String note, int generation) async =>
      QualityDetail.fromJson(_data((await client.post<Map<String, dynamic>>(
              '/admin/quality-cases/$publicId/actions',
              data: {'action': action, 'note': note},
              options: _session(generation)))
          .data));
}
