import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

/// Interceptor ghi log request/response của HTTP Client một cách trực quan trong quá trình debug
class LoggingInterceptor extends Interceptor {
  LoggingInterceptor({void Function(String)? log}) : _log = log;

  final void Function(String)? _log;
  final Logger _logger = Logger(
    printer: PrettyPrinter(
      methodCount: 0,
      errorMethodCount: 5,
      lineLength: 90,
      colors: true,
      printEmojis: true,
      dateTimeFormat: DateTimeFormat.onlyTimeAndSinceStart,
    ),
  );

  void _write(String message) {
    if (_log != null) {
      _log(message);
    } else if (kDebugMode) {
      _logger.d(message);
    }
  }

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    _write('HTTP ${options.method} ${options.uri.path}');
    super.onRequest(options, handler);
  }

  @override
  void onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) {
    _write('HTTP ${response.statusCode} ${response.requestOptions.uri.path}');
    super.onResponse(response, handler);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    _write('HTTP error ${err.response?.statusCode ?? 'network'} ${err.requestOptions.uri.path}');
    super.onError(err, handler);
  }
}
