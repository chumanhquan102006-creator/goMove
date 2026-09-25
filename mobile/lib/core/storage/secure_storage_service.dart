import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../constants/storage_keys.dart';

/// Dịch vụ quản lý bộ nhớ bảo mật lưu trữ JWT tokens & phiên đăng nhập (Điều 139)
abstract class SecureStorageService {
  Future<void> saveTokens({required String accessToken, required String refreshToken});
  Future<String?> getAccessToken();
  Future<String?> getRefreshToken();
  Future<void> saveUserPublicId(String publicId);
  Future<String?> getUserPublicId();
  Future<void> clearAll();
}

class SecureStorageServiceImpl implements SecureStorageService {
  final FlutterSecureStorage _storage;

  SecureStorageServiceImpl({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(
                encryptedSharedPreferences: true,
              ),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock,
              ),
            );

  @override
  Future<void> saveTokens({required String accessToken, required String refreshToken}) async {
    await Future.wait([
      _storage.write(key: StorageKeys.accessToken, value: accessToken),
      _storage.write(key: StorageKeys.refreshToken, value: refreshToken),
    ]);
  }

  @override
  Future<String?> getAccessToken() async {
    return _storage.read(key: StorageKeys.accessToken);
  }

  @override
  Future<String?> getRefreshToken() async {
    return _storage.read(key: StorageKeys.refreshToken);
  }

  @override
  Future<void> saveUserPublicId(String publicId) async {
    await _storage.write(key: StorageKeys.userPublicId, value: publicId);
  }

  @override
  Future<String?> getUserPublicId() async {
    return _storage.read(key: StorageKeys.userPublicId);
  }

  @override
  Future<void> clearAll() async {
    await _storage.deleteAll();
  }
}
