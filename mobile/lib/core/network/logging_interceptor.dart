import 'package:dio/dio.dart';
import 'package:logger/logger.dart';

/// Interceptor ghi log request/response của HTTP Client một cách trực quan trong quá trình debug
class LoggingInterceptor extends Interceptor {
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

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    _logger.i('🌐 [HTTP REQUEST] ${options.method} --> ${options.uri}\n'
        'Headers: ${options.headers}\n'
        'Data: ${options.data}');
    super.onRequest(options, handler);
  }

  @override
  void onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) {
    _logger.d('✅ [HTTP RESPONSE] ${response.statusCode} <-- ${response.requestOptions.uri}\n'
        'Payload: ${response.data}');
    super.onResponse(response, handler);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    _logger.e('❌ [HTTP ERROR] ${err.response?.statusCode} <-- ${err.requestOptions.uri}\n'
        'Message: ${err.message}\n'
        'Response: ${err.response?.data}');
    super.onError(err, handler);
  }
}
