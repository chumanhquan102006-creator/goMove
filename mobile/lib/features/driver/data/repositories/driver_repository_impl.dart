import 'package:dio/dio.dart';
import '../../../../core/constants/api_endpoints.dart';
import '../../../../core/network/api_client.dart';
import '../../../../core/network/auth_interceptor.dart';
import '../../domain/models/driver_models.dart';
import '../../domain/repositories/driver_repository.dart';

class DriverRepositoryImpl implements DriverRepository {
  final ApiClient _client;
  DriverRepositoryImpl(this._client);

  // The interceptor rejects requests whose originating session was replaced.
  Options _session(int generation) =>
      Options(extra: {AuthInterceptor.sessionGenerationExtraKey: generation});

  dynamic _payload(Map<String, dynamic>? envelope) {
    if (envelope?['success'] != true) {
      throw const FormatException('Máy chủ không xác nhận thành công');
    }
    return envelope?['data'];
  }

  Map<String, dynamic> _data(Map<String, dynamic>? envelope) {
    final value = _payload(envelope);
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Phản hồi máy chủ thiếu dữ liệu');
    }
    return value;
  }

  @override
  Future<DriverProfile> onboard(String licenseNumber, int session) async {
    final response = await _client.post<Map<String, dynamic>>(
        ApiEndpoints.driverOnboarding,
        data: {'licenseNumber': licenseNumber},
        options: _session(session));
    return DriverProfile.fromJson(_data(response.data));
  }

  @override
  Future<DriverProfile> setStatus(String status, int session) async {
    final response = await _client.patch<Map<String, dynamic>>(
        ApiEndpoints.driverOperatingStatus,
        data: {'status': status},
        options: _session(session));
    return DriverProfile.fromJson(_data(response.data));
  }

  @override
  Future<List<DriverVehicle>> vehicles(int session) async {
    final response = await _client.get<Map<String, dynamic>>(
        ApiEndpoints.driverVehicles,
        options: _session(session));
    final data = _payload(response.data);
    if (data is! List) throw const FormatException('Danh sách xe không hợp lệ');
    return data
        .map((item) => DriverVehicle.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<DriverVehicle> addVehicle(VehicleDraft draft, int session) async {
    final response = await _client.post<Map<String, dynamic>>(
        ApiEndpoints.driverVehicles,
        data: draft.toJson(),
        options: _session(session));
    return DriverVehicle.fromJson(_data(response.data));
  }

  @override
  Future<DriverVehicle> activateVehicle(String publicId, int session) async {
    final response = await _client.patch<Map<String, dynamic>>(
        ApiEndpoints.activateDriverVehicle(publicId),
        options: _session(session));
    return DriverVehicle.fromJson(_data(response.data));
  }

  @override
  Future<void> uploadLocation(DriverCoordinates location, int session) async {
    final response = await _client.put<Map<String, dynamic>>(
        ApiEndpoints.driverLocation,
        data: location.toJson(),
        options: _session(session));
    _data(response.data);
  }

  @override
  Future<List<DriverOffer>> activeOffers(int session) async {
    final response = await _client.get<Map<String, dynamic>>(
        ApiEndpoints.activeDriverOffers,
        options: _session(session));
    final data = _payload(response.data);
    if (data is! List) {
      throw const FormatException('Danh sách đề nghị không hợp lệ');
    }
    return data
        .map((item) => DriverOffer.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<OfferDecision> accept(String offerPublicId, int session) async {
    final response = await _client.post<Map<String, dynamic>>(
        ApiEndpoints.acceptDriverOffer(offerPublicId),
        options: _session(session));
    return OfferDecision.fromJson(_data(response.data));
  }

  @override
  Future<OfferDecision> reject(String offerPublicId, int session) async {
    final response = await _client.post<Map<String, dynamic>>(
        ApiEndpoints.rejectDriverOffer(offerPublicId),
        options: _session(session));
    return OfferDecision.fromJson(_data(response.data));
  }

  @override
  Future<BookingTracking> tracking(String bookingPublicId, int session) async {
    final response = await _client.get<Map<String, dynamic>>(
        ApiEndpoints.bookingTracking(bookingPublicId),
        options: _session(session));
    return BookingTracking.fromJson(_data(response.data));
  }
}
