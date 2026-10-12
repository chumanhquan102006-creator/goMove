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
        userPublicId: user.publicId,
      );

      return Success(user);
    } on ServerException catch (e) {
      return Error(AuthFailureMapper.map(
        code: e.errorCode,
        serverMessage: e.message,
        statusCode: e.statusCode,
        details: e.details,
      ));
    } on UnauthorizedException catch (e) {
      return Error(AuthFailureMapper.map(
        code: e.errorCode ?? 'INVALID_CREDENTIALS',
        serverMessage: e.message,
        statusCode: 401,
      ));
    } on NetworkException catch (e) {
      return Error(NetworkFailure(message: e.message));
    } catch (_) {
      return const Error(ServerFailure(message: 'Không thể đăng nhập. Vui lòng thử lại.'));
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
        details: e.details,
      ));
    } on NetworkException catch (e) {
      return Error(NetworkFailure(message: e.message));
    } on UnauthorizedException catch (_) {
      return const Error(UnauthorizedFailure());
    } catch (_) {
      return const Error(ServerFailure(message: 'Không thể đăng ký tài khoản.'));
    }
  }

  @override
  Future<Result<User>> getCurrentUser() async {
    try {
      final session = await _localDataSource.getSession();
      final user = await _remoteDataSource.getCurrentUser();
      if (!await _localDataSource.isCurrentSession(session.generation)) {
        return const Error(UnauthorizedFailure());
      }
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
    } catch (_) {
      return const Error(ServerFailure(message: 'Không thể lấy thông tin người dùng.'));
    }
  }

  @override
  Future<Result<void>> logout() async {
    int? generation;
    try {
      final session = await _localDataSource.getSession();
      generation = session.generation;
      final refreshToken = session.refreshToken;
      if (refreshToken != null && refreshToken.isNotEmpty) {
        try {
          await _remoteDataSource.logout(
            RefreshTokenRequestModel(refreshToken: refreshToken),
          );
        } catch (_) {
          // Vẫn tiến hành xóa sạch bộ nhớ local dù server có lỗi mạng
        }
      }
      await _localDataSource.clearAuthDataIfCurrent(generation);
      return const Success(null);
    } catch (_) {
      if (generation != null) {
        await _localDataSource.clearAuthDataIfCurrent(generation);
      }
      return const Error(CacheFailure(message: 'Không thể xóa dữ liệu phiên làm việc.'));
    }
  }

  @override
  Future<Result<bool>> isAuthenticated() async {
    try {
      final refreshToken = await _localDataSource.getRefreshToken();
      return Success(refreshToken != null && refreshToken.isNotEmpty);
    } catch (_) {
      return const Error(CacheFailure(message: 'Lỗi kiểm tra trạng thái đăng nhập.'));
    }
  }

  @override
  Future<Result<User>> checkAuthStatus() async {
    int? generation;
    try {
      final session = await _localDataSource.getSession();
      generation = session.generation;
      final refreshToken = session.refreshToken;
      if (refreshToken == null || refreshToken.isEmpty) {
        return const Error(UnauthorizedFailure());
      }

      // ApiClient refreshes a 401 exactly once; never rotate again here.
      final user = await _remoteDataSource.getCurrentUser();
      if (!await _localDataSource.saveUserPublicIdIfCurrent(generation, user.publicId)) {
        return const Error(UnauthorizedFailure());
      }
      return Success(user);
    } on NetworkException catch (e) {
      return Error(NetworkFailure(message: e.message));
    } on ServerException catch (e) {
      return Error(AuthFailureMapper.map(code: e.errorCode, serverMessage: e.message, statusCode: e.statusCode));
    } on UnauthorizedException catch (_) {
      if (generation != null) {
        await _localDataSource.clearAuthDataIfCurrent(generation);
      }
      return const Error(UnauthorizedFailure());
    } catch (_) {
      return const Error(ServerFailure(message: 'Không thể khôi phục phiên đăng nhập.'));
    }
  }
}
