import '../../../../core/error/exceptions.dart';
import '../../../../core/error/failures.dart';
import '../../../../core/utils/result.dart';
import '../../domain/entities/user.dart';
import '../../domain/repositories/auth_repository.dart';
import '../datasources/auth_local_datasource.dart';
import '../datasources/auth_remote_datasource.dart';
import '../models/auth_token_model.dart';
import '../models/login_request_model.dart';
import '../models/refresh_token_request_model.dart';
import '../models/register_request_model.dart';
import '../models/user_model.dart';

/// [AuthRepositoryImpl] triển khai kết nối trực tiếp đến Spring Boot Backend qua REST API Dio.
/// Chịu trách nhiệm chuyển đổi Exception tầng Data thành Failure tầng Domain theo bản đồ mã lỗi (Mục H).
class AuthRepositoryImpl implements AuthRepository {
  final AuthRemoteDataSource _remoteDataSource;
  final AuthLocalDataSource _localDataSource;

  AuthRepositoryImpl({
    required AuthRemoteDataSource remoteDataSource,
    required AuthLocalDataSource localDataSource,
  })  : _remoteDataSource = remoteDataSource,
        _localDataSource = localDataSource;

  @override
  Future<Result<User>> login({
    required String identifier,
    required String password,
  }) async {
    try {
      final result = await _remoteDataSource.login(
        LoginRequestModel(
          identifier: identifier,
          password: password,
        ),
      );

      final token = result['token'] as AuthTokenModel;
      final user = result['user'] as UserModel;

      // Lưu trữ bảo mật JWT Tokens & publicId (Điều 139)
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
    } on UnauthorizedException catch (e) {
      return Error(AuthFailureMapper.map(
        code: e.errorCode ?? 'INVALID_CREDENTIALS',
        serverMessage: e.message,
        statusCode: 401,
      ));
    } on NetworkException catch (e) {
      return Error(NetworkFailure(message: e.message));
    } catch (e) {
      return Error(ServerFailure(message: 'Lỗi không xác định: $e'));
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
      final user = await _remoteDataSource.register(
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
    } on NetworkException catch (e) {
      return Error(NetworkFailure(message: e.message));
    } catch (e) {
      return Error(ServerFailure(message: 'Lỗi đăng ký tài khoản: $e'));
    }
  }

  @override
  Future<Result<User>> getCurrentUser() async {
    try {
      final user = await _remoteDataSource.getCurrentUser();
      return Success(user);
    } on ServerException catch (e) {
      return Error(AuthFailureMapper.map(
        code: e.errorCode,
        serverMessage: e.message,
        statusCode: e.statusCode,
      ));
    } on UnauthorizedException catch (e) {
      return Error(AuthFailureMapper.map(
        code: e.errorCode,
        serverMessage: e.message,
        statusCode: 401,
      ));
    } on NetworkException catch (e) {
      return Error(NetworkFailure(message: e.message));
    } catch (e) {
      return Error(ServerFailure(message: 'Lỗi lấy thông tin người dùng: $e'));
    }
  }

  @override
  Future<Result<void>> logout() async {
    try {
      final refreshToken = await _localDataSource.getRefreshToken();
      if (refreshToken != null && refreshToken.isNotEmpty) {
        try {
          await _remoteDataSource.logout(
            RefreshTokenRequestModel(refreshToken: refreshToken),
          );
        } catch (_) {
          // Vẫn tiến hành xóa sạch bộ nhớ local dù server có lỗi mạng
        }
      }
      await _localDataSource.clearAuthData();
      return const Success(null);
    } catch (e) {
      await _localDataSource.clearAuthData();
      return Error(CacheFailure(message: 'Không thể xóa dữ liệu phiên làm việc: $e'));
    }
  }

  @override
  Future<Result<bool>> isAuthenticated() async {
    try {
      final refreshToken = await _localDataSource.getRefreshToken();
      return Success(refreshToken != null && refreshToken.isNotEmpty);
    } catch (e) {
      return Error(CacheFailure(message: 'Lỗi kiểm tra trạng thái đăng nhập: $e'));
    }
  }

  @override
  Future<Result<User>> checkAuthStatus() async {
    try {
      final refreshToken = await _localDataSource.getRefreshToken();
      if (refreshToken == null || refreshToken.isEmpty) {
        return const Error(UnauthorizedFailure());
      }

      // Thử lấy thông tin User hiện tại trước
      try {
        final user = await _remoteDataSource.getCurrentUser();
        return Success(user);
      } catch (_) {
        // Nếu Access Token hết hạn, thử refresh token
        final refreshResult = await _remoteDataSource.refreshToken(
          RefreshTokenRequestModel(refreshToken: refreshToken),
        );

        final token = refreshResult['token'] as AuthTokenModel;
        await _localDataSource.saveTokens(
          accessToken: token.accessToken,
          refreshToken: token.refreshToken,
        );

        UserModel? user = refreshResult['user'] as UserModel?;
        user ??= await _remoteDataSource.getCurrentUser();
        await _localDataSource.saveUserPublicId(user.publicId);

        return Success(user);
      }
    } catch (e) {
      await _localDataSource.clearAuthData();
      return const Error(UnauthorizedFailure());
    }
  }
}
