enum VehicleType { motorbike, car4Seat, car7Seat }

extension VehicleTypeApi on VehicleType {
  String get apiValue => switch (this) {
        VehicleType.motorbike => 'MOTORBIKE',
        VehicleType.car4Seat => 'CAR_4_SEAT',
        VehicleType.car7Seat => 'CAR_7_SEAT',
      };

  String get label => switch (this) {
        VehicleType.motorbike => 'Xe máy',
        VehicleType.car4Seat => 'Ô tô 4 chỗ',
        VehicleType.car7Seat => 'Ô tô 7 chỗ',
      };

  static VehicleType parse(String value) => switch (value) {
        'MOTORBIKE' => VehicleType.motorbike,
        'CAR_4_SEAT' => VehicleType.car4Seat,
        'CAR_7_SEAT' => VehicleType.car7Seat,
        _ => throw FormatException('Unknown vehicle type: $value'),
      };
}

class Coordinates {
  final double latitude;
  final double longitude;
  const Coordinates(this.latitude, this.longitude);

  bool get isValid =>
      latitude.isFinite &&
      longitude.isFinite &&
      latitude >= -90 &&
      latitude <= 90 &&
      longitude >= -180 &&
      longitude <= 180;

  Map<String, dynamic> toJson(String prefix) => {
        '${prefix}Latitude': latitude,
        '${prefix}Longitude': longitude,
      };
}

class QuoteRequest {
  final Coordinates pickup;
  final Coordinates dropoff;
  final VehicleType vehicleType;
  const QuoteRequest(
      {required this.pickup, required this.dropoff, required this.vehicleType});

  void validate() {
    if (!pickup.isValid ||
        !dropoff.isValid ||
        (pickup.latitude == dropoff.latitude &&
            pickup.longitude == dropoff.longitude)) {
      throw const FormatException(
          'Tọa độ không hợp lệ hoặc hai điểm trùng nhau.');
    }
  }

  Map<String, dynamic> toJson() {
    validate();
    return {
      ...pickup.toJson('pickup'),
      ...dropoff.toJson('dropoff'),
      'vehicleType': vehicleType.apiValue,
    };
  }
}

class Quote {
  final String publicId;
  final Coordinates pickup;
  final Coordinates dropoff;
  final VehicleType vehicleType;
  final String distanceMeters;
  final String durationSeconds;
  final String currency;
  final String baseFare;
  final String distanceFare;
  final String timeFare;
  final String surcharge;
  final String surgeAmount;
  final String discountAmount;
  final String roundingAdjustment;
  final String finalFare;
  final String status;
  final DateTime issuedAt;
  final DateTime expiresAt;

  const Quote(
      {required this.publicId,
      required this.pickup,
      required this.dropoff,
      required this.vehicleType,
      required this.distanceMeters,
      required this.durationSeconds,
      required this.currency,
      required this.baseFare,
      required this.distanceFare,
      required this.timeFare,
      required this.surcharge,
      required this.surgeAmount,
      required this.discountAmount,
      required this.roundingAdjustment,
      required this.finalFare,
      required this.status,
      required this.issuedAt,
      required this.expiresAt});

  bool isUsableAt(DateTime now) =>
      status == 'ISSUED' && now.isBefore(expiresAt);
}
