import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gomove_mobile/core/error/exceptions.dart';
import 'package:gomove_mobile/core/storage/secure_storage_service.dart';
import 'package:gomove_mobile/core/theme/app_motion.dart';
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
    expect(find.textContaining('Chưa có tọa độ điểm đón/đến hợp lệ'),
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
    expect(find.text('Biên nhận CASH · PAID'), findsNothing);

    final receiptSeen =
        screenCubit.stream.firstWhere((state) => state.receipt != null);
    repository.paymentStatus = 'PAID';
    cashReply.complete(_receipt('booking-1'));
    await receiptSeen;
    await tester.pump();
    expect(screenCubit.state.payment?.status, 'PAID');
    expect(screenCubit.state.receipt?.paymentStatus, 'PAID');
    await tester.scrollUntilVisible(find.text('Biên nhận CASH · PAID'), 200);
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
    await tester.scrollUntilVisible(find.text('Biên nhận CASH · PAID'), 200);
    final receiptMotion = tester.widget<TweenAnimationBuilder<double>>(
        find.byKey(const ValueKey('driver-cash-receipt-payment-1')));
    expect(receiptMotion.duration, Duration.zero);
    expect(
      find.ancestor(
        of: find.text('Biên nhận CASH · PAID'),
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
