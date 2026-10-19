import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gomove_mobile/core/config/app_config.dart';
import 'package:gomove_mobile/core/di/injection.dart';
import 'package:gomove_mobile/core/error/exceptions.dart';
import 'package:gomove_mobile/core/storage/secure_storage_service.dart';
import 'package:gomove_mobile/core/utils/result.dart';
import 'package:gomove_mobile/features/auth/domain/entities/user.dart';
import 'package:gomove_mobile/features/auth/domain/repositories/auth_repository.dart';
import 'package:gomove_mobile/features/auth/domain/usecases/check_auth_status_usecase.dart';
import 'package:gomove_mobile/features/auth/domain/usecases/login_usecase.dart';
import 'package:gomove_mobile/features/auth/domain/usecases/logout_usecase.dart';
import 'package:gomove_mobile/features/auth/domain/usecases/register_usecase.dart';
import 'package:gomove_mobile/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:gomove_mobile/features/auth/presentation/bloc/auth_event.dart';
import 'package:gomove_mobile/features/auth/presentation/bloc/auth_state.dart';
import 'package:gomove_mobile/features/customer/data/active_booking_store.dart';
import 'package:gomove_mobile/features/customer/data/booking_intent_store.dart';
import 'package:gomove_mobile/features/customer/domain/models/booking.dart';
import 'package:gomove_mobile/features/customer/domain/models/booking_intent.dart';
import 'package:gomove_mobile/features/customer/domain/models/quote.dart';
import 'package:gomove_mobile/features/customer/domain/repositories/customer_repository.dart';
import 'package:gomove_mobile/features/customer/domain/usecases/customer_usecases.dart';
import 'package:gomove_mobile/features/customer/presentation/bloc/booking_cubit.dart';
import 'package:gomove_mobile/features/customer/presentation/bloc/customer_active_booking_cubit.dart';
import 'package:gomove_mobile/features/customer/presentation/bloc/quote_cubit.dart';
import 'package:gomove_mobile/features/customer/presentation/screens/customer_home_screen.dart';
import 'package:gomove_mobile/features/trip/domain/models/trip_models.dart';
import 'package:gomove_mobile/features/trip/domain/repositories/trip_repository.dart';
import 'package:mocktail/mocktail.dart';

const customerA = '550e8400-e29b-41d4-a716-446655440001';
const customerB = '550e8400-e29b-41d4-a716-446655440002';
const bookingId = '550e8400-e29b-41d4-a716-446655440099';
const quoteId = '550e8400-e29b-41d4-a716-446655440003';

const userA = User(
    publicId: customerA,
    phoneNumber: '0900000001',
    fullName: 'Customer A',
    role: UserRole.customer);
const userB = User(
    publicId: customerB,
    phoneNumber: '0900000002',
    fullName: 'Customer B',
    role: UserRole.customer);

Booking booking(String status) => Booking(
    publicId: bookingId,
    quotePublicId: quoteId,
    status: status,
    vehicleType: VehicleType.motorbike,
    currency: 'VND',
    finalFare: '16500',
    createdAt: DateTime.utc(2026, 10, 19));

class _AuthRepository implements AuthRepository {
  @override
  Future<Result<User>> checkAuthStatus() async => const Success(userA);
  @override
  Future<Result<User>> login(
          {required String identifier, required String password}) async =>
      const Success(userB);
  @override
  Future<Result<User>> getCurrentUser() async => const Success(userA);
  @override
  Future<Result<bool>> isAuthenticated() async => const Success(true);
  @override
  Future<Result<void>> logout() async => const Success(null);
  @override
  Future<Result<User>> register(
          {required String phone,
          String? email,
          required String password,
          required String fullName}) =>
      throw UnimplementedError();
}

class _CustomerRepository implements CustomerRepository {
  Booking value = booking('DRIVER_ARRIVED');
  Object? error;
  final requested = <String>[];

  @override
  Future<Booking> getBooking(String publicId, {int? sessionGeneration}) async {
    requested.add(publicId);
    if (error != null) throw error!;
    return value;
  }

  @override
  Future<Booking> createBooking(String quotePublicId, String idempotencyKey,
          {int? sessionGeneration}) =>
      throw UnimplementedError();
  @override
  Future<Quote> getQuote(String publicId) => throw UnimplementedError();
  @override
  Future<Quote> requestQuote(QuoteRequest request) =>
      throw UnimplementedError();
}

class _ActiveStore implements ActiveBookingStore {
  final records = <String, ActiveBookingRecord>{};
  @override
  Future<ActiveBookingRecord?> read(String customerPublicId) async =>
      records[customerPublicId];
  @override
  Future<void> write(
      String customerPublicId, ActiveBookingRecord record) async {
    records[customerPublicId] = record;
  }

  @override
  Future<void> clear(String customerPublicId) async {
    records.remove(customerPublicId);
  }
}

class _IntentStore implements BookingIntentStore {
  @override
  Future<BookingIntent?> read(String customerPublicId) async => null;
  @override
  Future<void> write(BookingIntent intent) async {}
  @override
  Future<void> clear(String customerPublicId) async {}
}

class _TripRepository implements TripRepository {
  String paymentStatus = 'PENDING';
  @override
  Future<CashPayment> payment(String bookingPublicId, int generation) async =>
      CashPayment(
          paymentPublicId: '550e8400-e29b-41d4-a716-446655440004',
          bookingPublicId: bookingPublicId,
          method: 'CASH',
          status: paymentStatus,
          amount: '16500.00',
          currency: 'VND');
  @override
  Future<TrackingSnapshot> tracking(String bookingPublicId, int generation) =>
      throw UnimplementedError();
  @override
  Future<TripTransition> transition(
          String bookingPublicId, TripAction action, int generation) =>
      throw UnimplementedError();
  @override
  Future<CashReceipt> confirmCash(String bookingPublicId, int generation) =>
      throw UnimplementedError();
}

class _Session extends Mock implements SecureStorageService {}

void main() {
  late _CustomerRepository repository;
  late _ActiveStore activeStore;
  late _TripRepository tripRepository;
  late _Session session;
  late AuthBloc auth;

  setUp(() async {
    await sl.reset();
    AppConfig.reset();
    AppConfig.initialize(forceMock: false);
    repository = _CustomerRepository();
    activeStore = _ActiveStore();
    tripRepository = _TripRepository();
    session = _Session();
    when(() => session.getSession()).thenAnswer(
        (_) async => const AuthSessionSnapshot(7, 'access', 'refresh'));
    when(() => session.getUserPublicId()).thenAnswer((_) async => customerA);
    when(() => session.isCurrentSession(any())).thenAnswer((_) async => true);

    final getBooking = GetBookingUseCase(repository);
    sl.registerFactory<QuoteCubit>(
        () => QuoteCubit(RequestQuoteUseCase(repository)));
    sl.registerFactoryParam<BookingCubit, String, void>((account, _) =>
        BookingCubit(
            CreateBookingUseCase(repository, _IntentStore()), account));
    sl.registerFactoryParam<CustomerActiveBookingCubit, String, void>(
        (account, _) => CustomerActiveBookingCubit(
            getBooking, tripRepository, activeStore, session, account));

    final authRepository = _AuthRepository();
    auth = AuthBloc(
        loginUseCase: LoginUseCase(authRepository),
        registerUseCase: RegisterUseCase(authRepository),
        logoutUseCase: LogoutUseCase(authRepository),
        checkAuthStatusUseCase: CheckAuthStatusUseCase(authRepository));
    auth.add(const AuthCheckRequested());
    await auth.stream.firstWhere((state) => state is AuthenticatedState);
  });

  tearDown(() async {
    await auth.close();
    await sl.reset();
    AppConfig.reset();
  });

  Future<void> showHome(WidgetTester tester) async {
    await tester.pumpWidget(BlocProvider<AuthBloc>.value(
        value: auth,
        child: const MaterialApp(home: CustomerHomeScreen(user: userA))));
    await tester.pumpAndSettle();
  }

  testWidgets('Saved DRIVER_ARRIVED Booking has a verified resume entry',
      (tester) async {
    activeStore.records[customerA] = const ActiveBookingRecord(
        customerPublicId: customerA, bookingPublicId: bookingId);
    await showHome(tester);
    expect(repository.requested, [bookingId]);
    expect(find.text('Tài xế đã đến điểm đón.'), findsOneWidget);
    final resume = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Tiếp tục chuyến đang diễn ra'));
    expect(resume.onPressed, isNotNull);
  });

  testWidgets('App resume revalidates an account-scoped saved Booking',
      (tester) async {
    await showHome(tester);
    expect(repository.requested, isEmpty);
    activeStore.records[customerA] = const ActiveBookingRecord(
        customerPublicId: customerA, bookingPublicId: bookingId);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(repository.requested, [bookingId]);
    expect(find.text('Tiếp tục chuyến đang diễn ra'), findsOneWidget);
  });

  testWidgets('Manual UUID requires form validity and server authorization',
      (tester) async {
    await showHome(tester);
    expect(find.text('Tiếp tục chuyến đang diễn ra'), findsNothing);
    await tester.tap(find.text('Khôi phục Booking bằng UUID').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).last, 'not-a-uuid');
    await tester.tap(find.text('Kiểm tra Booking'));
    await tester.pumpAndSettle();
    expect(find.text('Nhập đúng UUID của Booking'), findsOneWidget);
    expect(repository.requested, isEmpty);

    await tester.enterText(find.byType(TextFormField).last, bookingId);
    await tester.tap(find.text('Kiểm tra Booking'));
    await tester.pumpAndSettle();
    expect(repository.requested, [bookingId]);
    expect(activeStore.records[customerA]?.bookingPublicId, bookingId);
    expect(find.text('Tiếp tục chuyến đang diễn ra'), findsOneWidget);
  });

  testWidgets('Unauthorized manual UUID never becomes a resume card',
      (tester) async {
    repository.error =
        const ServerException(message: 'forbidden', statusCode: 403);
    await showHome(tester);
    await tester.tap(find.text('Khôi phục Booking bằng UUID').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).last, bookingId);
    await tester.tap(find.text('Kiểm tra Booking'));
    await tester.pumpAndSettle();
    expect(activeStore.records, isEmpty);
    expect(find.text('Tiếp tục chuyến đang diễn ra'), findsNothing);
    expect(find.textContaining('không được phép xem Booking'), findsOneWidget);
    expect(find.text('Khôi phục Booking bằng UUID'), findsOneWidget);
  });

  testWidgets('COMPLETED plus PAID is a final card, not an active trip',
      (tester) async {
    activeStore.records[customerA] = const ActiveBookingRecord(
        customerPublicId: customerA, bookingPublicId: bookingId);
    repository.value = booking('COMPLETED');
    tripRepository.paymentStatus = 'PAID';
    await showHome(tester);
    expect(find.text('Tiếp tục chuyến đang diễn ra'), findsNothing);
    expect(find.text('Chuyến đã hoàn thành · Đã thanh toán (PAID)'),
        findsOneWidget);
  });

  testWidgets('COMPLETED plus CASH PENDING keeps a resume entry',
      (tester) async {
    activeStore.records[customerA] = const ActiveBookingRecord(
        customerPublicId: customerA, bookingPublicId: bookingId);
    repository.value = booking('COMPLETED');
    await showHome(tester);
    expect(find.text('Tiếp tục chuyến đang diễn ra'), findsOneWidget);
    expect(find.text('Thanh toán tiền mặt chưa xác nhận (PENDING).'),
        findsOneWidget);
    expect(
        find.text('Chuyến đã hoàn thành · Đã thanh toán (PAID)'), findsNothing);
  });

  testWidgets('Account replacement hides A Booking immediately',
      (tester) async {
    activeStore.records[customerA] = const ActiveBookingRecord(
        customerPublicId: customerA, bookingPublicId: bookingId);
    await showHome(tester);
    expect(find.textContaining(bookingId), findsOneWidget);
    final bReady = auth.stream.firstWhere((state) =>
        state is AuthenticatedState && state.user.publicId == customerB);
    auth.add(const AuthLoginSubmitted(identifier: 'B', password: 'password'));
    await tester.runAsync(() => bReady.timeout(const Duration(seconds: 2)));
    await tester.pump();
    expect(auth.state, isA<AuthenticatedState>());
    expect((auth.state as AuthenticatedState).user.publicId, customerB);
    expect(find.textContaining(bookingId), findsNothing);
    expect(find.textContaining('Customer A'), findsNothing);
  });
}
