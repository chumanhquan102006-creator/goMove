import '../../../../core/error/exceptions.dart';
import '../../../../core/error/failures.dart';
import '../../../../core/utils/result.dart';
import '../../domain/entities/user.dart';
import '../../domain/repositories/auth_repository.dart';
import '../datasources/auth_local_datasource.dart';
import '../datasources/auth_mock_datasource.dart';
import '../models/auth_token_model.dart';
import '../models/login_request_model.dart';
import '../models/register_request_model.dart';
import '../models/user_model.dart';

/// [MockAuthRepositoryImpl] triển khai Mock Repository cho chiến lược Frontend-First (Điều 161, 162).
/// Cung cấp dữ liệu giả lập chuẩn nghiệp vụ xe công nghệ sinh viên (Customer & Driver),
/// giúp toàn bộ giao diện và luồng BLoC hoạt động độc lập 100% khi chưa kết nối Backend.
class MockAuthRepositoryImpl implements AuthRepository {
  final AuthMockDataSource _mockDataSource;
  final AuthLocalDataSource _localDataSource;

  MockAuthRepositoryImpl({
    required AuthMockDataSource mockDataSource,
    required AuthLocalDataSource localDataSource,
  })  : _mockDataSource = mockDataSource,
        _localDataSource = localDataSource;

  @override
  Future<Result<User>> login({
    required String identifier,
    required String password,
  }) async {
    try {
      final result = await _mockDataSource.login(
        LoginRequestModel(
          identifier: identifier,
          password: password,
        ),
      );

      final token = result['token'] as AuthTokenModel;
      final user = result['user'] as UserModel;

      await _localDataSource.saveTokens(
        accessToken: token.accessToken,
        refreshToken: token.refreshToken,
      );
      await _localDataSource.saveUserPublicId(user.publicId);

      return Success(user);
    } on ServerException catch (e) {
      return Error(AuthFailureMapper.map(
        code: e.errorCode,
        serverMessage: e.message,
        statusCode: e.statusCode,
      ));
    } catch (e) {
      return Error(MockDataFailure(message: 'Lỗi phát sinh từ Mock Auth: $e'));
    }
  }

  @override
  Future<Result<User>> register({
    required String phone,
    String? email,
    required String password,
    required String fullName,
  }) async {
    try {
      final user = await _mockDataSource.register(
        RegisterRequestModel(
          phone: phone,
          email: email,
          password: password,
          fullName: fullName,
        ),
      );

      return Success(user);
    } on ServerException catch (e) {
      return Error(AuthFailureMapper.map(
        code: e.errorCode,
        serverMessage: e.message,
        statusCode: e.statusCode,
      ));
    } catch (e) {
      return Error(MockDataFailure(message: 'Lỗi đăng ký Mock: $e'));
    }
  }

  @override
  Future<Result<User>> getCurrentUser() async {
    try {
      final user = await _mockDataSource.getCurrentUser();
      return Success(user);
    } on UnauthorizedException catch (e) {
      return Error(UnauthorizedFailure(message: e.message));
    } catch (e) {
      return Error(MockDataFailure(message: 'Lỗi lấy thông tin Mock User: $e'));
    }
  }

  @override
  Future<Result<void>> logout() async {
    try {
      await _localDataSource.clearAuthData();
      return const Success(null);
    } catch (e) {
      return Error(CacheFailure(message: 'Lỗi dọn dẹp phiên làm việc Mock: $e'));
    }
  }

  @override
  Future<Result<bool>> isAuthenticated() async {
    try {
      final token = await _localDataSource.getRefreshToken();
      return Success(token != null && token.isNotEmpty);
    } catch (e) {
      return Error(CacheFailure(message: 'Lỗi kiểm tra Mock Token: $e'));
    }
  }

  @override
  Future<Result<User>> checkAuthStatus() async {
    try {
      final token = await _localDataSource.getRefreshToken();
      if (token == null || token.isEmpty) {
        return const Error(UnauthorizedFailure());
      }
      final user = await _mockDataSource.getCurrentUser();
      return Success(user);
    } catch (_) {
      return const Error(UnauthorizedFailure());
    }
  }
}
