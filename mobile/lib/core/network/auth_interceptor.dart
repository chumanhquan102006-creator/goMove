import 'package:dio/dio.dart';
import '../storage/secure_storage_service.dart';
import 'token_refresher.dart';

/// [AuthInterceptor] chịu trách nhiệm:
/// 1. Tự động đính kèm Access Token vào Header của các Request cần bảo mật.
/// 2. Bắt lỗi 401 Unauthorized, kích hoạt TokenRefresher để thực hiện Token Rotation an toàn,
///    sau đó retry lại request ban đầu với Access Token mới (Mục D.2 & F).
class AuthInterceptor extends QueuedInterceptor {
  final SecureStorageService _storageService;
  final TokenRefresher _tokenRefresher;
  final Dio Function() _getDio;

  AuthInterceptor({
    required SecureStorageService storageService,
    required TokenRefresher tokenRefresher,
    required Dio Function() getDio,
  })  : _storageService = storageService,
        _tokenRefresher = tokenRefresher,
        _getDio = getDio;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final path = options.path;
    // Bỏ qua đính kèm token đối với các API public (login, register, refresh)
    final isPublicPath = path.contains('/auth/login') ||
        path.contains('/auth/register') ||
        path.contains('/auth/refresh');

    if (!isPublicPath) {
      final token = await _storageService.getAccessToken();
      if (token != null && token.isNotEmpty) {
        options.headers['Authorization'] = 'Bearer $token';
      }
    }

    options.headers['Accept'] = 'application/json';
    options.headers['Content-Type'] = 'application/json';

    return handler.next(options);
  }

  @override
  Future<void> onError(DioException err, ErrorInterceptorHandler handler) async {
    final response = err.response;
    final statusCode = response?.statusCode;
    final requestPath = err.requestOptions.path;

    // Chỉ can thiệp khi gặp lỗi 401 Unauthorized
    if (statusCode == 401) {
      // 1. Nếu chính request `/auth/refresh` hoặc `/auth/login` bị 401:
      // Tuyệt đối KHÔNG thử refresh lại để tránh vòng lặp vô hạn (Infinite loop).
      if (requestPath.contains('/auth/refresh') ||
          requestPath.contains('/auth/login') ||
          requestPath.contains('/auth/register')) {
        if (requestPath.contains('/auth/refresh')) {
          await _storageService.clearAll();
          _tokenRefresher.onAuthenticationExpired?.call();
        }
        return handler.next(err);
      }

      // 2. Với các request nghiệp vụ thông thường: Kích hoạt Token Rotation qua Mutex Lock
      final newAccessToken = await _tokenRefresher.refreshToken();

      if (newAccessToken != null && newAccessToken.isNotEmpty) {
        // Cập nhật header với token mới và thực hiện retry request
        final requestOptions = err.requestOptions;
        requestOptions.headers['Authorization'] = 'Bearer $newAccessToken';

        try {
          final retryResponse = await _getDio().fetch(requestOptions);
          return handler.resolve(retryResponse);
        } on DioException catch (retryError) {
          return handler.next(retryError);
        }
      }
    }

    return handler.next(err);
  }
}
