import 'package:equatable/equatable.dart';

/// Lớp cơ sở định nghĩa các lỗi nghiệp vụ thuộc tầng Domain.
/// Không để rò rỉ ngoại lệ tầng Data (DioException, SocketException) lên UI.
abstract class Failure extends Equatable {
  final String message;
  final String? code;

  const Failure({
    required this.message,
    this.code,
  });

  @override
  List<Object?> get props => [message, code];
}

class ServerFailure extends Failure {
  final int? statusCode;

  const ServerFailure({
    required super.message,
    super.code,
    this.statusCode,
  });

  @override
  List<Object?> get props => [message, code, statusCode];
}

class NetworkFailure extends Failure {
  const NetworkFailure({
    super.message = 'Không thể kết nối đến máy chủ GoMove. Vui lòng kiểm tra lại mạng.',
    super.code = 'NETWORK_UNAVAILABLE',
  });
}

class UnauthorizedFailure extends Failure {
  const UnauthorizedFailure({
    super.message = 'Phiên đăng nhập đã hết hạn. Vui lòng đăng nhập lại.',
    super.code = 'UNAUTHORIZED',
  });
}

class CacheFailure extends Failure {
  const CacheFailure({
    super.message = 'Lỗi truy xuất bộ nhớ cục bộ bảo mật.',
    super.code = 'CACHE_ERROR',
  });
}

class ValidationFailure extends Failure {
  const ValidationFailure({
    required super.message,
    super.code = 'VALIDATION_FAILED',
  });
}

class MockDataFailure extends Failure {
  const MockDataFailure({
    required super.message,
    super.code = 'MOCK_ERROR',
  });
}

// =============================================================================
// CÁC FAILURE NGHIỆP VỤ XÁC THỰC CỤ THỂ THEO BẢN ĐỒ MÃ LỖI (Mục H)
// =============================================================================

class InvalidCredentialsFailure extends Failure {
  const InvalidCredentialsFailure({
    super.message = 'Số điện thoại hoặc mật khẩu không chính xác.',
    super.code = 'INVALID_CREDENTIALS',
  });
}

class PhoneAlreadyExistsFailure extends Failure {
  const PhoneAlreadyExistsFailure({
    super.message = 'Số điện thoại này đã được đăng ký tài khoản.',
    super.code = 'PHONE_ALREADY_EXISTS',
  });
}

class EmailAlreadyExistsFailure extends Failure {
  const EmailAlreadyExistsFailure({
    super.message = 'Email này đã được sử dụng.',
    super.code = 'EMAIL_ALREADY_EXISTS',
  });
}

class AccountLockedFailure extends Failure {
  const AccountLockedFailure({
    super.message = 'Tài khoản bị tạm khóa do nhập sai quá 5 lần. Vui lòng thử lại sau 15 phút.',
    super.code = 'ACCOUNT_LOCKED',
  });
}

class AccountDisabledFailure extends Failure {
  const AccountDisabledFailure({
    super.message = 'Tài khoản đã bị vô hiệu hóa. Vui lòng liên hệ bộ phận hỗ trợ.',
    super.code = 'ACCOUNT_DISABLED',
  });
}

class RefreshTokenExpiredFailure extends Failure {
  const RefreshTokenExpiredFailure({
    super.message = 'Phiên đăng nhập đã hết hạn. Vui lòng đăng nhập lại.',
    super.code = 'REFRESH_TOKEN_EXPIRED',
  });
}

/// Mapper chuyển đổi mã lỗi từ Backend Spring Boot sang Failure tương ứng
class AuthFailureMapper {
  static Failure map({
    String? code,
    String? serverMessage,
    int? statusCode,
  }) {
    switch (code) {
      case 'INVALID_CREDENTIALS':
        return const InvalidCredentialsFailure();
      case 'PHONE_ALREADY_EXISTS':
        return const PhoneAlreadyExistsFailure();
      case 'EMAIL_ALREADY_EXISTS':
        return const EmailAlreadyExistsFailure();
      case 'ACCOUNT_LOCKED':
        return const AccountLockedFailure();
      case 'ACCOUNT_DISABLED':
        return const AccountDisabledFailure();
      case 'REFRESH_TOKEN_EXPIRED':
      case 'REFRESH_TOKEN_REVOKED':
        return const RefreshTokenExpiredFailure();
      case 'NETWORK_UNAVAILABLE':
        return const NetworkFailure();
      default:
        if (statusCode == 401) {
          return UnauthorizedFailure(
            message: serverMessage ?? 'Phiên đăng nhập đã hết hạn. Vui lòng đăng nhập lại.',
          );
        }
        return ServerFailure(
          message: serverMessage ?? 'Đã có lỗi xảy ra từ máy chủ.',
          code: code,
          statusCode: statusCode,
        );
    }
  }
}
