class AdminPage<T> {
  final List<T> items;
  final int page;
  final int size;
  final int total;

  const AdminPage(this.items, this.page, this.size, this.total);

  bool get hasNext => (page + 1) * size < total;

  factory AdminPage.fromJson(
      Map<String, dynamic> json, T Function(Map<String, dynamic>) parse) {
    final raw = json['items'];
    if (raw is! List) {
      throw const FormatException('Danh sách quản trị không hợp lệ');
    }
    return AdminPage(
        raw
            .map((item) => parse(Map<String, dynamic>.from(item as Map)))
            .toList(),
        (json['page'] as num).toInt(),
        (json['size'] as num).toInt(),
        (json['total'] as num).toInt());
  }
}

class AdminDashboard {
  final Map<String, int> counts;
  final String collectibleAmount;
  final String voidAmount;

  const AdminDashboard(this.counts, this.collectibleAmount, this.voidAmount);

  factory AdminDashboard.fromJson(Map<String, dynamic> json) {
    const fields = [
      'customers',
      'drivers',
      'pendingApprovals',
      'driversOnline',
      'driversOffline',
      'driversBusy',
      'activeBookings',
      'completedBookings',
      'cancelledBookings',
      'noDriverAvailableBookings',
      'paidCashPayments',
      'collectiblePendingCashPayments',
      'voidCashPayments'
    ];
    return AdminDashboard({
      for (final field in fields) field: (json[field] as num).toInt(),
    }, json['collectiblePendingCashAmount'].toString(),
        json['voidCashAmount'].toString());
  }
}

class AdminVehicle {
  final String publicId;
  final String plate;
  final String type;
  final String description;
  final bool active;

  const AdminVehicle(
      this.publicId, this.plate, this.type, this.description, this.active);

  factory AdminVehicle.fromJson(Map<String, dynamic> json) => AdminVehicle(
      json['publicId'] as String,
      json['licensePlate'] as String,
      json['vehicleType'] as String,
      [json['brand'], json['model'], json['color']]
          .whereType<String>()
          .where((part) => part.isNotEmpty)
          .join(' · '),
      json['active'] as bool);
}

class AdminDriver {
  final String publicId;
  final String fullName;
  final String phone;
  final String licenseNumber;
  final String approvalStatus;
  final String operatingStatus;
  final int totalTrips;
  final bool unreleasedBooking;
  final List<AdminVehicle> vehicles;

  const AdminDriver(
      this.publicId,
      this.fullName,
      this.phone,
      this.licenseNumber,
      this.approvalStatus,
      this.operatingStatus,
      this.totalTrips,
      this.unreleasedBooking,
      this.vehicles);

  factory AdminDriver.fromJson(Map<String, dynamic> json) => AdminDriver(
      json['publicId'] as String,
      json['fullName'] as String,
      json['phone'] as String,
      json['licenseNumber'] as String,
      json['approvalStatus'] as String,
      json['operatingStatus'] as String,
      (json['totalTrips'] as num).toInt(),
      json['unreleasedBooking'] as bool,
      (json['vehicles'] as List? ?? const [])
          .map((value) =>
              AdminVehicle.fromJson(Map<String, dynamic>.from(value as Map)))
          .toList());
}

/// A successful PATCH confirms the requested status. A lost PATCH response
/// needs a read-only reconciliation; it must never trigger an automatic retry.
class AdminApprovalResult {
  final bool confirmed;
  final AdminDriver? reconciledDriver;

  const AdminApprovalResult.confirmed([this.reconciledDriver])
      : confirmed = true;
  const AdminApprovalResult.uncertain([this.reconciledDriver])
      : confirmed = false;
}

class AdminAccount {
  final String publicId;
  final String fullName;
  final String phone;
  final String? email;
  final String role;
  final String status;
  final String? driverApprovalStatus;
  final String? driverOperatingStatus;
  final bool activeBooking;
  final String? lastBookingAt;

  const AdminAccount(
      this.publicId,
      this.fullName,
      this.phone,
      this.email,
      this.role,
      this.status,
      this.driverApprovalStatus,
      this.driverOperatingStatus,
      this.activeBooking,
      this.lastBookingAt);

  factory AdminAccount.fromJson(Map<String, dynamic> json) => AdminAccount(
      json['publicId'] as String,
      json['fullName'] as String,
      json['phone'] as String,
      json['email'] as String?,
      json['role'] as String,
      json['status'] as String,
      json['driverApprovalStatus'] as String?,
      json['driverOperatingStatus'] as String?,
      json['activeBooking'] as bool,
      json['lastBookingAt'] as String?);
}

class AdminBooking {
  final String publicId;
  final String status;
  final String vehicleType;
  final String fare;
  final String cashStatus;

  const AdminBooking(
      this.publicId, this.status, this.vehicleType, this.fare, this.cashStatus);

  factory AdminBooking.fromJson(Map<String, dynamic> json) => AdminBooking(
      json['publicId'] as String,
      json['status'] as String,
      json['vehicleType'] as String,
      json['finalFare'].toString(),
      (json['cashStatus'] as String?) ?? 'UNAVAILABLE');
}
