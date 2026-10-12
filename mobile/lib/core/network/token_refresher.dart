import 'package:dio/dio.dart';
import 'package:logger/logger.dart';
import '../config/app_config.dart';
import '../constants/api_endpoints.dart';
import '../storage/secure_storage_service.dart';

class RefreshResult {
  final String? accessToken;
  final bool transientFailure;
  const RefreshResult({this.accessToken, this.transientFailure = false});
}

/// [TokenRefresher] quản lý tập trung việc làm mới (refresh) Access Token theo phiên.
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

  final Map<int, Future<RefreshResult>> _inFlight = {};

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
  bool get isRefreshing => _inFlight.isNotEmpty;

  /// Concurrent 401s in one session share a rotation; a new session does not.
  Future<RefreshResult> refreshToken(int generation) async {
    final active = _inFlight[generation];
    if (active != null) {
      _logger.d('⏳ TokenRefresher: Đang có tiến trình refresh token chạy, xếp hàng chờ...');
      return active;
    }
    final task = _refresh(generation);
    _inFlight[generation] = task;
    try {
      return await task;
    } finally {
      _inFlight.removeWhere((key, _) => key == generation);
    }
  }

  Future<RefreshResult> _refresh(int generation) async {
    try {
      final session = await _storageService.getSession();
      if (session.generation != generation) return const RefreshResult();
      final currentRefreshToken = session.refreshToken;
      if (currentRefreshToken == null || currentRefreshToken.isEmpty) {
        _logger.w('⚠️ TokenRefresher: Không tìm thấy refreshToken trong SecureStorage.');
        await _handleAuthExpired(generation);
        return const RefreshResult();
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
            final saved = await _storageService.rotateTokensIfCurrent(
              generation: generation,
              expectedRefreshToken: currentRefreshToken,
              accessToken: newAccessToken,
              refreshToken: newRefreshToken,
            );
            return saved
                ? RefreshResult(accessToken: newAccessToken)
                : const RefreshResult();
          }
        }
      }

      _logger.e('❌ TokenRefresher: Dữ liệu response refresh không hợp lệ.');
      await _handleAuthExpired(generation);
      return const RefreshResult();
    } on DioException catch (error) {
      _logger.e('TokenRefresher: refresh failed');
      // Transient network failures do not prove that the refresh token was revoked.
      if (error.response?.statusCode == 400 || error.response?.statusCode == 401 ||
          error.response?.statusCode == 403) {
        await _handleAuthExpired(generation);
        return const RefreshResult();
      }
      return const RefreshResult(transientFailure: true);
    } catch (_) {
      _logger.e('TokenRefresher: refresh response invalid');
      await _handleAuthExpired(generation);
      return const RefreshResult();
    }
  }

  Future<void> _handleAuthExpired(int generation) async {
    if (await _storageService.clearIfCurrent(generation)) {
      onAuthenticationExpired?.call();
    }
  }
}
