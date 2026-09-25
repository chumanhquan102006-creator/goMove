import '../../../../core/storage/secure_storage_service.dart';

abstract class AuthLocalDataSource {
  Future<void> saveTokens({required String accessToken, required String refreshToken});
  Future<String?> getAccessToken();
  Future<String?> getRefreshToken();
  Future<void> saveUserPublicId(String publicId);
  Future<String?> getUserPublicId();
  Future<void> clearAuthData();
}

class AuthLocalDataSourceImpl implements AuthLocalDataSource {
  final SecureStorageService _storageService;

  AuthLocalDataSourceImpl({required SecureStorageService storageService})
      : _storageService = storageService;

  @override
  Future<void> saveTokens({required String accessToken, required String refreshToken}) async {
    await _storageService.saveTokens(accessToken: accessToken, refreshToken: refreshToken);
  }

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
