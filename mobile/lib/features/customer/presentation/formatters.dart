import '../domain/models/quote.dart';

String vnd(String amount) {
  final match = RegExp(r'^(-?)(\d+)(?:\.(\d+))?$').firstMatch(amount);
  if (match == null) return '$amount VND';
  final digits = match.group(2)!;
  final grouped =
      digits.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => '.');
  // Whole-VND totals are clean, while nonzero fractional fare lines retain
  // the exact precision supplied by the server (for example 4.500,50 VND).
  final suppliedFraction = match.group(3) ?? '';
  final fractional =
      RegExp(r'[1-9]').hasMatch(suppliedFraction) ? suppliedFraction : '';
  return '${match.group(1)}$grouped${fractional.isEmpty ? '' : ',$fractional'} VND';
}

String distanceLabel(Quote quote) {
  final meters = double.tryParse(quote.distanceMeters);
  return meters == null
      ? '${quote.distanceMeters} m'
      : '${(meters / 1000).toStringAsFixed(2)} km';
}

String durationLabel(Quote quote) {
  final seconds = double.tryParse(quote.durationSeconds);
  return seconds == null
      ? '${quote.durationSeconds} giây'
      : '${(seconds / 60).ceil()} phút';
}
