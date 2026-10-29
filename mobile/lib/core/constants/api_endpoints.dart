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
  static String quoteRoute(String publicId) => '/quotes/$publicId/route';
  static const String bookings = '/bookings';
  static String booking(String publicId) => '/bookings/$publicId';
  static String bookingRoute(String publicId) => '/bookings/$publicId/route';
  static String bookingTracking(String publicId) =>
      '/bookings/$publicId/tracking';
  static String bookingEta(String publicId) => '/bookings/$publicId/eta';
  static String bookingPayment(String publicId) =>
      '/bookings/$publicId/payment';
  static String driverTripAction(String bookingPublicId, String action) =>
      '/drivers/me/trips/$bookingPublicId/$action';
  static String confirmTripCash(String bookingPublicId) =>
      '/drivers/me/trips/$bookingPublicId/cash/confirm';

  static const String driverOnboarding = '/drivers/onboarding';
  static const String driverOperatingStatus = '/drivers/me/operating-status';
  static const String driverVehicles = '/drivers/me/vehicles';
  static String activateDriverVehicle(String publicId) =>
      '/drivers/me/vehicles/$publicId/activate';
  static const String driverLocation = '/drivers/me/location';
  static const String activeDriverOffers = '/drivers/me/offers/active';
  static String acceptDriverOffer(String publicId) =>
      '/drivers/me/offers/$publicId/accept';
  static String rejectDriverOffer(String publicId) =>
      '/drivers/me/offers/$publicId/reject';
}
