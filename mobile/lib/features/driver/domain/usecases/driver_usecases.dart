import '../models/driver_models.dart';
import '../repositories/driver_repository.dart';

class DriverUseCases {
  final DriverRepository _repository;
  const DriverUseCases(this._repository);

  Future<DriverProfile> onboard(String license, int session) =>
      _repository.onboard(license, session);
  Future<DriverProfile> setStatus(String status, int session) =>
      _repository.setStatus(status, session);
  Future<List<DriverVehicle>> vehicles(int session) =>
      _repository.vehicles(session);
  Future<DriverVehicle> addVehicle(VehicleDraft draft, int session) =>
      _repository.addVehicle(draft, session);
  Future<DriverVehicle> activateVehicle(String id, int session) =>
      _repository.activateVehicle(id, session);
  Future<void> uploadLocation(DriverCoordinates location, int session) =>
      _repository.uploadLocation(location, session);
  Future<List<DriverOffer>> activeOffers(int session) =>
      _repository.activeOffers(session);
  Future<OfferDecision> accept(String id, int session) =>
      _repository.accept(id, session);
  Future<OfferDecision> reject(String id, int session) =>
      _repository.reject(id, session);
  Future<BookingTracking> tracking(String id, int session) =>
      _repository.tracking(id, session);
}
