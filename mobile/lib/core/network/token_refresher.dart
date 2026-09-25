import 'dart:async';
import 'package:dio/dio.dart';
import 'package:logger/logger.dart';
import '../config/app_config.dart';
import '../constants/api_endpoints.dart';
import '../storage/secure_storage_service.dart';

/// [TokenRefresher] quản lý tập trung việc làm mới (refresh) Access Token bằng cờ Mutex / Completer.
/// Đảm bảo nếu có nhiều request đồng thời gặp lỗi 401 Unauthorized, CHỈ CÓ DUY NHẤT 1 request
/// gọi endpoint `/api/v1/auth/refresh`, các request còn lại sẽ đợi kết quả và retry đồng bộ,
/// tránh race-condition vi phạm Token Rotation của Spring Boot Backend (Mục C.1 & F).
class TokenRefresher {
  final SecureStorageService _storageService;
  final Dio _refreshDio;
  final void Function()? onAuthenticationExpired;
  final Logger _logger = Logger(
    printer: PrettyPrinter(
      methodCount: 0,
      lineLength: 80,
      colors: true,
      printEmojis: true,
    ),
  );

  Completer<String?>? _refreshCompleter;

  TokenRefresher({
    required SecureStorageService storageService,
    required AppConfig config,
    Dio? refreshDio,
    this.onAuthenticationExpired,
  })  : _storageService = storageService,
        _refreshDio = refreshDio ??
            Dio(
              BaseOptions(
                baseUrl: config.apiBaseUrl,
                connectTimeout: config.connectTimeout,
                receiveTimeout: config.receiveTimeout,
                sendTimeout: config.sendTimeout,
                headers: {
                  'Accept': 'application/json',
                  'Content-Type': 'application/json',
                },
              ),
            );

  /// Kiểm tra xem hiện tại có tiến trình refresh token đang chạy hay không
  bool get isRefreshing => _refreshCompleter != null;

  /// Thực hiện làm mới Access Token với Mutex Lock
  Future<String?> refreshToken() async {
    // Nếu đã có một tiến trình refresh đang chạy, các request khác chỉ cần await Completer này
    if (_refreshCompleter != null) {
      _logger.d('⏳ TokenRefresher: Đang có tiến trình refresh token chạy, xếp hàng chờ...');
      return _refreshCompleter!.future;
    }

    final completer = Completer<String?>();
    _refreshCompleter = completer;

    try {
      final currentRefreshToken = await _storageService.getRefreshToken();
      if (currentRefreshToken == null || currentRefreshToken.isEmpty) {
        _logger.w('⚠️ TokenRefresher: Không tìm thấy refreshToken trong SecureStorage.');
        await _handleAuthExpired();
        completer.complete(null);
        return null;
      }

      _logger.i('🔄 TokenRefresher: Đang gửi yêu cầu Token Rotation tới ${ApiEndpoints.refresh}...');

      final response = await _refreshDio.post<Map<String, dynamic>>(
        ApiEndpoints.refresh,
        data: {'refreshToken': currentRefreshToken},
      );

      final responseData = response.data;
      if (response.statusCode == 200 && responseData != null) {
        final data = responseData['data'] as Map<String, dynamic>?;
        if (data != null) {
          final newAccessToken = data['accessToken'] as String?;
          final newRefreshToken = data['refreshToken'] as String?;

          if (newAccessToken != null && newRefreshToken != null) {
            _logger.i('✅ TokenRefresher: Hoán đổi token thành công! Đang lưu vào SecureStorage...');
            await _storageService.saveTokens(
              accessToken: newAccessToken,
              refreshToken: newRefreshToken,
            );

            completer.complete(newAccessToken);
            return newAccessToken;
          }
        }
      }

      _logger.e('❌ TokenRefresher: Dữ liệu response refresh không hợp lệ.');
      await _handleAuthExpired();
      completer.complete(null);
      return null;
    } catch (e) {
      _logger.e('❌ TokenRefresher: Refresh token thất bại hoặc bị thu hồi (401/Invalid): $e');
      await _handleAuthExpired();
      completer.complete(null);
      return null;
    } finally {
      _refreshCompleter = null;
    }
  }

  Future<void> _handleAuthExpired() async {
    await _storageService.clearAll();
    onAuthenticationExpired?.call();
  }
}
