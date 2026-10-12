import 'dart:io';
import 'package:dio/dio.dart';
import '../config/app_config.dart';
import '../error/exceptions.dart';
import 'auth_interceptor.dart';
import 'logging_interceptor.dart';

/// [ApiClient] đóng gói Dio Client, xử lý tập trung cấu hình mạng,
/// headers, timeout và chuyển đổi DioException thành các Exception chuẩn của ứng dụng.
class ApiClient {
  final Dio _dio;

  ApiClient({
    required AppConfig config,
    required AuthInterceptor authInterceptor,
    Dio? customDio,
  }) : _dio = customDio ??
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
            ) {
    _dio.interceptors.addAll([
      authInterceptor,
      LoggingInterceptor(),
    ]);
  }

  Dio get dioInstance => _dio;

  Future<Response<T>> get<T>(
    String path, {
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
  }) async {
    try {
      return await _dio.get<T>(
        path,
        queryParameters: queryParameters,
        options: options,
        cancelToken: cancelToken,
      );
    } on DioException catch (e) {
      throw _handleDioError(e);
    }
  }

  Future<Response<T>> post<T>(
    String path, {
    dynamic data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
  }) async {
    try {
      return await _dio.post<T>(
        path,
        data: data,
        queryParameters: queryParameters,
        options: options,
        cancelToken: cancelToken,
      );
    } on DioException catch (e) {
      throw _handleDioError(e);
    }
  }

  Future<Response<T>> put<T>(
    String path, {
    dynamic data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
  }) async {
    try {
      return await _dio.put<T>(
        path,
        data: data,
        queryParameters: queryParameters,
        options: options,
        cancelToken: cancelToken,
      );
    } on DioException catch (e) {
      throw _handleDioError(e);
    }
  }

  Future<Response<T>> delete<T>(
    String path, {
    dynamic data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
  }) async {
    try {
      return await _dio.delete<T>(
        path,
        data: data,
        queryParameters: queryParameters,
        options: options,
        cancelToken: cancelToken,
      );
    } on DioException catch (e) {
      throw _handleDioError(e);
    }
  }

  Exception _handleDioError(DioException error) {
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.connectionError ||
        error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.error is SocketException) {
      return const NetworkException('Không thể kết nối đến máy chủ GoMove. Vui lòng kiểm tra lại mạng.');
    }

    final response = error.response;
    if (response != null) {
      final statusCode = response.statusCode;
      final dynamic responseData = response.data;
      String message = 'Đã có lỗi xảy ra từ máy chủ.';
      String? errorCode;
      final details = <String, String>{};

      if (responseData is Map) {
        message = responseData['message']?.toString() ?? message;
        errorCode = responseData['code']?.toString() ?? responseData['errorCode']?.toString();
        final rawDetails = responseData['details'];
        if (rawDetails is Map) {
          for (final entry in rawDetails.entries) {
            if (entry.key is String && entry.value is String) {
              details[entry.key as String] = entry.value as String;
            }
          }
        }
      }

      if (statusCode == 401 && (errorCode == null || errorCode.isEmpty)) {
        return UnauthorizedException(message, errorCode);
      }

      return ServerException(
        message: message,
        statusCode: statusCode,
        errorCode: errorCode,
        details: details,
      );
    }

    return ServerException(message: error.message ?? 'Lỗi không xác định.');
  }
}
