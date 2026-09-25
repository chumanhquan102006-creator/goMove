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

  // Ride Hailing & Booking
  static const String estimateFare = '/rides/estimate';
  static const String createBooking = '/rides/booking';
  static String rideDetail(String publicId) => '/rides/$publicId';
  static String cancelRide(String publicId) => '/rides/$publicId/cancel';

  // Driver Operations
  static String acceptRide(String publicId) => '/driver/rides/$publicId/accept';
  static String startRide(String publicId) => '/driver/rides/$publicId/start';
  static String completeRide(String publicId) => '/driver/rides/$publicId/complete';
  static const String updateLocation = '/driver/location';

  // WebSocket STOMP Topics & Destinations
  static const String wsEndpoint = '/ws';
  static const String wsTopicRides = '/topic/rides';
  static String wsUserRideUpdates(String userPublicId) => '/user/$userPublicId/queue/rides';
  static String wsDriverRideUpdates(String driverPublicId) => '/driver/$driverPublicId/queue/rides';
}
