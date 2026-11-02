import 'package:dio/dio.dart';

import '../../../../core/network/api_client.dart';
import '../../../../core/network/auth_interceptor.dart';
import '../../domain/models/driver_earnings_summary.dart';
import '../../domain/repositories/driver_earnings_repository.dart';

class DriverEarningsRepositoryImpl implements DriverEarningsRepository {
  final ApiClient client;
  const DriverEarningsRepositoryImpl(this.client);

  @override
  Future<DriverEarningsSummary> summary(int sessionGeneration) async {
    final response = await client.get<Map<String, dynamic>>(
      '/drivers/me/commissions/summary',
      options: Options(extra: {
        AuthInterceptor.sessionGenerationExtraKey: sessionGeneration,
      }),
    );
    final envelope = response.data;
    if (envelope?['success'] != true || envelope?['data'] is! Map) {
      throw const FormatException('Phản hồi tiền mặt không hợp lệ');
    }
    return DriverEarningsSummary.fromJson(
        Map<String, dynamic>.from(envelope!['data'] as Map));
  }
}
