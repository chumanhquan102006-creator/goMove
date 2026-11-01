import '../models/booking.dart';
import '../models/trip_history.dart';

abstract class TripHistoryRepository {
  Future<HistoryPage> page(int page, int size, int sessionGeneration);
  Future<Booking> detail(String bookingPublicId, int sessionGeneration);
}
