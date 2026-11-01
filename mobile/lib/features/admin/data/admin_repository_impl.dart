import 'package:dio/dio.dart';

import '../../../core/error/exceptions.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/auth_interceptor.dart';
import '../domain/admin_models.dart';
import '../domain/admin_repository.dart';

class AdminRepositoryImpl implements AdminRepository {
  final ApiClient client;
  const AdminRepositoryImpl(this.client);

  Options _session(int generation) => Options(extra: {
        AuthInterceptor.sessionGenerationExtraKey: generation,
      });

  Map<String, dynamic> _data(Map<String, dynamic>? envelope) {
    if (envelope?['success'] != true || envelope?['data'] is! Map) {
      throw const FormatException('Phản hồi quản trị không hợp lệ');
    }
    return Map<String, dynamic>.from(envelope!['data'] as Map);
  }

  Map<String, dynamic> _query(
          int page, String? filterKey, String? filter, String? search) =>
      {
        'page': page,
        'size': 20,
        if (filterKey != null && filter != null) filterKey: filter,
        if (search != null && search.trim().isNotEmpty) 'q': search.trim(),
      };

  @override
  Future<AdminDashboard> dashboard(int generation) async {
    final response = await client.get<Map<String, dynamic>>('/admin/dashboard',
        options: _session(generation));
    return AdminDashboard.fromJson(_data(response.data));
  }

  @override
  Future<AdminPage<AdminDriver>> drivers(
      int page, String? approval, String? search, int generation) async {
    final response = await client.get<Map<String, dynamic>>('/admin/drivers',
        queryParameters: _query(page, 'approvalStatus', approval, search),
        options: _session(generation));
    return AdminPage.fromJson(_data(response.data), AdminDriver.fromJson);
  }

  @override
  Future<AdminDriver> driver(String publicId, int generation) async {
    final response = await client.get<Map<String, dynamic>>(
        '/admin/drivers/$publicId',
        options: _session(generation));
    return AdminDriver.fromJson(_data(response.data));
  }

  @override
  Future<AdminApprovalResult> setApproval(
      String publicId, String status, int generation) async {
    try {
      final response = await client.patch<Map<String, dynamic>>(
          '/drivers/$publicId/approval-status',
          data: {'status': status},
          options: _session(generation));
      final data = _data(response.data);
      if (data['publicId'] == publicId && data['approvalStatus'] == status) {
        return const AdminApprovalResult.confirmed();
      }
      // An unexpected successful response is not proof of this transition.
      return await _reconcile(publicId, status, generation);
    } on NetworkException {
      // Timeout/transport failure may occur after the server committed.
      return _reconcile(publicId, status, generation);
    } on ServerException catch (error) {
      if (error.statusCode != null && error.statusCode! >= 500) {
        return _reconcile(publicId, status, generation);
      }
      rethrow; // A confirmed 409 is a conflict, never an uncertain success.
    } on FormatException {
      return _reconcile(publicId, status, generation);
    }
  }

  Future<AdminApprovalResult> _reconcile(
      String publicId, String status, int generation) async {
    try {
      final current = await driver(publicId, generation);
      return current.approvalStatus == status
          ? AdminApprovalResult.confirmed(current)
          : AdminApprovalResult.uncertain(current);
    } on UnauthorizedException {
      rethrow;
    } on ServerException catch (error) {
      if (error.statusCode == 401 || error.statusCode == 403) rethrow;
      return const AdminApprovalResult.uncertain();
    } catch (_) {
      return const AdminApprovalResult.uncertain();
    }
  }

  @override
  Future<AdminPage<AdminAccount>> accounts(
      int page, String? role, String? search, int generation) async {
    final response = await client.get<Map<String, dynamic>>('/admin/accounts',
        queryParameters: _query(page, 'role', role, search),
        options: _session(generation));
    return AdminPage.fromJson(_data(response.data), AdminAccount.fromJson);
  }

  @override
  Future<AdminAccount> account(String publicId, int generation) async {
    final response = await client.get<Map<String, dynamic>>(
        '/admin/accounts/$publicId',
        options: _session(generation));
    return AdminAccount.fromJson(_data(response.data));
  }

  @override
  Future<AdminPage<AdminBooking>> bookings(
      int page, String? status, int generation) async {
    final response = await client.get<Map<String, dynamic>>('/admin/bookings',
        queryParameters: _query(page, 'status', status, null),
        options: _session(generation));
    return AdminPage.fromJson(_data(response.data), AdminBooking.fromJson);
  }
}
