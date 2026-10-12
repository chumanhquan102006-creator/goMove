import 'dart:async';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../constants/storage_keys.dart';

/// In-memory generation changes on every login/logout, but not on rotation.
/// Requests keep only [generation], never tokens, in Dio's request metadata.
class AuthSessionSnapshot {
  final int generation;
  final String? accessToken;
  final String? refreshToken;

  const AuthSessionSnapshot(this.generation, this.accessToken, this.refreshToken);
}

/// Dịch vụ quản lý bộ nhớ bảo mật lưu trữ JWT tokens & phiên đăng nhập (Điều 139)
abstract class SecureStorageService {
  Future<void> saveTokens({required String accessToken, required String refreshToken,
    String? userPublicId});
  Future<String?> getAccessToken();
  Future<String?> getRefreshToken();
  Future<void> saveUserPublicId(String publicId);
  Future<String?> getUserPublicId();
  Future<void> clearAll();
  Future<AuthSessionSnapshot> getSession();
  Future<bool> isCurrentSession(int generation);
  Future<bool> rotateTokensIfCurrent({required int generation,
    required String expectedRefreshToken, required String accessToken,
    required String refreshToken});
  Future<bool> saveUserPublicIdIfCurrent(int generation, String publicId);
  Future<bool> clearIfCurrent(int generation);
}

class SecureStorageServiceImpl implements SecureStorageService {
  final FlutterSecureStorage _storage;
  int _generation = 0;
  Future<void> _pending = Future<void>.value();

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

  Future<T> _synchronized<T>(Future<T> Function() action) async {
    final previous = _pending;
    final release = Completer<void>();
    _pending = release.future;
    await previous;
    try {
      return await action();
    } finally {
      release.complete();
    }
  }

  @override
  Future<void> saveTokens({required String accessToken,
      required String refreshToken, String? userPublicId}) => _synchronized(() async {
    // A login is a new session even if it is the same account.
    await _storage.write(key: StorageKeys.refreshToken, value: refreshToken);
    await _storage.write(key: StorageKeys.accessToken, value: accessToken);
    if (userPublicId == null) {
      await _storage.delete(key: StorageKeys.userPublicId);
    } else {
      await _storage.write(key: StorageKeys.userPublicId, value: userPublicId);
    }
    _generation++;
  });

  @override
  Future<AuthSessionSnapshot> getSession() => _synchronized(() async =>
      AuthSessionSnapshot(
        _generation,
        await _storage.read(key: StorageKeys.accessToken),
        await _storage.read(key: StorageKeys.refreshToken),
      ));

  @override
  Future<bool> isCurrentSession(int generation) =>
      _synchronized(() async => _generation == generation);

  @override
  Future<bool> rotateTokensIfCurrent({required int generation,
      required String expectedRefreshToken, required String accessToken,
      required String refreshToken}) => _synchronized(() async {
    if (_generation != generation ||
        await _storage.read(key: StorageKeys.refreshToken) != expectedRefreshToken) {
      return false;
    }
    // Rotation keeps the generation; only a new login/logout replaces it.
    await _storage.write(key: StorageKeys.refreshToken, value: refreshToken);
    await _storage.write(key: StorageKeys.accessToken, value: accessToken);
    return true;
  });

  @override
  Future<bool> saveUserPublicIdIfCurrent(int generation, String publicId) =>
      _synchronized(() async {
    if (_generation != generation) return false;
    await _storage.write(key: StorageKeys.userPublicId, value: publicId);
    return true;
  });

  @override
  Future<bool> clearIfCurrent(int generation) => _synchronized(() async {
    if (_generation != generation) return false;
    await _clear();
    return true;
  });

  Future<void> _clear() async {
    _generation++;
    await _storage.delete(key: StorageKeys.accessToken);
    await _storage.delete(key: StorageKeys.refreshToken);
    await _storage.delete(key: StorageKeys.userPublicId);
  }

  @override
  Future<String?> getAccessToken() => _synchronized(() =>
      _storage.read(key: StorageKeys.accessToken));

  @override
  Future<String?> getRefreshToken() => _synchronized(() =>
      _storage.read(key: StorageKeys.refreshToken));

  @override
  Future<void> saveUserPublicId(String publicId) => _synchronized(() =>
      _storage.write(key: StorageKeys.userPublicId, value: publicId));

  @override
  Future<String?> getUserPublicId() => _synchronized(() =>
      _storage.read(key: StorageKeys.userPublicId));

  @override
  Future<void> clearAll() => _synchronized(_clear);
}
