/// Wrapper định dạng chuẩn của toàn bộ phản hồi từ Spring Boot Backend GoMove:
/// {
///   "success": true,
///   "code": "SUCCESS",
///   "message": "...",
///   "data": { ... },
///   "timestamp": "2026-09-24T12:00:00Z"
/// }
class ApiResponseModel<T> {
  final bool success;
  final String code;
  final String message;
  final T? data;
  final String? timestamp;
  final String? path;
  final List<String>? details;

  const ApiResponseModel({
    required this.success,
    required this.code,
    required this.message,
    this.data,
    this.timestamp,
    this.path,
    this.details,
  });

  factory ApiResponseModel.fromJson(
    Map<String, dynamic> json,
    T Function(dynamic json)? fromJsonT,
  ) {
    return ApiResponseModel<T>(
      success: json['success'] as bool? ?? false,
      code: json['code'] as String? ?? '',
      message: json['message'] as String? ?? '',
      data: json['data'] != null && fromJsonT != null
          ? fromJsonT(json['data'])
          : json['data'] as T?,
      timestamp: json['timestamp'] as String?,
      path: json['path'] as String?,
      details: (json['details'] as List<dynamic>?)?.map((e) => e.toString()).toList(),
    );
  }
}
