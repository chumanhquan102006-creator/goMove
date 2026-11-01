import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gomove_mobile/core/config/app_config.dart';
import 'package:gomove_mobile/core/constants/api_endpoints.dart';
import 'package:gomove_mobile/core/error/exceptions.dart';
import 'package:gomove_mobile/core/network/api_client.dart';
import 'package:gomove_mobile/core/network/auth_interceptor.dart';
import 'package:gomove_mobile/core/network/token_refresher.dart';
import 'package:gomove_mobile/core/storage/secure_storage_service.dart';
import 'package:gomove_mobile/features/customer/data/repositories/geocoding_repository_impl.dart';
import 'package:gomove_mobile/features/customer/domain/models/place_search_result.dart';
import 'package:gomove_mobile/features/customer/domain/models/quote.dart';
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

Map<String, dynamic> _place({
  String label = 'Hồ Hoàn Kiếm, Hà Nội',
  double latitude = 21.0287,
  double longitude = 105.8524,
}) =>
    {
      'label': label,
      'name': 'Hồ Hoàn Kiếm',
      'street': null,
      'district': 'Hoàn Kiếm',
      'city': 'Hà Nội',
      'latitude': latitude,
      'longitude': longitude,
      'attribution': '© OpenStreetMap contributors',
    };

void main() {
  late _Storage storage;
  late _Adapter adapter;
  late GeocodingRepositoryImpl repository;
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
    adapter = _Adapter((_) async => _jsonBody({
          'success': true,
          'data': [_place()]
        }));
    dio.httpClientAdapter = adapter;
    repository = GeocodingRepositoryImpl(ApiClient(
        config: config,
        customDio: dio,
        authInterceptor: AuthInterceptor(
            storageService: storage,
            tokenRefresher: TokenRefresher(
                storageService: storage, config: config, refreshDio: Dio()),
            getDio: () => dio)));
  });

  test('Place response retains real optional fields and rejects invalid points',
      () {
    final place = PlaceSearchResult.fromJson(_place());
    expect(place.label, 'Hồ Hoàn Kiếm, Hà Nội');
    expect(place.name, 'Hồ Hoàn Kiếm');
    expect(place.street, isNull);
    expect(place.district, 'Hoàn Kiếm');
    expect(place.city, 'Hà Nội');
    expect(place.coordinates.latitude, 21.0287);
    expect(place.coordinates.longitude, 105.8524);
    expect(place.attribution, '© OpenStreetMap contributors');

    final noOptionalFields = PlaceSearchResult.fromJson({
      'label': 'Hà Nội',
      'latitude': 21,
      'longitude': 105,
    });
    expect(noOptionalFields.name, isNull);
    expect(noOptionalFields.district, isNull);
    expect(noOptionalFields.city, isNull);
    expect(noOptionalFields.attribution, isNull);

    expect(() => PlaceSearchResult.fromJson(_place(latitude: 91)),
        throwsFormatException);
    expect(() => PlaceSearchResult.fromJson(_place(longitude: double.nan)),
        throwsFormatException);
    expect(() => PlaceSearchResult.fromJson(_place(label: '  ')),
        throwsFormatException);
  });

  test(
      'Search sends bounded Vietnamese query with current session and maps up to five valid results',
      () async {
    adapter.reply = (_) async => _jsonBody({
          'success': true,
          'data': [
            _place(),
            {'label': 'bad', 'latitude': 999, 'longitude': 105},
            ...List.generate(
                6,
                (index) => _place(
                    label: 'Địa điểm $index', latitude: 21.01 + index / 1000)),
          ]
        });
    final results =
        await repository.search('  Hồ Hoàn Kiếm  ', sessionGeneration: 7);
    expect(results, hasLength(4)); // first five entries only; one invalid
    expect(results.first.label, 'Hồ Hoàn Kiếm, Hà Nội');
    expect(results.last.label, 'Địa điểm 2');
    expect(adapter.requests, hasLength(1));
    final request = adapter.requests.single;
    expect(request.method, 'GET');
    expect(request.path, ApiEndpoints.locationSearch);
    expect(request.uri.queryParameters, {'q': 'Hồ Hoàn Kiếm'});
    expect(request.headers['Authorization'], 'Bearer access-token');
    expect(request.extra[AuthInterceptor.sessionGenerationExtraKey], 7);
  });

  test('Short and oversized queries are rejected before dispatch', () async {
    await expectLater(repository.search(' a '), throwsFormatException);
    await expectLater(repository.search('a' * 101), throwsFormatException);
    expect(adapter.requests, isEmpty);
  });

  test('Reverse preserves exact selected point, allows null, rejects mismatch',
      () async {
    const point = Coordinates(21.0287, 105.8524);
    adapter.reply = (_) async => _jsonBody({'success': true, 'data': _place()});
    final result = await repository.reverse(point, sessionGeneration: 7);
    expect(result?.label, 'Hồ Hoàn Kiếm, Hà Nội');
    expect(result?.coordinates.latitude, point.latitude);
    expect(adapter.requests.single.path, ApiEndpoints.locationReverse);
    expect(adapter.requests.single.uri.queryParameters,
        {'latitude': '21.0287', 'longitude': '105.8524'});

    adapter.reply = (_) async => _jsonBody({'success': true, 'data': null});
    expect(await repository.reverse(point, sessionGeneration: 7), isNull);

    adapter.reply = (_) async => _jsonBody({
          'success': true,
          'data': _place(latitude: 21.0288),
        });
    await expectLater(
        repository.reverse(point, sessionGeneration: 7), throwsFormatException);
    await expectLater(
        repository.reverse(const Coordinates(91, 105), sessionGeneration: 7),
        throwsFormatException);
    expect(adapter.requests, hasLength(3));
  });

  test('Malformed envelope and provider rate limit are safe errors', () async {
    adapter.reply = (_) async => _jsonBody({
          'data': [_place()]
        });
    await expectLater(repository.search('Hoàn Kiếm', sessionGeneration: 7),
        throwsFormatException);
    adapter.reply = (_) async => _jsonBody({
          'success': false,
          'code': 'GEOCODING_RATE_LIMITED',
          'message': 'Address lookup is rate limited',
        }, 429);
    await expectLater(
        repository.search('Hoàn Kiếm', sessionGeneration: 7),
        throwsA(isA<ServerException>()
            .having((error) => error.statusCode, 'statusCode', 429)));
  });

  test('A replaced session cannot dispatch an old address lookup', () async {
    generation = 8;
    await expectLater(
        repository.search('Hoàn Kiếm', sessionGeneration: 7), throwsException);
    expect(adapter.requests, isEmpty);
  });
}
