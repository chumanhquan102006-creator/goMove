import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gomove_mobile/core/di/injection.dart';
import 'package:gomove_mobile/core/error/exceptions.dart';
import 'package:gomove_mobile/core/storage/secure_storage_service.dart';
import 'package:gomove_mobile/features/auth/domain/entities/user.dart';
import 'package:gomove_mobile/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:gomove_mobile/features/auth/presentation/bloc/auth_state.dart';
import 'package:gomove_mobile/features/customer/domain/models/booking.dart';
import 'package:gomove_mobile/features/customer/domain/models/place_search_result.dart';
import 'package:gomove_mobile/features/customer/domain/models/quote.dart';
import 'package:gomove_mobile/features/customer/domain/models/trip_history.dart';
import 'package:gomove_mobile/features/customer/domain/repositories/geocoding_repository.dart';
import 'package:gomove_mobile/features/customer/domain/repositories/trip_history_repository.dart';
import 'package:gomove_mobile/features/customer/presentation/bloc/trip_history_cubit.dart';
import 'package:gomove_mobile/features/customer/presentation/bloc/trip_history_detail_cubit.dart';
import 'package:gomove_mobile/features/customer/presentation/screens/trip_history_screen.dart';
import 'package:gomove_mobile/features/customer/presentation/screens/trip_history_detail_screen.dart';
import 'package:gomove_mobile/features/trip/domain/models/trip_models.dart';
import 'package:gomove_mobile/features/trip/domain/repositories/trip_repository.dart';
import 'package:mocktail/mocktail.dart';

const _accountA = '550e8400-e29b-41d4-a716-446655440001';
const _accountB = '550e8400-e29b-41d4-a716-446655440002';
const _bookingA = '550e8400-e29b-41d4-a716-446655440091';
const _bookingB = '550e8400-e29b-41d4-a716-446655440092';
const _pickup = Coordinates(21.0287, 105.8524);
const _dropoff = Coordinates(21.0245, 105.8576);

const _userA = User(
    publicId: _accountA,
    phoneNumber: '0900000001',
    fullName: 'Customer A',
    role: UserRole.customer);
const _userB = User(
    publicId: _accountB,
    phoneNumber: '0900000002',
    fullName: 'Customer B',
    role: UserRole.customer);

HistoryTrip _trip(String id, {String payment = 'PENDING'}) => HistoryTrip(
      bookingPublicId: id,
      createdAt: DateTime.utc(2026, 10, 1, 9),
      tripCompletedAt: DateTime.utc(2026, 10, 1, 9, 30),
      pickup: _pickup,
      dropoff: _dropoff,
      vehicleType: VehicleType.motorbike,
      finalFare: '16500.00',
      currency: 'VND',
      status: 'COMPLETED',
      paymentStatus: payment,
    );

Booking _detail(String id) => Booking(
      publicId: id,
      quotePublicId: '550e8400-e29b-41d4-a716-446655440003',
      status: 'COMPLETED',
      vehicleType: VehicleType.motorbike,
      currency: 'VND',
      finalFare: '16500.00',
      createdAt: DateTime.utc(2026, 10, 1, 9),
      tripCompletedAt: DateTime.utc(2026, 10, 1, 9, 30),
      pickup: _pickup,
      dropoff: _dropoff,
      distanceMeters: '5200.000',
      durationSeconds: '840.000',
    );

CashPayment _payment(String id, String status) => CashPayment(
      paymentPublicId: '550e8400-e29b-41d4-a716-446655440004',
      bookingPublicId: id,
      method: 'CASH',
      status: status,
      amount: '16500.00',
      currency: 'VND',
      paidAt: status == 'PAID' ? DateTime.utc(2026, 10, 1, 9, 35) : null,
    );

class _Session extends Mock implements SecureStorageService {}

class _AuthBloc extends Mock implements AuthBloc {}

class _HistoryRepository implements TripHistoryRepository {
  final pages = <int, HistoryPage>{};
  final pageCalls = <int>[];
  Completer<HistoryPage>? pendingPage;
  Object? pageError;
  Booking detailValue = _detail(_bookingA);
  Completer<Booking>? pendingDetail;
  Object? detailError;

  @override
  Future<HistoryPage> page(int page, int size, int sessionGeneration) async {
    pageCalls.add(page);
    if (pendingPage != null) return pendingPage!.future;
    if (pageError != null) throw pageError!;
    return pages[page] ?? HistoryPage(const [], page, size, 0, false);
  }

  @override
  Future<Booking> detail(String bookingPublicId, int sessionGeneration) async {
    if (pendingDetail != null) return pendingDetail!.future;
    if (detailError != null) throw detailError!;
    return detailValue;
  }
}

class _Geocoding implements GeocodingRepository {
  final calls = <Coordinates>[];
  Completer<PlaceSearchResult?>? pending;
  bool fail = false;
  Object? error;

  @override
  Future<PlaceSearchResult?> reverse(Coordinates point,
      {int? sessionGeneration}) async {
    calls.add(point);
    if (pending != null) return pending!.future;
    if (error != null) throw error!;
    if (fail) throw const NetworkException('offline');
    return PlaceSearchResult(
      label:
          point.latitude == _pickup.latitude ? 'Hồ Hoàn Kiếm' : 'Nhà hát Lớn',
      coordinates: point,
      attribution: '© OpenStreetMap contributors',
    );
  }

  @override
  Future<List<PlaceSearchResult>> search(String query,
          {int? sessionGeneration}) async =>
      const [];
}

class _TripRepository implements TripRepository {
  @override
  Future<TripTransition> cancelCustomer(String id, int generation) =>
      throw UnimplementedError();
  @override
  Future<TripTransition> cancelDriver(String id, int generation) =>
      throw UnimplementedError();
  CashPayment value = _payment(_bookingA, 'PENDING');
  Completer<CashPayment>? pending;
  Object? error;

  @override
  Future<CashPayment> payment(String bookingPublicId, int generation) async {
    if (pending != null) return pending!.future;
    if (error != null) throw error!;
    return value;
  }

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

void main() {
  late _Session session;
  late _HistoryRepository history;
  late _Geocoding geocoding;
  late _TripRepository trips;
  var generation = 7;
  var owner = _accountA;

  setUp(() async {
    await sl.reset();
    generation = 7;
    owner = _accountA;
    session = _Session();
    history = _HistoryRepository();
    geocoding = _Geocoding();
    trips = _TripRepository();
    when(() => session.getSession()).thenAnswer(
        (_) async => AuthSessionSnapshot(generation, 'access', 'refresh'));
    when(() => session.getUserPublicId()).thenAnswer((_) async => owner);
    when(() => session.isCurrentSession(any())).thenAnswer(
        (call) async => call.positionalArguments.first == generation);
  });

  tearDown(() async => sl.reset());

  test('History loads pages, resolves real addresses once and keeps order',
      () async {
    history.pages[0] = HistoryPage([_trip(_bookingB)], 0, 10, 2, true);
    history.pages[1] = HistoryPage([_trip(_bookingA)], 1, 10, 2, false);
    final cubit = TripHistoryCubit(history, geocoding, session, _accountA);
    await cubit.load();
    await pumpEventQueue();
    expect(cubit.state.items.map((item) => item.bookingPublicId), [_bookingB]);
    expect(cubit.state.addresses[TripHistoryCubit.pointKey(_pickup)]?.label,
        'Hồ Hoàn Kiếm');
    await cubit.more();
    await pumpEventQueue();
    expect(cubit.state.items.map((item) => item.bookingPublicId),
        [_bookingB, _bookingA]);
    expect(cubit.state.hasNext, isFalse);
    expect(history.pageCalls, [0, 1]);
    expect(geocoding.calls, hasLength(2));
    await cubit.close();
  });

  test('Empty, error, retry and failed address lookup show safe fallback',
      () async {
    final cubit = TripHistoryCubit(history, geocoding, session, _accountA);
    await cubit.load();
    expect(cubit.state.items, isEmpty);
    history.pageError = const NetworkException('offline');
    await cubit.load();
    expect(cubit.state.error, isNotNull);
    history.pageError = null;
    history.pages[0] = HistoryPage([_trip(_bookingA)], 0, 10, 1, false);
    geocoding.fail = true;
    await cubit.load();
    await pumpEventQueue();
    expect(cubit.state.error, isNull);
    expect(cubit.state.items, hasLength(1));
    expect(cubit.state.addresses, isEmpty);
    expect(geocoding.calls, hasLength(1));
    await cubit.close();
  });

  test('Old page and reverse responses cannot restore another account',
      () async {
    history.pendingPage = Completer<HistoryPage>();
    final cubit = TripHistoryCubit(history, geocoding, session, _accountA);
    final loading = cubit.load();
    await pumpEventQueue();
    owner = _accountB;
    generation = 8;
    history.pendingPage!
        .complete(HistoryPage([_trip(_bookingA)], 0, 10, 1, false));
    await loading;
    expect(cubit.state.sessionEnded, isTrue);
    expect(cubit.state.items, isEmpty);
    await cubit.close();

    owner = _accountA;
    generation = 7;
    history.pendingPage = null;
    history.pages[0] = HistoryPage([_trip(_bookingA)], 0, 10, 1, false);
    geocoding.pending = Completer<PlaceSearchResult?>();
    final next = TripHistoryCubit(history, geocoding, session, _accountA);
    await next.load();
    await pumpEventQueue();
    owner = _accountB;
    generation = 8;
    geocoding.pending!.complete(
        const PlaceSearchResult(label: 'Old address', coordinates: _pickup));
    await pumpEventQueue();
    expect(next.state.sessionEnded, isTrue);
    expect(next.state.addresses, isEmpty);
    expect(next.state.items, isEmpty);
    await next.close();
  });

  test(
      'Detail distinguishes CASH pending and paid receipt; refresh failure clears',
      () async {
    final cubit = TripHistoryDetailCubit(
        history, trips, geocoding, session, _accountA, _bookingA);
    await cubit.load();
    expect(cubit.state.booking?.publicId, _bookingA);
    expect(cubit.state.payment?.status, 'PENDING');
    expect(cubit.state.payment?.paidAt, isNull);
    trips.value = _payment(_bookingA, 'PAID');
    await cubit.load();
    expect(cubit.state.payment?.isPaid, isTrue);
    expect(cubit.state.payment?.paidAt, isNotNull);
    history.detailError = const NetworkException('offline');
    await cubit.load();
    expect(cubit.state.booking, isNull);
    expect(cubit.state.payment, isNull);
    expect(cubit.state.error, isNotNull);
    await cubit.close();
  });

  test('Detail rejects another Booking and late payment after account switch',
      () async {
    history.detailValue = _detail(_bookingB);
    final cubit = TripHistoryDetailCubit(
        history, trips, geocoding, session, _accountA, _bookingA);
    await cubit.load();
    expect(cubit.state.booking, isNull);
    history.detailValue = _detail(_bookingA);
    trips.pending = Completer<CashPayment>();
    final pending = cubit.load();
    await pumpEventQueue();
    owner = _accountB;
    generation = 8;
    trips.pending!.complete(_payment(_bookingA, 'PAID'));
    await pending;
    expect(cubit.state.sessionEnded, isTrue);
    expect(cubit.state.booking, isNull);
    expect(cubit.state.payment, isNull);
    await cubit.close();
  });

  test('Payment authorization failure never exposes stale receipt', () async {
    final cubit = TripHistoryDetailCubit(
        history, trips, geocoding, session, _accountA, _bookingA);
    trips.value = _payment(_bookingA, 'PAID');
    await cubit.load();
    expect(cubit.state.payment?.isPaid, isTrue);
    trips.error = const ServerException(message: 'not found', statusCode: 404);
    await cubit.load();
    expect(cubit.state.sessionEnded, isTrue);
    expect(cubit.state.payment, isNull);
    await cubit.close();
  });

  test('Geocoding access revocation clears historical data', () async {
    history.pages[0] = HistoryPage([_trip(_bookingA)], 0, 10, 1, false);
    geocoding.error =
        const ServerException(message: 'forbidden', statusCode: 403);
    final list = TripHistoryCubit(history, geocoding, session, _accountA);
    await list.load();
    await pumpEventQueue();
    expect(list.state.sessionEnded, isTrue);
    expect(list.state.items, isEmpty);
    await list.close();

    final detail = TripHistoryDetailCubit(
        history, trips, geocoding, session, _accountA, _bookingA);
    await detail.load();
    expect(detail.state.sessionEnded, isTrue);
    expect(detail.state.booking, isNull);
    expect(detail.state.payment, isNull);
    await detail.close();
  });

  testWidgets(
      'Small screen lists trips, opens detail and shows pending not receipt',
      (tester) async {
    history.pages[0] = HistoryPage([_trip(_bookingA)], 0, 10, 1, false);
    TripHistoryCubit? historyCubit;
    TripHistoryDetailCubit? detailCubit;
    sl.registerFactoryParam<TripHistoryCubit, String, void>((account, _) =>
        historyCubit = TripHistoryCubit(history, geocoding, session, account));
    sl.registerFactoryParam<TripHistoryDetailCubit, String, String>(
        (id, account) => detailCubit = TripHistoryDetailCubit(
            history, trips, geocoding, session, account, id));
    final auth = _AuthBloc();
    AuthState authState = const AuthenticatedState(_userA);
    final authChanges = StreamController<AuthState>.broadcast();
    addTearDown(authChanges.close);
    when(() => auth.state).thenAnswer((_) => authState);
    when(() => auth.stream).thenAnswer((_) => authChanges.stream);
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(BlocProvider<AuthBloc>.value(
        value: auth,
        child: const MaterialApp(
            home: TripHistoryScreen(customerPublicId: _accountA))));
    await tester.pumpAndSettle();
    expect(find.text('Lịch sử chuyến đi'), findsOneWidget);
    expect(find.textContaining('Hồ Hoàn Kiếm'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('history-$_bookingA')));
    await tester.pumpAndSettle();
    expect(find.text('Chi tiết chuyến'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Chờ xác nhận thanh toán'), 200,
        scrollable: find
            .descendant(
                of: find.byType(TripHistoryDetailScreen),
                matching: find.byType(Scrollable))
            .first);
    expect(find.text('Chờ xác nhận thanh toán'), findsOneWidget);
    expect(find.text('Biên nhận thanh toán'), findsNothing);
    expect(tester.takeException(), isNull);
    authState = const UnauthenticatedState();
    authChanges.add(authState);
    await tester.pumpAndSettle();
    expect(find.text('Chờ xác nhận thanh toán'), findsNothing);
    expect(find.text('Phiên đăng nhập đã thay đổi.'), findsOneWidget);
    expect(historyCubit?.state.addresses, isEmpty);
    expect(detailCubit?.state.booking, isNull);
    expect(detailCubit?.state.payment, isNull);
    authState = const AuthenticatedState(_userB);
    authChanges.add(authState);
    await tester.pumpAndSettle();
    expect(find.text('Chờ xác nhận thanh toán'), findsNothing);
    expect(detailCubit?.state.payment, isNull);
  });

  testWidgets('Paid trip shows in-app CASH receipt without contact data',
      (tester) async {
    trips.value = _payment(_bookingA, 'PAID');
    sl.registerFactoryParam<TripHistoryDetailCubit, String, String>(
        (id, account) => TripHistoryDetailCubit(
            history, trips, geocoding, session, account, id));
    final auth = _AuthBloc();
    when(() => auth.state).thenReturn(const AuthenticatedState(_userA));
    when(() => auth.stream).thenAnswer((_) => const Stream<AuthState>.empty());
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(BlocProvider<AuthBloc>.value(
        value: auth,
        child: const MaterialApp(
            home: TripHistoryDetailScreen(
                customerPublicId: _accountA, bookingPublicId: _bookingA))));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Biên nhận thanh toán'), 200,
        scrollable: find
            .descendant(
                of: find.byType(TripHistoryDetailScreen),
                matching: find.byType(Scrollable))
            .first);
    expect(find.text('Biên nhận thanh toán'), findsOneWidget);
    expect(find.text('Đã thanh toán'), findsOneWidget);
    expect(find.text('0900000001'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('History loading, empty and retry states are visible',
      (tester) async {
    history.pendingPage = Completer<HistoryPage>();
    TripHistoryCubit? cubit;
    sl.registerFactoryParam<TripHistoryCubit, String, void>((account, _) =>
        cubit = TripHistoryCubit(history, geocoding, session, account));
    final auth = _AuthBloc();
    when(() => auth.state).thenReturn(const AuthenticatedState(_userA));
    when(() => auth.stream).thenAnswer((_) => const Stream<AuthState>.empty());
    await tester.pumpWidget(BlocProvider<AuthBloc>.value(
        value: auth,
        child: const MaterialApp(
            home: TripHistoryScreen(customerPublicId: _accountA))));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    history.pendingPage!.complete(const HistoryPage([], 0, 10, 0, false));
    await tester.pumpAndSettle();
    expect(find.text('Chưa có chuyến hoàn thành.'), findsOneWidget);
    history.pendingPage = null;
    history.pageError = const NetworkException('offline');
    await cubit!.load();
    await tester.pumpAndSettle();
    expect(find.textContaining('Không kết nối được máy chủ'), findsOneWidget);
    history.pageError = null;
    await tester.tap(find.text('Thử lại'));
    await tester.pumpAndSettle();
    expect(find.text('Chưa có chuyến hoàn thành.'), findsOneWidget);
  });
}
