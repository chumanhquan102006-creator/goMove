import '../../../../core/error/exceptions.dart';
import '../../domain/entities/user.dart';
import '../models/auth_token_model.dart';
import '../models/login_request_model.dart';
import '../models/refresh_token_request_model.dart';
import '../models/register_request_model.dart';
import '../models/user_model.dart';

abstract class AuthMockDataSource {
  Future<Map<String, dynamic>> login(LoginRequestModel request);

  Future<UserModel> register(RegisterRequestModel request);

  Future<Map<String, dynamic>> refreshToken(RefreshTokenRequestModel request);

  Future<void> logout(RefreshTokenRequestModel request);

  Future<UserModel> getCurrentUser();
}

/// Triển khai Mock Data Source phục vụ chiến lược Frontend-First (Điều 161, 162).
/// Hỗ trợ kiểm thử đầy đủ luồng nghiệp vụ không cần Backend:
/// - Khách hàng sinh viên: SĐT `0901234567` / pass `123456`
/// - Tài xế sinh viên: SĐT `0909876543` / pass `123456`
class AuthMockDataSourceImpl implements AuthMockDataSource {
  UserModel? _currentUser;
  final Map<String, UserModel> _mockRegisteredUsers = {};

  @override
  Future<Map<String, dynamic>> login(LoginRequestModel request) async {
    // Mô phỏng độ trễ mạng thực tế 400ms
    await Future<void>.delayed(const Duration(milliseconds: 400));

    final identifier = request.identifier.trim();
    final password = request.password;

    if (password != '123456' && password != 'Password123!') {
      throw const ServerException(
        message: 'Số điện thoại hoặc mật khẩu không chính xác.',
        statusCode: 401,
        errorCode: 'INVALID_CREDENTIALS',
      );
    }

    if (identifier == '0901234567') {
      // Mock Customer (Sinh viên đặt xe)
      final user = const UserModel(
        publicId: '550e8400-e29b-41d4-a716-446655440001',
        phoneNumber: '0901234567',
        fullName: 'Nguyễn Văn Sinh Viên',
        email: 'sinhvien.nguyen@university.edu.vn',
        role: UserRole.customer,
        status: 'ACTIVE',
        isStudentVerified: true,
        studentCardId: 'SV2024-0981',
        avatarUrl: 'https://images.unsplash.com/photo-1535713875002-d1d0cf377fde?w=150',
      );

      final tokens = const AuthTokenModel(
        accessToken: 'mock_jwt_access_token_customer_uuid_0001',
        refreshToken: 'mock_jwt_refresh_token_customer_uuid_0001',
        tokenType: 'Bearer',
        expiresIn: 900,
      );

      _currentUser = user;
      return {'token': tokens, 'user': user};
    } else if (identifier == '0909876543') {
      // Mock Driver (Sinh viên chạy xe)
      final user = const UserModel(
        publicId: '550e8400-e29b-41d4-a716-446655440002',
        phoneNumber: '0909876543',
        fullName: 'Trần Văn Tài Xế',
        email: 'taixe.tran@university.edu.vn',
        role: UserRole.driver,
        status: 'ACTIVE',
        isStudentVerified: true,
        studentCardId: 'TX2023-4521',
        avatarUrl: 'https://images.unsplash.com/photo-1570295999919-56ceb5ecca61?w=150',
      );

      final tokens = const AuthTokenModel(
        accessToken: 'mock_jwt_access_token_driver_uuid_0002',
        refreshToken: 'mock_jwt_refresh_token_driver_uuid_0002',
        tokenType: 'Bearer',
        expiresIn: 900,
      );

      _currentUser = user;
      return {'token': tokens, 'user': user};
    } else if (_mockRegisteredUsers.containsKey(identifier)) {
      final user = _mockRegisteredUsers[identifier]!;
      final tokens = AuthTokenModel(
        accessToken: 'mock_jwt_access_token_${user.publicId}',
        refreshToken: 'mock_jwt_refresh_token_${user.publicId}',
      );
      _currentUser = user;
      return {'token': tokens, 'user': user};
    } else {
      // Cho phép test với bất kỳ số nào
      final user = UserModel(
        publicId: '550e8400-e29b-41d4-a716-${identifier.padLeft(12, '0')}',
        phoneNumber: identifier,
        fullName: 'Khách hàng GoMove ($identifier)',
        email: 'user_$identifier@gomove.vn',
        role: UserRole.customer,
        status: 'ACTIVE',
        isStudentVerified: false,
      );

      final tokens = const AuthTokenModel(
        accessToken: 'mock_jwt_access_token_generic',
        refreshToken: 'mock_jwt_refresh_token_generic',
      );

      _currentUser = user;
      return {'token': tokens, 'user': user};
    }
  }

  @override
  Future<UserModel> register(RegisterRequestModel request) async {
    await Future<void>.delayed(const Duration(milliseconds: 500));

    final phone = request.phone.trim();
    if (phone == '0901234567' || _mockRegisteredUsers.containsKey(phone)) {
      throw const ServerException(
        message: 'Số điện thoại này đã được đăng ký tài khoản.',
        statusCode: 409,
        errorCode: 'PHONE_ALREADY_EXISTS',
      );
    }

    final newUser = UserModel(
      publicId: '550e8400-e29b-41d4-a716-reg${DateTime.now().millisecondsSinceEpoch}',
      phoneNumber: phone,
      email: request.email,
      fullName: request.fullName,
      role: UserRole.customer, // Public registration CHỈ là CUSTOMER
      status: 'ACTIVE',
      isStudentVerified: false,
    );

    _mockRegisteredUsers[phone] = newUser;
    return newUser;
  }

  @override
  Future<Map<String, dynamic>> refreshToken(RefreshTokenRequestModel request) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final user = _currentUser ??
        const UserModel(
          publicId: '550e8400-e29b-41d4-a716-446655440001',
          phoneNumber: '0901234567',
          fullName: 'Nguyễn Văn Sinh Viên',
          email: 'sinhvien.nguyen@university.edu.vn',
          role: UserRole.customer,
          status: 'ACTIVE',
          isStudentVerified: true,
        );

    final newTokens = AuthTokenModel(
      accessToken: 'rotated_access_token_${DateTime.now().millisecondsSinceEpoch}',
      refreshToken: 'rotated_refresh_token_${DateTime.now().millisecondsSinceEpoch}',
    );

    return {'token': newTokens, 'user': user};
  }

  @override
  Future<void> logout(RefreshTokenRequestModel request) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    _currentUser = null;
  }

  @override
  Future<UserModel> getCurrentUser() async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (_currentUser == null) {
      // Trả về mock default user nếu có session
      return const UserModel(
        publicId: '550e8400-e29b-41d4-a716-446655440001',
        phoneNumber: '0901234567',
        fullName: 'Nguyễn Văn Sinh Viên',
        email: 'sinhvien.nguyen@university.edu.vn',
        role: UserRole.customer,
        status: 'ACTIVE',
        isStudentVerified: true,
      );
    }
    return _currentUser!;
  }
}
