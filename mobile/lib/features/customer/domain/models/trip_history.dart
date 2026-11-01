import 'quote.dart';

class HistoryTrip {
  final String bookingPublicId;
  final DateTime createdAt;
  final DateTime tripCompletedAt;
  final Coordinates pickup;
  final Coordinates dropoff;
  final VehicleType vehicleType;
  final String finalFare;
  final String currency;
  final String status;
  final String? paymentStatus;

  const HistoryTrip({
    required this.bookingPublicId,
    required this.createdAt,
    required this.tripCompletedAt,
    required this.pickup,
    required this.dropoff,
    required this.vehicleType,
    required this.finalFare,
    required this.currency,
    required this.status,
    required this.paymentStatus,
  });

  factory HistoryTrip.fromJson(Map<String, dynamic> json) {
    final trip = HistoryTrip(
      bookingPublicId: json['bookingPublicId'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      tripCompletedAt: DateTime.parse(json['tripCompletedAt'] as String),
      pickup: Coordinates((json['pickupLatitude'] as num).toDouble(),
          (json['pickupLongitude'] as num).toDouble()),
      dropoff: Coordinates((json['dropoffLatitude'] as num).toDouble(),
          (json['dropoffLongitude'] as num).toDouble()),
      vehicleType: VehicleTypeApi.parse(json['vehicleType'] as String),
      finalFare: json['finalFare'].toString(),
      currency: json['currency'] as String,
      status: json['status'] as String,
      paymentStatus: json['paymentStatus'] as String?,
    );
    if (trip.status != 'COMPLETED' ||
        !trip.pickup.isValid ||
        !trip.dropoff.isValid ||
        (trip.paymentStatus != null &&
            trip.paymentStatus != 'PAID' &&
            trip.paymentStatus != 'PENDING')) {
      throw const FormatException('Lịch sử chuyến không hợp lệ');
    }
    return trip;
  }
}

class HistoryPage {
  final List<HistoryTrip> items;
  final int page;
  final int size;
  final int totalElements;
  final bool hasNext;

  const HistoryPage(
      this.items, this.page, this.size, this.totalElements, this.hasNext);

  factory HistoryPage.fromJson(Map<String, dynamic> json) {
    final raw = json['items'];
    if (raw is! List) {
      throw const FormatException('Danh sách chuyến không hợp lệ');
    }
    final items = raw
        .map((item) =>
            HistoryTrip.fromJson(Map<String, dynamic>.from(item as Map)))
        .toList(growable: false);
    final page = json['page'] as int;
    final size = json['size'] as int;
    final total = json['totalElements'] as int;
    final hasNext = json['hasNext'] as bool;
    if (page < 0 || size < 1 || size > 50 || items.length > size || total < 0) {
      throw const FormatException('Phân trang lịch sử không hợp lệ');
    }
    return HistoryPage(items, page, size, total, hasNext);
  }
}
