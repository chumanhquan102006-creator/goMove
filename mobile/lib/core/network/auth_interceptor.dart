import 'package:dio/dio.dart';
import '../storage/secure_storage_service.dart';
import 'token_refresher.dart';

/// [AuthInterceptor] chịu trách nhiệm:
/// 1. Tự động đính kèm Access Token vào Header của các Request cần bảo mật.
/// 2. Bắt lỗi 401 Unauthorized, kích hoạt TokenRefresher để thực hiện Token Rotation an toàn,
///    sau đó retry lại request ban đầu với Access Token mới (Mục D.2 & F).
class AuthInterceptor extends Interceptor {
  static const _retried = 'authRetried';
  static const sessionGenerationExtraKey = 'gomoveAuthSessionGeneration';
  static const _sessionGeneration = sessionGenerationExtraKey;
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
      final session = await _storageService.getSession();
      final origin = options.extra[_sessionGeneration];
      if (origin != null && origin != session.generation) {
        return handler.reject(DioException(
          requestOptions: options,
          type: DioExceptionType.cancel,
          message: 'Authenticated session changed',
        ));
      }
      final token = session.accessToken;
      if (token != null && token.isNotEmpty) {
        options.extra[_sessionGeneration] ??= session.generation;
        options.headers['Authorization'] = 'Bearer $token';
      } else {
        if (session.refreshToken != null && session.refreshToken!.isNotEmpty) {
          options.extra[_sessionGeneration] ??= session.generation;
        }
        options.headers.remove('Authorization');
      }
    }

    options.headers['Accept'] = 'application/json';
    options.headers['Content-Type'] = 'application/json';

    return handler.next(options);
  }

  @override
  Future<void> onResponse(Response<dynamic> response,
      ResponseInterceptorHandler handler) async {
    final origin = response.requestOptions.extra[_sessionGeneration];
    if (origin is int &&
        !await _storageService.isCurrentSession(origin)) {
      return handler.reject(DioException(
        requestOptions: response.requestOptions,
        type: DioExceptionType.cancel,
        message: 'Authenticated session changed',
      ));
    }
    return handler.next(response);
  }

  @override
  Future<void> onError(DioException err, ErrorInterceptorHandler handler) async {
    final response = err.response;
    final statusCode = response?.statusCode;
    final requestPath = err.requestOptions.path;

    // Chỉ can thiệp khi gặp lỗi 401 Unauthorized
    if (statusCode == 401 && err.requestOptions.extra[_retried] != true) {
      // Public auth calls are not tied to a protected request session. In
      // particular, their late 401 must never clear a newer login session.
      if (requestPath.contains('/auth/refresh') ||
          requestPath.contains('/auth/login') ||
          requestPath.contains('/auth/register')) {
        return handler.next(err);
      }

      final requestOptions = err.requestOptions;
      final origin = requestOptions.extra[_sessionGeneration];
      if (origin is! int) return handler.next(err);
      var current = await _storageService.getSession();
      if (current.generation != origin) return handler.next(err);
      final failedBearer = requestOptions.headers['Authorization'];
      final currentAccess = current.accessToken;
      String? newAccessToken;
      var transientFailure = false;
      if (currentAccess != null && currentAccess.isNotEmpty &&
          failedBearer != 'Bearer $currentAccess') {
        newAccessToken = currentAccess;
      } else {
        final result = await _tokenRefresher.refreshToken(origin);
        newAccessToken = result.accessToken;
        transientFailure = result.transientFailure;
      }

      current = await _storageService.getSession();
      if (current.generation != origin) return handler.next(err);

      if (newAccessToken != null && newAccessToken.isNotEmpty) {
        // A second same-session rotation may have completed; use its latest token.
        newAccessToken = current.accessToken;
      }
      if (newAccessToken != null && newAccessToken.isNotEmpty) {
        // Cập nhật header với token mới và thực hiện retry request
        requestOptions.extra[_retried] = true;
        requestOptions.headers['Authorization'] = 'Bearer $newAccessToken';

        try {
          final retryResponse = await _getDio().fetch<dynamic>(requestOptions);
          return handler.resolve(retryResponse);
        } on DioException catch (retryError) {
          return handler.next(retryError);
        }
      }
      if (transientFailure) {
        return handler.next(DioException(
          requestOptions: err.requestOptions,
          type: DioExceptionType.connectionError,
          message: 'Token refresh transport unavailable',
        ));
      }
    }

    return handler.next(err);
  }
}
