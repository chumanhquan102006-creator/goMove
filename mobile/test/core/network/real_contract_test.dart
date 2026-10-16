import 'dart:async';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gomove_mobile/core/config/app_config.dart';
import 'package:gomove_mobile/core/constants/api_endpoints.dart';
import 'package:gomove_mobile/core/error/exceptions.dart';
import 'package:gomove_mobile/core/network/api_client.dart';
import 'package:gomove_mobile/core/network/auth_interceptor.dart';
import 'package:gomove_mobile/core/network/logging_interceptor.dart';
import 'package:gomove_mobile/core/network/token_refresher.dart';
import 'package:gomove_mobile/core/storage/secure_storage_service.dart';
import 'package:gomove_mobile/features/auth/data/datasources/auth_remote_datasource.dart';
import 'package:gomove_mobile/features/auth/data/models/login_request_model.dart';
import 'package:gomove_mobile/features/auth/data/models/user_model.dart';
import 'package:gomove_mobile/features/auth/domain/entities/user.dart';
import 'package:gomove_mobile/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:gomove_mobile/features/auth/presentation/screens/role_home.dart';
import 'package:gomove_mobile/features/customer/data/repositories/customer_repository_impl.dart';
import 'package:gomove_mobile/features/customer/domain/models/quote.dart';
import 'package:gomove_mobile/features/customer/presentation/screens/customer_home_screen.dart';
import 'package:gomove_mobile/features/driver/presentation/screens/driver_home_screen.dart';
import 'package:gomove_mobile/core/di/injection.dart';

class MemoryAuthStorage implements SecureStorageService {
  String? access;
  String? refresh;
  String? userId;
  int generation = 0;
  @override
  Future<void> saveTokens(
      {required String accessToken, required String refreshToken,
      String? userPublicId}) async {
    access = accessToken;
    refresh = refreshToken;
    userId = userPublicId;
    generation++;
  }

  @override
  Future<AuthSessionSnapshot> getSession() async =>
      AuthSessionSnapshot(generation, access, refresh);
  @override
  Future<bool> isCurrentSession(int expected) async => generation == expected;
  @override
  Future<bool> rotateTokensIfCurrent({required int generation,
      required String expectedRefreshToken, required String accessToken,
      required String refreshToken}) async {
    if (this.generation != generation || refresh != expectedRefreshToken) {
      return false;
    }
    access = accessToken;
    refresh = refreshToken;
    return true;
  }
  @override
  Future<bool> saveUserPublicIdIfCurrent(int generation, String publicId) async {
    if (this.generation != generation) return false;
    userId = publicId;
    return true;
  }
  @override
  Future<bool> clearIfCurrent(int generation) async {
    if (this.generation != generation) return false;
    await clearAll();
    return true;
  }

  @override
  Future<String?> getAccessToken() async => access;
  @override
  Future<String?> getRefreshToken() async => refresh;
  @override
  Future<void> saveUserPublicId(String publicId) async {
    userId = publicId;
  }

  @override
  Future<String?> getUserPublicId() async => userId;
  @override
  Future<void> clearAll() async {
    generation++;
    access = null;
    refresh = null;
    userId = null;
  }
}

class FakeHttpAdapter implements HttpClientAdapter {
  final FutureOr<ResponseBody> Function(RequestOptions) respond;
  FakeHttpAdapter(this.respond);
  @override
  Future<ResponseBody> fetch(RequestOptions options,
          Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async =>
      await respond(options);
  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> quoteJson() => {
      'quotePublicId': '550e8400-e29b-41d4-a716-446655440001',
      'pickup': {'latitude': 21.0287, 'longitude': 105.8524},
      'dropoff': {'latitude': 21.0245, 'longitude': 105.8576},
      'vehicleType': 'MOTORBIKE',
      'distanceMeters': 1200,
      'durationSeconds': 400,
      'currency': 'VND',
      'baseFare': 12000,
      'distanceFare': 5400,
      'timeFare': 0,
      'surcharge': 0,
      'surgeAmount': 0,
      'discountAmount': 0,
      'roundingAdjustment': 0,
      'finalFare': 17400,
      'status': 'ISSUED',
      'issuedAt': '2026-10-11T00:00:00Z',
      'expiresAt': '2026-10-11T00:01:00Z',
    };

Map<String, dynamic> bookingJson() => {
      'bookingPublicId': '550e8400-e29b-41d4-a716-446655440002',
      'quotePublicId': '550e8400-e29b-41d4-a716-446655440001',
      'status': 'REQUESTED',
      'vehicleType': 'MOTORBIKE',
      'currency': 'VND',
      'finalFare': 17400,
      'createdAt': '2026-10-11T00:00:30Z',
    };

void main() {
  test('HTTPS origin yields HTTPS API and secure WebSocket default', () {
    final config = AppConfig.initialize(forceMock: false,
      customBaseUrl: 'https://api.example.test/');
    expect(config.apiBaseUrl, 'https://api.example.test/api/v1');
    expect(config.wsBaseUrl, 'wss://api.example.test/ws');
    expect(config.environment, AppEnvironment.dev);
  });

  test('Base URL and exact Auth/Quote/Booking contracts through Dio', () async {
    final config = AppConfig.initialize(
        forceMock: false, customBaseUrl: 'http://10.0.2.2:8080/api/v1///');
    expect(config.apiBaseUrl, 'http://10.0.2.2:8080/api/v1');
    expect(config.wsBaseUrl, 'ws://10.0.2.2:8080/ws');
    final storage = MemoryAuthStorage()..access = 'access-token';
    final dio = Dio(BaseOptions(baseUrl: config.apiBaseUrl));
    final refresh = TokenRefresher(
        storageService: storage, config: config, refreshDio: Dio());
    final auth = AuthInterceptor(
        storageService: storage, tokenRefresher: refresh, getDio: () => dio);
    final client =
        ApiClient(config: config, authInterceptor: auth, customDio: dio);
    final paths = <String>[];
    final headers = <String, dynamic>{};
    Map<String, dynamic>? bookingBody;
    Map<String, dynamic>? quoteBody;
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      paths.add(options.uri.toString());
      if (options.path == ApiEndpoints.login) {
        handler
            .resolve(Response(requestOptions: options, statusCode: 200, data: {
          'data': {
            'accessToken': 'jwt',
            'refreshToken': 'refresh',
            'tokenType': 'Bearer',
            'expiresIn': 900,
            'user': {
              'publicId': '550e8400-e29b-41d4-a716-446655440003',
              'phone': '0901234567',
              'email': null,
              'fullName': 'Customer',
              'role': 'CUSTOMER',
              'status': 'ACTIVE'
            },
          }
        }));
      } else if (options.path == ApiEndpoints.quotes) {
        quoteBody = Map<String, dynamic>.from(options.data as Map);
        handler.resolve(Response(
            requestOptions: options,
            statusCode: 201,
            data: {'data': quoteJson()}));
      } else if (options.path == ApiEndpoints.bookings) {
        bookingBody = Map<String, dynamic>.from(options.data as Map);
        headers.addAll(options.headers);
        handler.resolve(Response(
            requestOptions: options,
            statusCode: 201,
            data: {'data': bookingJson()}));
      } else if (options.path.startsWith('/bookings/')) {
        handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: {'data': bookingJson()}));
      } else if (options.path.startsWith('/quotes/')) {
        handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: {'data': quoteJson()}));
      } else {
        handler.reject(
            DioException(requestOptions: options, message: 'Unexpected path'));
      }
    }));

    final login = await AuthRemoteDataSourceImpl(apiClient: client).login(
        const LoginRequestModel(identifier: '0901234567', password: 'hidden'));
    expect((login['user'] as UserModel).role, UserRole.customer);
    expect((login['token'] as dynamic).accessToken, 'jwt');
    final repository = CustomerRepositoryImpl(client);
    final quote = await repository.requestQuote(const QuoteRequest(
        pickup: Coordinates(21.0287, 105.8524),
        dropoff: Coordinates(21.0245, 105.8576),
        vehicleType: VehicleType.motorbike));
    expect(quoteBody!['vehicleType'], 'MOTORBIKE');
    expect(quote.finalFare, '17400');
    await repository.getQuote(quote.publicId);
    final booking = await repository.createBooking(
        quote.publicId, '550e8400-e29b-41d4-a716-446655440099');
    expect(bookingBody, {'quotePublicId': quote.publicId});
    expect(headers['Idempotency-Key'], '550e8400-e29b-41d4-a716-446655440099');
    expect(booking.finalFare, quote.finalFare);
    await repository.getBooking(booking.publicId);
    expect(paths, [
      'http://10.0.2.2:8080/api/v1/auth/login',
      'http://10.0.2.2:8080/api/v1/quotes',
      'http://10.0.2.2:8080/api/v1/quotes/${quote.publicId}',
      'http://10.0.2.2:8080/api/v1/bookings',
      'http://10.0.2.2:8080/api/v1/bookings/${booking.publicId}',
    ]);
  });

  test('Dio parses Backend validation code and safe field details', () async {
    final config = AppConfig.initialize(
        forceMock: false, customBaseUrl: 'http://10.0.2.2:8080');
    final storage = MemoryAuthStorage();
    final dio = Dio(BaseOptions(baseUrl: config.apiBaseUrl));
    final client = ApiClient(
        config: config,
        authInterceptor: AuthInterceptor(
            storageService: storage,
            tokenRefresher: TokenRefresher(
                storageService: storage, config: config, refreshDio: Dio()),
            getDio: () => dio),
        customDio: dio);
    dio.httpClientAdapter = FakeHttpAdapter((_) => ResponseBody.fromString(
        '{"success":false,"code":"VALIDATION_ERROR",'
        '"message":"Request validation failed",'
        '"details":{"password":"size must be between 8 and 128",'
        '"unexpected":42}}',
        400,
        headers: {
          Headers.contentTypeHeader: ['application/json']
        }));
    await expectLater(
        client.post<Map<String, dynamic>>(ApiEndpoints.register,
            data: {'phone': '0901234567', 'password': 'short'}),
        throwsA(isA<ServerException>()
            .having((e) => e.errorCode, 'code', 'VALIDATION_ERROR')
            .having((e) => e.details,
                'string-only details', {'password': 'size must be between 8 and 128'})));
  });

  test(
      'Logging never includes tokens, passwords, Cookie, query or response payload',
      () async {
    final output = <String>[];
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api/v1'));
    dio.interceptors.add(LoggingInterceptor(log: output.add));
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      handler.resolve(Response(
          requestOptions: options,
          statusCode: 200,
          data: {'refreshToken': 'response-secret'}));
    }));
    await dio.post<dynamic>('/auth/login',
        data: {'password': 'password-secret'},
        queryParameters: {'token': 'query-secret'},
        options: Options(headers: {
          'Authorization': 'Bearer bearer-secret',
          'Cookie': 'cookie-secret'
        }));
    final joined = output.join(' ');
    for (final secret in [
      'password-secret',
      'query-secret',
      'bearer-secret',
      'cookie-secret',
      'response-secret'
    ]) {
      expect(joined, isNot(contains(secret)));
    }
    expect(joined, contains('/api/v1/auth/login'));
  });

  test('Concurrent 401 rotates once and retry preserves Idempotency-Key',
      () async {
    final config = AppConfig.initialize(
        forceMock: false, customBaseUrl: 'http://10.0.2.2:8080');
    final storage = MemoryAuthStorage()
      ..access = 'old-access'
      ..refresh = 'old-refresh';
    final refreshDio = Dio(BaseOptions(baseUrl: config.apiBaseUrl));
    var rotations = 0;
    refreshDio.interceptors
        .add(InterceptorsWrapper(onRequest: (options, handler) async {
      rotations++;
      expect(options.uri.path, '/api/v1/auth/refresh');
      expect((options.data as Map<String, dynamic>)['refreshToken'],
          'old-refresh');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      handler.resolve(Response(requestOptions: options, statusCode: 200, data: {
        'data': {
          'accessToken': 'new-access',
          'refreshToken': 'new-refresh',
        }
      }));
    }));
    final dio = Dio(BaseOptions(baseUrl: config.apiBaseUrl));
    final auth = AuthInterceptor(
        storageService: storage,
        tokenRefresher: TokenRefresher(
            storageService: storage, config: config, refreshDio: refreshDio),
        getDio: () => dio);
    dio.interceptors.add(auth);
    final seenKeys = <String>[];
    dio.httpClientAdapter = FakeHttpAdapter((options) {
      seenKeys.add(options.headers['Idempotency-Key']?.toString() ?? 'missing');
      final status =
          options.headers['Authorization'] == 'Bearer new-access' ? 201 : 401;
      return ResponseBody.fromString('{"ok":true}', status, headers: {
        Headers.contentTypeHeader: ['application/json']
      });
    });
    final responses = await Future.wait([
      dio.post<dynamic>('/bookings',
          data: {'quotePublicId': 'q'},
          options: Options(headers: {'Idempotency-Key': 'one-key'})),
      dio.post<dynamic>('/bookings',
          data: {'quotePublicId': 'q'},
          options: Options(headers: {'Idempotency-Key': 'one-key'})),
    ]);
    expect(responses.map((response) => response.statusCode), [201, 201]);
    expect(rotations, 1);
    expect(storage.access, 'new-access');
    expect(storage.refresh, 'new-refresh');
    expect(seenKeys, everyElement('one-key'));
  });

  test('A delayed 401 cannot retry an old request with B access token',
      () async {
    final config = AppConfig.initialize(
        forceMock: false, customBaseUrl: 'http://10.0.2.2:8080');
    final storage = MemoryAuthStorage();
    await storage.saveTokens(
        accessToken: 'A-access', refreshToken: 'A-refresh', userPublicId: 'A');
    final dio = Dio(BaseOptions(baseUrl: config.apiBaseUrl));
    dio.interceptors.add(AuthInterceptor(
        storageService: storage,
        tokenRefresher: TokenRefresher(
            storageService: storage, config: config, refreshDio: Dio()),
        getDio: () => dio));
    final reached = Completer<void>();
    final oldReply = Completer<ResponseBody>();
    final sentWith = <String?>[];
    dio.httpClientAdapter = FakeHttpAdapter((options) {
      sentWith.add(options.headers['Authorization']?.toString());
      if (!reached.isCompleted) reached.complete();
      return oldReply.future;
    });

    final oldRequest = dio.get<dynamic>('/quotes/old');
    await reached.future;
    await storage.clearAll();
    await storage.saveTokens(
        accessToken: 'B-access', refreshToken: 'B-refresh', userPublicId: 'B');
    oldReply.complete(ResponseBody.fromString('{}', 401, headers: {
      Headers.contentTypeHeader: ['application/json']
    }));
    await expectLater(oldRequest, throwsA(isA<DioException>()));
    expect(sentWith, ['Bearer A-access']);
    expect((await storage.getSession()).accessToken, 'B-access');
    expect(storage.userId, 'B');
  });

  test('A delayed successful response is rejected after B login', () async {
    final config = AppConfig.initialize(
        forceMock: false, customBaseUrl: 'http://10.0.2.2:8080');
    final storage = MemoryAuthStorage();
    await storage.saveTokens(accessToken: 'A-access',
        refreshToken: 'A-refresh', userPublicId: 'A');
    final dio = Dio(BaseOptions(baseUrl: config.apiBaseUrl));
    dio.interceptors.add(AuthInterceptor(
        storageService: storage,
        tokenRefresher: TokenRefresher(
            storageService: storage, config: config, refreshDio: Dio()),
        getDio: () => dio));
    final reached = Completer<void>();
    final oldReply = Completer<ResponseBody>();
    dio.httpClientAdapter = FakeHttpAdapter((options) {
      expect(options.headers['Authorization'], 'Bearer A-access');
      reached.complete();
      return oldReply.future;
    });
    final oldRequest = dio.get<dynamic>('/quotes/old');
    await reached.future;
    await storage.clearAll();
    await storage.saveTokens(accessToken: 'B-access',
        refreshToken: 'B-refresh', userPublicId: 'B');
    oldReply.complete(ResponseBody.fromString('{}', 200, headers: {
      Headers.contentTypeHeader: ['application/json']
    }));
    await expectLater(oldRequest, throwsA(isA<DioException>().having(
        (error) => error.type, 'type', DioExceptionType.cancel)));
    expect(storage.userId, 'B');
  });

  test('Late A refresh success or 401 cannot overwrite or clear B session',
      () async {
    for (final refreshSucceeds in [true, false]) {
      final config = AppConfig.initialize(
          forceMock: false, customBaseUrl: 'http://10.0.2.2:8080');
      final storage = MemoryAuthStorage();
      await storage.saveTokens(accessToken: 'A-access',
          refreshToken: 'A-refresh', userPublicId: 'A');
      final started = Completer<void>();
      final release = Completer<void>();
      final refreshDio = Dio(BaseOptions(baseUrl: config.apiBaseUrl));
      refreshDio.httpClientAdapter = FakeHttpAdapter((options) async {
        expect(options.uri.path, '/api/v1/auth/refresh');
        started.complete();
        await release.future;
        return ResponseBody.fromString(
            refreshSucceeds
                ? '{"data":{"accessToken":"A-new",'
                  '"refreshToken":"A-refresh-new"}}'
                : '{}',
            refreshSucceeds ? 200 : 401,
            headers: {Headers.contentTypeHeader: ['application/json']});
      });
      var expiredCallbacks = 0;
      final dio = Dio(BaseOptions(baseUrl: config.apiBaseUrl));
      dio.interceptors.add(AuthInterceptor(
          storageService: storage,
          tokenRefresher: TokenRefresher(
              storageService: storage, config: config,
              refreshDio: refreshDio,
              onAuthenticationExpired: () => expiredCallbacks++),
          getDio: () => dio));
      final sentWith = <String?>[];
      dio.httpClientAdapter = FakeHttpAdapter((options) {
        sentWith.add(options.headers['Authorization']?.toString());
        return ResponseBody.fromString('{}', 401, headers: {
          Headers.contentTypeHeader: ['application/json']
        });
      });
      final oldRequest = dio.post<dynamic>('/bookings',
          data: {'quotePublicId': 'A-quote'},
          options: Options(headers: {'Idempotency-Key': 'A-key'}));
      await started.future;
      await storage.clearAll();
      await storage.saveTokens(accessToken: 'B-access',
          refreshToken: 'B-refresh', userPublicId: 'B');
      release.complete();
      await expectLater(oldRequest, throwsA(isA<DioException>()));
      expect(sentWith, ['Bearer A-access']);
      expect((await storage.getSession()).accessToken, 'B-access');
      expect((await storage.getSession()).refreshToken, 'B-refresh');
      expect(storage.userId, 'B');
      expect(expiredCallbacks, 0);
    }
  });

  test(
      'Unknown and ADMIN roles cannot become Customer; DRIVER has distinct home',
      () {
    UserModel parse(String role) => UserModel.fromJson({
          'publicId': 'uuid',
          'phone': '0901234567',
          'fullName': 'Example',
          'role': role,
          'status': 'ACTIVE'
        });
    expect(parse('CUSTOMER').role, UserRole.customer);
    expect(parse('DRIVER').role, UserRole.driver);
    expect(parse('ADMIN').role, UserRole.admin);
    expect(parse('OTHER').role, UserRole.unknown);
    expect(homeForRole(parse('CUSTOMER')), isA<CustomerHomeScreen>());
    expect(homeForRole(parse('DRIVER')), isA<DriverHomeScreen>());
    expect(homeForRole(parse('ADMIN')), isNot(isA<CustomerHomeScreen>()));
  });

  testWidgets('Driver and unsupported roles render separate destinations',
      (tester) async {
    AppConfig.reset();
    final config = AppConfig.initialize(forceMock: true);
    await sl.reset();
    await setupServiceLocator(config: config);
    const base = User(
        publicId: 'uuid',
        phoneNumber: '0901234567',
        fullName: 'Driver',
        role: UserRole.driver);
    await tester.pumpWidget(BlocProvider(
        create: (_) => sl<AuthBloc>(),
        child: MaterialApp(home: homeForRole(base))));
    expect(find.text('GoMove Tài xế'), findsOneWidget);
    expect(find.textContaining('Chế độ mock'), findsOneWidget);
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    const admin = User(
        publicId: 'uuid',
        phoneNumber: '0901234567',
        fullName: 'Admin',
        role: UserRole.admin);
    await tester.pumpWidget(MaterialApp(home: homeForRole(admin)));
    expect(find.text('Không hỗ trợ vai trò'), findsOneWidget);
  });
}
