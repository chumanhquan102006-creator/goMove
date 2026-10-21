import '../models/trip_models.dart';

abstract class TripRepository {
  Future<TrackingSnapshot> tracking(
      String bookingPublicId, int sessionGeneration);
  Future<CashPayment> payment(String bookingPublicId, int sessionGeneration);
  Future<TripTransition> transition(
      String bookingPublicId, TripAction action, int sessionGeneration);
  Future<CashReceipt> confirmCash(
      String bookingPublicId, int sessionGeneration);
}
