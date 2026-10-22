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
  String bookingPublicId = bookingId,
  double? latitude,
  double? longitude,
  double? accuracy,
  double? bearing,
  DateTime? locationUpdatedAt,
}) =>
    TrackingSnapshot(
      bookingPublicId: bookingPublicId,
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
      accuracy: accuracy,
      bearing: bearing,
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

class _MapLifecycleSpy extends StatefulWidget {
  final VoidCallback onMount;
  final VoidCallback onDispose;

  const _MapLifecycleSpy({required this.onMount, required this.onDispose});

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
  Widget build(BuildContext context) => const Text('Bản đồ thử nghiệm');
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

  void registerScreenServices() {
    sl.registerSingleton<GetBookingUseCase>(GetBookingUseCase(CustomerStub()));
    sl.registerSingleton<TripRepository>(trips);
    sl.registerSingleton<SecureStorageService>(session);
    sl.registerSingleton<TripRealtimeClient>(realtime);
    addTearDown(() async => sl.reset());
  }

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

  test('Only valid active REST GPS can become a customer map location', () {
    final stamp = DateTime.utc(2026, 10, 16, 10, 11);
    final valid = CustomerLiveLocation.fromTracking(tracking('IN_PROGRESS',
        latitude: 21.1,
        longitude: 105.1,
        accuracy: 4,
        bearing: 90,
        locationUpdatedAt: stamp));
    expect(valid?.latitude, 21.1);
    expect(valid?.longitude, 105.1);
    expect(valid?.accuracy, 4);
    expect(valid?.bearing, 90);
    expect(valid?.updatedAt, stamp);

    expect(
        CustomerLiveLocation.fromTracking(tracking('IN_PROGRESS',
            latitude: double.nan, longitude: 105.1, locationUpdatedAt: stamp)),
        isNull);
    expect(
        CustomerLiveLocation.fromTracking(tracking('IN_PROGRESS',
            latitude: 91, longitude: 105.1, locationUpdatedAt: stamp)),
        isNull);
    expect(
        CustomerLiveLocation.fromTracking(tracking('IN_PROGRESS',
            latitude: 21.1, longitude: 181, locationUpdatedAt: stamp)),
        isNull);
    expect(
        CustomerLiveLocation.fromTracking(tracking('IN_PROGRESS',
            latitude: 21.1,
            longitude: 105.1,
            locationUpdatedAt: DateTime.utc(1969))),
        isNull);
    expect(
        CustomerLiveLocation.fromTracking(tracking('COMPLETED',
            latitude: 21.1, longitude: 105.1, locationUpdatedAt: stamp)),
        isNull);
    final sanitized = CustomerLiveLocation.fromTracking(tracking('IN_PROGRESS',
        latitude: 21.1,
        longitude: 105.1,
        accuracy: -1,
        bearing: double.infinity,
        locationUpdatedAt: stamp));
    expect(sanitized, isNotNull);
    expect(sanitized?.accuracy, isNull);
    expect(sanitized?.bearing, isNull);
  });

  test('Invalid REST fix is not exposed, then a valid refresh becomes visible',
      () async {
    final stamp = DateTime.utc(2026, 10, 16, 10, 11);
    trips.value = tracking('IN_PROGRESS',
        latitude: 95, longitude: 105.1, locationUpdatedAt: stamp);
    final cubit = BookingStatusCubit(
        GetBookingUseCase(CustomerStub()), booking(),
        tripRepository: trips, session: session, realtime: realtime);
    cubit.start();
    await flush();
    expect(cubit.state.status, 'IN_PROGRESS');
    expect(cubit.state.hasLiveLocation, isFalse);
    trips.value = tracking('IN_PROGRESS',
        latitude: 21.2, longitude: 105.2, locationUpdatedAt: stamp);
    await cubit.refresh();
    expect(cubit.state.hasLiveLocation, isTrue);
    expect(cubit.state.liveLocation?.latitude, 21.2);
    expect(cubit.state.liveLocation?.longitude, 105.2);
    await cubit.close();
  });

  test('Wrong-booking, older and equal STOMP GPS cannot replace a newer fix',
      () async {
    final stamp = DateTime.utc(2026, 10, 16, 10, 11);
    trips.value = tracking('IN_PROGRESS',
        latitude: 21.1, longitude: 105.1, locationUpdatedAt: stamp);
    final cubit = BookingStatusCubit(
        GetBookingUseCase(CustomerStub()), booking(),
        tripRepository: trips, session: session, realtime: realtime);
    cubit.start();
    await flush();
    final subscription = realtime.last!;
    subscription.eventController.add(TripDriverLocationEvent(otherBookingId, 22,
        106, null, null, stamp.add(const Duration(seconds: 10))));
    subscription.eventController.add(TripDriverLocationEvent(bookingId, 22, 106,
        null, null, stamp.subtract(const Duration(seconds: 1))));
    subscription.eventController
        .add(TripDriverLocationEvent(bookingId, 22, 106, null, null, stamp));
    await flush();
    expect(cubit.state.liveLocation?.latitude, 21.1);
    expect(cubit.state.liveLocation?.updatedAt, stamp);
    subscription.eventController.add(TripDriverLocationEvent(bookingId,
        double.nan, 106, null, null, stamp.add(const Duration(seconds: 2))));
    await flush();
    expect(cubit.state.liveLocation?.latitude, 21.1);
    final newer = stamp.add(const Duration(seconds: 3));
    subscription.eventController
        .add(TripDriverLocationEvent(bookingId, 21.3, 105.3, 3, 180, newer));
    await flush();
    expect(cubit.state.liveLocation?.latitude, 21.3);
    expect(cubit.state.liveLocation?.longitude, 105.3);
    expect(cubit.state.liveLocation?.updatedAt, newer);
    await cubit.close();
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

  test('An in-flight stale REST fix cannot revive GPS after completion',
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
    trips.heldTracking = Completer<TrackingSnapshot>();
    final inFlight = cubit.refresh();
    await flush();
    expect(trips.trackingCalls, 2);
    final subscription = realtime.last!;
    subscription.eventController.add(TripStatusChangedEvent(
        bookingId, 'COMPLETED', DateTime.utc(2026, 10, 16, 10, 20)));
    await flush();
    expect(cubit.state.status, 'COMPLETED');
    expect(cubit.state.hasLiveLocation, isFalse);
    expect(cubit.state.liveLocation, isNull);
    trips.heldTracking!.complete(tracking('IN_PROGRESS',
        latitude: 22,
        longitude: 106,
        locationUpdatedAt: firstFix.add(const Duration(minutes: 1))));
    await inFlight;
    await flush();
    expect(cubit.state.status, 'COMPLETED');
    expect(cubit.state.hasLiveLocation, isFalse);
    expect(cubit.state.liveLocation, isNull);
    expect(subscription.disposed, isTrue);
    await cubit.close();
  });

  test('A later stale REST status cannot undo a completed durable status',
      () async {
    trips.value = tracking('COMPLETED',
        latitude: 21,
        longitude: 105,
        locationUpdatedAt: DateTime.utc(2026, 10, 16, 10, 21));
    final cubit = BookingStatusCubit(
        GetBookingUseCase(CustomerStub()), booking(),
        tripRepository: trips, session: session, realtime: realtime);
    cubit.start();
    await flush();
    expect(cubit.state.status, 'COMPLETED');
    expect(cubit.state.liveLocation, isNull);
    expect(realtime.listens, 0);
    trips.value = tracking('IN_PROGRESS',
        latitude: 22,
        longitude: 106,
        locationUpdatedAt: DateTime.utc(2026, 10, 16, 10, 22));
    await cubit.refresh();
    expect(cubit.state.status, 'COMPLETED');
    expect(cubit.state.liveLocation, isNull);
    expect(realtime.listens, 0);
    await cubit.close();
  });

  test('Realtime loss keeps authorized REST GPS and reconnect reconciles',
      () async {
    final firstFix = DateTime.utc(2026, 10, 16, 10, 11);
    trips.value = tracking('IN_PROGRESS',
        latitude: 21.1, longitude: 105.1, locationUpdatedAt: firstFix);
    final cubit = BookingStatusCubit(
        GetBookingUseCase(CustomerStub()), booking(),
        tripRepository: trips, session: session, realtime: realtime);
    cubit.start();
    await flush();
    final subscription = realtime.last!;
    subscription.stateController.add(TripRealtimeConnectionState.reconnecting);
    await flush();
    expect(cubit.state.realtimeState, TripRealtimeConnectionState.reconnecting);
    subscription.stateController.add(TripRealtimeConnectionState.disconnected);
    await flush();
    expect(cubit.state.realtimeState, TripRealtimeConnectionState.disconnected);
    expect(cubit.state.hasLiveLocation, isTrue);
    trips.value = tracking('IN_PROGRESS',
        latitude: 21.2,
        longitude: 105.2,
        locationUpdatedAt: firstFix.add(const Duration(seconds: 5)));
    await cubit.refresh();
    expect(cubit.state.liveLocation?.latitude, 21.2);
    await realtime.reconcile!();
    subscription.stateController.add(TripRealtimeConnectionState.connected);
    await flush();
    expect(cubit.state.realtimeState, TripRealtimeConnectionState.connected);
    expect(cubit.state.liveLocation?.latitude, 21.2);
    expect(realtime.listens, 1);
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

  test('Session replacement clears an already visible driver fix', () async {
    var current = true;
    when(() => session.isCurrentSession(any()))
        .thenAnswer((_) async => current);
    trips.value = tracking('IN_PROGRESS',
        latitude: 21.1,
        longitude: 105.1,
        locationUpdatedAt: DateTime.utc(2026, 10, 16, 10, 11));
    final cubit = BookingStatusCubit(
        GetBookingUseCase(CustomerStub()), booking(),
        tripRepository: trips, session: session, realtime: realtime);
    cubit.start();
    await flush();
    expect(cubit.state.hasLiveLocation, isTrue);
    final subscription = realtime.last!;
    current = false;
    subscription.eventController.add(TripDriverLocationEvent(
        bookingId, 22, 106, null, null, DateTime.utc(2026, 10, 16, 10, 12)));
    await flush();
    expect(cubit.state.sessionEnded, isTrue);
    expect(cubit.state.tracking, isNull);
    expect(cubit.state.liveLocation, isNull);
    expect(subscription.disposed, isTrue);
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

  test('Equal or older REST GPS cannot replace the current STOMP fix',
      () async {
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

    trips.value = tracking('IN_PROGRESS',
        latitude: 21.3, longitude: 105.3, locationUpdatedAt: stamp);
    await cubit.refresh();
    expect(cubit.state.liveLocation?.latitude, 21.2);
    expect(cubit.state.liveLocation?.longitude, 105.2);
    expect(cubit.state.liveLocation?.updatedAt, stamp);

    trips.value = tracking('IN_PROGRESS',
        latitude: 21.4,
        longitude: 105.4,
        locationUpdatedAt: stamp.subtract(const Duration(seconds: 1)));
    await cubit.refresh();
    expect(cubit.state.liveLocation?.latitude, 21.2);
    expect(cubit.state.liveLocation?.longitude, 105.2);

    final newer = stamp.add(const Duration(seconds: 1));
    trips.value = tracking('IN_PROGRESS',
        latitude: 21.5, longitude: 105.5, locationUpdatedAt: newer);
    await cubit.refresh();
    expect(cubit.state.liveLocation?.latitude, 21.5);
    expect(cubit.state.liveLocation?.longitude, 105.5);
    expect(cubit.state.liveLocation?.updatedAt, newer);
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
    registerScreenServices();
    final seenLocations = <CustomerLiveLocation>[];
    await tester.pumpWidget(MaterialApp(
        home: BookingStatusScreen(
            booking: booking(),
            trackingMapBuilder: (context, location, connection) {
              seenLocations.add(location);
              return const Text('Bản đồ thử nghiệm');
            })));
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
    expect(find.text('Bản đồ thử nghiệm'), findsOneWidget);
    expect(seenLocations.last.latitude, 21.1);
    expect(seenLocations.last.longitude, 105.1);
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

  testWidgets('No authorized GPS shows placeholder without creating a map',
      (tester) async {
    trips.value = tracking('DRIVER_ACCEPTED');
    registerScreenServices();
    var mapBuilds = 0;
    await tester.pumpWidget(MaterialApp(
        home: BookingStatusScreen(
            booking: booking(),
            trackingMapBuilder: (_, __, ___) {
              mapBuilds++;
              return const Text('Bản đồ thử nghiệm');
            })));
    await tester.pump();
    await tester.pump();
    await tester.scrollUntilVisible(
        find.text('Chưa có vị trí GPS được phép hiển thị.'), 250,
        scrollable: find.byType(Scrollable).first);
    expect(mapBuilds, 0);
    expect(find.text('Bản đồ thử nghiệm'), findsNothing);
    await tester.scrollUntilVisible(find.text('Chưa thanh toán (PENDING)'), 250,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Chưa thanh toán (PENDING)'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Map setup fallback still leaves REST GPS text and CASH visible',
      (tester) async {
    trips.value = tracking('IN_PROGRESS',
        latitude: 21.1,
        longitude: 105.1,
        accuracy: 4,
        locationUpdatedAt: DateTime.utc(2026, 10, 16, 10, 11));
    registerScreenServices();
    await tester.pumpWidget(MaterialApp(
        home: BookingStatusScreen(
            booking: booking(),
            trackingMapBuilder: (_, __, ___) =>
                const Text('Không tải được bản đồ thử nghiệm'))));
    await tester.pump();
    await tester.pump();
    await tester.scrollUntilVisible(
        find.text('Không tải được bản đồ thử nghiệm'), 250,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Không tải được bản đồ thử nghiệm'), findsOneWidget);
    expect(find.text('Vĩ độ: 21.1'), findsOneWidget);
    expect(find.text('Kinh độ: 105.1'), findsOneWidget);
    expect(find.text('Độ chính xác: 4.0 m'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Chưa thanh toán (PENDING)'), 250,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Chưa thanh toán (PENDING)'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Completed trip removes mounted map but keeps CASH pending',
      (tester) async {
    trips.value = tracking('IN_PROGRESS',
        latitude: 21.1,
        longitude: 105.1,
        locationUpdatedAt: DateTime.utc(2026, 10, 16, 10, 11));
    registerScreenServices();
    var mounts = 0;
    var disposals = 0;
    await tester.pumpWidget(MaterialApp(
        home: BookingStatusScreen(
            booking: booking(),
            trackingMapBuilder: (_, __, ___) => _MapLifecycleSpy(
                onMount: () => mounts++, onDispose: () => disposals++))));
    await tester.pump();
    await tester.pump();
    await tester.scrollUntilVisible(find.text('Bản đồ thử nghiệm'), 250,
        scrollable: find.byType(Scrollable).first);
    expect(mounts - disposals, 1);
    final subscription = realtime.last!;
    trips.value = tracking('COMPLETED');
    subscription.eventController.add(TripStatusChangedEvent(
        bookingId, 'COMPLETED', DateTime.utc(2026, 10, 16, 10, 20)));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(disposals, mounts);
    expect(find.text('Bản đồ thử nghiệm'), findsNothing);
    await tester.scrollUntilVisible(
        find.text('Chuyến đã hoàn thành; vị trí hiện tại của tài xế được ẩn.'),
        250,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Vĩ độ: 21.1'), findsNothing);
    await tester.scrollUntilVisible(find.text('Chưa thanh toán (PENDING)'), 250,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Chưa thanh toán (PENDING)'), findsOneWidget);
    expect(subscription.disposed, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Leaving and re-entering screen disposes each map/subscription',
      (tester) async {
    trips.value = tracking('IN_PROGRESS',
        latitude: 21.1,
        longitude: 105.1,
        locationUpdatedAt: DateTime.utc(2026, 10, 16, 10, 11));
    registerScreenServices();
    var mounts = 0;
    var disposals = 0;
    Widget screen() => MaterialApp(
        home: BookingStatusScreen(
            booking: booking(),
            trackingMapBuilder: (_, __, ___) => _MapLifecycleSpy(
                onMount: () => mounts++, onDispose: () => disposals++)));
    await tester.pumpWidget(screen());
    await tester.pump();
    await tester.pump();
    await tester.scrollUntilVisible(find.text('Bản đồ thử nghiệm'), 250,
        scrollable: find.byType(Scrollable).first);
    expect(mounts - disposals, 1);
    final firstEntryMounts = mounts;
    final firstSubscription = realtime.last!;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(disposals, mounts);
    expect(firstSubscription.disposed, isTrue);

    await tester.pumpWidget(screen());
    await tester.pump();
    await tester.pump();
    await tester.scrollUntilVisible(find.text('Bản đồ thử nghiệm'), 250,
        scrollable: find.byType(Scrollable).first);
    expect(mounts, greaterThan(firstEntryMounts));
    expect(mounts - disposals, 1);
    expect(realtime.listens, 2);
    final secondSubscription = realtime.last!;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(disposals, mounts);
    expect(secondSubscription.disposed, isTrue);
  });
}
