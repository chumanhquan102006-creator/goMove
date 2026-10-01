import 'package:equatable/equatable.dart';

abstract class AuthEvent extends Equatable {
  const AuthEvent();

  @override
  List<Object?> get props => [];
}

/// Khôi phục và kiểm tra phiên đăng nhập hiện tại (Mục G)
class AuthCheckRequested extends AuthEvent {
  const AuthCheckRequested();
}

/// Alias tương thích ngược cho CheckAuthStatusEvent
typedef CheckAuthStatusEvent = AuthCheckRequested;

/// Yêu cầu đăng nhập tài khoản
class AuthLoginSubmitted extends AuthEvent {
  final String identifier;
  final String password;

  const AuthLoginSubmitted({
    required this.identifier,
    required this.password,
  });

  @override
  List<Object?> get props => [identifier, password];
}

/// Alias tương thích ngược
class LoginRequestedEvent extends AuthLoginSubmitted {
  const LoginRequestedEvent({
    required String phoneNumber,
    required super.password,
  }) : super(identifier: phoneNumber);
}

/// Yêu cầu đăng ký tài khoản Khách hàng mới (CUSTOMER ONLY - Mục A.4)
class AuthRegisterSubmitted extends AuthEvent {
  final String phone;
  final String? email;
  final String password;
  final String fullName;

  const AuthRegisterSubmitted({
    required this.phone,
    this.email,
    required this.password,
    required this.fullName,
  });

  @override
  List<Object?> get props => [phone, email, password, fullName];
}

/// Yêu cầu đăng xuất
class AuthLogoutRequested extends AuthEvent {
  const AuthLogoutRequested();
}

/// Alias tương thích ngược cho LogoutRequestedEvent
typedef LogoutRequestedEvent = AuthLogoutRequested;

/// Sự kiện cưỡng chế chuyển về trạng thái Unauthenticated khi refresh token thất bại
class AuthForceUnauthenticated extends AuthEvent {
  const AuthForceUnauthenticated();
}
