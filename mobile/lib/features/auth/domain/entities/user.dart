import 'package:equatable/equatable.dart';

enum UserRole {
  customer,
  driver,
}

/// Thực thể người dùng trong hệ thống GoMove (Clean Architecture Domain Entity).
/// Tuân thủ Điều 9 Master Context: Sử dụng publicId (UUID string), không dùng numeric id trên Client.
class User extends Equatable {
  final String publicId;
  final String phoneNumber;
  final String fullName;
  final String? email;
  final UserRole role;
  final String status;
  final bool isStudentVerified;
  final String? studentCardId;
  final String? avatarUrl;

  const User({
    required this.publicId,
    required this.phoneNumber,
    required this.fullName,
    this.email,
    required this.role,
    this.status = 'ACTIVE',
    this.isStudentVerified = false,
    this.studentCardId,
    this.avatarUrl,
  });

  @override
  List<Object?> get props => [
        publicId,
        phoneNumber,
        fullName,
        email,
        role,
        status,
        isStudentVerified,
        studentCardId,
        avatarUrl,
      ];
}
