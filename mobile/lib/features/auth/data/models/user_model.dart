import '../../domain/entities/user.dart';

/// DTO / Model ánh xạ dữ liệu User từ REST API Backend Spring Boot
/// Tuân thủ quy tắc backend: publicId là UUID string.
class UserModel extends User {
  const UserModel({
    required super.publicId,
    required super.phoneNumber,
    required super.fullName,
    super.email,
    required super.role,
    super.status,
    super.isStudentVerified,
    super.studentCardId,
    super.avatarUrl,
  });

  factory UserModel.fromJson(Map<String, dynamic> json) {
    return UserModel(
      publicId: json['publicId'] as String,
      phoneNumber: (json['phone'] ?? json['phoneNumber']) as String,
      fullName: json['fullName'] as String,
      email: json['email'] as String?,
      role: (json['role'] as String? ?? 'CUSTOMER').toUpperCase() == 'DRIVER'
          ? UserRole.driver
          : UserRole.customer,
      status: json['status'] as String? ?? 'ACTIVE',
      isStudentVerified: json['isStudentVerified'] as bool? ?? false,
      studentCardId: json['studentCardId'] as String?,
      avatarUrl: json['avatarUrl'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'publicId': publicId,
      'phone': phoneNumber,
      'phoneNumber': phoneNumber,
      'fullName': fullName,
      'email': email,
      'role': role == UserRole.driver ? 'DRIVER' : 'CUSTOMER',
      'status': status,
      'isStudentVerified': isStudentVerified,
      'studentCardId': studentCardId,
      'avatarUrl': avatarUrl,
    };
  }

  User toEntity() => this;
}
