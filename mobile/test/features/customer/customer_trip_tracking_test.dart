import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gomove_mobile/core/di/injection.dart';
import 'package:gomove_mobile/core/error/exceptions.dart';
import 'package:gomove_mobile/core/storage/secure_storage_service.dart';
import 'package:gomove_mobile/features/customer/domain/models/booking.dart';
import 'package:gomove_mobile/features/customer/domain/models/quote.dart';
import 'package:gomove_mobile/features/customer/domain/repositories/customer_repository.dart';
import 'package:gomove_mobile/features/customer/domain/usecases/customer_usecases.dart';
import 'package:gomove_mobile/features/customer/presentation/bloc/booking_status_cubit.dart';
import 'package:gomove_mobile/features/customer/presentation/screens/booking_status_screen.dart';
import 'package:gomove_mobile/features/trip/data/trip_realtime_client.dart';
import 'package:gomove_mobile/features/trip/domain/models/trip_models.dart';
import 'package:gomove_mobile/features/trip/domain/repositories/trip_repository.dart';
import 'package:mocktail/mocktail.dart';

const bookingId = '550e8400-e29b-41d4-a716-446655440002';
const otherBookingId = '550e8400-e29b-41d4-a716-446655440099';
const driverId = '550e8400-e29b-41d4-a716-446655440003';

Booking booking([String status = 'SEARCHING_DRIVER']) => Booking(
      publicId: bookingId,
      quotePublicId: '550e8400-e29b-41d4-a716-446655440001',
      status: status,
      vehicleType: VehicleType.motorbike,
      currency: 'VND',
      finalFare: '16500',
      createdAt: DateTime.utc(2026, 10, 16),
    );

TrackingSnapshot tracking(
  String status, {
  double? latitude,
  double? longitude,
  DateTime? locationUpdatedAt,
}) =>
    TrackingSnapshot(
      bookingPublicId: bookingId,
      status: status,
      driverPublicId: driverId,
      driverAcceptedAt: DateTime.utc(2026, 10, 16, 10),
      driverArrivedAt: const {
        'DRIVER_ARRIVED',
        'PASSENGER_ONBOARD',
        'IN_PROGRESS',
        'COMPLETED'
      }.contains(status)
          ? DateTime.utc(2026, 10, 16, 10, 5)
          : null,
      passengerOnboardAt: const {
        'PASSENGER_ONBOARD',
        'IN_PROGRESS',
        'COMPLETED'
      }.contains(status)
          ? DateTime.utc(2026, 10, 16, 10, 7)
          : null,
      tripStartedAt: const {'IN_PROGRESS', 'COMPLETED'}.contains(status)
          ? DateTime.utc(2026, 10, 16, 10, 10)
          : null,
      tripCompletedAt:
          status == 'COMPLETED' ? DateTime.utc(2026, 10, 16, 10, 20) : null,
      latitude: latitude,
      longitude: longitude,
      locationUpdatedAt: locationUpdatedAt,
    );

CashPayment payment(String status) => CashPayment(
      paymentPublicId: '550e8400-e29b-41d4-a716-446655440004',
      bookingPublicId: bookingId,
      method: 'CASH',
      status: status,
      amount: '16500.00',
      currency: 'VND',
      paidAt: status == 'PAID' ? DateTime.utc(2026, 10, 16, 10, 21) : null,
    );

TrackingSnapshot initialTracking() => tracking('DRIVER_ACCEPTED');
CashPayment initialPayment() => payment('PENDING');

class CustomerStub implements CustomerRepository {
  @override
  Future<Booking> getBooking(String publicId, {int? sessionGeneration}) async =>
      booking();
  @override
  Future<Booking> createBooking(String quotePublicId, String key,
          {int? sessionGeneration}) =>
      throw UnimplementedError();
  @override
  Future<Quote> getQuote(String publicId) => throw UnimplementedError();
  @override
  Future<Quote> requestQuote(QuoteRequest request) =>
      throw UnimplementedError();
}

class SessionStub extends Mock implements SecureStorageService {}

class TripRepositoryStub implements TripRepository {
  TrackingSnapshot value = initialTracking();
  CashPayment cash = initialPayment();
  Completer<TrackingSnapshot>? heldTracking;
  Object? trackingError;
  Object? paymentError;
  int trackingCalls = 0;
  int paymentCalls = 0;
  int transitionCalls = 0;
  int confirmCalls = 0;
  final generations = <int>[];

  @override
  Future<TrackingSnapshot> tracking(String id, int generation) async {
    trackingCalls++;
    generations.add(generation);
    if (trackingError != null) throw trackingError!;
    if (heldTracking != null) return heldTracking!.future;
    return value;
  }

  @override
  Future<CashPayment> payment(String id, int generation) async {
    paymentCalls++;
    generations.add(generation);
    if (paymentError != null) throw paymentError!;
    return cash;
  }

  @override
  Future<TripTransition> transition(
      String id, TripAction action, int generation) {
    transitionCalls++;
    throw UnimplementedError();
  }

  @override
  Future<CashReceipt> confirmCash(String id, int generation) {
    confirmCalls++;
    throw UnimplementedError();
  }
}

class RealtimeStub implements TripRealtimeClient {
  int listens = 0;
  String? booking;
  int? generation;
  bool? driver;
  RealtimeSubscriptionStub? last;
  Future<void> Function()? reconcile;

  @override
  TripRealtimeSubscription listen(
      {required String bookingPublicId,
      required int sessionGeneration,
      required bool driver,
      required Future<void> Function() reconcileBeforeEvents}) {
    listens++;
    booking = bookingPublicId;
    generation = sessionGeneration;
    this.driver = driver;
    reconcile = reconcileBeforeEvents;
    final created = RealtimeSubscriptionStub();
    addTearDown(created.closeStreams);
    return last = created;
  }
}

class RealtimeSubscriptionStub implements TripRealtimeSubscription {
  // Kept open after dispose only to simulate a late broker frame in a test.
  // ignore: close_sinks
  final eventController =
      StreamController<TripRealtimeEvent>.broadcast(sync: true);
  // ignore: close_sinks
  final stateController =
      StreamController<TripRealtimeConnectionState>.broadcast(sync: true);
  bool disposed = false;

  @override
  Stream<TripRealtimeEvent> get events => eventController.stream;
  @override
  Stream<TripRealtimeConnectionState> get connectionStates =>
      stateController.stream;
  @override
  TripRealtimeConnectionState get state =>
      TripRealtimeConnectionState.connected;
  @override
  Future<bool> sendLocation(_, {required DateTime sampledAt}) =>
      throw UnimplementedError();
  @override
  Future<void> dispose() async {
    disposed = true;
  }

  Future<void> closeStreams() async {
    await eventController.close();
    await stateController.close();
  }
}

Future<void> flush() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late SessionStub session;
  late TripRepositoryStub trips;
  late RealtimeStub realtime;

  setUp(() {
    session = SessionStub();
    trips = TripRepositoryStub();
    realtime = RealtimeStub();
    when(() => session.getSession()).thenAnswer(
        (_) async => const AuthSessionSnapshot(7, 'current-jwt', 'refresh'));
    when(() => session.isCurrentSession(any())).thenAnswer((_) async => true);
  });

  test('All server lifecycle statuses have Vietnamese labels', () {
    expect(customerTripStatusLabel('REQUESTED'), 'Đang tìm tài xế.');
    expect(customerTripStatusLabel('SEARCHING_DRIVER'), 'Đang tìm tài xế.');
    expect(
        customerTripStatusLabel('DRIVER_ACCEPTED'), 'Tài xế đã nhận chuyến.');
    expect(
        customerTripStatusLabel('DRIVER_ARRIVED'), 'Tài xế đã đến điểm đón.');
    expect(customerTripStatusLabel('PASSENGER_ONBOARD'), 'Đã đón khách.');
    expect(customerTripStatusLabel('IN_PROGRESS'), 'Chuyến đi đang diễn ra.');
    expect(customerTripStatusLabel('COMPLETED'), 'Chuyến đi đã hoàn thành.');
  });

  test('REST tracking/payment are durable and STOMP follows correct Booking',
      () async {
    trips.value = tracking('DRIVER_ACCEPTED');
    final cubit = BookingStatusCubit(
        GetBookingUseCase(CustomerStub()), booking(),
        tripRepository: trips, session: session, realtime: realtime);
    cubit.start();
    await flush();
    expect(cubit.state.status, 'DRIVER_ACCEPTED');
    expect(cubit.state.payment?.status, 'PENDING');
    expect(realtime.booking, bookingId);
    expect(realtime.generation, 7);
    expect(realtime.driver, isFalse);

    trips.value = tracking('DRIVER_ARRIVED');
    realtime.last!.eventController.add(TripStatusChangedEvent(
        otherBookingId, 'COMPLETED', DateTime.utc(2026, 10, 16, 10, 30)));
    await flush();
    expect(cubit.state.status, 'DRIVER_ACCEPTED');
    realtime.last!.eventController.add(TripStatusChangedEvent(
        bookingId, 'DRIVER_ARRIVED', DateTime.utc(2026, 10, 16, 10, 5)));
    await flush();
    expect(cubit.state.status, 'DRIVER_ARRIVED');
    expect(cubit.state.tracking?.driverArrivedAt,
        DateTime.utc(2026, 10, 16, 10, 5));
    expect(trips.transitionCalls, 0);
    expect(trips.confirmCalls, 0);
    await cubit.close();
  });

  test(
      'REST refresh repairs missed events and payment remains pending until PAID',
      () async {
    trips.value = tracking('IN_PROGRESS');
    final cubit = BookingStatusCubit(
        GetBookingUseCase(CustomerStub()), booking(),
        tripRepository: trips, session: session, realtime: realtime);
    cubit.start();
    await flush();
    expect(cubit.state.status, 'IN_PROGRESS');
    trips.value = tracking('COMPLETED');
    await cubit.refresh();
    expect(cubit.state.status, 'COMPLETED');
    expect(cubit.state.tracking?.tripCompletedAt,
        DateTime.utc(2026, 10, 16, 10, 20));
    expect(cubit.state.payment?.status, 'PENDING');
    expect(realtime.last!.disposed, isTrue);
    trips.cash = payment('PAID');
    await cubit.refresh();
    expect(cubit.state.payment?.status, 'PAID');
    expect(cubit.state.payment?.paidAt, DateTime.utc(2026, 10, 16, 10, 21));
    expect(trips.confirmCalls, 0);
    await cubit.close();
  });

  test('Completed event masks GPS immediately and late location is ignored',
      () async {
    final firstFix = DateTime.utc(2026, 10, 16, 10, 11);
    trips.value = tracking('IN_PROGRESS',
        latitude: 21.1, longitude: 105.1, locationUpdatedAt: firstFix);
    final cubit = BookingStatusCubit(
        GetBookingUseCase(CustomerStub()), booking(),
        tripRepository: trips, session: session, realtime: realtime);
    cubit.start();
    await flush();
    expect(cubit.state.hasLiveLocation, isTrue);
    final sub = realtime.last!;
    trips.value = tracking('COMPLETED');
    sub.eventController.add(TripStatusChangedEvent(
        bookingId, 'COMPLETED', DateTime.utc(2026, 10, 16, 10, 20)));
    await flush();
    expect(cubit.state.status, 'COMPLETED');
    expect(cubit.state.liveLocation, isNull);
    sub.eventController.add(TripDriverLocationEvent(
        bookingId, 22, 106, null, null, DateTime.utc(2026, 10, 16, 10, 25)));
    await flush();
    expect(cubit.state.hasLiveLocation, isFalse);
    expect(cubit.state.liveLocation, isNull);
    await cubit.close();
  });

  test('Session replacement rejects late REST and realtime results', () async {
    trips.heldTracking = Completer<TrackingSnapshot>();
    var current = true;
    when(() => session.isCurrentSession(any()))
        .thenAnswer((_) async => current);
    final cubit = BookingStatusCubit(
        GetBookingUseCase(CustomerStub()), booking(),
        tripRepository: trips, session: session, realtime: realtime);
    cubit.start();
    await flush();
    expect(trips.trackingCalls, 1);
    current = false;
    trips.heldTracking!.complete(tracking('IN_PROGRESS',
        latitude: 21,
        longitude: 105,
        locationUpdatedAt: DateTime.utc(2026, 10, 16, 10)));
    await flush();
    expect(cubit.state.sessionEnded, isTrue);
    expect(cubit.state.tracking, isNull);
    expect(cubit.state.liveLocation, isNull);
    expect(realtime.listens, 0);
    await cubit.close();
  });

  test('Payment access denial removes old-account tracking and GPS', () async {
    trips.value = tracking('IN_PROGRESS',
        latitude: 21,
        longitude: 105,
        locationUpdatedAt: DateTime.utc(2026, 10, 16, 10));
    trips.paymentError =
        const ServerException(message: 'not visible', statusCode: 403);
    final cubit = BookingStatusCubit(
        GetBookingUseCase(CustomerStub()), booking(),
        tripRepository: trips, session: session, realtime: realtime);
    cubit.start();
    await flush();
    expect(cubit.state.sessionEnded, isTrue);
    expect(cubit.state.tracking, isNull);
    expect(cubit.state.payment, isNull);
    expect(cubit.state.liveLocation, isNull);
    expect(realtime.listens, 0);
    await cubit.close();
  });

  test('Newer authorized STOMP GPS survives an active REST null fix', () async {
    trips.value = tracking('IN_PROGRESS');
    final cubit = BookingStatusCubit(
        GetBookingUseCase(CustomerStub()), booking(),
        tripRepository: trips, session: session, realtime: realtime);
    cubit.start();
    await flush();
    final stamp = DateTime.utc(2026, 10, 16, 10, 12);
    realtime.last!.eventController
        .add(TripDriverLocationEvent(bookingId, 21.2, 105.2, 4, 90, stamp));
    await flush();
    expect(cubit.state.liveLocation?.latitude, 21.2);
    await cubit.refresh();
    expect(cubit.state.status, 'IN_PROGRESS');
    expect(cubit.state.liveLocation?.updatedAt, stamp);
    trips.value = tracking('COMPLETED');
    await cubit.refresh();
    expect(cubit.state.liveLocation, isNull);
    await cubit.close();
  });

  test('Failed REST reconciliation cannot declare realtime connected',
      () async {
    final cubit = BookingStatusCubit(
        GetBookingUseCase(CustomerStub()), booking(),
        tripRepository: trips, session: session, realtime: realtime);
    cubit.start();
    await flush();
    trips.trackingError = const NetworkException();
    await expectLater(realtime.reconcile!(), throwsStateError);
    expect(cubit.state.error, isNotNull);
    await cubit.close();
  });

  testWidgets('Background and dispose cancel bounded polling/subscription',
      (tester) async {
    final cubit = BookingStatusCubit(
        GetBookingUseCase(CustomerStub()), booking(),
        tripRepository: trips,
        session: session,
        realtime: realtime,
        pollInterval: const Duration(seconds: 5));
    cubit.start();
    await tester.pump();
    await tester.pump();
    final sub = realtime.last!;
    final beforePause = trips.trackingCalls;
    cubit.stop();
    await tester.pump(const Duration(seconds: 20));
    expect(trips.trackingCalls, beforePause);
    expect(sub.disposed, isTrue);
    cubit.start();
    await tester.pump();
    await tester.pump();
    expect(realtime.listens, 2);
    await cubit.close();
    final beforeDispose = trips.trackingCalls;
    await tester.pump(const Duration(seconds: 20));
    expect(trips.trackingCalls, beforeDispose);
  });

  testWidgets('Customer screen shows timeline, times, cash, no Driver actions',
      (tester) async {
    trips.value = tracking('IN_PROGRESS',
        latitude: 21.1,
        longitude: 105.1,
        locationUpdatedAt: DateTime.utc(2026, 10, 16, 10, 11));
    sl.registerSingleton<GetBookingUseCase>(GetBookingUseCase(CustomerStub()));
    sl.registerSingleton<TripRepository>(trips);
    sl.registerSingleton<SecureStorageService>(session);
    sl.registerSingleton<TripRealtimeClient>(realtime);
    addTearDown(() async => sl.reset());
    await tester
        .pumpWidget(MaterialApp(home: BookingStatusScreen(booking: booking())));
    await tester.pump();
    await tester.pump();
    expect(find.text('Chuyến đi đang diễn ra.'), findsOneWidget);
    expect(find.text('16.500 VND'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Tài xế đã đến điểm đón'), 250,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Tài xế đã đến điểm đón'), findsOneWidget);
    expect(find.text('Đã đón khách'), findsOneWidget);
    final startedAt = DateTime.utc(2026, 10, 16, 10, 10).toLocal().toString();
    await tester.scrollUntilVisible(find.text(startedAt), 250,
        scrollable: find.byType(Scrollable).first);
    expect(find.text(startedAt), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Vĩ độ: 21.1'), 250,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Vĩ độ: 21.1'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Chưa thanh toán (PENDING)'), 250,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Chưa thanh toán (PENDING)'), findsOneWidget);
    expect(find.text('Xác nhận đã thu tiền mặt'), findsNothing);
    expect(find.text('Hoàn thành chuyến'), findsNothing);
    expect(trips.transitionCalls, 0);
    expect(trips.confirmCalls, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
