import '../models/driver_earnings_summary.dart';

abstract class DriverEarningsRepository {
  Future<DriverEarningsSummary> summary(int sessionGeneration);
}
