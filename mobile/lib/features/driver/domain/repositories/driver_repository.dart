import '../models/driver_models.dart';

abstract class DriverRepository {
  Future<DriverProfile> onboard(String licenseNumber, int session);
  Future<DriverProfile> setStatus(String status, int session);
  Future<List<DriverVehicle>> vehicles(int session);
  Future<DriverVehicle> addVehicle(VehicleDraft draft, int session);
  Future<DriverVehicle> activateVehicle(String publicId, int session);
  Future<void> uploadLocation(DriverCoordinates location, int session);
  Future<List<DriverOffer>> activeOffers(int session);
  Future<OfferDecision> accept(String offerPublicId, int session);
  Future<OfferDecision> reject(String offerPublicId, int session);
  Future<BookingTracking> tracking(String bookingPublicId, int session);
}
