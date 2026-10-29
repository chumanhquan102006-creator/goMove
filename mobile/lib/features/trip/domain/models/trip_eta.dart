/// A short-lived, server-authorized road estimate. It is presentation data,
/// never a trip transition or an input to the accepted fare.
class TripEta {
  final String bookingPublicId;
  final String status;
  final String phase;
  final String availability;
  final String? reason;
  final double? distanceMeters;
  final double? durationSeconds;
  final DateTime? calculatedAt;
  final DateTime? locationUpdatedAt;
  final DateTime? expiresAt;
  final DateTime servedAt;

  const TripEta({
    required this.bookingPublicId,
    required this.status,
    required this.phase,
    required this.availability,
    this.reason,
    this.distanceMeters,
    this.durationSeconds,
    this.calculatedAt,
    this.locationUpdatedAt,
    this.expiresAt,
    required this.servedAt,
  });

  static double? _quantity(Object? value) {
    if (value == null) return null;
    final number = value is num
        ? value.toDouble()
        : value is String
            ? double.tryParse(value)
            : null;
    if (number == null || !number.isFinite || number < 0) {
      throw const FormatException('Giá trị ETA không hợp lệ');
    }
    return number;
  }

  static DateTime? _date(Object? value) {
    if (value == null) return null;
    if (value is! String) {
      throw const FormatException('Thời điểm ETA không hợp lệ');
    }
    return DateTime.parse(value).toUtc();
  }

  factory TripEta.fromJson(Map<String, dynamic> json) {
    final bookingPublicId = json['bookingPublicId'];
    final status = json['status'];
    final phase = json['phase'];
    final availability = json['availability'];
    final reason = json['reason'];
    if (bookingPublicId is! String ||
        bookingPublicId.isEmpty ||
        status is! String ||
        !const {'PICKUP', 'DESTINATION', 'NONE'}.contains(phase) ||
        !const {'AVAILABLE', 'UNAVAILABLE'}.contains(availability) ||
        (reason != null && reason is! String)) {
      throw const FormatException('Phản hồi ETA không hợp lệ');
    }
    final result = TripEta(
      bookingPublicId: bookingPublicId,
      status: status,
      phase: phase as String,
      availability: availability as String,
      reason: reason as String?,
      distanceMeters: _quantity(json['distanceMeters']),
      durationSeconds: _quantity(json['durationSeconds']),
      calculatedAt: _date(json['calculatedAt']),
      locationUpdatedAt: _date(json['locationUpdatedAt']),
      expiresAt: _date(json['expiresAt']),
      servedAt: _date(json['servedAt']) ??
          (throw const FormatException('Phản hồi ETA thiếu thời điểm máy chủ')),
    );
    if (result.availability == 'AVAILABLE' &&
        (result.phase == 'NONE' ||
            result.distanceMeters == null ||
            result.durationSeconds == null ||
            result.calculatedAt == null ||
            result.locationUpdatedAt == null ||
            result.expiresAt == null ||
            !result.expiresAt!.isAfter(result.calculatedAt!) ||
            !result.expiresAt!.isAfter(result.servedAt) ||
            result.servedAt.isBefore(result.calculatedAt!) ||
            result.locationUpdatedAt!.isAfter(result.calculatedAt!))) {
      throw const FormatException('ETA khả dụng thiếu dữ liệu');
    }
    return result;
  }

  bool isAvailableFor(String bookingId, String currentStatus) {
    final expectedPhase = switch (currentStatus) {
      'DRIVER_ACCEPTED' => 'PICKUP',
      'IN_PROGRESS' => 'DESTINATION',
      _ => 'NONE',
    };
    return bookingPublicId == bookingId &&
        status == currentStatus &&
        phase == expectedPhase &&
        expectedPhase != 'NONE' &&
        availability == 'AVAILABLE';
  }

  /// The server's `servedAt` makes this independent of the device wall clock.
  /// Subtract the elapsed request time before starting a local monotonic timer,
  /// so a slow response cannot extend the server's expiry.
  Duration? remainingAfter(Duration requestElapsed) {
    if (availability != 'AVAILABLE' || expiresAt == null) return null;
    final serverTtl = expiresAt!.difference(servedAt);
    final capped = serverTtl > const Duration(seconds: 30)
        ? const Duration(seconds: 30)
        : serverTtl;
    final remaining = capped - requestElapsed;
    return remaining > Duration.zero ? remaining : null;
  }
}
