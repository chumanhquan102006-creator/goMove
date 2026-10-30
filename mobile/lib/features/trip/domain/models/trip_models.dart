enum TripAction { arrive, onboard, start, complete }

extension TripActionContract on TripAction {
  String get path => name;

  String get fromStatus => switch (this) {
        TripAction.arrive => 'DRIVER_ACCEPTED',
        TripAction.onboard => 'DRIVER_ARRIVED',
        TripAction.start => 'PASSENGER_ONBOARD',
        TripAction.complete => 'IN_PROGRESS',
      };

  String get toStatus => switch (this) {
        TripAction.arrive => 'DRIVER_ARRIVED',
        TripAction.onboard => 'PASSENGER_ONBOARD',
        TripAction.start => 'IN_PROGRESS',
        TripAction.complete => 'COMPLETED',
      };
}

TripAction? actionForTripStatus(String status) {
  for (final action in TripAction.values) {
    if (action.fromStatus == status) return action;
  }
  return null;
}

DateTime? _date(dynamic value) =>
    value == null ? null : DateTime.parse(value as String).toUtc();

double? _coordinate(dynamic value) =>
    value == null ? null : (value as num).toDouble();

Map<String, dynamic>? _object(dynamic value) =>
    value is Map<String, dynamic> ? value : null;

class AssignedDriverSummary {
  final String publicId;
  final String displayName;
  final String? phone;

  const AssignedDriverSummary(
      {required this.publicId, required this.displayName, this.phone});

  static AssignedDriverSummary? fromJson(dynamic value) {
    final json = _object(value);
    if (json == null ||
        json['publicId'] is! String ||
        json['displayName'] is! String) {
      return null;
    }
    return AssignedDriverSummary(
        publicId: json['publicId'] as String,
        displayName: json['displayName'] as String,
        phone: json['phone'] is String ? json['phone'] as String : null);
  }
}

class AssignedVehicleSummary {
  final String vehicleType;
  final String licensePlate;
  final String? brand;
  final String? model;

  const AssignedVehicleSummary(
      {required this.vehicleType,
      required this.licensePlate,
      this.brand,
      this.model});

  static AssignedVehicleSummary? fromJson(dynamic value) {
    final json = _object(value);
    if (json == null ||
        json['vehicleType'] is! String ||
        json['licensePlate'] is! String) {
      return null;
    }
    return AssignedVehicleSummary(
        vehicleType: json['vehicleType'] as String,
        licensePlate: json['licensePlate'] as String,
        brand: json['brand'] is String ? json['brand'] as String : null,
        model: json['model'] is String ? json['model'] as String : null);
  }
}

class CustomerSummary {
  final String displayName;
  final String? phone;

  const CustomerSummary({required this.displayName, this.phone});

  static CustomerSummary? fromJson(dynamic value) {
    final json = _object(value);
    if (json == null || json['displayName'] is! String) {
      return null;
    }
    return CustomerSummary(
        displayName: json['displayName'] as String,
        phone: json['phone'] is String ? json['phone'] as String : null);
  }
}

class TrackingSnapshot {
  final String bookingPublicId;
  final String status;
  final String? driverPublicId;
  final DateTime? driverAcceptedAt;
  final DateTime? driverArrivedAt;
  final DateTime? passengerOnboardAt;
  final DateTime? tripStartedAt;
  final DateTime? tripCompletedAt;
  final double? latitude;
  final double? longitude;
  final double? accuracy;
  final double? bearing;
  final DateTime? locationUpdatedAt;
  final AssignedDriverSummary? assignedDriver;
  final AssignedVehicleSummary? assignedVehicle;
  final CustomerSummary? customer;

  const TrackingSnapshot(
      {required this.bookingPublicId,
      required this.status,
      this.driverPublicId,
      this.driverAcceptedAt,
      this.driverArrivedAt,
      this.passengerOnboardAt,
      this.tripStartedAt,
      this.tripCompletedAt,
      this.latitude,
      this.longitude,
      this.accuracy,
      this.bearing,
      this.locationUpdatedAt,
      this.assignedDriver,
      this.assignedVehicle,
      this.customer});

  bool get allowsLiveLocation => const {
        'DRIVER_ACCEPTED',
        'DRIVER_ARRIVED',
        'PASSENGER_ONBOARD',
        'IN_PROGRESS'
      }.contains(status);

  TrackingSnapshot withoutParticipantDetails() => TrackingSnapshot(
        bookingPublicId: bookingPublicId,
        status: status,
        driverPublicId: driverPublicId,
        driverAcceptedAt: driverAcceptedAt,
        driverArrivedAt: driverArrivedAt,
        passengerOnboardAt: passengerOnboardAt,
        tripStartedAt: tripStartedAt,
        tripCompletedAt: tripCompletedAt,
        latitude: latitude,
        longitude: longitude,
        accuracy: accuracy,
        bearing: bearing,
        locationUpdatedAt: locationUpdatedAt,
      );

  factory TrackingSnapshot.fromJson(Map<String, dynamic> json) {
    final status = json['status'] as String;
    final live = const {
      'DRIVER_ACCEPTED',
      'DRIVER_ARRIVED',
      'PASSENGER_ONBOARD',
      'IN_PROGRESS'
    }.contains(status);
    return TrackingSnapshot(
      bookingPublicId: json['bookingPublicId'] as String,
      status: status,
      driverPublicId: json['driverPublicId'] as String?,
      driverAcceptedAt: _date(json['driverAcceptedAt']),
      driverArrivedAt: _date(json['driverArrivedAt']),
      passengerOnboardAt: _date(json['passengerOnboardAt']),
      tripStartedAt: _date(json['tripStartedAt']),
      tripCompletedAt: _date(json['tripCompletedAt']),
      // Defense in depth: a terminal Booking never exposes a cached/live fix.
      latitude: live ? _coordinate(json['latitude']) : null,
      longitude: live ? _coordinate(json['longitude']) : null,
      accuracy: live ? _coordinate(json['accuracy']) : null,
      bearing: live ? _coordinate(json['bearing']) : null,
      locationUpdatedAt: live ? _date(json['locationUpdatedAt']) : null,
      assignedDriver:
          live ? AssignedDriverSummary.fromJson(json['assignedDriver']) : null,
      assignedVehicle: live
          ? AssignedVehicleSummary.fromJson(json['assignedVehicle'])
          : null,
      customer: live ? CustomerSummary.fromJson(json['customer']) : null,
    );
  }
}

class TripTransition {
  final String bookingPublicId;
  final String status;
  final DateTime transitionedAt;

  const TripTransition(this.bookingPublicId, this.status, this.transitionedAt);

  factory TripTransition.fromJson(Map<String, dynamic> json) => TripTransition(
        json['bookingPublicId'] as String,
        json['status'] as String,
        DateTime.parse(json['transitionedAt'] as String).toUtc(),
      );
}

class CashPayment {
  final String paymentPublicId;
  final String bookingPublicId;
  final String method;
  final String status;
  final String amount;
  final String currency;
  final DateTime? paidAt;

  const CashPayment(
      {required this.paymentPublicId,
      required this.bookingPublicId,
      required this.method,
      required this.status,
      required this.amount,
      required this.currency,
      this.paidAt});

  bool get isPaid => status == 'PAID';

  factory CashPayment.fromJson(Map<String, dynamic> json) => CashPayment(
        paymentPublicId: json['paymentPublicId'] as String,
        bookingPublicId: json['bookingPublicId'] as String,
        method: json['method'] as String,
        status: json['status'] as String,
        amount: json['amount'].toString(),
        currency: json['currency'] as String,
        paidAt: _date(json['paidAt']),
      );
}

class CashReceipt {
  final String paymentPublicId;
  final String bookingPublicId;
  final String paymentStatus;
  final String paymentMethod;
  final String cashCollectedAmount;
  final String currency;
  final String commissionRate;
  final String commissionAmount;
  final String commissionPolicyVersion;
  final DateTime paidAt;
  final DateTime driverReleasedAt;

  const CashReceipt(
      {required this.paymentPublicId,
      required this.bookingPublicId,
      required this.paymentStatus,
      required this.paymentMethod,
      required this.cashCollectedAmount,
      required this.currency,
      required this.commissionRate,
      required this.commissionAmount,
      required this.commissionPolicyVersion,
      required this.paidAt,
      required this.driverReleasedAt});

  factory CashReceipt.fromJson(Map<String, dynamic> json) => CashReceipt(
        paymentPublicId: json['paymentPublicId'] as String,
        bookingPublicId: json['bookingPublicId'] as String,
        paymentStatus: json['paymentStatus'] as String,
        paymentMethod: json['paymentMethod'] as String,
        cashCollectedAmount: json['cashCollectedAmount'].toString(),
        currency: json['currency'] as String,
        commissionRate: json['commissionRate'].toString(),
        commissionAmount: json['commissionAmount'].toString(),
        commissionPolicyVersion: json['commissionPolicyVersion'] as String,
        paidAt: DateTime.parse(json['paidAt'] as String).toUtc(),
        driverReleasedAt:
            DateTime.parse(json['driverReleasedAt'] as String).toUtc(),
      );
}
