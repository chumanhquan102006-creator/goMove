import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gomove_mobile/core/config/app_config.dart';
import 'package:gomove_mobile/core/network/auth_interceptor.dart';
import 'package:gomove_mobile/core/network/token_refresher.dart';
import 'package:gomove_mobile/core/storage/secure_storage_service.dart';

class FakeSecureStorageService implements SecureStorageService {
  String? accessToken;
  String? refreshToken;
  String? userPublicId;
  int clearAllCallCount = 0;

  @override
  Future<void> saveTokens({required String accessToken, required String refreshToken}) async {
    this.accessToken = accessToken;
    this.refreshToken = refreshToken;
  }

  @override
  Future<String?> getAccessToken() async => accessToken;

  @override
  Future<String?> getRefreshToken() async => refreshToken;

  @override
  Future<void> saveUserPublicId(String publicId) async {
    userPublicId = publicId;
  }

  @override
  Future<String?> getUserPublicId() async => userPublicId;

  @override
  Future<void> clearAll() async {
    accessToken = null;
    refreshToken = null;
    userPublicId = null;
    clearAllCallCount++;
  }
}

class FakeRequestInterceptorHandler extends RequestInterceptorHandler {
  RequestOptions? nextOptions;

  @override
  void next(RequestOptions requestOptions) {
    nextOptions = requestOptions;
  }
}

class FakeErrorInterceptorHandler extends ErrorInterceptorHandler {
  DioException? nextError;
  Response<dynamic>? resolvedResponse;

  @override
  void next(DioException err) {
    nextError = err;
  }

  @override
  void resolve(Response<dynamic> response) {
    resolvedResponse = response;
  }
}

void main() {
  late FakeSecureStorageService fakeStorage;
  late TokenRefresher tokenRefresher;
  late AuthInterceptor interceptor;
  late Dio fakeDio;

  setUp(() {
    AppConfig.initialize(env: AppEnvironment.mock, forceMock: true);
    fakeStorage = FakeSecureStorageService();
    fakeDio = Dio();

    tokenRefresher = TokenRefresher(
      storageService: fakeStorage,
      config: AppConfig.instance,
      refreshDio: fakeDio,
    );

    interceptor = AuthInterceptor(
      storageService: fakeStorage,
      tokenRefresher: tokenRefresher,
      getDio: () => fakeDio,
    );
  });

  group('AuthInterceptor Tests', () {
    test('Tự động gắn Bearer Token cho các endpoint bảo mật', () async {
      fakeStorage.accessToken = 'test_valid_access_token';

      final options = RequestOptions(path: '/rides/estimate');
      final handler = FakeRequestInterceptorHandler();

      await interceptor.onRequest(options, handler);

      expect(handler.nextOptions, isNotNull);
      expect(handler.nextOptions!.headers['Authorization'], equals('Bearer test_valid_access_token'));
      expect(handler.nextOptions!.headers['Accept'], equals('application/json'));
    });

    test('Bỏ qua gắn token cho các endpoint public (/auth/login, /auth/register, /auth/refresh)', () async {
      fakeStorage.accessToken = 'test_valid_access_token';

      final loginOptions = RequestOptions(path: '/auth/login');
      final loginHandler = FakeRequestInterceptorHandler();
      await interceptor.onRequest(loginOptions, loginHandler);
      expect(loginHandler.nextOptions!.headers.containsKey('Authorization'), isFalse);

      final registerOptions = RequestOptions(path: '/auth/register');
      final registerHandler = FakeRequestInterceptorHandler();
      await interceptor.onRequest(registerOptions, registerHandler);
      expect(registerHandler.nextOptions!.headers.containsKey('Authorization'), isFalse);

      final refreshOptions = RequestOptions(path: '/auth/refresh');
      final refreshHandler = FakeRequestInterceptorHandler();
      await interceptor.onRequest(refreshOptions, refreshHandler);
      expect(refreshHandler.nextOptions!.headers.containsKey('Authorization'), isFalse);
    });

    test('Khi endpoint /auth/refresh bị lỗi 401: Xóa storage và KHÔNG gọi refresh lặp vô hạn', () async {
      fakeStorage.refreshToken = 'expired_refresh_token';

      final refreshOptions = RequestOptions(path: '/auth/refresh');
      final dioError = DioException(
        requestOptions: refreshOptions,
        response: Response(
          requestOptions: refreshOptions,
          statusCode: 401,
        ),
      );
      final handler = FakeErrorInterceptorHandler();

      await interceptor.onError(dioError, handler);

      expect(handler.nextError, equals(dioError));
      expect(fakeStorage.clearAllCallCount, equals(1));
      expect(tokenRefresher.isRefreshing, isFalse);
    });
  });
}
