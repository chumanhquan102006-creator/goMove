class DriverEarningsSummary {
  final int paidTripCount;
  final String cashCollectedAmount;
  final String commissionDue;
  final String afterCommissionAmount;
  final String currency;

  const DriverEarningsSummary({
    required this.paidTripCount,
    required this.cashCollectedAmount,
    required this.commissionDue,
    required this.afterCommissionAmount,
    required this.currency,
  });

  factory DriverEarningsSummary.fromJson(Map<String, dynamic> json) {
    if (json['paidTripCount'] is! num ||
        json['cashCollectedAmount'] is! String ||
        json['commissionDueAmount'] is! String ||
        json['afterCommissionAmount'] is! String ||
        json['currency'] != 'VND') {
      throw const FormatException('Tóm tắt tiền mặt không hợp lệ');
    }
    return DriverEarningsSummary(
      paidTripCount: (json['paidTripCount'] as num).toInt(),
      cashCollectedAmount: json['cashCollectedAmount'] as String,
      commissionDue: json['commissionDueAmount'] as String,
      afterCommissionAmount: json['afterCommissionAmount'] as String,
      currency: json['currency'] as String,
    );
  }
}
