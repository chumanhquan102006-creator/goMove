import 'dart:async';
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
import 'package:gomove_mobile/features/trip/data/repositories/road_route_repository_impl.dart';
import 'package:mocktail/mocktail.dart';

class _Storage extends Mock implements SecureStorageService {}

class _RouteAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  final requested = Completer<void>();
  Future<ResponseBody> Function(RequestOptions) reply;

  _RouteAdapter(this.reply);

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) {
    requests.add(options);
    if (!requested.isCompleted) requested.complete();
    return reply(options);
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _route({String? bookingId, bool available = true}) => {
      'sourceQuotePublicId': 'quote-1',
      'bookingPublicId': bookingId,
      'availability': available ? 'AVAILABLE' : 'UNAVAILABLE',
      'geometryFormat': available ? 'GEOJSON_LINESTRING' : null,
      'geometry': available
          ? {
              'type': 'LineString',
              'coordinates': [
                [105.8524, 21.0287],
                [105.8550, 21.0260],
                [105.8576, 21.0245]
              ],
            }
          : null,
      'routingProvider': 'OSRM',
      'capturedAt': '2026-10-27T03:00:00Z',
    };

ResponseBody _jsonBody(Object value, [int status = 200]) =>
    ResponseBody.fromString(jsonEncode(value), status, headers: {
      Headers.contentTypeHeader: ['application/json']
    });

void main() {
  late _Storage storage;
  late _RouteAdapter adapter;
  late RoadRouteRepositoryImpl repository;
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
    adapter = _RouteAdapter(
        (_) async => _jsonBody({'success': true, 'data': _route()}));
    dio.httpClientAdapter = adapter;
    repository = RoadRouteRepositoryImpl(ApiClient(
        config: config,
        customDio: dio,
        authInterceptor: AuthInterceptor(
            storageService: storage,
            tokenRefresher: TokenRefresher(
                storageService: storage, config: config, refreshDio: Dio()),
            getDio: () => dio)));
  });

  test(
      'Quote and Booking use exact authorized GET paths and session generation',
      () async {
    final quote = await repository.quote('quote-1', 12);
    expect(quote.available, isTrue);
    expect(quote.points, hasLength(3));
    expect(adapter.requests.single.path, '/quotes/quote-1/route');

    adapter.reply = (_) async =>
        _jsonBody({'success': true, 'data': _route(bookingId: 'booking-1')});
    final booking = await repository.booking('booking-1', 12);
    expect(booking.available, isTrue);
    expect(booking.bookingPublicId, 'booking-1');
    expect(adapter.requests.last.path, '/bookings/booking-1/route');
    expect(adapter.requests, hasLength(2));
    for (final request in adapter.requests) {
      expect(request.method, 'GET');
      expect(request.data, isNull);
      expect(request.headers['Authorization'], 'Bearer access-token');
      expect(request.extra[AuthInterceptor.sessionGenerationExtraKey], 12);
    }
  });

  test(
      'UNAVAILABLE remains an authorized empty route; malformed IDs and envelope fail',
      () async {
    adapter.reply = (_) async => _jsonBody({
          'success': true,
          'data': _route(bookingId: 'booking-1', available: false)
        });
    final route = await repository.booking('booking-1', 12);
    expect(route.available, isFalse);
    expect(route.points, isEmpty);

    adapter.reply = (_) async => _jsonBody(
        {'success': true, 'data': _route(bookingId: 'someone-elses-booking')});
    await expectLater(
        repository.booking('booking-1', 12), throwsA(isA<FormatException>()));
    adapter.reply = (_) async =>
        _jsonBody({'success': true, 'data': _route(bookingId: 'booking-1')});
    await expectLater(
        repository.quote('quote-1', 12), throwsA(isA<FormatException>()));
    adapter.reply = (_) async => _jsonBody({'success': false, 'data': null});
    await expectLater(
        repository.quote('quote-1', 12), throwsA(isA<FormatException>()));
  });

  test('401, 403 and masked 404 are errors, never route-unavailable fallbacks',
      () async {
    for (final status in [401, 403, 404]) {
      adapter.reply = (_) async => _jsonBody({
            'success': false,
            'code': status == 404 ? 'BOOKING_NOT_FOUND' : 'FORBIDDEN',
            'message': 'Access denied'
          }, status);
      await expectLater(
          repository.booking('booking-1', 12),
          throwsA(isA<ServerException>()
              .having((error) => error.statusCode, 'statusCode', status)));
    }
  });

  test(
      'replaced session blocks dispatch and late response before route parsing',
      () async {
    generation = 13;
    await expectLater(repository.quote('quote-1', 12), throwsException);
    expect(adapter.requests, isEmpty);

    generation = 12;
    final pending = Completer<ResponseBody>();
    adapter.reply = (_) => pending.future;
    final oldRequest = repository.booking('booking-1', 12);
    await adapter.requested.future;
    generation = 13;
    pending.complete(
        _jsonBody({'success': true, 'data': _route(bookingId: 'booking-1')}));
    await expectLater(oldRequest, throwsException);
    expect(adapter.requests, hasLength(1));
  });
}
