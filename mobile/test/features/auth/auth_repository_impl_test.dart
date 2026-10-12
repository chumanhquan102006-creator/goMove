import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:gomove_mobile/core/error/exceptions.dart';
import 'package:gomove_mobile/core/error/failures.dart';
import 'package:gomove_mobile/core/utils/result.dart';
import 'package:gomove_mobile/core/storage/secure_storage_service.dart';
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
  Object? exceptionToThrow;
  int refreshCalls = 0;
  int meCalls = 0;
  Completer<UserModel>? meCompleter;
  Completer<void>? meStarted;
  Completer<void>? logoutCompleter;
  Completer<void>? logoutStarted;

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
    refreshCalls++;
    if (exceptionToThrow != null) throw exceptionToThrow!;
    return {};
  }

  @override
  Future<void> logout(RefreshTokenRequestModel request) async {
    logoutStarted?.complete();
    if (logoutCompleter != null) await logoutCompleter!.future;
    if (exceptionToThrow != null) throw exceptionToThrow!;
  }

  @override
  Future<UserModel> getCurrentUser() async {
    meCalls++;
    meStarted?.complete();
    if (meCompleter != null) return meCompleter!.future;
    if (exceptionToThrow != null) throw exceptionToThrow!;
    return registerResponse!;
  }
}

class FakeLocalDataSource implements AuthLocalDataSource {
  String? accessToken;
  String? refreshToken;
  String? userPublicId;
  int generation = 0;

  @override
  Future<void> saveTokens({required String accessToken,
      required String refreshToken, String? userPublicId}) async {
    this.accessToken = accessToken;
    this.refreshToken = refreshToken;
    this.userPublicId = userPublicId;
    generation++;
  }

  @override
  Future<AuthSessionSnapshot> getSession() async =>
      AuthSessionSnapshot(generation, accessToken, refreshToken);
  @override
  Future<bool> isCurrentSession(int expected) async => generation == expected;
  @override
  Future<bool> saveUserPublicIdIfCurrent(int expected, String publicId) async {
    if (generation != expected) return false;
    userPublicId = publicId;
    return true;
  }
  @override
  Future<bool> clearAuthDataIfCurrent(int expected) async {
    if (generation != expected) return false;
    await clearAuthData();
    return true;
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
    generation++;
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

    test('Registration retains structured field errors without raw backend text',
        () async {
      remoteDataSource.exceptionToThrow = const ServerException(
        message: 'java.lang.IllegalArgumentException: secret stack trace',
        statusCode: 400,
        errorCode: 'VALIDATION_ERROR',
        details: {'password': 'size must be between 8 and 128'},
      );
      final result = await repository.register(
          phone: '0901234567', password: 'short', fullName: 'Nguyễn Văn An');
      final failure = (result as Error<User>).failure;
      expect(failure, isA<ValidationFailure>());
      expect((failure as ValidationFailure).fieldErrors['password'],
          'Mật khẩu phải có từ 8 đến 128 ký tự.');
      expect(failure.message, isNot(contains('java.lang')));
    });

    test('Registration maps duplicate phone/email, 401 and 409 safely',
        () async {
      for (final entry in <(String?, int, Type)>[
        ('PHONE_ALREADY_EXISTS', 409, PhoneAlreadyExistsFailure),
        ('EMAIL_ALREADY_EXISTS', 409, EmailAlreadyExistsFailure),
        (null, 401, UnauthorizedFailure),
        (null, 409, ServerFailure),
      ]) {
        remoteDataSource.exceptionToThrow = ServerException(
          message: 'java.lang.RuntimeException: sensitive backend detail',
          statusCode: entry.$2,
          errorCode: entry.$1,
        );
        final result = await repository.register(
            phone: '0901234567', password: 'Password123', fullName: 'Name');
        final failure = (result as Error<User>).failure;
        expect(failure.runtimeType, entry.$3);
        expect(failure.message, isNot(contains('java.lang')));
      }
    });

    test('Registration handles bare 401 and transport failures clearly',
        () async {
      remoteDataSource.exceptionToThrow =
          const UnauthorizedException('raw backend unauthorized');
      var result = await repository.register(
          phone: '0901234567', password: 'Password123', fullName: 'Name');
      expect((result as Error<User>).failure, isA<UnauthorizedFailure>());
      remoteDataSource.exceptionToThrow = const NetworkException();
      result = await repository.register(
          phone: '0901234567', password: 'Password123', fullName: 'Name');
      expect((result as Error<User>).failure, isA<NetworkFailure>());
    });

    test('Session restoration gets /me once without a second token rotation', () async {
      localDataSource.refreshToken = 'stored-refresh';
      remoteDataSource.registerResponse = tUser;
      final result = await repository.checkAuthStatus();
      expect(result, isA<Success<User>>());
      expect(remoteDataSource.meCalls, 1);
      expect(remoteDataSource.refreshCalls, 0);
      expect(localDataSource.userPublicId, tUser.publicId);
    });

    test('Network failure during session restoration preserves stored refresh token', () async {
      localDataSource.refreshToken = 'stored-refresh';
      remoteDataSource.exceptionToThrow = const NetworkException();
      final result = await repository.checkAuthStatus();
      expect(result.isFailure, isTrue);
      expect(localDataSource.refreshToken, 'stored-refresh');
      expect(remoteDataSource.refreshCalls, 0);
    });

    test('Logout revokes remotely and clears local auth state', () async {
      localDataSource.accessToken = 'access';
      localDataSource.refreshToken = 'refresh';
      final result = await repository.logout();
      expect(result.isSuccess, isTrue);
      expect(localDataSource.accessToken, isNull);
      expect(localDataSource.refreshToken, isNull);
    });

    test('A delayed /me 401 cannot clear B login session', () async {
      await localDataSource.saveTokens(accessToken: 'A-access',
          refreshToken: 'A-refresh', userPublicId: 'A');
      remoteDataSource.meStarted = Completer<void>();
      remoteDataSource.meCompleter = Completer<UserModel>();
      final pending = repository.checkAuthStatus();
      await remoteDataSource.meStarted!.future;
      await localDataSource.saveTokens(accessToken: 'B-access',
          refreshToken: 'B-refresh', userPublicId: 'B');
      remoteDataSource.meCompleter!.completeError(
          const UnauthorizedException('A token expired'));
      expect((await pending).isFailure, isTrue);
      expect(localDataSource.accessToken, 'B-access');
      expect(localDataSource.refreshToken, 'B-refresh');
      expect(localDataSource.userPublicId, 'B');
    });

    test('A delayed successful /me cannot replace B cached identity', () async {
      await localDataSource.saveTokens(accessToken: 'A-access',
          refreshToken: 'A-refresh', userPublicId: 'A');
      remoteDataSource.meStarted = Completer<void>();
      remoteDataSource.meCompleter = Completer<UserModel>();
      final pending = repository.checkAuthStatus();
      await remoteDataSource.meStarted!.future;
      await localDataSource.saveTokens(accessToken: 'B-access',
          refreshToken: 'B-refresh', userPublicId: 'B');
      remoteDataSource.meCompleter!.complete(tUser);
      expect((await pending).isFailure, isTrue);
      expect(localDataSource.userPublicId, 'B');
    });

    test('A delayed logout cannot clear B login session', () async {
      await localDataSource.saveTokens(accessToken: 'A-access',
          refreshToken: 'A-refresh', userPublicId: 'A');
      remoteDataSource.logoutStarted = Completer<void>();
      remoteDataSource.logoutCompleter = Completer<void>();
      final pending = repository.logout();
      await remoteDataSource.logoutStarted!.future;
      await localDataSource.saveTokens(accessToken: 'B-access',
          refreshToken: 'B-refresh', userPublicId: 'B');
      remoteDataSource.logoutCompleter!.complete();
      await pending;
      expect(localDataSource.accessToken, 'B-access');
      expect(localDataSource.refreshToken, 'B-refresh');
      expect(localDataSource.userPublicId, 'B');
    });
  });
}
