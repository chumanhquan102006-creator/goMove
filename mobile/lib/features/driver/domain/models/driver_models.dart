class DriverProfile {
  final String publicId;
  final String approvalStatus;
  final String operatingStatus;

  const DriverProfile(this.publicId, this.approvalStatus, this.operatingStatus);

  factory DriverProfile.fromJson(Map<String, dynamic> json) => DriverProfile(
        json['publicId'] as String,
        json['approvalStatus'] as String,
        json['operatingStatus'] as String,
      );
}

class DriverVehicle {
  final String publicId;
  final String licensePlate;
  final String vehicleType;
  final String? brand;
  final String? model;
  final String? color;
  final bool active;

  const DriverVehicle(this.publicId, this.licensePlate, this.vehicleType,
      this.brand, this.model, this.color, this.active);

  factory DriverVehicle.fromJson(Map<String, dynamic> json) => DriverVehicle(
        json['publicId'] as String,
        json['licensePlate'] as String,
        json['vehicleType'] as String,
        json['brand'] as String?,
        json['model'] as String?,
        json['color'] as String?,
        json['active'] as bool? ?? false,
      );
}

class VehicleDraft {
  final String licensePlate;
  final String vehicleType;
  final String? brand;
  final String? model;
  final String? color;

  const VehicleDraft(this.licensePlate, this.vehicleType,
      {this.brand, this.model, this.color});

  Map<String, dynamic> toJson() => {
        'licensePlate': licensePlate,
        'vehicleType': vehicleType,
        'brand': brand,
        'model': model,
        'color': color,
      };
}

class DriverCoordinates {
  final double latitude;
  final double longitude;
  final double? accuracy;
  final double? bearing;
  final bool approximate;

  /// Timestamp supplied by the device fix, never sent to the Backend.
  final DateTime? sampledAt;

  const DriverCoordinates(this.latitude, this.longitude,
      {this.accuracy, this.bearing, this.approximate = false, this.sampledAt});

  Map<String, dynamic> toJson() {
    if (!latitude.isFinite ||
        latitude < -90 ||
        latitude > 90 ||
        !longitude.isFinite ||
        longitude < -180 ||
        longitude > 180) {
      throw const FormatException('Tọa độ GPS không hợp lệ');
    }
    return {
      'latitude': latitude,
      'longitude': longitude,
      'accuracy': accuracy != null && accuracy!.isFinite && accuracy! >= 0
          ? accuracy
          : null,
      'bearing': bearing != null &&
              bearing!.isFinite &&
              bearing! >= 0 &&
              bearing! < 360
          ? bearing
          : null,
    };
  }
}

class DriverOffer {
  final String offerPublicId;
  final String bookingPublicId;
  final double pickupLatitude;
  final double pickupLongitude;
  final double dropoffLatitude;
  final double dropoffLongitude;
  final String vehicleType;
  final String currency;
  final String finalFare;
  final DateTime expiresAt;

  const DriverOffer(
      {required this.offerPublicId,
      required this.bookingPublicId,
      required this.pickupLatitude,
      required this.pickupLongitude,
      required this.dropoffLatitude,
      required this.dropoffLongitude,
      required this.vehicleType,
      required this.currency,
      required this.finalFare,
      required this.expiresAt});

  factory DriverOffer.fromJson(Map<String, dynamic> json) => DriverOffer(
        offerPublicId: json['offerPublicId'] as String,
        bookingPublicId: json['bookingPublicId'] as String,
        pickupLatitude: (json['pickupLatitude'] as num).toDouble(),
        pickupLongitude: (json['pickupLongitude'] as num).toDouble(),
        dropoffLatitude: (json['dropoffLatitude'] as num).toDouble(),
        dropoffLongitude: (json['dropoffLongitude'] as num).toDouble(),
        vehicleType: json['vehicleType'] as String,
        currency: json['currency'] as String,
        finalFare: json['finalFare'].toString(),
        expiresAt: DateTime.parse(json['expiresAt'] as String).toUtc(),
      );

  Map<String, dynamic> toJson() => {
        'offerPublicId': offerPublicId,
        'bookingPublicId': bookingPublicId,
        'pickupLatitude': pickupLatitude,
        'pickupLongitude': pickupLongitude,
        'dropoffLatitude': dropoffLatitude,
        'dropoffLongitude': dropoffLongitude,
        'vehicleType': vehicleType,
        'currency': currency,
        'finalFare': finalFare,
        'expiresAt': expiresAt.toIso8601String(),
      };
}

int remainingOfferSeconds(DateTime expiresAt, DateTime now) {
  final remainingMicros = expiresAt.difference(now).inMicroseconds;
  if (remainingMicros <= 0) return 0;
  return (remainingMicros + Duration.microsecondsPerSecond - 1) ~/
      Duration.microsecondsPerSecond;
}

class OfferDecision {
  final String offerPublicId;
  final String status;

  const OfferDecision(this.offerPublicId, this.status);
  factory OfferDecision.fromJson(Map<String, dynamic> json) =>
      OfferDecision(json['offerPublicId'] as String, json['status'] as String);
}

class BookingTracking {
  final String bookingPublicId;
  final String status;
  final String? driverPublicId;

  const BookingTracking(this.bookingPublicId, this.status, this.driverPublicId);
  factory BookingTracking.fromJson(Map<String, dynamic> json) =>
      BookingTracking(json['bookingPublicId'] as String,
          json['status'] as String, json['driverPublicId'] as String?);
}
