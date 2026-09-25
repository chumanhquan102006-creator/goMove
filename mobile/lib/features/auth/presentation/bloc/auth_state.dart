import 'package:equatable/equatable.dart';
import '../../domain/entities/user.dart';

abstract class AuthState extends Equatable {
  const AuthState();

  @override
  List<Object?> get props => [];
}

/// Trạng thái khởi tạo ban đầu trước khi kích hoạt splash check
class AuthInitialState extends AuthState {
  const AuthInitialState();
}

/// Trạng thái đang xử lý (loading splash, login, register, logout)
class AuthLoadingState extends AuthState {
  const AuthLoadingState();
}

/// Trạng thái đã xác thực thành công với thông tin User
class AuthenticatedState extends AuthState {
  final User user;

  const AuthenticatedState(this.user);

  @override
  List<Object?> get props => [user];
}

/// Trạng thái chưa đăng nhập hoặc phiên đã hết hạn
class UnauthenticatedState extends AuthState {
  const UnauthenticatedState();
}

/// Trạng thái đăng ký tài khoản thành công
class AuthRegistrationSuccessState extends AuthState {
  final User user;

  const AuthRegistrationSuccessState(this.user);

  @override
  List<Object?> get props => [user];
}

/// Trạng thái lỗi nghiệp vụ hoặc kỹ thuật
class AuthErrorState extends AuthState {
  final String message;
  final String? code;

  const AuthErrorState({
    required this.message,
    this.code,
  });

  @override
  List<Object?> get props => [message, code];
}
