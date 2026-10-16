import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gomove_mobile/core/config/app_config.dart';
import 'package:gomove_mobile/core/network/api_client.dart';
import 'package:gomove_mobile/core/network/auth_interceptor.dart';
import 'package:gomove_mobile/core/network/token_refresher.dart';
import 'package:gomove_mobile/core/storage/secure_storage_service.dart';
import 'package:gomove_mobile/features/driver/data/repositories/driver_repository_impl.dart';
import 'package:gomove_mobile/features/driver/domain/models/driver_models.dart';
import 'package:mocktail/mocktail.dart';

class MockSession extends Mock implements SecureStorageService {}

class ContractAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    final path = options.path;
    dynamic data;
    if (path == '/drivers/me/vehicles' && options.method == 'GET') {
      data = [vehicleJson()];
    } else if (path.startsWith('/drivers/me/vehicles/')) {
      data = vehicleJson(active: true);
    } else if (path == '/drivers/me/vehicles') {
      data = vehicleJson(active: false);
    } else if (path == '/drivers/me/offers/active') {
      data = [offerJson()];
    } else if (path.endsWith('/accept')) {
      data = {
        'offerPublicId': 'offer-1',
        'status': 'ACCEPTED',
        'respondedAt': '2026-10-12T12:00:02Z'
      };
    } else if (path.endsWith('/reject')) {
      data = {
        'offerPublicId': 'offer-1',
        'status': 'REJECTED',
        'respondedAt': '2026-10-12T12:00:02Z'
      };
    } else if (path.endsWith('/tracking')) {
      data = {
        'bookingPublicId': 'booking-1',
        'status': 'DRIVER_ACCEPTED',
        'driverPublicId': 'driver-1'
      };
    } else if (path == '/drivers/me/location') {
      data = {
        'latitude': 21.0287,
        'longitude': 105.8524,
        'updatedAt': '2026-10-12T12:00:00Z'
      };
    } else {
      data = {
        'publicId': 'driver-1',
        'approvalStatus': 'APPROVED',
        'operatingStatus': path == '/drivers/onboarding' ? 'OFFLINE' : 'ONLINE'
      };
    }
    return ResponseBody.fromString(
        jsonEncode({'success': true, 'data': data}), 200,
        headers: {
          Headers.contentTypeHeader: ['application/json']
        });
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> vehicleJson({bool active = true}) => {
      'publicId': 'vehicle-1',
      'driverPublicId': 'driver-1',
      'licensePlate': '79A-123.45',
      'vehicleType': 'MOTORBIKE',
      'brand': 'Honda',
      'model': 'Wave',
      'color': 'Black',
      'active': active,
    };

Map<String, dynamic> offerJson() => {
      'offerPublicId': 'offer-1',
      'bookingPublicId': 'booking-1',
      'pickupLatitude': 21.0287,
      'pickupLongitude': 105.8524,
      'dropoffLatitude': 21.0245,
      'dropoffLongitude': 105.8576,
      'vehicleType': 'MOTORBIKE',
      'currency': 'VND',
      'finalFare': 16500.00,
      'offeredAt': '2026-10-12T12:00:00Z',
      'expiresAt': '2026-10-12T12:00:15Z',
    };

void main() {
  test('Driver REST contract uses exact method/path/body and ApiResponse data',
      () async {
    AppConfig.reset();
    final config = AppConfig.initialize(
        forceMock: false, customBaseUrl: 'http://localhost:8080');
    final storage = MockSession();
    when(() => storage.getSession()).thenAnswer(
        (_) async => const AuthSessionSnapshot(7, 'access', 'refresh'));
    when(() => storage.isCurrentSession(any())).thenAnswer((_) async => true);
    final dio = Dio(BaseOptions(baseUrl: config.apiBaseUrl));
    final adapter = ContractAdapter();
    dio.httpClientAdapter = adapter;
    final client = ApiClient(
        config: config,
        customDio: dio,
        authInterceptor: AuthInterceptor(
            storageService: storage,
            tokenRefresher:
                TokenRefresher(storageService: storage, config: config),
            getDio: () => dio));
    final repo = DriverRepositoryImpl(client);

    await repo.onboard('79A1-123456', 7);
    expect(adapter.requests.last.method, 'POST');
    expect(adapter.requests.last.path, '/drivers/onboarding');
    expect(adapter.requests.last.data, {'licenseNumber': '79A1-123456'});

    final vehicles = await repo.vehicles(7);
    expect(vehicles.single.publicId, 'vehicle-1');
    expect(adapter.requests.last.method, 'GET');
    expect(adapter.requests.last.path, '/drivers/me/vehicles');

    await repo.addVehicle(
        const VehicleDraft('79B-456.78', 'CAR_4_SEAT',
            brand: 'Toyota', model: 'Vios', color: 'White'),
        7);
    expect(adapter.requests.last.method, 'POST');
    expect(adapter.requests.last.data['vehicleType'], 'CAR_4_SEAT');
    expect(adapter.requests.last.data['licensePlate'], '79B-456.78');

    await repo.activateVehicle('vehicle-1', 7);
    expect(adapter.requests.last.method, 'PATCH');
    expect(
        adapter.requests.last.path, '/drivers/me/vehicles/vehicle-1/activate');

    await repo.setStatus('ONLINE', 7);
    expect(adapter.requests.last.method, 'PATCH');
    expect(adapter.requests.last.path, '/drivers/me/operating-status');
    expect(adapter.requests.last.data, {'status': 'ONLINE'});
    await repo.setStatus('OFFLINE', 7);
    expect(adapter.requests.last.data, {'status': 'OFFLINE'});

    await repo.uploadLocation(
        const DriverCoordinates(21.0287, 105.8524, accuracy: 8, bearing: 0), 7);
    expect(adapter.requests.last.method, 'PUT');
    expect(adapter.requests.last.path, '/drivers/me/location');
    expect(adapter.requests.last.data, {
      'latitude': 21.0287,
      'longitude': 105.8524,
      'accuracy': 8.0,
      'bearing': 0.0,
    });

    final offers = await repo.activeOffers(7);
    expect(adapter.requests.last.method, 'GET');
    expect(adapter.requests.last.path, '/drivers/me/offers/active');
    expect(offers.single.finalFare, '16500.0');
    expect(offers.single.expiresAt, DateTime.utc(2026, 10, 12, 12, 0, 15));

    final accepted = await repo.accept('offer-1', 7);
    expect(adapter.requests.last.method, 'POST');
    expect(adapter.requests.last.path, '/drivers/me/offers/offer-1/accept');
    expect(accepted.status, 'ACCEPTED');
    await repo.reject('offer-1', 7);
    expect(adapter.requests.last.method, 'POST');
    expect(adapter.requests.last.path, '/drivers/me/offers/offer-1/reject');
    final tracking = await repo.tracking('booking-1', 7);
    expect(adapter.requests.last.method, 'GET');
    expect(adapter.requests.last.path, '/bookings/booking-1/tracking');
    expect(tracking.driverPublicId, 'driver-1');
    expect(
        adapter.requests.every(
            (request) => request.extra['gomoveAuthSessionGeneration'] == 7),
        isTrue);
  });
}
