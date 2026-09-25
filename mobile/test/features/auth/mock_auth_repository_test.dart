import 'package:flutter_test/flutter_test.dart';
import 'package:gomove_mobile/core/utils/result.dart';
import 'package:gomove_mobile/features/auth/data/datasources/auth_local_datasource.dart';
import 'package:gomove_mobile/features/auth/data/datasources/auth_mock_datasource.dart';
import 'package:gomove_mobile/features/auth/data/repositories/mock_auth_repository_impl.dart';
import 'package:gomove_mobile/features/auth/domain/entities/user.dart';

class FakeAuthLocalDataSource implements AuthLocalDataSource {
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
  late MockAuthRepositoryImpl repository;
  late AuthMockDataSource mockDataSource;
  late FakeAuthLocalDataSource fakeLocalDataSource;

  setUp(() {
    mockDataSource = AuthMockDataSourceImpl();
    fakeLocalDataSource = FakeAuthLocalDataSource();
    repository = MockAuthRepositoryImpl(
      mockDataSource: mockDataSource,
      localDataSource: fakeLocalDataSource,
    );
  });

  group('MockAuthRepository Tests', () {
    test('Đăng nhập thành công với tài khoản khách hàng SV (0901234567 / 123456)', () async {
      final result = await repository.login(
        identifier: '0901234567',
        password: '123456',
      );

      expect(result.isSuccess, isTrue);
      expect(result, isA<Success<User>>());

      final user = (result as Success<User>).data;
      expect(user.publicId, equals('550e8400-e29b-41d4-a716-446655440001'));
      expect(user.role, equals(UserRole.customer));
      expect(user.isStudentVerified, isTrue);
      expect(fakeLocalDataSource.accessToken, isNotNull);
      expect(fakeLocalDataSource.userPublicId, equals(user.publicId));
    });

    test('Đăng nhập thành công với tài khoản tài xế SV (0909876543 / 123456)', () async {
      final result = await repository.login(
        identifier: '0909876543',
        password: '123456',
      );

      expect(result.isSuccess, isTrue);
      final user = (result as Success<User>).data;
      expect(user.role, equals(UserRole.driver));
    });

    test('Đăng ký thành công tài khoản khách hàng mới', () async {
      final result = await repository.register(
        phone: '0912345678',
        email: 'test@student.edu.vn',
        password: 'Password123!',
        fullName: 'Le Van Test',
      );

      expect(result.isSuccess, isTrue);
      final user = (result as Success<User>).data;
      expect(user.role, equals(UserRole.customer));
      expect(user.fullName, equals('Le Van Test'));
    });

    test('Đăng nhập thất bại khi sai mật khẩu', () async {
      final result = await repository.login(
        identifier: '0901234567',
        password: 'wrong_password',
      );

      expect(result.isFailure, isTrue);
      expect(result, isA<Error<User>>());
    });
  });
}
