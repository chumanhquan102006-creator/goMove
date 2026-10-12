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

  const Booking(
      {required this.publicId,
      required this.quotePublicId,
      required this.status,
      required this.vehicleType,
      required this.currency,
      required this.finalFare,
      required this.createdAt,
      this.driverPublicId,
      this.vehiclePublicId});

  bool get isCompleted => status == 'COMPLETED';
}
