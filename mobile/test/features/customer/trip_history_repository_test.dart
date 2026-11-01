import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gomove_mobile/core/config/app_config.dart';
import 'package:gomove_mobile/core/constants/api_endpoints.dart';
import 'package:gomove_mobile/core/network/api_client.dart';
import 'package:gomove_mobile/core/network/auth_interceptor.dart';
import 'package:gomove_mobile/core/network/token_refresher.dart';
import 'package:gomove_mobile/core/storage/secure_storage_service.dart';
import 'package:gomove_mobile/features/customer/data/repositories/trip_history_repository_impl.dart';
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

const _id = '550e8400-e29b-41d4-a716-446655440099';
const _fare = '1234567890123.00';

Map<String, dynamic> _item() => {
      'bookingPublicId': _id,
      'createdAt': '2026-10-01T09:00:00Z',
      'tripCompletedAt': '2026-10-01T09:30:00Z',
      'pickupLatitude': 21.0287,
      'pickupLongitude': 105.8524,
      'dropoffLatitude': 21.0245,
      'dropoffLongitude': 105.8576,
      'vehicleType': 'MOTORBIKE',
      'finalFare': _fare,
      'currency': 'VND',
      'status': 'COMPLETED',
      'paymentStatus': 'PENDING',
    };

String _numericFare(Object data) => jsonEncode({'success': true, 'data': data})
    .replaceAll('"finalFare":"$_fare"', '"finalFare":$_fare');

ResponseBody _body(String raw, [int status = 200]) =>
    ResponseBody.fromString(raw, status, headers: {
      Headers.contentTypeHeader: ['application/json']
    });

void main() {
  late _Storage storage;
  late _Adapter adapter;
  late TripHistoryRepositoryImpl repository;
  var generation = 7;

  setUp(() {
    generation = 7;
    AppConfig.reset();
    final config = AppConfig.initialize(
        forceMock: false, customBaseUrl: 'http://localhost:8080');
    storage = _Storage();
    when(() => storage.getSession()).thenAnswer(
        (_) async => AuthSessionSnapshot(generation, 'access-token', null));
    when(() => storage.isCurrentSession(any())).thenAnswer(
        (call) async => call.positionalArguments.first == generation);
    final dio = Dio(BaseOptions(baseUrl: config.apiBaseUrl));
    adapter = _Adapter((_) async => _body(_numericFare({
          'items': [_item()],
          'page': 0,
          'size': 10,
          'totalElements': 1,
          'hasNext': false,
        })));
    dio.httpClientAdapter = adapter;
    repository = TripHistoryRepositoryImpl(ApiClient(
        config: config,
        customDio: dio,
        authInterceptor: AuthInterceptor(
            storageService: storage,
            tokenRefresher: TokenRefresher(
                storageService: storage, config: config, refreshDio: Dio()),
            getDio: () => dio)));
  });

  test('History parses exact fare and sends bounded page with session',
      () async {
    final page = await repository.page(0, 10, 7);
    expect(page.items, hasLength(1));
    expect(page.items.single.finalFare, _fare);
    expect(page.items.single.paymentStatus, 'PENDING');
    expect(page.items.single.pickup.latitude, 21.0287);
    expect(page.hasNext, isFalse);
    final request = adapter.requests.single;
    expect(request.path, ApiEndpoints.bookingHistory);
    expect(request.uri.queryParameters, {'page': '0', 'size': '10'});
    expect(request.headers['Authorization'], 'Bearer access-token');
    expect(request.extra[AuthInterceptor.sessionGenerationExtraKey], 7);
  });

  test('Empty page and invalid or mismatched pages are handled', () async {
    adapter.reply = (_) async => _body(_numericFare({
          'items': <Object>[],
          'page': 0,
          'size': 10,
          'totalElements': 0,
          'hasNext': false
        }));
    expect((await repository.page(0, 10, 7)).items, isEmpty);
    await expectLater(repository.page(1, 10, 7), throwsFormatException);
    adapter.reply = (_) async => _body(_numericFare({
          'items': [
            {..._item(), 'status': 'IN_PROGRESS'}
          ],
          'page': 0,
          'size': 10,
          'totalElements': 1,
          'hasNext': false
        }));
    await expectLater(repository.page(0, 10, 7), throwsFormatException);
  });

  test('Detail uses owned Booking GET and preserves exact fare', () async {
    adapter.reply = (_) async => _body(_numericFare({
          'bookingPublicId': _id,
          'quotePublicId': '550e8400-e29b-41d4-a716-446655440003',
          'status': 'COMPLETED',
          'vehicleType': 'MOTORBIKE',
          'currency': 'VND',
          'finalFare': _fare,
          'createdAt': '2026-10-01T09:00:00Z',
          'tripCompletedAt': '2026-10-01T09:30:00Z',
          'pickupLatitude': 21.0287,
          'pickupLongitude': 105.8524,
          'dropoffLatitude': 21.0245,
          'dropoffLongitude': 105.8576,
          'distanceMeters': 5200.000,
          'durationSeconds': 840.000,
        }));
    final detail = await repository.detail(_id, 7);
    expect(detail.publicId, _id);
    expect(detail.finalFare, _fare);
    expect(detail.pickup?.longitude, 105.8524);
    expect(detail.distanceMeters, '5200.0');
    expect(adapter.requests.single.path, ApiEndpoints.booking(_id));
  });

  test('Replaced session never dispatches history request', () async {
    generation = 8;
    await expectLater(repository.page(0, 10, 7), throwsException);
    expect(adapter.requests, isEmpty);
  });
}
