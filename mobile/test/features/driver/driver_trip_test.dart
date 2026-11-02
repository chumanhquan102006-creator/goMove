import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gomove_mobile/core/error/exceptions.dart';
import 'package:gomove_mobile/core/storage/secure_storage_service.dart';
import 'package:gomove_mobile/core/theme/app_motion.dart';
import 'package:gomove_mobile/features/customer/domain/models/place_search_result.dart';
import 'package:gomove_mobile/features/customer/domain/models/quote.dart';
import 'package:gomove_mobile/features/customer/domain/repositories/geocoding_repository.dart';
import 'package:gomove_mobile/features/driver/data/location/driver_location_source.dart';
import 'package:gomove_mobile/features/driver/domain/models/driver_models.dart';
import 'package:gomove_mobile/features/driver/presentation/bloc/driver_trip_cubit.dart';
import 'package:gomove_mobile/features/driver/presentation/screens/driver_trip_map.dart';
import 'package:gomove_mobile/features/driver/presentation/screens/driver_trip_screen.dart';
import 'package:gomove_mobile/features/trip/data/trip_realtime_client.dart';
import 'package:gomove_mobile/features/trip/domain/models/trip_models.dart';
import 'package:gomove_mobile/features/trip/domain/repositories/trip_repository.dart';
import 'package:mocktail/mocktail.dart';

class _Session extends Mock implements SecureStorageService {}

class _Geocoder implements GeocodingRepository {
  int calls = 0;
  Future<PlaceSearchResult?> Function(Coordinates point)? reply;

  @override
  Future<List<PlaceSearchResult>> search(String query,
          {int? sessionGeneration}) async =>
      const [];

  @override
  Future<PlaceSearchResult?> reverse(Coordinates point,
      {int? sessionGeneration}) {
    calls++;
    return reply?.call(point) ??
        Future.value(PlaceSearchResult(
            label:
                point.latitude == 21.0287 ? 'Hồ Hoàn Kiếm' : 'Bến xe Mỹ Đình',
            coordinates: point));
  }
}

class _Repository implements TripRepository {
  @override
  Future<TripTransition> cancelCustomer(String id, int generation) =>
      throw UnimplementedError();
  @override
  Future<TripTransition> cancelDriver(String id, int generation) async {
    cancelCalls++;
    if (cancelError != null) throw cancelError!;
    if (cancelReply != null) return cancelReply!();
    status = 'CANCELLED';
    return TripTransition(id, 'CANCELLED', DateTime.utc(2026, 10, 16, 10));
  }

  String status = 'DRIVER_ACCEPTED';
  String paymentStatus = 'PENDING';
  int transitionCalls = 0;
  int cashCalls = 0;
  int trackingCalls = 0;
  int paymentCalls = 0;
  int cancelCalls = 0;
  Object? transitionError;
  Object? cashError;
  Object? cancelError;
  Future<TrackingSnapshot> Function(String bookingPublicId)? trackingReply;
  Future<CashPayment> Function(String bookingPublicId)? paymentReply;
  Future<TripTransition> Function(TripAction)? transitionReply;
  Future<CashReceipt> Function()? cashReply;
  Future<TripTransition> Function()? cancelReply;

  @override
  Future<TrackingSnapshot> tracking(
      String bookingPublicId, int sessionGeneration) async {
    trackingCalls++;
    if (trackingReply != null) return trackingReply!(bookingPublicId);
    return TrackingSnapshot(
        bookingPublicId: bookingPublicId,
        status: status,
        driverPublicId: 'driver-1',
        driverAcceptedAt: DateTime.utc(2026, 10, 16, 10),
        tripCompletedAt:
            status == 'COMPLETED' ? DateTime.utc(2026, 10, 16, 10, 5) : null);
  }

  @override
  Future<CashPayment> payment(
      String bookingPublicId, int sessionGeneration) async {
    paymentCalls++;
    if (paymentReply != null) return paymentReply!(bookingPublicId);
    return CashPayment(
        paymentPublicId: 'payment-1',
        bookingPublicId: bookingPublicId,
        method: 'CASH',
        status: paymentStatus,
        amount: '16500.00',
        currency: 'VND',
        paidAt:
            paymentStatus == 'PAID' ? DateTime.utc(2026, 10, 16, 10, 6) : null);
  }

  @override
  Future<TripTransition> transition(
      String bookingPublicId, TripAction action, int sessionGeneration) async {
    transitionCalls++;
    if (transitionReply != null) return transitionReply!(action);
    if (transitionError != null) throw transitionError!;
    status = action.toStatus;
    return TripTransition(
        bookingPublicId, status, DateTime.utc(2026, 10, 16, 10, 3));
  }

  @override
  Future<CashReceipt> confirmCash(
      String bookingPublicId, int sessionGeneration) async {
    cashCalls++;
    if (cashReply != null) return cashReply!();
    if (cashError != null) throw cashError!;
    paymentStatus = 'PAID';
    return _receipt(bookingPublicId);
  }
}

CashReceipt _receipt(String id) => CashReceipt(
    paymentPublicId: 'payment-1',
    bookingPublicId: id,
    paymentStatus: 'PAID',
    paymentMethod: 'CASH',
    cashCollectedAmount: '16500.00',
    currency: 'VND',
    commissionRate: '0.20',
    commissionAmount: '3300.00',
    commissionPolicyVersion: 'v1',
    paidAt: DateTime.utc(2026, 10, 16, 10, 6),
    driverReleasedAt: DateTime.utc(2026, 10, 16, 10, 6));

class _Realtime implements TripRealtimeClient {
  _Subscription? latest;
  int listens = 0;
  @override
  TripRealtimeSubscription listen(
      {required String bookingPublicId,
      required int sessionGeneration,
      required bool driver,
      required Future<void> Function() reconcileBeforeEvents}) {
    listens++;
    latest = _Subscription();
    return latest!;
  }
}

class _Subscription implements TripRealtimeSubscription {
  final _events = StreamController<TripRealtimeEvent>.broadcast();
  final _states = StreamController<TripRealtimeConnectionState>.broadcast();
  TripRealtimeConnectionState _state = TripRealtimeConnectionState.connecting;
  bool disposed = false;
  int sends = 0;

  void connect() {
    _state = TripRealtimeConnectionState.connected;
    _states.add(_state);
  }

  void event(TripRealtimeEvent event) => _events.add(event);

  @override
  Stream<TripRealtimeEvent> get events => _events.stream;
  @override
  Stream<TripRealtimeConnectionState> get connectionStates => _states.stream;
  @override
  TripRealtimeConnectionState get state => _state;
  @override
  Future<bool> sendLocation(DriverCoordinates point,
      {required DateTime sampledAt}) async {
    sends++;
    return true;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    _state = TripRealtimeConnectionState.disconnected;
    await _events.close();
    await _states.close();
  }
}

class _Location implements DriverLocationSource {
  int calls = 0;
  @override
  Future<DriverCoordinates> current() async {
    calls++;
    return DriverCoordinates(21.0287, 105.8524,
        accuracy: 5, sampledAt: DateTime.now());
  }

  @override
  Future<void> openSettings(DriverLocationProblem? problem) async {}
}

void main() {
  late _Repository repository;
  late _Session session;
  late _Realtime realtime;
  late _Location location;
  late DriverTripCubit cubit;
  late int generation;
  final released = <CashReceipt>[];

  setUp(() {
    repository = _Repository();
    session = _Session();
    realtime = _Realtime();
    location = _Location();
    generation = 1;
    released.clear();
    when(() => session.getSession()).thenAnswer(
        (_) async => AuthSessionSnapshot(generation, 'access', 'refresh'));
    when(() => session.isCurrentSession(any())).thenAnswer(
        (call) async => call.positionalArguments.first == generation);
    cubit = DriverTripCubit(
        bookingPublicId: 'booking-1',
        repository: repository,
        session: session,
        realtime: realtime,
        location: location,
        onSettled: (receipt) async => released.add(receipt),
        pollInterval: const Duration(hours: 1),
        gpsInterval: const Duration(hours: 1));
  });

  tearDown(() async => cubit.close());

  test('Driver map validates both offer points and creates point markers only',
      () {
    final markers = DriverTripMap.pointMarkers(_offer());
    expect(DriverTripMap.hasValidPoints(_offer()), isTrue);
    expect(markers, hasLength(2));
    expect(markers.first.geometry?.latitude, closeTo(21.0287, 1e-9));
    expect(markers.first.geometry?.longitude, closeTo(105.8524, 1e-9));
    expect(markers.last.geometry?.latitude, closeTo(21.0245, 1e-9));
    expect(markers.last.geometry?.longitude, closeTo(105.8576, 1e-9));
    expect(markers.first.circleColor, '#FFFFFF');
    expect(markers.last.circleColor, '#E87521');
    expect(DriverTripMap.hasValidPoints(_offer(pickupLatitude: double.nan)),
        isFalse);
    expect(
        DriverTripMap.hasValidPoints(_offer(dropoffLongitude: 181)), isFalse);
  });

  test('all four actions are enabled only by server-confirmed state, in order',
      () async {
    await cubit.initialize();
    expect(cubit.state.availableAction, TripAction.arrive);
    for (final action in TripAction.values) {
      await cubit.perform(action);
      expect(repository.status, action.toStatus);
      expect(cubit.state.status, action.toStatus);
      expect(repository.transitionCalls, action.index + 1);
    }
    expect(cubit.state.availableAction, isNull);
    expect(cubit.state.canConfirmCash, isTrue);
    expect(released, isEmpty);
    expect(cubit.state.receipt, isNull);
  });

  test('Driver cancellation is allowed only before passenger pickup', () {
    for (final status in ['DRIVER_ACCEPTED', 'DRIVER_ARRIVED']) {
      expect(
          DriverTripState(
                  tracking: TrackingSnapshot(
                      bookingPublicId: 'booking-1', status: status))
              .canCancel,
          isTrue);
    }
    for (final status in [
      'PASSENGER_ONBOARD',
      'IN_PROGRESS',
      'COMPLETED',
      'CANCELLED'
    ]) {
      expect(
          DriverTripState(
                  tracking: TrackingSnapshot(
                      bookingPublicId: 'booking-1', status: status))
              .canCancel,
          isFalse);
    }
  });

  test('Confirmed Driver cancellation is single-flight and releases UI state',
      () async {
    final cancelled = <String>[];
    final local = DriverTripCubit(
        bookingPublicId: 'booking-1',
        repository: repository,
        session: session,
        realtime: realtime,
        location: location,
        onCancelled: (id) async => cancelled.add(id),
        pollInterval: const Duration(hours: 1),
        gpsInterval: const Duration(hours: 1));
    addTearDown(local.close);
    await local.initialize();
    expect(local.state.canCancel, isTrue);
    final pending = Completer<TripTransition>();
    repository.cancelReply = () => pending.future;
    final first = local.cancel();
    await local.cancel();
    expect(repository.cancelCalls, 1);
    expect(local.state.operationBusy, isTrue);
    repository.status = 'CANCELLED';
    pending.complete(TripTransition(
        'booking-1', 'CANCELLED', DateTime.utc(2026, 10, 16, 10)));
    await first;
    expect(local.state.status, 'CANCELLED');
    expect(local.state.payment, isNull);
    expect(local.state.availableAction, isNull);
    expect(local.state.canConfirmCash, isFalse);
    expect(cancelled, ['booking-1']);
  });

  test('Driver timeout is unresolved until fresh REST confirms cancellation',
      () async {
    repository.cancelError = const NetworkException('timeout');
    await cubit.initialize();
    await cubit.cancel();
    expect(cubit.state.status, 'DRIVER_ACCEPTED');
    expect(cubit.state.unresolved, isTrue);
    expect(cubit.state.canCancel, isFalse);
    repository.status = 'CANCELLED';
    await cubit.refresh();
    expect(cubit.state.status, 'CANCELLED');
    expect(cubit.state.unresolved, isFalse);
  });

  test('Customer cancellation on REST removes Driver contact and GPS channel',
      () async {
    final cancelled = <String>[];
    repository.trackingReply = (_) async => const TrackingSnapshot(
        bookingPublicId: 'booking-1',
        status: 'DRIVER_ACCEPTED',
        driverPublicId: 'driver-1',
        customer: CustomerSummary(displayName: 'Khách B', phone: '0900000002'));
    final local = DriverTripCubit(
        bookingPublicId: 'booking-1',
        repository: repository,
        session: session,
        realtime: realtime,
        location: location,
        onCancelled: (id) async => cancelled.add(id),
        pollInterval: const Duration(hours: 1),
        gpsInterval: const Duration(hours: 1));
    addTearDown(local.close);
    await local.initialize();
    expect(local.state.tracking?.customer?.phone, '0900000002');
    repository.trackingReply = (_) async => TrackingSnapshot(
        bookingPublicId: 'booking-1',
        status: 'CANCELLED',
        driverPublicId: 'driver-1',
        cancelledAt: DateTime.utc(2026, 10, 16, 10));
    await local.refresh();
    expect(local.state.status, 'CANCELLED');
    expect(local.state.tracking?.customer, isNull);
    expect(local.state.payment, isNull);
    expect(realtime.latest?.disposed, isTrue);
    expect(cancelled, ['booking-1']);
  });

  test('CANCELLED event blocks an older REST read until cleanup is verified',
      () async {
    const active = TrackingSnapshot(
        bookingPublicId: 'booking-1',
        status: 'DRIVER_ACCEPTED',
        driverPublicId: 'driver-1',
        latitude: 21.1,
        longitude: 105.1,
        customer: CustomerSummary(displayName: 'Khách A', phone: '0900000002'));
    final cancelled = <String>[];
    repository.trackingReply = (_) async => active;
    final local = DriverTripCubit(
        bookingPublicId: 'booking-1',
        repository: repository,
        session: session,
        realtime: realtime,
        location: location,
        onCancelled: (id) async => cancelled.add(id),
        pollInterval: const Duration(hours: 1),
        gpsInterval: const Duration(hours: 1));
    addTearDown(local.close);
    await local.initialize();
    expect(local.state.tracking?.customer?.phone, '0900000002');
    final subscription = realtime.latest!;
    subscription.connect();
    await Future<void>.delayed(Duration.zero);

    final old = Completer<TrackingSnapshot>();
    repository.trackingReply = (_) => old.future;
    final oldRefresh = local.refresh();
    await Future<void>.delayed(Duration.zero);
    final terminal = local.stream.firstWhere((s) => s.status == 'CANCELLED');
    subscription.event(TripStatusChangedEvent(
        'booking-1', 'CANCELLED', DateTime.utc(2026, 10, 16, 10, 5)));
    await terminal;
    expect(local.state.tracking?.customer, isNull);
    expect(local.state.tracking?.latitude, isNull);
    expect(local.state.payment, isNull);
    expect(local.state.availableAction, isNull);
    expect(local.state.canCancel, isFalse);
    expect(cancelled, isEmpty);

    final failed = local.stream.firstWhere((s) => s.error != null);
    repository.trackingReply = (_) async => throw const NetworkException();
    old.complete(active);
    await oldRefresh;
    await failed;
    expect(local.state.status, 'CANCELLED');
    expect(local.state.tracking?.customer, isNull);
    expect(local.state.tracking?.latitude, isNull);
    expect(local.state.availableAction, isNull);
    expect(cancelled, isEmpty);
    expect(subscription.disposed, isTrue);
    final sends = subscription.sends;
    await local.sendGpsOnce();
    expect(subscription.sends, sends);

    repository.trackingReply = (_) async => TrackingSnapshot(
        bookingPublicId: 'booking-1',
        status: 'CANCELLED',
        driverPublicId: 'driver-1',
        cancelledAt: DateTime.utc(2026, 10, 16, 10, 5));
    await local.refresh(manual: true);
    expect(local.state.status, 'CANCELLED');
    expect(
        local.state.tracking?.cancelledAt, DateTime.utc(2026, 10, 16, 10, 5));
    expect(cancelled, ['booking-1']);
    await local.refresh();
    expect(cancelled, ['booking-1']);
  });

  test('COMPLETED event waits for fresh REST before CASH PENDING or PAID',
      () async {
    const active = TrackingSnapshot(
        bookingPublicId: 'booking-1',
        status: 'IN_PROGRESS',
        driverPublicId: 'driver-1',
        latitude: 21.1,
        longitude: 105.1,
        customer: CustomerSummary(displayName: 'Khách A', phone: '0900000002'));
    var completions = 0;
    repository.trackingReply = (_) async => active;
    final local = DriverTripCubit(
        bookingPublicId: 'booking-1',
        repository: repository,
        session: session,
        realtime: realtime,
        location: location,
        onCompleted: (_) => completions++,
        pollInterval: const Duration(hours: 1),
        gpsInterval: const Duration(hours: 1));
    addTearDown(local.close);
    await local.initialize();
    final subscription = realtime.latest!;
    final old = Completer<TrackingSnapshot>();
    repository.trackingReply = (_) => old.future;
    final oldRefresh = local.refresh();
    await Future<void>.delayed(Duration.zero);
    final terminal = local.stream.firstWhere((s) => s.status == 'COMPLETED');
    subscription.event(TripStatusChangedEvent(
        'booking-1', 'COMPLETED', DateTime.utc(2026, 10, 16, 10, 5)));
    await terminal;
    expect(local.state.tracking?.customer, isNull);
    expect(local.state.tracking?.latitude, isNull);
    expect(local.state.payment, isNull);
    expect(local.state.canConfirmCash, isFalse);
    expect(local.state.availableAction, isNull);

    final failed = local.stream.firstWhere((s) => s.error != null);
    repository.trackingReply = (_) async => throw const NetworkException();
    old.complete(active);
    await oldRefresh;
    await failed;
    expect(local.state.status, 'COMPLETED');
    expect(local.state.tracking?.customer, isNull);
    expect(local.state.payment, isNull);
    expect(local.state.canConfirmCash, isFalse);

    repository.trackingReply = (_) async => TrackingSnapshot(
        bookingPublicId: 'booking-1',
        status: 'COMPLETED',
        driverPublicId: 'driver-1',
        tripCompletedAt: DateTime.utc(2026, 10, 16, 10, 5));
    await local.refresh();
    expect(local.state.payment?.status, 'PENDING');
    expect(local.state.canConfirmCash, isTrue);
    expect(completions, 1);
    repository.paymentStatus = 'PAID';
    await local.refresh();
    expect(local.state.payment?.status, 'PAID');
    expect(local.state.canConfirmCash, isFalse);
    expect(local.state.canRecoverReceipt, isTrue);
  });

  test('A new but stale active REST read cannot undo a terminal event',
      () async {
    const active = TrackingSnapshot(
        bookingPublicId: 'booking-1',
        status: 'DRIVER_ACCEPTED',
        customer: CustomerSummary(displayName: 'Khách A', phone: '0900000002'));
    final cancelled = <String>[];
    repository.trackingReply = (_) async => active;
    final local = DriverTripCubit(
        bookingPublicId: 'booking-1',
        repository: repository,
        session: session,
        realtime: realtime,
        location: location,
        onCancelled: (id) async => cancelled.add(id),
        pollInterval: const Duration(hours: 1),
        gpsInterval: const Duration(hours: 1));
    addTearDown(local.close);
    await local.initialize();
    final terminal = local.stream.firstWhere((s) => s.status == 'CANCELLED');
    realtime.latest!.event(TripStatusChangedEvent(
        'booking-1', 'CANCELLED', DateTime.utc(2026, 10, 16, 10, 5)));
    await terminal;
    await local.refresh(manual: true);
    expect(local.state.status, 'CANCELLED');
    expect(local.state.tracking?.customer, isNull);
    expect(local.state.availableAction, isNull);
    expect(cancelled, isEmpty);

    repository.trackingReply = (_) async => const TrackingSnapshot(
        bookingPublicId: 'booking-1', status: 'CANCELLED');
    await local.refresh();
    expect(cancelled, ['booking-1']);
  });

  test('Confirmed cancellation retries local cleanup after callback failure',
      () async {
    repository.status = 'CANCELLED';
    var attempts = 0;
    final local = DriverTripCubit(
        bookingPublicId: 'booking-1',
        repository: repository,
        session: session,
        realtime: realtime,
        location: location,
        onCancelled: (_) async {
          attempts++;
          if (attempts == 1) throw StateError('temporary local store error');
        },
        pollInterval: const Duration(hours: 1),
        gpsInterval: const Duration(hours: 1));
    addTearDown(local.close);
    await local.initialize();
    expect(attempts, 1);
    expect(local.state.status, 'CANCELLED');
    await local.refresh();
    expect(attempts, 2);
    await local.refresh();
    expect(attempts, 2);
  });

  test('Replaced Driver session ignores late cancellation response', () async {
    await cubit.initialize();
    final pending = Completer<TripTransition>();
    repository.cancelReply = () => pending.future;
    final request = cubit.cancel();
    await Future<void>.delayed(Duration.zero);
    generation++;
    pending.complete(TripTransition(
        'booking-1', 'CANCELLED', DateTime.utc(2026, 10, 16, 10)));
    await request;
    expect(cubit.state.sessionEnded, isTrue);
    expect(cubit.state.tracking, isNull);
    expect(cubit.state.payment, isNull);
  });

  test('duplicate taps produce one in-flight transition', () async {
    await cubit.initialize();
    final pending = Completer<TripTransition>();
    repository.transitionReply = (_) => pending.future;
    final first = cubit.perform(TripAction.arrive);
    await cubit.perform(TripAction.arrive);
    expect(repository.transitionCalls, 1);
    repository.status = 'DRIVER_ARRIVED';
    pending.complete(
        TripTransition('booking-1', 'DRIVER_ARRIVED', DateTime.utc(2026)));
    await first;
    expect(cubit.state.status, 'DRIVER_ARRIVED');
  });

  test('an older poll cannot undo a confirmed trip transition', () async {
    await cubit.initialize();
    final trackingStarted = Completer<void>();
    final oldTracking = Completer<TrackingSnapshot>();
    repository.trackingReply = (id) {
      trackingStarted.complete();
      return oldTracking.future;
    };
    final oldRefresh = cubit.refresh();
    await trackingStarted.future;
    final confirmed = cubit.stream
        .firstWhere((state) => state.transition?.status == 'DRIVER_ARRIVED');
    final action = cubit.perform(TripAction.arrive);
    await confirmed;
    repository.trackingReply = null;
    oldTracking.complete(const TrackingSnapshot(
        bookingPublicId: 'booking-1', status: 'DRIVER_ACCEPTED'));
    await Future.wait([oldRefresh, action]);
    if (cubit.state.status != 'DRIVER_ARRIVED') {
      await cubit.stream
          .firstWhere((state) => state.status == 'DRIVER_ARRIVED')
          .timeout(const Duration(seconds: 1));
    }
    expect(cubit.state.status, 'DRIVER_ARRIVED');
    expect(cubit.state.availableAction, TripAction.onboard);
    expect(repository.transitionCalls, 1);
  });

  test('409 preserves a recoverable server-confirmed state', () async {
    repository.transitionError =
        const ServerException(message: 'backend', statusCode: 409);
    await cubit.initialize();
    await cubit.perform(TripAction.arrive);
    expect(cubit.state.status, 'DRIVER_ACCEPTED');
    expect(cubit.state.sessionEnded, isFalse);
    expect(cubit.state.availableAction, TripAction.arrive);
    expect(cubit.state.error, isNotNull);
  });

  for (final code in [401, 403, 404]) {
    test('$code ends trip access and blocks actions and further polling',
        () async {
      repository.transitionError =
          ServerException(message: 'backend', statusCode: code);
      await cubit.initialize();
      await cubit.perform(TripAction.arrive);
      expect(cubit.state.sessionEnded, isTrue);
      expect(cubit.state.status, isNull);
      expect(cubit.state.availableAction, isNull);
      expect(cubit.state.canConfirmCash, isFalse);
      expect(cubit.state.error, isNotNull);
      final calls = repository.trackingCalls;
      await cubit.refresh();
      await cubit.perform(TripAction.arrive);
      expect(repository.trackingCalls, calls);
      expect(repository.transitionCalls, 1);
    });
  }

  test('lost transition response reconciles via REST without replay', () async {
    await cubit.initialize();
    repository.transitionReply = (_) async {
      repository.status = 'DRIVER_ARRIVED';
      throw const NetworkException();
    };
    await cubit.perform(TripAction.arrive);
    expect(repository.transitionCalls, 1);
    expect(cubit.state.status, 'DRIVER_ARRIVED');
    expect(cubit.state.unresolved, isFalse);
  });

  test('old session response cannot mutate new account state', () async {
    await cubit.initialize();
    final pending = Completer<TripTransition>();
    repository.transitionReply = (_) => pending.future;
    final first = cubit.perform(TripAction.arrive);
    generation = 2;
    pending.complete(
        TripTransition('booking-1', 'DRIVER_ARRIVED', DateTime.utc(2026)));
    await first;
    expect(cubit.state.status, isNull);
    expect(cubit.state.sessionEnded, isTrue);
    expect(cubit.state.receipt, isNull);
  });

  test(
      'COMPLETED PENDING requires explicit cash action; replay recovers receipt',
      () async {
    repository.status = 'COMPLETED';
    await cubit.initialize();
    expect(cubit.state.availableAction, isNull);
    expect(cubit.state.canConfirmCash, isTrue);
    expect(repository.cashCalls, 0);
    repository.cashReply = () async {
      repository.paymentStatus = 'PAID';
      throw const NetworkException();
    };
    await cubit.confirmCash();
    expect(cubit.state.payment?.status, 'PAID');
    expect(cubit.state.receipt, isNull);
    expect(released, isEmpty);
    expect(cubit.state.canRecoverReceipt, isTrue);
    repository.cashReply = () async => _receipt('booking-1');
    await cubit.recoverReceipt();
    expect(repository.cashCalls, 2);
    expect(cubit.state.receipt?.commissionAmount, '3300.00');
    expect(released.single.driverReleasedAt, DateTime.utc(2026, 10, 16, 10, 6));
  });

  test('cash is unavailable before COMPLETED and no duplicate settlement',
      () async {
    await cubit.initialize();
    await cubit.confirmCash();
    expect(repository.cashCalls, 0);
    repository.status = 'COMPLETED';
    await cubit.refresh();
    final pending = Completer<CashReceipt>();
    repository.cashReply = () => pending.future;
    final first = cubit.confirmCash();
    await cubit.confirmCash();
    expect(repository.cashCalls, 1);
    repository.paymentStatus = 'PAID';
    pending.complete(_receipt('booking-1'));
    await first;
    expect(released.length, 1);
  });

  test('an older PENDING payment read cannot re-enable settled cash', () async {
    repository.status = 'COMPLETED';
    await cubit.initialize();
    final paymentStarted = Completer<void>();
    final oldPayment = Completer<CashPayment>();
    repository.paymentReply = (id) {
      paymentStarted.complete();
      return oldPayment.future;
    };
    final oldRefresh = cubit.refresh();
    await paymentStarted.future;
    final receiptSeen =
        cubit.stream.firstWhere((state) => state.receipt != null);
    final settle = cubit.confirmCash();
    await receiptSeen;
    repository.paymentReply = null;
    oldPayment.complete(const CashPayment(
        paymentPublicId: 'payment-1',
        bookingPublicId: 'booking-1',
        method: 'CASH',
        status: 'PENDING',
        amount: '16500.00',
        currency: 'VND'));
    await Future.wait([oldRefresh, settle]);
    if (cubit.state.payment?.status != 'PAID') {
      await cubit.stream
          .firstWhere((state) => state.payment?.status == 'PAID')
          .timeout(const Duration(seconds: 1));
    }
    expect(cubit.state.receipt?.paymentStatus, 'PAID');
    expect(cubit.state.payment?.status, 'PAID');
    expect(cubit.state.canConfirmCash, isFalse);
    expect(repository.cashCalls, 1);
  });

  test('background and dispose close subscription and ignore late events',
      () async {
    await cubit.initialize();
    final old = realtime.latest!;
    old.connect();
    await Future<void>.delayed(Duration.zero);
    await cubit.pause();
    expect(old.disposed, isTrue);
    expect(cubit.state.foreground, isFalse);
    expect(cubit.state.realtime, TripRealtimeConnectionState.disconnected);
    repository.status = 'DRIVER_ARRIVED';
    await cubit.resume();
    expect(realtime.listens, 2);
    expect(cubit.state.status, 'DRIVER_ARRIVED');
    await cubit.close();
    expect(realtime.latest!.disposed, isTrue);
  });

  test('Driver contact stays cleared until resume tracking is authorized',
      () async {
    const active = TrackingSnapshot(
        bookingPublicId: 'booking-1',
        status: 'DRIVER_ACCEPTED',
        driverPublicId: 'driver-1',
        customer:
            CustomerSummary(displayName: 'Customer A', phone: '0900000002'));
    repository.trackingReply = (_) async => active;
    await cubit.initialize();
    expect(cubit.state.tracking?.customer, isNotNull);
    final payment = cubit.state.payment;
    await cubit.pause();
    expect(cubit.state.tracking?.customer, isNull);
    expect(cubit.state.status, 'DRIVER_ACCEPTED');
    expect(cubit.state.payment, same(payment));

    final fresh = Completer<TrackingSnapshot>();
    repository.trackingReply = (_) => fresh.future;
    final resumed = cubit.resume();
    await Future<void>.delayed(Duration.zero);
    expect(cubit.state.tracking?.customer, isNull);
    fresh.complete(active);
    await resumed;
    expect(cubit.state.tracking?.customer?.displayName, 'Customer A');
  });

  test('In-flight Driver tracking cannot restore contact after pause',
      () async {
    const active = TrackingSnapshot(
        bookingPublicId: 'booking-1',
        status: 'DRIVER_ACCEPTED',
        driverPublicId: 'driver-1',
        customer:
            CustomerSummary(displayName: 'Customer A', phone: '0900000002'));
    repository.trackingReply = (_) async => active;
    await cubit.initialize();
    final old = Completer<TrackingSnapshot>();
    repository.trackingReply = (_) => old.future;
    final pending = cubit.refresh();
    await Future<void>.delayed(Duration.zero);
    await cubit.pause();
    old.complete(active);
    await pending;
    expect(cubit.state.tracking?.customer, isNull);
    repository.trackingReply = (_) async => active;
    await cubit.resume();
    expect(cubit.state.tracking?.customer?.displayName, 'Customer A');
  });

  test('Failed Driver resume does not resurrect contact', () async {
    repository.trackingReply = (_) async => const TrackingSnapshot(
        bookingPublicId: 'booking-1',
        status: 'DRIVER_ACCEPTED',
        driverPublicId: 'driver-1',
        customer: CustomerSummary(displayName: 'Customer A'));
    await cubit.initialize();
    await cubit.pause();
    repository.trackingReply = (_) async => throw const NetworkException();
    await cubit.resume();
    expect(cubit.state.tracking?.customer, isNull);
    expect(cubit.state.error, isNotNull);
  });

  test('Background account change clears Driver contact permanently', () async {
    repository.trackingReply = (_) async => const TrackingSnapshot(
        bookingPublicId: 'booking-1',
        status: 'DRIVER_ACCEPTED',
        driverPublicId: 'driver-1',
        customer: CustomerSummary(displayName: 'Customer A'));
    await cubit.initialize();
    await cubit.pause();
    generation = 2;
    await cubit.resume();
    expect(cubit.state.sessionEnded, isTrue);
    expect(cubit.state.tracking, isNull);
  });

  testWidgets('Trip card moves only on confirmed status and does not replay',
      (tester) async {
    final screenCubit = DriverTripCubit(
        bookingPublicId: 'booking-1',
        repository: repository,
        session: session,
        realtime: realtime,
        location: location,
        pollInterval: const Duration(hours: 1),
        gpsInterval: const Duration(hours: 1));
    await tester.pumpWidget(MaterialApp(
      home: DriverAcceptedBookingScreen(
        offer: _offer(),
        tripCubit: screenCubit,
        mapBuilder: _fakeMap,
      ),
    ));
    await tester.pump();
    expect(find.byKey(const ValueKey('driver-trip-status-DRIVER_ACCEPTED')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('driver-customer-card')), findsNothing);
    final motion = tester.widget<AnimatedSwitcher>(
        find.byKey(const ValueKey('driver-trip-status-motion')));
    expect(motion.duration, AppMotion.card);

    repository.status = 'DRIVER_ARRIVED';
    await screenCubit.refresh();
    await tester.pump();
    expect(find.byKey(const ValueKey('driver-trip-status-DRIVER_ARRIVED')),
        findsOneWidget);
    await tester.pump(AppMotion.card);
    expect(find.byKey(const ValueKey('driver-trip-status-DRIVER_ACCEPTED')),
        findsNothing);
    await screenCubit.refresh();
    await tester.pump();
    expect(find.byKey(const ValueKey('driver-trip-status-DRIVER_ARRIVED')),
        findsOneWidget);
    expect(repository.transitionCalls, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Driver cancellation requires confirmation on narrow screen',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final local = DriverTripCubit(
        bookingPublicId: 'booking-1',
        repository: repository,
        session: session,
        realtime: realtime,
        location: location,
        pollInterval: const Duration(hours: 1),
        gpsInterval: const Duration(hours: 1));
    await tester.pumpWidget(MaterialApp(
        home: DriverAcceptedBookingScreen(
            offer: _offer(), tripCubit: local, mapBuilder: _fakeMap)));
    await tester.pump();
    await tester.drag(find.byKey(const ValueKey('driver-trip-sheet-scroll')),
        const Offset(0, -260));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('driver-cancel-trip')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('driver-cancel-trip')));
    await tester.pump();
    expect(find.text('Hủy chuyến đã nhận?'), findsOneWidget);
    await tester.tap(find.text('Giữ chuyến'));
    await tester.pumpAndSettle();
    expect(repository.cancelCalls, 0);
    await tester.tap(find.byKey(const ValueKey('driver-cancel-trip')));
    await tester.pump();
    await tester.tap(find.text('Xác nhận hủy'));
    await tester.pumpAndSettle();
    expect(repository.cancelCalls, 1);
    expect(find.text('Chuyến đi đã được hủy', skipOffstage: false),
        findsOneWidget);
    expect(find.text('Xác nhận đã thu tiền mặt'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Driver customer card requires active authorized tracking',
      (tester) async {
    repository.trackingReply = (_) async => const TrackingSnapshot(
        bookingPublicId: 'booking-1',
        status: 'DRIVER_ACCEPTED',
        driverPublicId: 'driver-1',
        customer: CustomerSummary(displayName: 'Khách B', phone: '0900000002'));
    final screenCubit = DriverTripCubit(
        bookingPublicId: 'booking-1',
        repository: repository,
        session: session,
        realtime: realtime,
        location: location,
        pollInterval: const Duration(hours: 1),
        gpsInterval: const Duration(hours: 1));
    await tester.pumpWidget(MaterialApp(
        home: DriverAcceptedBookingScreen(
            offer: _offer(), tripCubit: screenCubit, mapBuilder: _fakeMap)));
    await tester.pump();
    await tester.drag(find.byKey(const ValueKey('driver-trip-sheet-scroll')),
        const Offset(0, -350));
    await tester.pumpAndSettle();
    expect(find.text('Khách B', skipOffstage: false), findsOneWidget);
    expect(find.text('Điện thoại: 0900000002', skipOffstage: false),
        findsOneWidget);

    repository.trackingReply = (_) async => const TrackingSnapshot(
        bookingPublicId: 'booking-1',
        status: 'COMPLETED',
        driverPublicId: 'driver-1',
        customer: CustomerSummary(displayName: 'Khách B'));
    unawaited(screenCubit.refresh());
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('driver-customer-card')), findsNothing);
    generation = 2;
    unawaited(screenCubit.refresh());
    await tester.pump();
    expect(find.byKey(const ValueKey('driver-customer-card')), findsNothing);
    expect(screenCubit.state.sessionEnded, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Driver addresses require assigned tracking and fresh resume',
      (tester) async {
    final geocoder = _Geocoder();
    final screenCubit = DriverTripCubit(
        bookingPublicId: 'booking-1',
        repository: repository,
        session: session,
        realtime: realtime,
        location: location,
        pollInterval: const Duration(hours: 1),
        gpsInterval: const Duration(hours: 1));
    await tester.pumpWidget(MaterialApp(
        home: DriverAcceptedBookingScreen(
            offer: _offer(),
            tripCubit: screenCubit,
            geocodingRepository: geocoder,
            addressSession: session,
            mapBuilder: _fakeMap)));
    await tester.pump();
    await tester.pump();
    await tester.drag(find.byKey(const ValueKey('driver-trip-sheet-scroll')),
        const Offset(0, -350));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Điểm đón và điểm đến'), 80,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Điểm đón và điểm đến'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Điểm đón: Hồ Hoàn Kiếm'), findsOneWidget);
    expect(find.textContaining('Điểm đến: Bến xe Mỹ Đình'), findsOneWidget);
    expect(geocoder.calls, 2);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(find.textContaining('Điểm đón: Hồ Hoàn Kiếm'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Điểm đón: Hồ Hoàn Kiếm'), findsOneWidget);
    expect(geocoder.calls, 4);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Unassigned Driver never resolves private Booking addresses',
      (tester) async {
    repository.trackingReply = (_) async => const TrackingSnapshot(
        bookingPublicId: 'booking-1', status: 'DRIVER_ACCEPTED');
    final geocoder = _Geocoder();
    final screenCubit = DriverTripCubit(
        bookingPublicId: 'booking-1',
        repository: repository,
        session: session,
        realtime: realtime,
        location: location,
        pollInterval: const Duration(hours: 1));
    await tester.pumpWidget(MaterialApp(
        home: DriverAcceptedBookingScreen(
            offer: _offer(),
            tripCubit: screenCubit,
            geocodingRepository: geocoder,
            addressSession: session,
            mapBuilder: _fakeMap)));
    await tester.pump();
    await tester.pump();
    expect(geocoder.calls, 0);
    expect(find.text('Đang xác minh thông tin chuyến với máy chủ.'),
        findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Late Driver address cannot survive background account switch',
      (tester) async {
    final pending = Completer<PlaceSearchResult?>();
    final geocoder = _Geocoder()..reply = (_) => pending.future;
    final screenCubit = DriverTripCubit(
        bookingPublicId: 'booking-1',
        repository: repository,
        session: session,
        realtime: realtime,
        location: location,
        pollInterval: const Duration(hours: 1));
    await tester.pumpWidget(MaterialApp(
        home: DriverAcceptedBookingScreen(
            offer: _offer(),
            tripCubit: screenCubit,
            geocodingRepository: geocoder,
            addressSession: session,
            mapBuilder: _fakeMap)));
    await tester.pump();
    await tester.pump();
    expect(geocoder.calls, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    generation = 2;
    pending.complete(const PlaceSearchResult(
        label: 'Địa chỉ của phiên cũ',
        coordinates: Coordinates(21.0287, 105.8524)));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Địa chỉ của phiên cũ'), findsNothing);
    expect(screenCubit.state.sessionEnded, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Driver address request stays on tracking session generation',
      (tester) async {
    var sessionReads = 0;
    when(() => session.getSession()).thenAnswer(
        (_) async => AuthSessionSnapshot(++sessionReads, 'access', 'refresh'));
    final geocoder = _Geocoder();
    final screenCubit = DriverTripCubit(
        bookingPublicId: 'booking-1',
        repository: repository,
        session: session,
        realtime: realtime,
        location: location,
        pollInterval: const Duration(hours: 1));
    await tester.pumpWidget(MaterialApp(
        home: DriverAcceptedBookingScreen(
            offer: _offer(),
            tripCubit: screenCubit,
            geocodingRepository: geocoder,
            addressSession: session,
            mapBuilder: _fakeMap)));
    await tester.pump();
    await tester.pump();
    expect(screenCubit.authorizedSessionGeneration, 1);
    expect(sessionReads, greaterThanOrEqualTo(2));
    expect(geocoder.calls, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Driver sheet drags, scrolls and keeps server action reachable',
      (tester) async {
    final screenCubit = DriverTripCubit(
        bookingPublicId: 'booking-1',
        repository: repository,
        session: session,
        realtime: realtime,
        location: location,
        pollInterval: const Duration(hours: 1),
        gpsInterval: const Duration(hours: 1));
    await tester.pumpWidget(MaterialApp(
      home: DriverAcceptedBookingScreen(
        offer: _offer(),
        tripCubit: screenCubit,
        mapBuilder: _fakeMap,
      ),
    ));
    await tester.pump();
    final sheet = tester.widget<DraggableScrollableSheet>(
        find.byKey(const ValueKey('driver-trip-sheet')));
    expect(sheet.minChildSize, .42);
    expect(sheet.maxChildSize, .84);
    expect(sheet.snap, isTrue);
    final scroll = tester.widget<ListView>(
        find.byKey(const ValueKey('driver-trip-sheet-scroll')));
    expect(scroll.controller, isNotNull);
    expect(
        find.widgetWithText(FilledButton, 'Đã đến điểm đón'), findsOneWidget);
    final collapsed = tester
        .getSize(find.byKey(const ValueKey('driver-trip-sheet-surface')))
        .height;

    await tester.drag(find.byKey(const ValueKey('driver-trip-sheet-scroll')),
        const Offset(0, -350));
    await tester.pumpAndSettle();
    final expanded = tester
        .getSize(find.byKey(const ValueKey('driver-trip-sheet-surface')))
        .height;
    expect(expanded, greaterThan(collapsed));
    expect(repository.transitionCalls, 0,
        reason: 'Dragging a sheet is never a trip transition');
    expect(find.byKey(const ValueKey('driver-trip-fake-map')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Only the same authorized Booking shows the Driver map',
      (tester) async {
    repository.trackingReply = (_) async => const TrackingSnapshot(
        bookingPublicId: 'another-booking',
        status: 'DRIVER_ACCEPTED',
        driverPublicId: 'driver-1');
    final screenCubit = DriverTripCubit(
        bookingPublicId: 'booking-1',
        repository: repository,
        session: session,
        realtime: realtime,
        location: location,
        pollInterval: const Duration(hours: 1),
        gpsInterval: const Duration(hours: 1));
    var mounts = 0;
    var disposals = 0;
    await tester.pumpWidget(MaterialApp(
      home: DriverAcceptedBookingScreen(
        offer: _offer(),
        tripCubit: screenCubit,
        mapBuilder: (_, __) => _MapMountSpy(
          onMount: () => mounts++,
          onDispose: () => disposals++,
        ),
      ),
    ));
    await tester.pump();
    expect(find.byType(_MapMountSpy), findsNothing);
    expect(find.textContaining('Đang xác minh chuyến và vị trí được phép xem'),
        findsOneWidget);

    repository.trackingReply = null;
    await screenCubit.refresh();
    await tester.pump();
    expect(find.byType(_MapMountSpy), findsOneWidget);
    expect(mounts, 1);
    repository.status = 'DRIVER_ARRIVED';
    await screenCubit.refresh();
    await tester.pump();
    expect(mounts, 1);
    expect(disposals, 0);

    generation = 2;
    await screenCubit.refresh();
    await tester.pump();
    expect(find.byType(_MapMountSpy), findsNothing);
    expect(disposals, 1);
    expect(screenCubit.state.sessionEnded, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Missing coordinates never fabricate a map or block trip action',
      (tester) async {
    final screenCubit = DriverTripCubit(
        bookingPublicId: 'booking-1',
        repository: repository,
        session: session,
        realtime: realtime,
        location: location,
        pollInterval: const Duration(hours: 1),
        gpsInterval: const Duration(hours: 1));
    await tester.pumpWidget(MaterialApp(
      home: DriverAcceptedBookingScreen(
        offer: _offer(pickupLatitude: double.nan),
        tripCubit: screenCubit,
        mapBuilder: _fakeMap,
      ),
    ));
    await tester.pump();
    expect(find.byKey(const ValueKey('driver-trip-fake-map')), findsNothing);
    expect(find.textContaining('Chưa có vị trí điểm đón và điểm đến hợp lệ'),
        findsWidgets);
    final action = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Đã đến điểm đón'));
    expect(action.onPressed, isNotNull);
    expect(repository.transitionCalls, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('CASH stays PENDING until the server returns a PAID receipt',
      (tester) async {
    repository.status = 'COMPLETED';
    final cashReply = Completer<CashReceipt>();
    repository.cashReply = () => cashReply.future;
    final screenCubit = DriverTripCubit(
        bookingPublicId: 'booking-1',
        repository: repository,
        session: session,
        realtime: realtime,
        location: location,
        pollInterval: const Duration(hours: 1),
        gpsInterval: const Duration(hours: 1));
    await tester.pumpWidget(MaterialApp(
      home: DriverAcceptedBookingScreen(
        offer: _offer(),
        tripCubit: screenCubit,
        mapBuilder: _fakeMap,
      ),
    ));
    await tester.pump();
    expect(screenCubit.state.payment?.status, 'PENDING');
    expect(screenCubit.state.receipt, isNull);
    await tester.scrollUntilVisible(find.text('Xác nhận đã thu tiền mặt'), 250);
    await tester.tap(find.text('Xác nhận đã thu tiền mặt'));
    await tester.pump();
    await tester.tap(find.text('Tôi đã thu tiền mặt'));
    await tester.pump();
    expect(repository.cashCalls, 1);
    expect(screenCubit.state.payment?.status, 'PENDING');
    expect(screenCubit.state.receipt, isNull);
    expect(find.text('Biên nhận tiền mặt'), findsNothing);

    final receiptSeen =
        screenCubit.stream.firstWhere((state) => state.receipt != null);
    repository.paymentStatus = 'PAID';
    cashReply.complete(_receipt('booking-1'));
    await receiptSeen;
    await tester.pump();
    expect(screenCubit.state.payment?.status, 'PAID');
    expect(screenCubit.state.receipt?.paymentStatus, 'PAID');
    await tester.scrollUntilVisible(find.text('Biên nhận tiền mặt'), 200);
    final receiptMotion = tester.widget<TweenAnimationBuilder<double>>(
        find.byKey(const ValueKey('driver-cash-receipt-payment-1')));
    expect(receiptMotion.duration, AppMotion.cash);
    expect(repository.cashCalls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Trip and CASH motion are immediate when animations disabled',
      (tester) async {
    repository.status = 'COMPLETED';
    final screenCubit = DriverTripCubit(
        bookingPublicId: 'booking-1',
        repository: repository,
        session: session,
        realtime: realtime,
        location: location,
        pollInterval: const Duration(hours: 1),
        gpsInterval: const Duration(hours: 1));
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: DriverAcceptedBookingScreen(
          offer: _offer(),
          tripCubit: screenCubit,
          mapBuilder: _fakeMap,
        ),
      ),
    ));
    await tester.pump();
    final motion = tester.widget<AnimatedSwitcher>(
        find.byKey(const ValueKey('driver-trip-status-motion')));
    expect(motion.duration, Duration.zero);
    final sheet = tester.widget<DraggableScrollableSheet>(
        find.byKey(const ValueKey('driver-trip-sheet')));
    expect(sheet.snap, isFalse);
    expect(screenCubit.state.status, 'COMPLETED');
    expect(screenCubit.state.payment?.status, 'PENDING');
    await screenCubit.confirmCash();
    await tester.pump();
    await tester.scrollUntilVisible(find.text('Biên nhận tiền mặt'), 200);
    final receiptMotion = tester.widget<TweenAnimationBuilder<double>>(
        find.byKey(const ValueKey('driver-cash-receipt-payment-1')));
    expect(receiptMotion.duration, Duration.zero);
    expect(
      find.ancestor(
        of: find.text('Biên nhận tiền mặt'),
        matching: find.byType(Opacity),
      ),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

DriverOffer _offer(
        {double pickupLatitude = 21.0287,
        double dropoffLongitude = 105.8576}) =>
    DriverOffer(
      offerPublicId: 'offer-1',
      bookingPublicId: 'booking-1',
      pickupLatitude: pickupLatitude,
      pickupLongitude: 105.8524,
      dropoffLatitude: 21.0245,
      dropoffLongitude: dropoffLongitude,
      vehicleType: 'MOTORBIKE',
      currency: 'VND',
      finalFare: '16500',
      expiresAt: DateTime.utc(2026, 10, 16, 10, 0, 15),
    );

Widget _fakeMap(BuildContext _, DriverOffer __) =>
    const ColoredBox(key: ValueKey('driver-trip-fake-map'), color: Colors.blue);

class _MapMountSpy extends StatefulWidget {
  final VoidCallback onMount;
  final VoidCallback onDispose;

  const _MapMountSpy({required this.onMount, required this.onDispose});

  @override
  State<_MapMountSpy> createState() => _MapMountSpyState();
}

class _MapMountSpyState extends State<_MapMountSpy> {
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
  Widget build(BuildContext context) => const ColoredBox(color: Colors.blue);
}
