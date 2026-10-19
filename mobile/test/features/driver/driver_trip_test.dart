import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:gomove_mobile/core/error/exceptions.dart';
import 'package:gomove_mobile/core/storage/secure_storage_service.dart';
import 'package:gomove_mobile/features/driver/data/location/driver_location_source.dart';
import 'package:gomove_mobile/features/driver/domain/models/driver_models.dart';
import 'package:gomove_mobile/features/driver/presentation/bloc/driver_trip_cubit.dart';
import 'package:gomove_mobile/features/trip/data/trip_realtime_client.dart';
import 'package:gomove_mobile/features/trip/domain/models/trip_models.dart';
import 'package:gomove_mobile/features/trip/domain/repositories/trip_repository.dart';
import 'package:mocktail/mocktail.dart';

class _Session extends Mock implements SecureStorageService {}

class _Repository implements TripRepository {
  String status = 'DRIVER_ACCEPTED';
  String paymentStatus = 'PENDING';
  int transitionCalls = 0;
  int cashCalls = 0;
  int trackingCalls = 0;
  int paymentCalls = 0;
  Object? transitionError;
  Object? cashError;
  Future<TrackingSnapshot> Function(String bookingPublicId)? trackingReply;
  Future<CashPayment> Function(String bookingPublicId)? paymentReply;
  Future<TripTransition> Function(TripAction)? transitionReply;
  Future<CashReceipt> Function()? cashReply;

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
}
