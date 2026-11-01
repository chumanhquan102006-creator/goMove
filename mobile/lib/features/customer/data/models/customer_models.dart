import '../../domain/models/booking.dart';
import '../../domain/models/quote.dart';

class CustomerModels {
  static Map<String, dynamic> payload(dynamic response) {
    if (response is! Map<String, dynamic> ||
        response['data'] is! Map<String, dynamic>) {
      throw const FormatException('Invalid API response');
    }
    return response['data'] as Map<String, dynamic>;
  }

  static Quote quote(Map<String, dynamic> json) {
    final pickup = json['pickup'] as Map<String, dynamic>;
    final dropoff = json['dropoff'] as Map<String, dynamic>;
    return Quote(
      publicId: json['quotePublicId'] as String,
      pickup: Coordinates((pickup['latitude'] as num).toDouble(),
          (pickup['longitude'] as num).toDouble()),
      dropoff: Coordinates((dropoff['latitude'] as num).toDouble(),
          (dropoff['longitude'] as num).toDouble()),
      vehicleType: VehicleTypeApi.parse(json['vehicleType'] as String),
      distanceMeters: json['distanceMeters'].toString(),
      durationSeconds: json['durationSeconds'].toString(),
      currency: json['currency'] as String,
      baseFare: json['baseFare'].toString(),
      distanceFare: json['distanceFare'].toString(),
      timeFare: json['timeFare'].toString(),
      surcharge: json['surcharge'].toString(),
      surgeAmount: json['surgeAmount'].toString(),
      discountAmount: json['discountAmount'].toString(),
      roundingAdjustment: json['roundingAdjustment'].toString(),
      finalFare: json['finalFare'].toString(),
      status: json['status'] as String,
      issuedAt: DateTime.parse(json['issuedAt'] as String),
      expiresAt: DateTime.parse(json['expiresAt'] as String),
    );
  }

  static Booking booking(Map<String, dynamic> json) => Booking(
        publicId: json['bookingPublicId'] as String,
        quotePublicId: json['quotePublicId'] as String,
        status: json['status'] as String,
        vehicleType: VehicleTypeApi.parse(json['vehicleType'] as String),
        currency: json['currency'] as String,
        finalFare: json['finalFare'].toString(),
        createdAt: DateTime.parse(json['createdAt'] as String),
        driverPublicId: json['driverPublicId'] as String?,
        vehiclePublicId: json['vehiclePublicId'] as String?,
        pickup: json['pickupLatitude'] is num && json['pickupLongitude'] is num
            ? Coordinates((json['pickupLatitude'] as num).toDouble(),
                (json['pickupLongitude'] as num).toDouble())
            : null,
        dropoff:
            json['dropoffLatitude'] is num && json['dropoffLongitude'] is num
                ? Coordinates((json['dropoffLatitude'] as num).toDouble(),
                    (json['dropoffLongitude'] as num).toDouble())
                : null,
        distanceMeters: json['distanceMeters']?.toString(),
        durationSeconds: json['durationSeconds']?.toString(),
        tripCompletedAt: json['tripCompletedAt'] == null
            ? null
            : DateTime.parse(json['tripCompletedAt'] as String),
        cancelledAt: json['cancelledAt'] == null
            ? null
            : DateTime.parse(json['cancelledAt'] as String),
        cancelledBy: json['cancelledBy'] as String?,
        dispatchFailedAt: json['dispatchFailedAt'] == null
            ? null
            : DateTime.parse(json['dispatchFailedAt'] as String),
      );
}
