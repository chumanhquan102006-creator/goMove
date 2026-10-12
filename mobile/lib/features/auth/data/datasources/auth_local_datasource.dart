import '../../../../core/storage/secure_storage_service.dart';

abstract class AuthLocalDataSource {
  Future<void> saveTokens({required String accessToken, required String refreshToken,
    String? userPublicId});
  Future<String?> getAccessToken();
  Future<String?> getRefreshToken();
  Future<void> saveUserPublicId(String publicId);
  Future<String?> getUserPublicId();
  Future<void> clearAuthData();
  Future<AuthSessionSnapshot> getSession();
  Future<bool> isCurrentSession(int generation);
  Future<bool> saveUserPublicIdIfCurrent(int generation, String publicId);
  Future<bool> clearAuthDataIfCurrent(int generation);
}

class AuthLocalDataSourceImpl implements AuthLocalDataSource {
  final SecureStorageService _storageService;

  AuthLocalDataSourceImpl({required SecureStorageService storageService})
      : _storageService = storageService;

  @override
  Future<void> saveTokens({required String accessToken,
      required String refreshToken, String? userPublicId}) async {
    await _storageService.saveTokens(accessToken: accessToken,
        refreshToken: refreshToken, userPublicId: userPublicId);
  }

  @override
  Future<AuthSessionSnapshot> getSession() => _storageService.getSession();

  @override
  Future<bool> isCurrentSession(int generation) =>
      _storageService.isCurrentSession(generation);

  @override
  Future<bool> saveUserPublicIdIfCurrent(int generation, String publicId) =>
      _storageService.saveUserPublicIdIfCurrent(generation, publicId);

  @override
  Future<bool> clearAuthDataIfCurrent(int generation) =>
      _storageService.clearIfCurrent(generation);

  @override
  Future<String?> getAccessToken() => _storageService.getAccessToken();

  @override
  Future<String?> getRefreshToken() => _storageService.getRefreshToken();

  @override
  Future<void> saveUserPublicId(String publicId) => _storageService.saveUserPublicId(publicId);

  @override
  Future<String?> getUserPublicId() => _storageService.getUserPublicId();

  @override
  Future<void> clearAuthData() => _storageService.clearAll();
}
