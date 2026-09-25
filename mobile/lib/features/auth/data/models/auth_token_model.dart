import '../../domain/entities/auth_token.dart';

class AuthTokenModel extends AuthToken {
  const AuthTokenModel({
    required super.accessToken,
    required super.refreshToken,
    super.tokenType,
    super.expiresIn,
  });

  factory AuthTokenModel.fromJson(Map<String, dynamic> json) {
    return AuthTokenModel(
      accessToken: json['accessToken'] as String,
      refreshToken: json['refreshToken'] as String,
      tokenType: json['tokenType'] as String? ?? 'Bearer',
      expiresIn: json['expiresIn'] as int? ?? 86400,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'accessToken': accessToken,
      'refreshToken': refreshToken,
      'tokenType': tokenType,
      'expiresIn': expiresIn,
    };
  }
}
