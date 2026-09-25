import '../../../../core/constants/api_endpoints.dart';
import '../../../../core/network/api_client.dart';
import '../models/auth_token_model.dart';
import '../models/login_request_model.dart';
import '../models/refresh_token_request_model.dart';
import '../models/register_request_model.dart';
import '../models/user_model.dart';

abstract class AuthRemoteDataSource {
  Future<Map<String, dynamic>> login(LoginRequestModel request);

  Future<UserModel> register(RegisterRequestModel request);

  Future<Map<String, dynamic>> refreshToken(RefreshTokenRequestModel request);

  Future<void> logout(RefreshTokenRequestModel request);

  Future<UserModel> getCurrentUser();
}

class AuthRemoteDataSourceImpl implements AuthRemoteDataSource {
  final ApiClient _apiClient;

  AuthRemoteDataSourceImpl({required ApiClient apiClient}) : _apiClient = apiClient;

  @override
  Future<Map<String, dynamic>> login(LoginRequestModel request) async {
    final response = await _apiClient.post<Map<String, dynamic>>(
      ApiEndpoints.login,
      data: request.toJson(),
    );

    final rawData = response.data;
    final Map<String, dynamic> data = (rawData?['data'] is Map<String, dynamic>)
        ? rawData!['data'] as Map<String, dynamic>
        : rawData ?? <String, dynamic>{};

    final token = AuthTokenModel.fromJson(data);
    final userJson = data['user'] as Map<String, dynamic>? ?? <String, dynamic>{};
    final user = UserModel.fromJson(userJson);

    return {
      'token': token,
      'user': user,
    };
  }

  @override
  Future<UserModel> register(RegisterRequestModel request) async {
    final response = await _apiClient.post<Map<String, dynamic>>(
      ApiEndpoints.register,
      data: request.toJson(),
    );

    final rawData = response.data;
    final Map<String, dynamic> data = (rawData?['data'] is Map<String, dynamic>)
        ? rawData!['data'] as Map<String, dynamic>
        : rawData ?? <String, dynamic>{};

    return UserModel.fromJson(data);
  }

  @override
  Future<Map<String, dynamic>> refreshToken(RefreshTokenRequestModel request) async {
    final response = await _apiClient.post<Map<String, dynamic>>(
      ApiEndpoints.refresh,
      data: request.toJson(),
    );

    final rawData = response.data;
    final Map<String, dynamic> data = (rawData?['data'] is Map<String, dynamic>)
        ? rawData!['data'] as Map<String, dynamic>
        : rawData ?? <String, dynamic>{};

    final token = AuthTokenModel.fromJson(data);
    UserModel? user;
    if (data['user'] is Map<String, dynamic>) {
      user = UserModel.fromJson(data['user'] as Map<String, dynamic>);
    }

    return {
      'token': token,
      'user': user,
    };
  }

  @override
  Future<void> logout(RefreshTokenRequestModel request) async {
    await _apiClient.post<Map<String, dynamic>>(
      ApiEndpoints.logout,
      data: request.toJson(),
    );
  }

  @override
  Future<UserModel> getCurrentUser() async {
    final response = await _apiClient.get<Map<String, dynamic>>(ApiEndpoints.me);

    final rawData = response.data;
    final Map<String, dynamic> data = (rawData?['data'] is Map<String, dynamic>)
        ? rawData!['data'] as Map<String, dynamic>
        : rawData ?? <String, dynamic>{};

    return UserModel.fromJson(data);
  }
}
