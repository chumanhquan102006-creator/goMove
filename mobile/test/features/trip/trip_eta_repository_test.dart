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
import 'package:gomove_mobile/features/trip/data/repositories/trip_eta_repository_impl.dart';
import 'package:mocktail/mocktail.dart';

class _Storage extends Mock implements SecureStorageService {}

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

ResponseBody _jsonBody(Object value, [int status = 200]) =>
    ResponseBody.fromString(jsonEncode(value), status, headers: {
      Headers.contentTypeHeader: ['application/json']
    });

Map<String, dynamic> _eta([String id = 'booking-1']) => {
      'bookingPublicId': id,
      'status': 'DRIVER_ACCEPTED',
      'phase': 'PICKUP',
      'availability': 'AVAILABLE',
      'reason': null,
      'distanceMeters': 900.0,
      'durationSeconds': 240.0,
      'calculatedAt': '2026-10-28T10:00:00Z',
      'locationUpdatedAt': '2026-10-28T09:59:59Z',
      'expiresAt': '2026-10-28T10:00:30Z',
      'servedAt': '2026-10-28T10:00:00Z',
    };

void main() {
  late _Storage storage;
  late _Adapter adapter;
  late TripEtaRepositoryImpl repository;
  var generation = 12;

  setUp(() {
    generation = 12;
    AppConfig.reset();
    final config = AppConfig.initialize(
        forceMock: false, customBaseUrl: 'http://localhost:8080');
    storage = _Storage();
    when(() => storage.getSession()).thenAnswer(
        (_) async => AuthSessionSnapshot(generation, 'access-token', null));
    when(() => storage.isCurrentSession(any())).thenAnswer(
        (call) async => call.positionalArguments.first == generation);
    when(() => storage.clearIfCurrent(any())).thenAnswer((_) async => false);
    final dio = Dio(BaseOptions(baseUrl: config.apiBaseUrl));
    adapter =
        _Adapter((_) async => _jsonBody({'success': true, 'data': _eta()}));
    dio.httpClientAdapter = adapter;
    repository = TripEtaRepositoryImpl(ApiClient(
        config: config,
        customDio: dio,
        authInterceptor: AuthInterceptor(
            storageService: storage,
            tokenRefresher: TokenRefresher(
                storageService: storage, config: config, refreshDio: Dio()),
            getDio: () => dio)));
  });

  test('ETA uses authorized GET bound to the caller session', () async {
    final result = await repository.booking('booking-1', 12);
    expect(result.phase, 'PICKUP');
    expect(result.distanceMeters, 900);
    expect(adapter.requests, hasLength(1));
    final request = adapter.requests.single;
    expect(request.path, '/bookings/booking-1/eta');
    expect(request.method, 'GET');
    expect(request.data, isNull);
    expect(request.headers['Authorization'], 'Bearer access-token');
    expect(request.extra[AuthInterceptor.sessionGenerationExtraKey], 12);
  });

  test('Wrong Booking, malformed envelope and masked 404 are rejected',
      () async {
    adapter.reply = (_) async =>
        _jsonBody({'success': true, 'data': _eta('other-booking')});
    await expectLater(
        repository.booking('booking-1', 12), throwsA(isA<FormatException>()));
    adapter.reply = (_) async => _jsonBody({'success': false, 'data': null});
    await expectLater(
        repository.booking('booking-1', 12), throwsA(isA<FormatException>()));
    adapter.reply =
        (_) async => _jsonBody({'success': false, 'message': 'Not found'}, 404);
    await expectLater(
        repository.booking('booking-1', 12),
        throwsA(isA<ServerException>()
            .having((e) => e.statusCode, 'statusCode', 404)));
  });

  test('Replaced login session cannot dispatch ETA request', () async {
    generation = 13;
    await expectLater(repository.booking('booking-1', 12), throwsException);
    expect(adapter.requests, isEmpty);
  });
}
