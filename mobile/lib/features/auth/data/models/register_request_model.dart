/// DTO Request gửi lên Backend cho luồng Đăng ký (CUSTOMER ONLY - Mục E.1)
class RegisterRequestModel {
  final String phone;
  final String? email;
  final String password;
  final String fullName;

  const RegisterRequestModel({
    required this.phone,
    this.email,
    required this.password,
    required this.fullName,
  });

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{
      'phone': phone,
      'password': password,
      'fullName': fullName,
    };
    if (email != null && email!.trim().isNotEmpty) {
      map['email'] = email!.trim();
    }
    return map;
  }
}
