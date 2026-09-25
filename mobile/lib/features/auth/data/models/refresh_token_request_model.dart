/// DTO Request cho Token Refresh và Logout (Mục E.4 & E.5)
class RefreshTokenRequestModel {
  final String refreshToken;

  const RefreshTokenRequestModel({
    required this.refreshToken,
  });

  Map<String, dynamic> toJson() {
    return {
      'refreshToken': refreshToken,
    };
  }
}
