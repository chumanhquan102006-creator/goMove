import 'package:get_it/get_it.dart';
import '../../features/auth/data/datasources/auth_local_datasource.dart';
import '../../features/auth/data/datasources/auth_mock_datasource.dart';
import '../../features/auth/data/datasources/auth_remote_datasource.dart';
import '../../features/auth/data/repositories/auth_repository_impl.dart';
import '../../features/auth/data/repositories/mock_auth_repository_impl.dart';
import '../../features/auth/domain/repositories/auth_repository.dart';
import '../../features/auth/domain/usecases/check_auth_status_usecase.dart';
import '../../features/auth/domain/usecases/get_current_user_usecase.dart';
import '../../features/auth/domain/usecases/login_usecase.dart';
import '../../features/auth/domain/usecases/logout_usecase.dart';
import '../../features/auth/domain/usecases/register_usecase.dart';
import '../../features/auth/presentation/bloc/auth_bloc.dart';
import '../config/app_config.dart';
import '../network/api_client.dart';
import '../network/auth_interceptor.dart';
import '../network/token_refresher.dart';
import '../storage/secure_storage_service.dart';

final GetIt sl = GetIt.instance;

/// Khởi tạo toàn bộ Dependencies cho ứng dụng.
/// Cung cấp điểm neo (Hook) chuyển đổi chuyển đổi mượt mà giữa Mock và Real Repository
/// theo đúng chiến lược Frontend-First (Điều 161, 162 Master Context).
Future<void> setupServiceLocator({required AppConfig config}) async {
  // -------------------------------------------------------------
  // 1. Hạ tầng Core & Storage
  // -------------------------------------------------------------
  sl.registerSingleton<AppConfig>(config);

  sl.registerLazySingleton<SecureStorageService>(
    () => SecureStorageServiceImpl(),
  );

  sl.registerLazySingleton<TokenRefresher>(
    () => TokenRefresher(
      storageService: sl<SecureStorageService>(),
      config: sl<AppConfig>(),
    ),
  );

  sl.registerLazySingleton<AuthInterceptor>(
    () => AuthInterceptor(
      storageService: sl<SecureStorageService>(),
      tokenRefresher: sl<TokenRefresher>(),
      getDio: () => sl<ApiClient>().dioInstance,
    ),
  );

  sl.registerLazySingleton<ApiClient>(
    () => ApiClient(
      config: sl<AppConfig>(),
      authInterceptor: sl<AuthInterceptor>(),
    ),
  );

  // -------------------------------------------------------------
  // 2. Data Sources
  // -------------------------------------------------------------
  sl.registerLazySingleton<AuthLocalDataSource>(
    () => AuthLocalDataSourceImpl(storageService: sl<SecureStorageService>()),
  );

  sl.registerLazySingleton<AuthRemoteDataSource>(
    () => AuthRemoteDataSourceImpl(apiClient: sl<ApiClient>()),
  );

  sl.registerLazySingleton<AuthMockDataSource>(
    () => AuthMockDataSourceImpl(),
  );

  // -------------------------------------------------------------
  // 3. Repositories (ĐIỂM NEO HOOK: Mock vs Real Switching)
  // -------------------------------------------------------------
  if (config.isMock) {
    // =========================================================================
    // [HOOK MOCK]: Đăng ký Mock Repository phục vụ phát triển giao diện & luồng.
    // Toàn bộ BLoC và Widget sẽ nhận MockAuthRepositoryImpl mà KHÔNG biết đây là Mock.
    // =========================================================================
    sl.registerLazySingleton<AuthRepository>(
      () => MockAuthRepositoryImpl(
        mockDataSource: sl<AuthMockDataSource>(),
        localDataSource: sl<AuthLocalDataSource>(),
      ),
    );
  } else {
    // =========================================================================
    // [HOOK REAL]: Đăng ký Real Repository kết nối trực tiếp đến Spring Boot API.
    // Chuyển đổi chỉ bằng cách đổi cờ isMock trong AppConfig mà không đụng vào Presentation.
    // =========================================================================
    sl.registerLazySingleton<AuthRepository>(
      () => AuthRepositoryImpl(
        remoteDataSource: sl<AuthRemoteDataSource>(),
        localDataSource: sl<AuthLocalDataSource>(),
      ),
    );
  }

  // -------------------------------------------------------------
  // 4. Domain UseCases
  // -------------------------------------------------------------
  sl.registerLazySingleton<LoginUseCase>(
    () => LoginUseCase(sl<AuthRepository>()),
  );

  sl.registerLazySingleton<RegisterUseCase>(
    () => RegisterUseCase(sl<AuthRepository>()),
  );

  sl.registerLazySingleton<LogoutUseCase>(
    () => LogoutUseCase(sl<AuthRepository>()),
  );

  sl.registerLazySingleton<CheckAuthStatusUseCase>(
    () => CheckAuthStatusUseCase(sl<AuthRepository>()),
  );

  sl.registerLazySingleton<GetCurrentUserUseCase>(
    () => GetCurrentUserUseCase(sl<AuthRepository>()),
  );

  // -------------------------------------------------------------
  // 5. Presentation BLoCs (Đăng ký Factory)
  // -------------------------------------------------------------
  sl.registerFactory<AuthBloc>(
    () => AuthBloc(
      loginUseCase: sl<LoginUseCase>(),
      registerUseCase: sl<RegisterUseCase>(),
      logoutUseCase: sl<LogoutUseCase>(),
      checkAuthStatusUseCase: sl<CheckAuthStatusUseCase>(),
    ),
  );
}
