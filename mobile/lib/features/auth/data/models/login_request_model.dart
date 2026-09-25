/// DTO Request gửi lên Backend cho luồng Đăng nhập (Mục E.2)
class LoginRequestModel {
  final String identifier;
  final String password;

  const LoginRequestModel({
    required this.identifier,
    required this.password,
  });

  Map<String, dynamic> toJson() {
    return {
      'identifier': identifier,
      'password': password,
    };
  }
}
