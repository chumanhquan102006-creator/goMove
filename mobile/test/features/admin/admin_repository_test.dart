import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gomove_mobile/core/config/app_config.dart';
import 'package:gomove_mobile/core/error/exceptions.dart';
import 'package:gomove_mobile/core/network/api_client.dart';
import 'package:gomove_mobile/core/network/auth_interceptor.dart';
import 'package:gomove_mobile/core/network/token_refresher.dart';
import 'package:gomove_mobile/core/storage/secure_storage_service.dart';
import 'package:gomove_mobile/features/admin/data/admin_repository_impl.dart';
import 'package:gomove_mobile/features/admin/domain/admin_models.dart';
import 'package:mocktail/mocktail.dart';

class _Session extends Mock implements SecureStorageService {}

class _Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  Future<ResponseBody> Function(RequestOptions) reply;
  _Adapter(this.reply);

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) {
    requests.add(options);
    return reply(options);
  }

  @override
  void close({bool force = false}) {}
}

const _driverId = '550e8400-e29b-41d4-a716-446655440003';

ResponseBody _body(Object data, [int status = 200]) =>
    ResponseBody.fromString(jsonEncode(data), status, headers: {
      Headers.contentTypeHeader: ['application/json']
    });

Map<String, dynamic> _driver(String status) => {
      'publicId': _driverId,
      'fullName': 'Driver A',
      'phone': '0900000002',
      'licenseNumber': 'GPLX-1',
      'approvalStatus': status,
      'operatingStatus': 'OFFLINE',
      'totalTrips': 0,
      'unreleasedBooking': false,
      'vehicles': <Object>[],
    };

void main() {
  late _Adapter adapter;
  late AdminRepositoryImpl repository;

  setUp(() {
    AppConfig.reset();
    final config = AppConfig.initialize(
        forceMock: false, customBaseUrl: 'http://localhost:8080');
    final session = _Session();
    when(() => session.getSession()).thenAnswer(
        (_) async => const AuthSessionSnapshot(7, 'access', 'refresh'));
    when(() => session.isCurrentSession(any())).thenAnswer((_) async => true);
    final dio = Dio(BaseOptions(baseUrl: config.apiBaseUrl));
    adapter = _Adapter((options) async {
      if (options.method == 'PATCH') {
        return _body({
          'success': true,
          'data': {'publicId': _driverId, 'approvalStatus': 'APPROVED'}
        });
      }
      throw StateError('Unexpected GET');
    });
    dio.httpClientAdapter = adapter;
    repository = AdminRepositoryImpl(ApiClient(
      config: config,
      customDio: dio,
      authInterceptor: AuthInterceptor(
        storageService: session,
        tokenRefresher: TokenRefresher(
            storageService: session, config: config, refreshDio: Dio()),
        getDio: () => dio,
      ),
    ));
  });

  test('Confirmed PATCH does not depend on a follow-up GET', () async {
    final result = await repository.setApproval(_driverId, 'APPROVED', 7);
    expect(result.confirmed, isTrue);
    expect(result.reconciledDriver, isNull);
    expect(adapter.requests, hasLength(1));
    expect(adapter.requests.single.method, 'PATCH');
    expect(adapter.requests.single.path, '/drivers/$_driverId/approval-status');
    expect(adapter.requests.single.data, {'status': 'APPROVED'});
    expect(
        adapter
            .requests.single.extra[AuthInterceptor.sessionGenerationExtraKey],
        7);
  });

  test('PATCH timeout reconciles desired status with one authorized GET',
      () async {
    adapter.reply = (options) async {
      if (options.method == 'PATCH') {
        throw DioException(
            requestOptions: options, type: DioExceptionType.receiveTimeout);
      }
      return _body({'success': true, 'data': _driver('APPROVED')});
    };
    final result = await repository.setApproval(_driverId, 'APPROVED', 7);
    expect(result.confirmed, isTrue);
    expect(result.reconciledDriver?.approvalStatus, 'APPROVED');
    expect(adapter.requests.map((request) => request.method), ['PATCH', 'GET']);
    expect(adapter.requests.last.path, '/admin/drivers/$_driverId');
  });

  test('Timeout with different or unavailable server state stays uncertain',
      () async {
    adapter.reply = (options) async {
      if (options.method == 'PATCH') {
        throw DioException(
            requestOptions: options, type: DioExceptionType.receiveTimeout);
      }
      return _body({'success': true, 'data': _driver('PENDING')});
    };
    final observed = await repository.setApproval(_driverId, 'APPROVED', 7);
    expect(observed.confirmed, isFalse);
    expect(observed.reconciledDriver?.approvalStatus, 'PENDING');
    expect(adapter.requests.map((request) => request.method), ['PATCH', 'GET']);

    adapter.requests.clear();
    adapter.reply = (options) async => throw DioException(
        requestOptions: options, type: DioExceptionType.receiveTimeout);
    final unavailable = await repository.setApproval(_driverId, 'APPROVED', 7);
    expect(unavailable.confirmed, isFalse);
    expect(unavailable.reconciledDriver, isNull);
    expect(adapter.requests.map((request) => request.method), ['PATCH', 'GET']);
  });

  test('Confirmed 409 remains conflict and never triggers reconciliation',
      () async {
    adapter.reply = (_) async => _body({
          'success': false,
          'code': 'DRIVER_HAS_UNRELEASED_BOOKING',
          'message': 'Driver approval cannot change',
        }, 409);
    await expectLater(
        repository.setApproval(_driverId, 'SUSPENDED', 7),
        throwsA(isA<ServerException>()
            .having((error) => error.statusCode, 'statusCode', 409)
            .having((error) => error.errorCode, 'errorCode',
                'DRIVER_HAS_UNRELEASED_BOOKING')));
    expect(adapter.requests.map((request) => request.method), ['PATCH']);
  });

  test('Booking parses only existing authorized list fields and optional IDs',
      () {
    final booking = AdminBooking.fromJson({
      'publicId': 'booking-1',
      'status': 'COMPLETED',
      'vehicleType': 'MOTORBIKE',
      'finalFare': '16500.00',
      'currency': 'VND',
      'cashStatus': 'VOID',
      'customerPublicId': 'customer-1',
      'driverPublicId': 'driver-1',
      'createdAt': '2026-11-01T08:30:00Z',
    });
    expect(booking.customerPublicId, 'customer-1');
    expect(booking.driverPublicId, 'driver-1');
    expect(booking.createdAt?.toUtc(), DateTime.utc(2026, 11, 1, 8, 30));
    expect(booking.cashStatus, 'VOID');
    expect(booking.currencyCode, 'VND');

    final older = AdminBooking.fromJson({
      'publicId': 'booking-2',
      'status': 'REQUESTED',
      'vehicleType': 'CAR_4_SEAT',
      'finalFare': 25000,
    });
    expect(older.customerPublicId, isNull);
    expect(older.driverPublicId, isNull);
    expect(older.createdAt, isNull);
    expect(older.currencyCode, isNull);
    expect(older.cashStatus, 'UNAVAILABLE');
  });

  test('Dashboard rejects missing counters instead of displaying a false zero',
      () {
    expect(
        () => AdminDashboard.fromJson({
              'customers': 4,
              'collectiblePendingCashAmount': '0.00',
              'voidCashAmount': '0.00',
            }),
        throwsFormatException);
  });
}
