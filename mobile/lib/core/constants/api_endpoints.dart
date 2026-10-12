/// Định nghĩa các Endpoint REST API chuẩn theo hợp đồng Backend Modular Monolith Spring Boot.
/// Tuyệt đối tuân thủ sử dụng publicId (UUID string), không sử dụng numeric ID (Điều 9).
class ApiEndpoints {
  ApiEndpoints._();

  // Auth & Identity (Spring Boot Monolith /api/v1/auth/*)
  static const String register = '/auth/register';
  static const String login = '/auth/login';
  static const String refresh = '/auth/refresh';
  static const String refreshToken = '/auth/refresh'; // Alias tương thích
  static const String logout = '/auth/logout';
  static const String me = '/auth/me';

  static const String quotes = '/quotes';
  static String quote(String publicId) => '/quotes/$publicId';
  static const String bookings = '/bookings';
  static String booking(String publicId) => '/bookings/$publicId';
}
