import 'quote.dart';

class Booking {
  final String publicId;
  final String quotePublicId;
  final String status;
  final VehicleType vehicleType;
  final String currency;
  final String finalFare;
  final DateTime createdAt;
  final String? driverPublicId;
  final String? vehiclePublicId;
  final Coordinates? pickup;
  final Coordinates? dropoff;
  final String? distanceMeters;
  final String? durationSeconds;
  final DateTime? tripCompletedAt;
  final DateTime? cancelledAt;
  final String? cancelledBy;
  final DateTime? dispatchFailedAt;

  const Booking(
      {required this.publicId,
      required this.quotePublicId,
      required this.status,
      required this.vehicleType,
      required this.currency,
      required this.finalFare,
      required this.createdAt,
      this.driverPublicId,
      this.vehiclePublicId,
      this.pickup,
      this.dropoff,
      this.distanceMeters,
      this.durationSeconds,
      this.tripCompletedAt,
      this.cancelledAt,
      this.cancelledBy,
      this.dispatchFailedAt});

  bool get isCompleted => status == 'COMPLETED';
}
