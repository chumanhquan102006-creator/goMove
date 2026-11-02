import 'package:get_it/get_it.dart';
import '../../features/admin/data/admin_repository_impl.dart';
import '../../features/admin/domain/admin_repository.dart';
import '../../features/admin/presentation/admin_cubit.dart';
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
import '../../features/customer/data/active_booking_store.dart';
import '../../features/customer/data/booking_intent_store.dart';
import '../../features/customer/data/repositories/customer_repository_impl.dart';
import '../../features/customer/data/repositories/geocoding_repository_impl.dart';
import '../../features/customer/data/repositories/trip_history_repository_impl.dart';
import '../../features/customer/domain/repositories/customer_repository.dart';
import '../../features/customer/domain/repositories/geocoding_repository.dart';
import '../../features/customer/domain/repositories/trip_history_repository.dart';
import '../../features/customer/domain/usecases/customer_usecases.dart';
import '../../features/customer/presentation/bloc/booking_cubit.dart';
import '../../features/customer/presentation/bloc/customer_active_booking_cubit.dart';
import '../../features/customer/presentation/bloc/quote_cubit.dart';
import '../../features/customer/presentation/bloc/trip_history_cubit.dart';
import '../../features/customer/presentation/bloc/trip_history_detail_cubit.dart';
import '../../features/driver/data/accepted_booking_store.dart';
import '../../features/driver/data/location/driver_location_source.dart';
import '../../features/driver/data/repositories/driver_repository_impl.dart';
import '../../features/driver/data/repositories/driver_earnings_repository_impl.dart';
import '../../features/driver/domain/repositories/driver_earnings_repository.dart';
import '../../features/driver/domain/repositories/driver_repository.dart';
import '../../features/driver/domain/usecases/driver_usecases.dart';
import '../../features/driver/presentation/bloc/driver_cubit.dart';
import '../../features/driver/presentation/bloc/driver_earnings_cubit.dart';
import '../../features/driver/presentation/bloc/onboarding_cubit.dart';
import '../../features/review/data/rating_repository_impl.dart';
import '../../features/review/data/review_repository_impl.dart';
import '../../features/review/domain/rating_repository.dart';
import '../../features/review/domain/review_repository.dart';
import '../../features/review/presentation/admin_quality_cubit.dart';
import '../../features/review/presentation/driver_reputation_cubit.dart';
import '../../features/review/presentation/rating_cubit.dart';
import '../../features/trip/data/repositories/trip_repository_impl.dart';
import '../../features/trip/data/repositories/trip_eta_repository_impl.dart';
import '../../features/trip/data/repositories/road_route_repository_impl.dart';
import '../../features/trip/data/trip_realtime_client.dart';
import '../../features/trip/domain/repositories/trip_repository.dart';
import '../../features/trip/domain/repositories/trip_eta_repository.dart';
import '../../features/trip/domain/repositories/road_route_repository.dart';
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

  sl.registerLazySingleton<AdminRepository>(
      () => AdminRepositoryImpl(sl<ApiClient>()));
  sl.registerLazySingleton<RatingRepository>(
      () => RatingRepositoryImpl(sl<ApiClient>()));
  sl.registerFactoryParam<RatingCubit, String, String>(
      (bookingPublicId, customerPublicId) => RatingCubit(sl<RatingRepository>(),
          sl<SecureStorageService>(), customerPublicId, bookingPublicId));
  sl.registerLazySingleton<ReviewRepository>(
      () => ReviewRepositoryImpl(sl<ApiClient>()));
  sl.registerFactoryParam<DriverReputationCubit, String, void>(
      (driverPublicId, _) => DriverReputationCubit(
          sl<ReviewRepository>(), sl<SecureStorageService>(), driverPublicId));
  sl.registerFactoryParam<AdminQualityCubit, String, void>((adminPublicId, _) =>
      AdminQualityCubit(
          sl<ReviewRepository>(), sl<SecureStorageService>(), adminPublicId));
  sl.registerFactoryParam<AdminCubit, String, void>((adminPublicId, _) =>
      AdminCubit(
          sl<AdminRepository>(), sl<SecureStorageService>(), adminPublicId));

  sl.registerLazySingleton<CustomerRepository>(
      () => CustomerRepositoryImpl(sl<ApiClient>()));
  sl.registerLazySingleton<GeocodingRepository>(
      () => GeocodingRepositoryImpl(sl<ApiClient>()));
  sl.registerLazySingleton<TripHistoryRepository>(
      () => TripHistoryRepositoryImpl(sl<ApiClient>()));
  sl.registerFactoryParam<TripHistoryCubit, String, void>(
      (customerPublicId, _) => TripHistoryCubit(
          sl<TripHistoryRepository>(),
          sl<GeocodingRepository>(),
          sl<SecureStorageService>(),
          customerPublicId));
  sl.registerFactoryParam<TripHistoryDetailCubit, String, String>(
      (bookingPublicId, customerPublicId) => TripHistoryDetailCubit(
          sl<TripHistoryRepository>(),
          sl<TripRepository>(),
          sl<GeocodingRepository>(),
          sl<SecureStorageService>(),
          customerPublicId,
          bookingPublicId));
  sl.registerLazySingleton<BookingIntentStore>(
      () => SecureBookingIntentStore());
  sl.registerLazySingleton<ActiveBookingStore>(
      () => SecureActiveBookingStore());
  sl.registerLazySingleton<RequestQuoteUseCase>(
      () => RequestQuoteUseCase(sl<CustomerRepository>()));
  sl.registerLazySingleton<GetQuoteUseCase>(
      () => GetQuoteUseCase(sl<CustomerRepository>()));
  sl.registerLazySingleton<GetBookingUseCase>(
      () => GetBookingUseCase(sl<CustomerRepository>()));
  sl.registerLazySingleton<CreateBookingUseCase>(() => CreateBookingUseCase(
      sl<CustomerRepository>(), sl<BookingIntentStore>(),
      confirmedStore: sl<ActiveBookingStore>()));
  sl.registerFactory<QuoteCubit>(() => QuoteCubit(sl<RequestQuoteUseCase>()));
  sl.registerFactoryParam<BookingCubit, String, void>((customerPublicId, _) =>
      BookingCubit(sl<CreateBookingUseCase>(), customerPublicId,
          session: sl<SecureStorageService>()));

  sl.registerLazySingleton<DriverRepository>(
      () => DriverRepositoryImpl(sl<ApiClient>()));
  sl.registerLazySingleton<DriverEarningsRepository>(
      () => DriverEarningsRepositoryImpl(sl<ApiClient>()));
  sl.registerFactoryParam<DriverEarningsCubit, String, void>(
      (userPublicId, _) => DriverEarningsCubit(sl<DriverEarningsRepository>(),
          sl<SecureStorageService>(), userPublicId));
  sl.registerLazySingleton<DriverUseCases>(
      () => DriverUseCases(sl<DriverRepository>()));
  sl.registerLazySingleton<DriverLocationSource>(
      () => GeolocatorDriverLocationSource());
  sl.registerLazySingleton<AcceptedBookingStore>(
      () => SecureAcceptedBookingStore());
  sl.registerLazySingleton<TripRepository>(
      () => TripRepositoryImpl(sl<ApiClient>()));
  sl.registerLazySingleton<TripEtaRepository>(
      () => TripEtaRepositoryImpl(sl<ApiClient>()));
  sl.registerLazySingleton<RoadRouteRepository>(
      () => RoadRouteRepositoryImpl(sl<ApiClient>()));
  sl.registerFactoryParam<CustomerActiveBookingCubit, String, void>(
      (customerPublicId, _) => CustomerActiveBookingCubit(
          sl<GetBookingUseCase>(),
          sl<TripRepository>(),
          sl<ActiveBookingStore>(),
          sl<SecureStorageService>(),
          customerPublicId));
  sl.registerLazySingleton<TripRealtimeClient>(() => TripRealtimeClientImpl(
      config: sl<AppConfig>(), session: sl<SecureStorageService>()));
  sl.registerFactory<OnboardingCubit>(
      () => OnboardingCubit(sl<DriverUseCases>(), sl<SecureStorageService>()));
  sl.registerFactoryParam<DriverCubit, String, void>((userPublicId, _) =>
      DriverCubit(
          useCases: sl<DriverUseCases>(),
          location: sl<DriverLocationSource>(),
          session: sl<SecureStorageService>(),
          acceptedStore: sl<AcceptedBookingStore>(),
          tripRepository: sl<TripRepository>(),
          userPublicId: userPublicId,
          isMock: config.isMock));
}
