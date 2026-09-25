/// Các ngoại lệ kỹ thuật thuộc tầng Data
class ServerException implements Exception {
  final String message;
  final int? statusCode;
  final String? errorCode;

  const ServerException({
    required this.message,
    this.statusCode,
    this.errorCode,
  });

  @override
  String toString() => 'ServerException(status: $statusCode, code: $errorCode, message: $message)';
}

class NetworkException implements Exception {
  final String message;

  const NetworkException([this.message = 'Lỗi kết nối mạng']);

  @override
  String toString() => 'NetworkException: $message';
}

class UnauthorizedException implements Exception {
  final String message;
  final String? errorCode;

  const UnauthorizedException([
    this.message = 'Chưa xác thực hoặc token hết hạn',
    this.errorCode,
  ]);

  @override
  String toString() => 'UnauthorizedException(code: $errorCode, message: $message)';
}

class CacheException implements Exception {
  final String message;

  const CacheException([this.message = 'Lỗi đọc/ghi bộ nhớ']);

  @override
  String toString() => 'CacheException: $message';
}
