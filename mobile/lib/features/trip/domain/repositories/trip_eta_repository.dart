import '../models/trip_eta.dart';

abstract class TripEtaRepository {
  Future<TripEta> booking(String bookingPublicId, int sessionGeneration);
}
