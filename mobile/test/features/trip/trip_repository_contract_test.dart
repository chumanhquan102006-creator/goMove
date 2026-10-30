import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gomove_mobile/core/config/app_config.dart';
import 'package:gomove_mobile/core/network/api_client.dart';
import 'package:gomove_mobile/core/network/auth_interceptor.dart';
import 'package:gomove_mobile/core/network/token_refresher.dart';
import 'package:gomove_mobile/core/storage/secure_storage_service.dart';
import 'package:gomove_mobile/features/trip/data/repositories/trip_repository_impl.dart';
import 'package:gomove_mobile/features/trip/domain/models/trip_models.dart';
import 'package:mocktail/mocktail.dart';

class _Session extends Mock implements SecureStorageService {}

class _TripAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  String bookingStatus = 'DRIVER_ACCEPTED';
  String paymentStatus = 'PENDING';
  String? rawOverride;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    if (rawOverride != null) {
      return ResponseBody.fromString(rawOverride!, 200, headers: {
        Headers.contentTypeHeader: ['application/json']
      });
    }
    final path = options.path;
    dynamic data;
    if (path.endsWith('/tracking')) {
      data = {
        'bookingPublicId': 'booking-1',
        'status': bookingStatus,
        'driverPublicId': 'driver-1',
        'driverAcceptedAt': '2026-10-16T10:00:00Z',
        'driverArrivedAt':
            bookingStatus == 'DRIVER_ACCEPTED' ? null : '2026-10-16T10:01:00Z',
        'passengerOnboardAt': null,
        'tripStartedAt': null,
        'tripCompletedAt':
            bookingStatus == 'COMPLETED' ? '2026-10-16T10:05:00Z' : null,
        'latitude': 21.0287,
        'longitude': 105.8524,
        'accuracy': 7.0,
        'bearing': 90.0,
        'locationUpdatedAt': '2026-10-16T10:02:00Z',
      };
    } else if (path.endsWith('/payment')) {
      data = {
        'paymentPublicId': 'payment-1',
        'bookingPublicId': 'booking-1',
        'method': 'CASH',
        'status': paymentStatus,
        'amount': 16500.00,
        'currency': 'VND',
        'paidAt': paymentStatus == 'PAID' ? '2026-10-16T10:06:00Z' : null,
      };
    } else if (path.endsWith('/cash/confirm')) {
      data = {
        'paymentPublicId': 'payment-1',
        'bookingPublicId': 'booking-1',
        'paymentStatus': 'PAID',
        'paymentMethod': 'CASH',
        'cashCollectedAmount': 16500.00,
        'currency': 'VND',
        'commissionRate': 0.20,
        'commissionAmount': 3300.00,
        'commissionPolicyVersion': 'v1',
        'paidAt': '2026-10-16T10:06:00Z',
        'driverReleasedAt': '2026-10-16T10:06:00Z',
      };
    } else {
      final action = path.split('/').last;
      final status = {
        'arrive': 'DRIVER_ARRIVED',
        'onboard': 'PASSENGER_ONBOARD',
        'start': 'IN_PROGRESS',
        'complete': 'COMPLETED',
      }[action];
      data = {
        'bookingPublicId': 'booking-1',
        'status': status,
        'transitionedAt': '2026-10-16T10:03:00Z',
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

void main() {
  test('Tracking participant summaries parse optionally and expire with trip',
      () {
    final active = TrackingSnapshot.fromJson({
      'bookingPublicId': 'booking-1',
      'status': 'DRIVER_ARRIVED',
      'assignedDriver': {
        'publicId': 'driver-1',
        'displayName': 'Tài xế A',
        'phone': '0900000001'
      },
      'assignedVehicle': {
        'vehicleType': 'MOTORBIKE',
        'licensePlate': '29A-12345',
        'brand': null,
        'model': null
      },
      'customer': {'displayName': 'Khách B', 'phone': '0900000002'},
    });
    expect(active.assignedDriver?.displayName, 'Tài xế A');
    expect(active.assignedVehicle?.licensePlate, '29A-12345');
    expect(active.assignedVehicle?.brand, isNull);
    expect(active.customer?.phone, '0900000002');
    final missing = TrackingSnapshot.fromJson(
        {'bookingPublicId': 'booking-1', 'status': 'DRIVER_ACCEPTED'});
    expect(missing.assignedDriver, isNull);
    expect(missing.assignedVehicle, isNull);
    expect(missing.customer, isNull);
    final completed = TrackingSnapshot.fromJson({
      'bookingPublicId': 'booking-1',
      'status': 'COMPLETED',
      'assignedDriver': {'publicId': 'driver-1', 'displayName': 'Tài xế A'},
      'assignedVehicle': {
        'vehicleType': 'MOTORBIKE',
        'licensePlate': '29A-12345'
      },
      'customer': {'displayName': 'Khách B'},
    });
    expect(completed.assignedDriver, isNull);
    expect(completed.assignedVehicle, isNull);
    expect(completed.customer, isNull);
  });
  test(
      'Trip REST methods, exact action paths, no POST body and session binding',
      () async {
    AppConfig.reset();
    final config = AppConfig.initialize(
        forceMock: false, customBaseUrl: 'http://localhost:8080');
    final storage = _Session();
    when(() => storage.getSession()).thenAnswer(
        (_) async => const AuthSessionSnapshot(12, 'access', 'refresh'));
    when(() => storage.isCurrentSession(any())).thenAnswer((_) async => true);
    final dio = Dio(BaseOptions(baseUrl: config.apiBaseUrl));
    final adapter = _TripAdapter();
    dio.httpClientAdapter = adapter;
    final repo = TripRepositoryImpl(ApiClient(
        config: config,
        customDio: dio,
        authInterceptor: AuthInterceptor(
            storageService: storage,
            tokenRefresher:
                TokenRefresher(storageService: storage, config: config),
            getDio: () => dio)));

    for (final action in TripAction.values) {
      final response = await repo.transition('booking-1', action, 12);
      expect(response.status, action.toStatus);
      expect(adapter.requests.last.method, 'POST');
      expect(adapter.requests.last.path,
          '/drivers/me/trips/booking-1/${action.path}');
      expect(adapter.requests.last.data, isNull);
    }
    final tracking = await repo.tracking('booking-1', 12);
    expect(tracking.status, 'DRIVER_ACCEPTED');
    expect(tracking.latitude, 21.0287);
    expect(adapter.requests.last.path, '/bookings/booking-1/tracking');
    expect(adapter.requests.last.method, 'GET');

    adapter.bookingStatus = 'COMPLETED';
    final completed = await repo.tracking('booking-1', 12);
    expect(completed.tripCompletedAt, isNotNull);
    expect(completed.driverPublicId, 'driver-1');
    expect(completed.latitude, isNull);
    expect(completed.longitude, isNull);
    expect(completed.accuracy, isNull);
    expect(completed.bearing, isNull);
    expect(completed.locationUpdatedAt, isNull);

    final payment = await repo.payment('booking-1', 12);
    expect(payment.status, 'PENDING');
    expect(payment.amount, isA<String>());
    expect(adapter.requests.last.path, '/bookings/booking-1/payment');
    final receipt = await repo.confirmCash('booking-1', 12);
    expect(receipt.paymentStatus, 'PAID');
    expect(receipt.commissionAmount, isA<String>());
    expect(receipt.driverReleasedAt, DateTime.utc(2026, 10, 16, 10, 6));
    expect(
        adapter.requests.last.path, '/drivers/me/trips/booking-1/cash/confirm');
    expect(adapter.requests.last.method, 'POST');
    expect(adapter.requests.last.data, isNull);
    expect(
        adapter.requests.every((request) =>
            request.extra[AuthInterceptor.sessionGenerationExtraKey] == 12),
        isTrue);

    adapter.rawOverride =
        '{"success":true,"data":{"paymentPublicId":"payment-1",'
        '"bookingPublicId":"booking-1","method":"CASH","status":"PENDING",'
        '"amount":9007199254740993.01,"currency":"VND","paidAt":null}}';
    final exact = await repo.payment('booking-1', 12);
    expect(exact.amount, '9007199254740993.01');
  });
}
