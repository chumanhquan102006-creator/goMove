import 'package:flutter_test/flutter_test.dart';
import 'package:gomove_mobile/core/error/exceptions.dart';
import 'package:gomove_mobile/core/error/failures.dart';
import 'package:gomove_mobile/core/utils/result.dart';
import 'package:gomove_mobile/features/auth/data/datasources/auth_local_datasource.dart';
import 'package:gomove_mobile/features/auth/data/datasources/auth_remote_datasource.dart';
import 'package:gomove_mobile/features/auth/data/models/auth_token_model.dart';
import 'package:gomove_mobile/features/auth/data/models/login_request_model.dart';
import 'package:gomove_mobile/features/auth/data/models/refresh_token_request_model.dart';
import 'package:gomove_mobile/features/auth/data/models/register_request_model.dart';
import 'package:gomove_mobile/features/auth/data/models/user_model.dart';
import 'package:gomove_mobile/features/auth/data/repositories/auth_repository_impl.dart';
import 'package:gomove_mobile/features/auth/domain/entities/user.dart';

class MockRemoteDataSource implements AuthRemoteDataSource {
  Map<String, dynamic>? loginResponse;
  UserModel? registerResponse;
  ServerException? exceptionToThrow;

  @override
  Future<Map<String, dynamic>> login(LoginRequestModel request) async {
    if (exceptionToThrow != null) throw exceptionToThrow!;
    return loginResponse!;
  }

  @override
  Future<UserModel> register(RegisterRequestModel request) async {
    if (exceptionToThrow != null) throw exceptionToThrow!;
    return registerResponse!;
  }

  @override
  Future<Map<String, dynamic>> refreshToken(RefreshTokenRequestModel request) async {
    if (exceptionToThrow != null) throw exceptionToThrow!;
    return {};
  }

  @override
  Future<void> logout(RefreshTokenRequestModel request) async {
    if (exceptionToThrow != null) throw exceptionToThrow!;
  }

  @override
  Future<UserModel> getCurrentUser() async {
    if (exceptionToThrow != null) throw exceptionToThrow!;
    return registerResponse!;
  }
}

class FakeLocalDataSource implements AuthLocalDataSource {
  String? accessToken;
  String? refreshToken;
  String? userPublicId;

  @override
  Future<void> saveTokens({required String accessToken, required String refreshToken}) async {
    this.accessToken = accessToken;
    this.refreshToken = refreshToken;
  }

  @override
  Future<String?> getAccessToken() async => accessToken;

  @override
  Future<String?> getRefreshToken() async => refreshToken;

  @override
  Future<void> saveUserPublicId(String publicId) async {
    userPublicId = publicId;
  }

  @override
  Future<String?> getUserPublicId() async => userPublicId;

  @override
  Future<void> clearAuthData() async {
    accessToken = null;
    refreshToken = null;
    userPublicId = null;
  }
}

void main() {
  late AuthRepositoryImpl repository;
  late MockRemoteDataSource remoteDataSource;
  late FakeLocalDataSource localDataSource;

  const tUser = UserModel(
    publicId: '550e8400-e29b-41d4-a716-446655440000',
    phoneNumber: '0987654321',
    fullName: 'Nguyen Van A',
    email: 'user@example.com',
    role: UserRole.customer,
    status: 'ACTIVE',
    isStudentVerified: true,
  );

  const tTokens = AuthTokenModel(
    accessToken: 'test_access_jwt',
    refreshToken: 'test_refresh_opaque',
    tokenType: 'Bearer',
    expiresIn: 900,
  );

  setUp(() {
    remoteDataSource = MockRemoteDataSource();
    localDataSource = FakeLocalDataSource();
    repository = AuthRepositoryImpl(
      remoteDataSource: remoteDataSource,
      localDataSource: localDataSource,
    );
  });

  group('AuthRepositoryImpl Tests', () {
    test('login() thành công: trả về User và lưu cả 2 token vào SecureStorage', () async {
      remoteDataSource.loginResponse = {
        'token': tTokens,
        'user': tUser,
      };

      final result = await repository.login(
        identifier: '0987654321',
        password: 'Password123!',
      );

      expect(result.isSuccess, isTrue);
      expect(result, isA<Success<User>>());

      final user = (result as Success<User>).data;
      expect(user.publicId, equals('550e8400-e29b-41d4-a716-446655440000'));
      expect(user.role, equals(UserRole.customer));

      // Kiểm chứng token lưu vào storage
      expect(localDataSource.accessToken, equals('test_access_jwt'));
      expect(localDataSource.refreshToken, equals('test_refresh_opaque'));
      expect(localDataSource.userPublicId, equals('550e8400-e29b-41d4-a716-446655440000'));
    });

    test('register() thành công với vai trò CUSTOMER duy nhất', () async {
      remoteDataSource.registerResponse = tUser;

      final result = await repository.register(
        phone: '0987654321',
        email: 'user@example.com',
        password: 'Password123!',
        fullName: 'Nguyen Van A',
      );

      expect(result.isSuccess, isTrue);
      final user = (result as Success<User>).data;
      expect(user.role, equals(UserRole.customer));
      expect(user.publicId, equals('550e8400-e29b-41d4-a716-446655440000'));
    });

    test('Bắt và map chính xác mã lỗi INVALID_CREDENTIALS từ server', () async {
      remoteDataSource.exceptionToThrow = const ServerException(
        message: 'Thông tin đăng nhập không chính xác',
        statusCode: 401,
        errorCode: 'INVALID_CREDENTIALS',
      );

      final result = await repository.login(
        identifier: '0987654321',
        password: 'wrong_password',
      );

      expect(result.isFailure, isTrue);
      expect(result, isA<Error<User>>());

      final failure = (result as Error<User>).failure;
      expect(failure, isA<InvalidCredentialsFailure>());
      expect(failure.message, equals('Số điện thoại hoặc mật khẩu không chính xác.'));
      expect(failure.code, equals('INVALID_CREDENTIALS'));
    });

    test('Bắt và map chính xác mã lỗi ACCOUNT_LOCKED từ server', () async {
      remoteDataSource.exceptionToThrow = const ServerException(
        message: 'Tài khoản bị tạm khóa do nhập sai quá 5 lần',
        statusCode: 403,
        errorCode: 'ACCOUNT_LOCKED',
      );

      final result = await repository.login(
        identifier: '0987654321',
        password: 'wrong_password',
      );

      expect(result.isFailure, isTrue);
      final failure = (result as Error<User>).failure;
      expect(failure, isA<AccountLockedFailure>());
      expect(failure.message, equals('Tài khoản bị tạm khóa do nhập sai quá 5 lần. Vui lòng thử lại sau 15 phút.'));
      expect(failure.code, equals('ACCOUNT_LOCKED'));
    });
  });
}
