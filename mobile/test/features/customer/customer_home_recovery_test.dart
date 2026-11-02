import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gomove_mobile/core/config/app_config.dart';
import 'package:gomove_mobile/core/di/injection.dart';
import 'package:gomove_mobile/core/error/exceptions.dart';
import 'package:gomove_mobile/core/storage/secure_storage_service.dart';
import 'package:gomove_mobile/core/theme/app_motion.dart';
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
import 'package:gomove_mobile/features/customer/domain/models/place_search_result.dart';
import 'package:gomove_mobile/features/customer/domain/repositories/customer_repository.dart';
import 'package:gomove_mobile/features/customer/domain/repositories/geocoding_repository.dart';
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

PlaceSearchResult place(String label, Coordinates point) => PlaceSearchResult(
    label: label,
    name: label,
    coordinates: point,
    attribution: '© OpenStreetMap contributors · Photon');

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
  Completer<Booking>? pending;
  final requested = <String>[];
  final quoteRequests = <QuoteRequest>[];
  int createCalls = 0;
  Object? quoteError;
  Completer<Quote>? pendingQuote;

  @override
  Future<Booking> getBooking(String publicId, {int? sessionGeneration}) async {
    requested.add(publicId);
    if (error != null) throw error!;
    if (pending != null) return pending!.future;
    return value;
  }

  @override
  Future<Booking> createBooking(String quotePublicId, String idempotencyKey,
      {int? sessionGeneration}) {
    createCalls++;
    throw UnimplementedError();
  }

  @override
  Future<Quote> getQuote(String publicId) => throw UnimplementedError();
  @override
  Future<Quote> requestQuote(QuoteRequest request) async {
    quoteRequests.add(request);
    if (quoteError != null) throw quoteError!;
    if (pendingQuote != null) return pendingQuote!.future;
    throw UnimplementedError();
  }
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
  @override
  Future<TripTransition> cancelCustomer(String id, int generation) =>
      throw UnimplementedError();
  @override
  Future<TripTransition> cancelDriver(String id, int generation) =>
      throw UnimplementedError();
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

class _GeocodingRepository implements GeocodingRepository {
  final searches = <String>[];
  final reverses = <Coordinates>[];
  Future<List<PlaceSearchResult>> Function(String)? searchHandler;
  Future<PlaceSearchResult?> Function(Coordinates)? reverseHandler;

  @override
  Future<List<PlaceSearchResult>> search(String query,
      {int? sessionGeneration}) {
    searches.add(query);
    return searchHandler?.call(query) ?? Future.value(const []);
  }

  @override
  Future<PlaceSearchResult?> reverse(Coordinates point,
      {int? sessionGeneration}) {
    reverses.add(point);
    return reverseHandler?.call(point) ?? Future.value(null);
  }
}

class _MapLifecycleSpy extends StatefulWidget {
  final VoidCallback onMount;
  final VoidCallback onDispose;
  final Widget child;

  const _MapLifecycleSpy(
      {required this.onMount, required this.onDispose, required this.child});

  @override
  State<_MapLifecycleSpy> createState() => _MapLifecycleSpyState();
}

class _MapLifecycleSpyState extends State<_MapLifecycleSpy> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

void main() {
  late _CustomerRepository repository;
  late _ActiveStore activeStore;
  late _TripRepository tripRepository;
  late _Session session;
  late _GeocodingRepository geocoding;
  late AuthBloc auth;
  late Coordinates mapTap;
  late bool mapUnavailable;
  Coordinates? lastMapPickup;
  Coordinates? lastMapDropoff;
  var mapMounts = 0;
  var mapDisposals = 0;

  Widget fakeMapBuilder(BuildContext context, Coordinates? pickup,
      Coordinates? dropoff, ValueChanged<Coordinates> onTap) {
    lastMapPickup = pickup;
    lastMapDropoff = dropoff;
    if (mapUnavailable) {
      return const Text('Bản đồ giả không tải được');
    }
    return _MapLifecycleSpy(
      onMount: () => mapMounts++,
      onDispose: () => mapDisposals++,
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          // Match the uncovered top strip when the booking sheet is expanded.
          padding: const EdgeInsets.only(top: 8),
          child: TextButton(
              onPressed: () => onTap(mapTap),
              child: const Text('Chọn trên bản đồ giả')),
        ),
      ),
    );
  }

  setUp(() async {
    await sl.reset();
    AppConfig.reset();
    AppConfig.initialize(forceMock: false);
    repository = _CustomerRepository();
    mapTap = const Coordinates(21.031, 105.841);
    mapUnavailable = false;
    lastMapPickup = null;
    lastMapDropoff = null;
    mapMounts = 0;
    mapDisposals = 0;
    activeStore = _ActiveStore();
    tripRepository = _TripRepository();
    session = _Session();
    geocoding = _GeocodingRepository();
    sl.registerSingleton<GeocodingRepository>(geocoding);
    sl.registerSingleton<SecureStorageService>(session);
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

  Future<void> showHome(WidgetTester tester,
      {bool reducedMotion = false}) async {
    await tester.pumpWidget(BlocProvider<AuthBloc>.value(
        value: auth,
        child: MaterialApp(
            builder: (context, child) => reducedMotion
                ? MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(disableAnimations: true),
                    child: child!,
                  )
                : child!,
            home:
                CustomerHomeScreen(user: userA, mapBuilder: fakeMapBuilder))));
    await tester.pumpAndSettle();
  }

  Future<void> selectOnFakeMap(
      WidgetTester tester, String mode, Coordinates point) async {
    mapTap = point;
    // The map button is below the choice chips. A previous selection may leave
    // the lazy ListView scrolled past them, so begin each selection at the top.
    tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .jumpTo(0);
    await tester.pump();
    await tester.scrollUntilVisible(find.text(mode), 250,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text(mode));
    await tester.pump();
    await tester.tap(find.text('Chọn trên bản đồ giả'));
    await tester.pumpAndSettle();
  }

  Future<void> enterCoordinate(
      WidgetTester tester, String label, String value) async {
    final field = find.widgetWithText(TextFormField, label);
    await tester.scrollUntilVisible(field, 250,
        scrollable: find.byType(Scrollable).first);
    await tester.enterText(field, value);
    await tester.pump();
  }

  Future<void> requestQuote(WidgetTester tester) async {
    final action = find.text('Lấy báo giá từ máy chủ');
    await tester.scrollUntilVisible(action, 250,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(action);
    await tester.pumpAndSettle();
  }

  testWidgets('Map pickup selection changes pickup but not destination',
      (tester) async {
    repository.quoteError =
        const ServerException(message: 'routing unavailable', statusCode: 503);
    await showHome(tester);
    await selectOnFakeMap(
        tester, 'Chọn điểm đón', const Coordinates(21.031, 105.841));
    await requestQuote(tester);

    expect(repository.quoteRequests, hasLength(1));
    expect(repository.quoteRequests.single.toJson(), {
      'pickupLatitude': 21.031,
      'pickupLongitude': 105.841,
      'dropoffLatitude': 21.0245,
      'dropoffLongitude': 105.8576,
      'vehicleType': 'MOTORBIKE',
    });
    expect(repository.createCalls, 0);
  });

  testWidgets('Booking sheet drags and scrolls without remounting map',
      (tester) async {
    await showHome(tester);
    final sheetFinder = find.byKey(const ValueKey('customer-booking-sheet'));
    final scrollFinder =
        find.byKey(const ValueKey('customer-booking-sheet-scroll'));
    final sheet = tester.widget<DraggableScrollableSheet>(sheetFinder);
    final scroll = tester.widget<ListView>(scrollFinder);
    expect(sheet.snap, isTrue);
    expect(sheet.minChildSize, .46);
    expect(scroll.controller, isNotNull);
    expect(mapMounts - mapDisposals, 1);
    final collapsedHeight = tester.getSize(sheetFinder).height;

    await tester.dragFrom(
        tester.getCenter(
            find.byKey(const ValueKey('customer-booking-sheet-handle'))),
        const Offset(0, -350));
    await tester.pumpAndSettle();
    expect(tester.getSize(sheetFinder).height, greaterThan(collapsedHeight));
    expect(mapMounts - mapDisposals, 1);

    await tester.scrollUntilVisible(find.text('Điểm đến · kinh độ'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Điểm đến · kinh độ'), findsOneWidget);
    expect(find.text('Lấy báo giá từ máy chủ'), findsOneWidget);
    expect(mapMounts - mapDisposals, 1);
    expect(repository.quoteRequests, isEmpty);
    expect(repository.createCalls, 0);
  });

  testWidgets('Selection motion follows point choice without a Quote request',
      (tester) async {
    await showHome(tester);
    await tester.scrollUntilVisible(find.text('Chọn điểm đón'), 250,
        scrollable: find.byType(Scrollable).first);
    expect(
        tester
            .widget<AnimatedScale>(
                find.byKey(const ValueKey('pickup-selection-motion')))
            .scale,
        1);
    expect(
        tester
            .widget<AnimatedScale>(
                find.byKey(const ValueKey('dropoff-selection-motion')))
            .duration,
        AppMotion.touch);

    await selectOnFakeMap(
        tester, 'Chọn điểm đến', const Coordinates(21.05, 105.88));
    tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .jumpTo(0);
    await tester.pump();
    await tester.scrollUntilVisible(find.text('Chọn điểm đến'), 250,
        scrollable: find.byType(Scrollable).first);
    final selected = tester.widget<AnimatedScale>(
        find.byKey(const ValueKey('dropoff-selection-motion')));
    expect(selected.scale, 1);
    expect(selected.duration, AppMotion.touch);
    expect(lastMapDropoff?.latitude, 21.05);
    expect(lastMapDropoff?.longitude, 105.88);
    expect(repository.quoteRequests, isEmpty);
    expect(repository.createCalls, 0);
  });

  testWidgets('Reduced motion keeps map point selection immediate',
      (tester) async {
    await showHome(tester, reducedMotion: true);
    await tester.scrollUntilVisible(find.text('Chọn điểm đón'), 250,
        scrollable: find.byType(Scrollable).first);
    expect(
        tester
            .widget<AnimatedScale>(
                find.byKey(const ValueKey('pickup-selection-motion')))
            .duration,
        Duration.zero);
    await selectOnFakeMap(
        tester, 'Chọn điểm đến', const Coordinates(21.05, 105.88));
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('_MapTarget.dropoff-point-summary-motion')),
        250,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(find.text('Vĩ độ 21.050000 · Kinh độ 105.880000'), findsOneWidget);
    expect(
        tester
            .widget<AnimatedContainer>(find.byKey(
                const ValueKey('_MapTarget.dropoff-point-summary-motion')))
            .duration,
        Duration.zero);
    expect(repository.quoteRequests, isEmpty);
  });

  testWidgets('Map destination selection changes destination but not pickup',
      (tester) async {
    repository.quoteError =
        const ServerException(message: 'routing unavailable', statusCode: 503);
    await showHome(tester);
    await selectOnFakeMap(
        tester, 'Chọn điểm đến', const Coordinates(21.05, 105.88));
    await requestQuote(tester);

    expect(repository.quoteRequests.single.toJson(), {
      'pickupLatitude': 21.0287,
      'pickupLongitude': 105.8524,
      'dropoffLatitude': 21.05,
      'dropoffLongitude': 105.88,
      'vehicleType': 'MOTORBIKE',
    });
    expect(repository.createCalls, 0);
  });

  testWidgets('Map points preserve latitude-longitude order and vehicle type',
      (tester) async {
    repository.quoteError =
        const ServerException(message: 'routing unavailable', statusCode: 503);
    await showHome(tester);
    await selectOnFakeMap(
        tester, 'Chọn điểm đón', const Coordinates(21.1234, 105.5678));
    await selectOnFakeMap(
        tester, 'Chọn điểm đến', const Coordinates(21.9876, 105.4321));
    final vehicle = find.byKey(const ValueKey('customer-vehicle-CAR_4_SEAT'));
    await tester.scrollUntilVisible(vehicle, 250,
        scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(vehicle);
    await tester.pumpAndSettle();
    await tester.tap(vehicle);
    await tester.pumpAndSettle();
    await requestQuote(tester);

    expect(repository.quoteRequests.single.toJson(), {
      'pickupLatitude': 21.1234,
      'pickupLongitude': 105.5678,
      'dropoffLatitude': 21.9876,
      'dropoffLongitude': 105.4321,
      'vehicleType': 'CAR_4_SEAT',
    });
  });

  testWidgets(
      'Location summaries label coordinates without inventing addresses',
      (tester) async {
    await showHome(tester);
    await tester.scrollUntilVisible(find.text('Đang chọn: Điểm đón'), 250,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Đang chọn: Điểm đón'), findsOneWidget);
    await selectOnFakeMap(
        tester, 'Chọn điểm đến', const Coordinates(21.05, 105.88));
    tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .jumpTo(0);
    await tester.pump();
    await tester.scrollUntilVisible(find.text('Đang chọn: Điểm đến'), 250,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Đang chọn: Điểm đến'), findsOneWidget);
    await tester.scrollUntilVisible(
        find.text('Vĩ độ 21.050000 · Kinh độ 105.880000'), 60,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Vĩ độ 21.050000 · Kinh độ 105.880000'), findsOneWidget);
    expect(find.text('Vĩ độ 21.028700 · Kinh độ 105.852400'), findsOneWidget);
    expect(repository.quoteRequests, isEmpty);
    expect(repository.createCalls, 0);
  });

  testWidgets('Narrow Customer Home keeps manual fallback and Quote reachable',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    mapUnavailable = true;
    repository.quoteError =
        const ServerException(message: 'routing unavailable', statusCode: 503);
    await showHome(tester);
    await enterCoordinate(tester, 'Điểm đón · vĩ độ', '21.03');
    await enterCoordinate(tester, 'Điểm đến · kinh độ', '105.86');
    await requestQuote(tester);
    expect(tester.takeException(), isNull);
    expect(repository.quoteRequests, hasLength(1));
    expect(repository.createCalls, 0);
  });

  testWidgets('Unavailable map leaves manual coordinate fallback usable',
      (tester) async {
    mapUnavailable = true;
    repository.quoteError =
        const ServerException(message: 'routing unavailable', statusCode: 503);
    await showHome(tester);
    expect(find.text('Bản đồ giả không tải được'), findsOneWidget);
    await enterCoordinate(tester, 'Điểm đón · vĩ độ', '21.03');
    await enterCoordinate(tester, 'Điểm đón · kinh độ', '105.84');
    await enterCoordinate(tester, 'Điểm đến · vĩ độ', '21.04');
    await enterCoordinate(tester, 'Điểm đến · kinh độ', '105.86');
    await requestQuote(tester);

    expect(repository.quoteRequests.single.toJson(), {
      'pickupLatitude': 21.03,
      'pickupLongitude': 105.84,
      'dropoffLatitude': 21.04,
      'dropoffLongitude': 105.86,
      'vehicleType': 'MOTORBIKE',
    });
    expect(repository.createCalls, 0);
  });

  testWidgets('Invalid manual coordinates never request a Quote or Booking',
      (tester) async {
    mapUnavailable = true;
    await showHome(tester);
    await enterCoordinate(tester, 'Điểm đón · vĩ độ', '91');
    await requestQuote(tester);
    expect(repository.quoteRequests, isEmpty);
    expect(repository.createCalls, 0);
  });

  testWidgets('Identical pickup and destination never request a Quote',
      (tester) async {
    await showHome(tester);
    await enterCoordinate(tester, 'Điểm đón · vĩ độ', '21.0245');
    await enterCoordinate(tester, 'Điểm đón · kinh độ', '105.8576');
    await requestQuote(tester);
    expect(find.text('Tọa độ không hợp lệ hoặc hai điểm trùng nhau.'),
        findsOneWidget);
    expect(repository.quoteRequests, isEmpty);
    expect(repository.createCalls, 0);
  });

  testWidgets('Rapid repeated Quote taps submit only one request',
      (tester) async {
    repository.pendingQuote = Completer<Quote>();
    await showHome(tester);
    await tester.scrollUntilVisible(find.text('Lấy báo giá từ máy chủ'), 250,
        scrollable: find.byType(Scrollable).first);
    final action = tester.widget<FilledButton>(find.ancestor(
        of: find.text('Lấy báo giá từ máy chủ'),
        matching: find.byType(FilledButton)));
    action.onPressed!();
    action.onPressed!();
    await tester.pump();
    expect(repository.quoteRequests, hasLength(1));
    expect(repository.createCalls, 0);
    repository.pendingQuote!.completeError(
        const ServerException(message: 'routing unavailable', statusCode: 503));
    await tester.pumpAndSettle();
    expect(repository.quoteRequests, hasLength(1));
  });

  testWidgets('Map selection does not carry across Customer accounts',
      (tester) async {
    await showHome(tester);
    await selectOnFakeMap(
        tester, 'Chọn điểm đón', const Coordinates(21.031, 105.841));
    expect(lastMapPickup?.latitude, 21.031);
    expect(lastMapPickup?.longitude, 105.841);

    final bReady = auth.stream.firstWhere((state) =>
        state is AuthenticatedState && state.user.publicId == customerB);
    auth.add(const AuthLoginSubmitted(identifier: 'B', password: 'password'));
    await tester.runAsync(() => bReady.timeout(const Duration(seconds: 2)));
    await tester.pump();
    await tester.pumpWidget(BlocProvider<AuthBloc>.value(
        value: auth,
        child: MaterialApp(
            home:
                CustomerHomeScreen(user: userB, mapBuilder: fakeMapBuilder))));
    await tester.pumpAndSettle();
    expect(find.text('Chọn trên bản đồ giả'), findsOneWidget);

    expect(lastMapPickup?.latitude, 21.0287);
    expect(lastMapPickup?.longitude, 105.8524);
    expect(lastMapDropoff?.latitude, 21.0245);
    expect(lastMapDropoff?.longitude, 105.8576);
  });

  testWidgets('Recovery control is visible with no saved Booking',
      (tester) async {
    await showHome(tester);
    final recovery = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Tìm lại chuyến bằng mã'));
    expect(recovery.onPressed, isNotNull);
    expect(repository.requested, isEmpty);
  });

  testWidgets('Recovery control stays visible while verification is loading',
      (tester) async {
    activeStore.records[customerA] = const ActiveBookingRecord(
        customerPublicId: customerA, bookingPublicId: bookingId);
    repository.pending = Completer<Booking>();
    await tester.pumpWidget(BlocProvider<AuthBloc>.value(
        value: auth,
        child: MaterialApp(
            home:
                CustomerHomeScreen(user: userA, mapBuilder: fakeMapBuilder))));
    await tester.pump();
    final recovery = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Tìm lại chuyến bằng mã'));
    expect(recovery.onPressed, isNull);
    repository.pending!.complete(booking('DRIVER_ARRIVED'));
    await tester.pumpAndSettle();
    expect(find.text('Tiếp tục chuyến đang diễn ra'), findsOneWidget);
  });

  testWidgets('Recovery control stays visible when the session has ended',
      (tester) async {
    when(() => session.getSession())
        .thenAnswer((_) async => const AuthSessionSnapshot(7, null, 'refresh'));
    await showHome(tester);
    final recovery = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Tìm lại chuyến bằng mã'));
    expect(recovery.onPressed, isNull);
    expect(find.textContaining('Phiên đăng nhập đã thay đổi'), findsWidgets);
  });

  testWidgets('Backend recovery failure keeps manual control discoverable',
      (tester) async {
    activeStore.records[customerA] = const ActiveBookingRecord(
        customerPublicId: customerA, bookingPublicId: bookingId);
    repository.error =
        const ServerException(message: 'route unavailable', statusCode: 503);
    await showHome(tester);
    final recovery = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Tìm lại chuyến bằng mã'));
    expect(recovery.onPressed, isNotNull);
    expect(find.text('Tiếp tục chuyến đang diễn ra'), findsNothing);
    expect(find.textContaining('Máy chủ đang bận'), findsOneWidget);
  });

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
    final entrance = find.ancestor(
        of: find.text('Tiếp tục chuyến đang diễn ra'),
        matching: find.byType(TweenAnimationBuilder<double>));
    expect(entrance, findsOneWidget);
    expect(tester.widget<TweenAnimationBuilder<double>>(entrance).duration,
        AppMotion.card);
    expect(repository.requested, [bookingId]);
  });

  testWidgets('Reduced motion shows verified Booking without spatial entrance',
      (tester) async {
    activeStore.records[customerA] = const ActiveBookingRecord(
        customerPublicId: customerA, bookingPublicId: bookingId);
    await showHome(tester, reducedMotion: true);
    expect(find.text('Tiếp tục chuyến đang diễn ra'), findsOneWidget);
    expect(
        find.ancestor(
            of: find.text('Tiếp tục chuyến đang diễn ra'),
            matching: find.byType(TweenAnimationBuilder<double>)),
        findsNothing);
    expect(repository.requested, [bookingId]);
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
    await tester.tap(find.text('Tìm lại chuyến bằng mã').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).last, 'not-a-uuid');
    await tester.tap(find.text('Tìm chuyến'));
    await tester.pumpAndSettle();
    expect(find.text('Mã tham chiếu chưa đúng định dạng'), findsOneWidget);
    expect(repository.requested, isEmpty);

    await tester.enterText(find.byType(TextFormField).last, bookingId);
    await tester.tap(find.text('Tìm chuyến'));
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
    await tester.tap(find.text('Tìm lại chuyến bằng mã').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).last, bookingId);
    await tester.tap(find.text('Tìm chuyến'));
    await tester.pumpAndSettle();
    expect(activeStore.records, isEmpty);
    expect(find.text('Tiếp tục chuyến đang diễn ra'), findsNothing);
    expect(find.textContaining('không được phép xem Booking'), findsOneWidget);
    expect(find.text('Tìm lại chuyến bằng mã'), findsOneWidget);
  });

  testWidgets('COMPLETED plus PAID is a final card, not an active trip',
      (tester) async {
    activeStore.records[customerA] = const ActiveBookingRecord(
        customerPublicId: customerA, bookingPublicId: bookingId);
    repository.value = booking('COMPLETED');
    tripRepository.paymentStatus = 'PAID';
    await showHome(tester);
    expect(find.text('Tiếp tục chuyến đang diễn ra'), findsNothing);
    expect(find.text('Chuyến đã hoàn thành · Đã thanh toán'), findsOneWidget);
  });

  testWidgets('COMPLETED plus CASH PENDING keeps a resume entry',
      (tester) async {
    activeStore.records[customerA] = const ActiveBookingRecord(
        customerPublicId: customerA, bookingPublicId: bookingId);
    repository.value = booking('COMPLETED');
    await showHome(tester);
    expect(find.text('Tiếp tục chuyến đang diễn ra'), findsOneWidget);
    expect(find.text('Thanh toán tiền mặt đang chờ xác nhận.'), findsOneWidget);
    expect(find.text('Chuyến đã hoàn thành · Đã thanh toán'), findsNothing);
  });

  testWidgets('Account replacement hides A Booking immediately',
      (tester) async {
    activeStore.records[customerA] = const ActiveBookingRecord(
        customerPublicId: customerA, bookingPublicId: bookingId);
    await showHome(tester);
    expect(find.text('Tiếp tục chuyến đang diễn ra'), findsOneWidget);
    final bReady = auth.stream.firstWhere((state) =>
        state is AuthenticatedState && state.user.publicId == customerB);
    auth.add(const AuthLoginSubmitted(identifier: 'B', password: 'password'));
    await tester.runAsync(() => bReady.timeout(const Duration(seconds: 2)));
    await tester.pump();
    expect(auth.state, isA<AuthenticatedState>());
    expect((auth.state as AuthenticatedState).user.publicId, customerB);
    expect(find.text('Tiếp tục chuyến đang diễn ra'), findsNothing);
    expect(find.textContaining('Customer A'), findsNothing);
  });

  testWidgets('Search debounces, selects real pickup, and keeps destination',
      (tester) async {
    geocoding.searchHandler = (_) async => [
          place('Hồ Hoàn Kiếm', const Coordinates(21.0287, 105.8524)),
        ];
    await showHome(tester);
    final pickupSearch = find.byKey(const ValueKey('pickup-place-search'));
    await tester.scrollUntilVisible(pickupSearch, 250,
        scrollable: find.byType(Scrollable).first);
    await tester.enterText(pickupSearch, 'Hồ Hoàn Kiếm');
    await tester.pump(const Duration(milliseconds: 350));
    expect(geocoding.searches, isEmpty);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    expect(geocoding.searches, ['Hồ Hoàn Kiếm']);
    await tester.scrollUntilVisible(find.text('Hồ Hoàn Kiếm').last, 100,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Hồ Hoàn Kiếm').last);
    await tester.pumpAndSettle();
    expect(lastMapPickup?.latitude, 21.0287);
    expect(lastMapPickup?.longitude, 105.8524);
    expect(lastMapDropoff?.latitude, 21.0245);
    expect(lastMapDropoff?.longitude, 105.8576);
    expect(mapMounts - mapDisposals, 1);
    expect(find.text('© OpenStreetMap contributors · Photon'), findsOneWidget);
  });

  testWidgets('Pickup and destination searches stay independent',
      (tester) async {
    geocoding.searchHandler = (query) async => [
          query.contains('Hoàn')
              ? place('Hồ Hoàn Kiếm', const Coordinates(21.0287, 105.8524))
              : place('Bến xe Mỹ Đình', const Coordinates(21.028, 105.778)),
        ];
    await showHome(tester);
    for (final entry in [
      (const ValueKey('pickup-place-search'), 'Hồ Hoàn Kiếm'),
      (const ValueKey('dropoff-place-search'), 'Bến xe Mỹ Đình'),
    ]) {
      final field = find.byKey(entry.$1);
      await tester.scrollUntilVisible(field, 250,
          scrollable: find.byType(Scrollable).first);
      await tester.enterText(field, entry.$2);
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pump();
      await tester.scrollUntilVisible(find.text(entry.$2).last, 100,
          scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text(entry.$2).last);
      await tester.pump();
    }
    expect(lastMapPickup?.longitude, 105.8524);
    expect(lastMapDropoff?.longitude, 105.778);
    expect(repository.quoteRequests, isEmpty);
  });

  testWidgets('Late search for old query cannot replace newer results',
      (tester) async {
    final old = Completer<List<PlaceSearchResult>>();
    geocoding.searchHandler = (query) => query == 'Địa điểm cũ'
        ? old.future
        : Future.value(
            [place('Địa điểm mới', const Coordinates(21.03, 105.85))]);
    await showHome(tester);
    final field = find.byKey(const ValueKey('pickup-place-search'));
    await tester.scrollUntilVisible(field, 250,
        scrollable: find.byType(Scrollable).first);
    await tester.enterText(field, 'Địa điểm cũ');
    await tester.pump(const Duration(milliseconds: 450));
    await tester.enterText(field, 'Địa điểm mới');
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pump();
    old.complete([place('Kết quả cũ', const Coordinates(20, 105))]);
    await tester.pumpAndSettle();
    expect(find.text('Kết quả cũ'), findsNothing);
    expect(find.text('Địa điểm mới'), findsWidgets);
    expect(geocoding.searches, ['Địa điểm cũ', 'Địa điểm mới']);
  });

  testWidgets(
      'Map reverse label is bound to exact point and manual edit clears it',
      (tester) async {
    geocoding.reverseHandler = (point) async => place('Phố Tràng Tiền', point);
    await showHome(tester);
    await selectOnFakeMap(tester, 'Chọn điểm đón',
        const Coordinates(21.031234567, 105.841234567));
    expect(geocoding.reverses.single.latitude, 21.031234567);
    expect(lastMapPickup?.latitude, 21.031234567);
    await tester.scrollUntilVisible(find.text('Phố Tràng Tiền'), 100,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Phố Tràng Tiền'), findsOneWidget);
    await enterCoordinate(tester, 'Điểm đón · vĩ độ', '21.04');
    expect(find.text('Phố Tràng Tiền'), findsNothing);
    expect(lastMapPickup?.latitude, 21.04);
  });

  testWidgets('Unavailable reverse keeps selected marker and fallback message',
      (tester) async {
    geocoding.reverseHandler = (_) async =>
        throw const ServerException(message: 'busy', statusCode: 429);
    await showHome(tester);
    await selectOnFakeMap(
        tester, 'Chọn điểm đến', const Coordinates(21.05, 105.88));
    expect(lastMapDropoff?.latitude, 21.05);
    expect(find.textContaining('Không thể xác minh địa chỉ'), findsOneWidget);
  });

  testWidgets('Account replacement ignores a late place-search response',
      (tester) async {
    final pending = Completer<List<PlaceSearchResult>>();
    geocoding.searchHandler = (_) => pending.future;
    await showHome(tester);
    final field = find.byKey(const ValueKey('pickup-place-search'));
    await tester.scrollUntilVisible(field, 250,
        scrollable: find.byType(Scrollable).first);
    await tester.enterText(field, 'Địa chỉ riêng A');
    await tester.pump(const Duration(milliseconds: 450));
    final bReady = auth.stream.firstWhere((state) =>
        state is AuthenticatedState && state.user.publicId == customerB);
    auth.add(const AuthLoginSubmitted(identifier: 'B', password: 'password'));
    await tester.runAsync(() => bReady.timeout(const Duration(seconds: 2)));
    await tester.pumpWidget(BlocProvider<AuthBloc>.value(
        value: auth,
        child: MaterialApp(
            home:
                CustomerHomeScreen(user: userB, mapBuilder: fakeMapBuilder))));
    pending.complete([place('Địa chỉ riêng A', const Coordinates(21, 105))]);
    await tester.pumpAndSettle();
    expect(find.text('Địa chỉ riêng A'), findsNothing);
    expect(lastMapPickup?.latitude, 21.0287);
  });

  testWidgets('Background cancels search and resume keeps Quote fallback',
      (tester) async {
    await showHome(tester);
    final field = find.byKey(const ValueKey('pickup-place-search'));
    await tester.scrollUntilVisible(field, 250,
        scrollable: find.byType(Scrollable).first);
    await tester.enterText(field, 'Đại học Quốc gia Hà Nội');
    await tester.pump(const Duration(milliseconds: 150));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump(const Duration(milliseconds: 500));
    expect(geocoding.searches, isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    repository.quoteError =
        const ServerException(message: 'routing unavailable', statusCode: 503);
    await requestQuote(tester);
    expect(repository.quoteRequests, hasLength(1));
  });

  testWidgets('Late reverse cannot relabel manually changed coordinates',
      (tester) async {
    final pending = Completer<PlaceSearchResult?>();
    geocoding.reverseHandler = (_) => pending.future;
    await showHome(tester);
    await selectOnFakeMap(
        tester, 'Chọn điểm đón', const Coordinates(21.031, 105.841));
    await enterCoordinate(tester, 'Điểm đón · vĩ độ', '21.04');
    pending.complete(place('Phố cũ', const Coordinates(21.031, 105.841)));
    await tester.pumpAndSettle();
    expect(find.text('Phố cũ'), findsNothing);
    expect(lastMapPickup?.latitude, 21.04);
  });

  testWidgets('Small screen and keyboard keep both searches usable',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await showHome(tester);
    final field = find.byKey(const ValueKey('dropoff-place-search'));
    await tester.scrollUntilVisible(field, 250,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(field);
    await tester.enterText(field, 'Bến xe Mỹ Đình');
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(geocoding.searches, ['Bến xe Mỹ Đình']);
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('pickup-place-search')), -250,
        scrollable: find.byType(Scrollable).first);
    expect(find.byKey(const ValueKey('pickup-place-search')), findsOneWidget);
  });

  testWidgets('Empty search and rate limit keep manual fallback available',
      (tester) async {
    geocoding.searchHandler = (_) async => const [];
    await showHome(tester);
    final field = find.byKey(const ValueKey('pickup-place-search'));
    await tester.scrollUntilVisible(field, 250,
        scrollable: find.byType(Scrollable).first);
    await tester.enterText(field, 'Địa điểm không có');
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pump();
    expect(find.text('Không tìm thấy địa điểm phù hợp.'), findsWidgets);

    geocoding.searchHandler = (_) async =>
        throw const ServerException(message: 'rate limit', statusCode: 429);
    await tester.enterText(field, 'Địa điểm khác');
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pump();
    expect(find.textContaining('đang giới hạn yêu cầu'), findsWidgets);
    await enterCoordinate(tester, 'Điểm đón · vĩ độ', '21.03');
    expect(lastMapPickup?.latitude, 21.03);
  });

  testWidgets('Duplicate names select the tapped result coordinates',
      (tester) async {
    geocoding.searchHandler = (_) async => const [
          PlaceSearchResult(
              label: 'Quán cà phê, Quận A',
              name: 'Quán cà phê',
              coordinates: Coordinates(21.01, 105.81)),
          PlaceSearchResult(
              label: 'Quán cà phê, Quận B',
              name: 'Quán cà phê',
              coordinates: Coordinates(21.02, 105.82)),
        ];
    await showHome(tester);
    final field = find.byKey(const ValueKey('dropoff-place-search'));
    await tester.scrollUntilVisible(field, 250,
        scrollable: find.byType(Scrollable).first);
    await tester.enterText(field, 'Quán cà phê');
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pump();
    final secondResult = find.textContaining('Quán cà phê, Quận B');
    await tester.scrollUntilVisible(secondResult, 100,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(secondResult);
    await tester.pump();
    expect(lastMapDropoff?.latitude, 21.02);
    expect(lastMapDropoff?.longitude, 105.82);
    expect(lastMapPickup?.latitude, 21.0287);
  });

  testWidgets('Map tap and manual edit clear old place text and suggestions',
      (tester) async {
    geocoding.searchHandler = (_) async => [
          place('Hồ Hoàn Kiếm', const Coordinates(21.0287, 105.8524)),
        ];
    await showHome(tester);
    final pickupSearch = find.byKey(const ValueKey('pickup-place-search'));
    await tester.scrollUntilVisible(pickupSearch, 250,
        scrollable: find.byType(Scrollable).first);
    await tester.enterText(pickupSearch, 'Hồ Hoàn Kiếm');
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pump();
    await tester.tap(find.text('Hồ Hoàn Kiếm').last);
    await tester.pump();
    await tester.scrollUntilVisible(pickupSearch, -250,
        scrollable: find.byType(Scrollable).first);
    expect(tester.widget<TextField>(pickupSearch).controller!.text,
        'Hồ Hoàn Kiếm');

    await selectOnFakeMap(
        tester, 'Chọn điểm đón', const Coordinates(21.031, 105.841));
    await tester.scrollUntilVisible(pickupSearch, -250,
        scrollable: find.byType(Scrollable).first);
    expect(tester.widget<TextField>(pickupSearch).controller!.text, isEmpty);
    expect(find.text('Hồ Hoàn Kiếm'), findsNothing);
    expect(lastMapPickup?.latitude, 21.031);

    await tester.scrollUntilVisible(pickupSearch, -250,
        scrollable: find.byType(Scrollable).first);
    await tester.enterText(pickupSearch, 'Hồ Hoàn Kiếm');
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pump();
    expect(find.text('Hồ Hoàn Kiếm'), findsWidgets);
    await enterCoordinate(tester, 'Điểm đón · kinh độ', '105.84');
    await tester.scrollUntilVisible(pickupSearch, -250,
        scrollable: find.byType(Scrollable).first);
    expect(tester.widget<TextField>(pickupSearch).controller!.text, isEmpty);
    expect(find.text('Hồ Hoàn Kiếm'), findsNothing);
    expect(lastMapPickup?.longitude, 105.84);
  });

  testWidgets(
      'Search result waiting on session check cannot return in background',
      (tester) async {
    geocoding.searchHandler = (_) async => [
          place('Địa chỉ cũ', const Coordinates(21.03, 105.85)),
        ];
    await showHome(tester);
    final check = Completer<bool>();
    when(() => session.isCurrentSession(7)).thenAnswer((_) => check.future);
    final field = find.byKey(const ValueKey('pickup-place-search'));
    await tester.scrollUntilVisible(field, 250,
        scrollable: find.byType(Scrollable).first);
    await tester.enterText(field, 'Địa chỉ cũ');
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pump();
    expect(geocoding.searches, ['Địa chỉ cũ']);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    check.complete(true);
    await tester.pump();
    expect(
        find.ancestor(
            of: find.text('Địa chỉ cũ'), matching: find.byType(ListTile)),
        findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(
        find.ancestor(
            of: find.text('Địa chỉ cũ'), matching: find.byType(ListTile)),
        findsNothing);
  });

  testWidgets(
      'Reverse result waiting on session check cannot relabel after resume',
      (tester) async {
    geocoding.reverseHandler = (point) async => place('Phố cũ', point);
    await showHome(tester);
    final check = Completer<bool>();
    when(() => session.isCurrentSession(7)).thenAnswer((_) => check.future);
    await selectOnFakeMap(
        tester, 'Chọn điểm đón', const Coordinates(21.031, 105.841));
    expect(geocoding.reverses, hasLength(1));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    check.complete(true);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.text('Phố cũ'), findsNothing);
    expect(lastMapPickup?.latitude, 21.031);
  });

  testWidgets('New query invalidates a search waiting on session check',
      (tester) async {
    geocoding.searchHandler = (_) async => [
          place('Kết quả cũ', const Coordinates(21.03, 105.85)),
        ];
    await showHome(tester);
    final check = Completer<bool>();
    when(() => session.isCurrentSession(7)).thenAnswer((_) => check.future);
    final field = find.byKey(const ValueKey('pickup-place-search'));
    await tester.scrollUntilVisible(field, 250,
        scrollable: find.byType(Scrollable).first);
    await tester.enterText(field, 'Địa chỉ cũ');
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pump();
    expect(geocoding.searches, ['Địa chỉ cũ']);
    await tester.enterText(field, 'M');
    check.complete(true);
    await tester.pump();
    expect(find.text('Kết quả cũ'), findsNothing);
    expect(tester.widget<TextField>(field).controller!.text, 'M');
  });

  testWidgets('New map point invalidates reverse waiting on session check',
      (tester) async {
    geocoding.reverseHandler = (point) async =>
        place(point.latitude == 21.031 ? 'Phố cũ' : 'Phố mới', point);
    await showHome(tester);
    final check = Completer<bool>();
    when(() => session.isCurrentSession(7)).thenAnswer((_) => check.future);
    await selectOnFakeMap(
        tester, 'Chọn điểm đón', const Coordinates(21.031, 105.841));
    await selectOnFakeMap(
        tester, 'Chọn điểm đón', const Coordinates(21.04, 105.84));
    check.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('Phố cũ'), findsNothing);
    await tester.scrollUntilVisible(find.text('Phố mới'), 100,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Phố mới'), findsOneWidget);
    expect(lastMapPickup?.latitude, 21.04);
  });
}
