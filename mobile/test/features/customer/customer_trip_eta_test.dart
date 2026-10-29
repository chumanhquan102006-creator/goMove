import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gomove_mobile/core/error/exceptions.dart';
import 'package:gomove_mobile/core/storage/secure_storage_service.dart';
import 'package:gomove_mobile/features/customer/presentation/widgets/customer_trip_eta.dart';
import 'package:gomove_mobile/features/trip/domain/models/trip_eta.dart';
import 'package:gomove_mobile/features/trip/domain/repositories/trip_eta_repository.dart';
import 'package:mocktail/mocktail.dart';

class _Session extends Mock implements SecureStorageService {}

class _EtaRepository implements TripEtaRepository {
  int calls = 0;
  final generations = <int>[];
  Future<TripEta> Function(String, int) reply;
  _EtaRepository(this.reply);

  @override
  Future<TripEta> booking(String bookingPublicId, int generation) {
    calls++;
    generations.add(generation);
    return reply(bookingPublicId, generation);
  }
}

TripEta _eta(DateTime now,
        {String status = 'DRIVER_ACCEPTED',
        String phase = 'PICKUP',
        String availability = 'AVAILABLE',
        String? reason}) =>
    TripEta(
      bookingPublicId: 'booking-1',
      status: status,
      phase: phase,
      availability: availability,
      reason: reason,
      distanceMeters: availability == 'AVAILABLE' ? 900 : null,
      durationSeconds: availability == 'AVAILABLE' ? 240 : null,
      calculatedAt: availability == 'AVAILABLE' ? now : null,
      locationUpdatedAt: availability == 'AVAILABLE'
          ? now.subtract(const Duration(seconds: 1))
          : null,
      expiresAt: availability == 'AVAILABLE'
          ? now.add(const Duration(seconds: 30))
          : null,
      servedAt: now,
    );

Widget _app(String status, _EtaRepository repository, _Session session) =>
    MaterialApp(
      home: Scaffold(
        body: CustomerTripEta(
          bookingPublicId: 'booking-1',
          status: status,
          repository: repository,
          session: session,
          refreshInterval: const Duration(minutes: 10),
        ),
      ),
    );

void main() {
  late _Session session;
  late _EtaRepository repository;
  late DateTime clock;
  var generation = 7;

  setUp(() {
    generation = 7;
    clock = DateTime.now().toUtc();
    session = _Session();
    when(() => session.getSession()).thenAnswer(
        (_) async => AuthSessionSnapshot(generation, 'access', 'refresh'));
    when(() => session.isCurrentSession(any())).thenAnswer(
        (call) async => call.positionalArguments.first == generation);
    repository = _EtaRepository((_, __) async => _eta(clock));
  });

  testWidgets(
      'Pickup ETA is approximate, server-backed and fits narrow portrait',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(_app('DRIVER_ACCEPTED', repository, session));
    await tester.pump();
    expect(find.text('Đón bạn sau khoảng 4 phút'), findsOneWidget);
    expect(find.text('Cách điểm đón khoảng 900 m'), findsOneWidget);
    expect(find.textContaining('Ước tính cập nhật lúc'), findsOneWidget);
    expect(repository.calls, 1);
    expect(repository.generations.single, 7);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'In-progress shows road remaining ETA; other stages never call ETA',
      (tester) async {
    repository.reply = (_, __) async =>
        _eta(clock, status: 'IN_PROGRESS', phase: 'DESTINATION');
    await tester.pumpWidget(_app('SEARCHING_DRIVER', repository, session));
    await tester.pump();
    expect(repository.calls, 0);
    expect(find.byKey(const ValueKey('customer-trip-eta-card')), findsNothing);
    await tester.pumpWidget(_app('IN_PROGRESS', repository, session));
    await tester.pump();
    expect(find.text('Dự kiến đến nơi trong khoảng 4 phút'), findsOneWidget);
    expect(find.text('Còn khoảng 900 m theo đường phố'), findsOneWidget);
    await tester.pumpWidget(_app('COMPLETED', repository, session));
    await tester.pump();
    expect(find.textContaining('Còn khoảng'), findsNothing);
    expect(repository.calls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Unavailable and REST failure never reuse old estimate',
      (tester) async {
    await tester.pumpWidget(_app('DRIVER_ACCEPTED', repository, session));
    await tester.pump();
    expect(find.text('Đón bạn sau khoảng 4 phút'), findsOneWidget);
    repository.reply = (_, __) async =>
        _eta(clock, availability: 'UNAVAILABLE', reason: 'GPS_STALE');
    // Resume invalidates the old result, then asks the same authorized API.
    final lifecycle =
        tester.state(find.byType(CustomerTripEta)) as WidgetsBindingObserver;
    lifecycle.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump();
    expect(find.textContaining('Đón bạn sau'), findsNothing);
    lifecycle.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(
        find.text('Vị trí GPS đã cũ; đang chờ cập nhật mới.'), findsOneWidget);
    repository.reply = (_, __) async => throw const NetworkException('offline');
    lifecycle.didChangeAppLifecycleState(AppLifecycleState.paused);
    lifecycle.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(find.text('Chưa có ước tính đáng tin cậy.'), findsOneWidget);
    expect(find.textContaining('Đón bạn sau'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Expired ETA disappears without a simulated countdown',
      (tester) async {
    await tester.pumpWidget(_app('DRIVER_ACCEPTED', repository, session));
    await tester.pump();
    expect(find.text('Đón bạn sau khoảng 4 phút'), findsOneWidget);
    await tester.pump(const Duration(seconds: 31));
    expect(find.text('Đón bạn sau khoảng 4 phút'), findsNothing);
    expect(find.text('Chưa có ước tính đáng tin cậy.'), findsOneWidget);
    expect(repository.calls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Cached ETA expires by server TTL despite device clock skew',
      (tester) async {
    final calculatedAt = DateTime.utc(2040, 1, 1);
    repository.reply = (_, __) async => TripEta(
          bookingPublicId: 'booking-1',
          status: 'DRIVER_ACCEPTED',
          phase: 'PICKUP',
          availability: 'AVAILABLE',
          distanceMeters: 900,
          durationSeconds: 240,
          calculatedAt: calculatedAt,
          locationUpdatedAt: calculatedAt.subtract(const Duration(seconds: 1)),
          servedAt: calculatedAt.add(const Duration(seconds: 20)),
          expiresAt: calculatedAt.add(const Duration(seconds: 30)),
        );
    await tester.pumpWidget(_app('DRIVER_ACCEPTED', repository, session));
    await tester.pump();
    expect(find.text('Đón bạn sau khoảng 4 phút'), findsOneWidget);
    await tester.pump(const Duration(seconds: 11));
    expect(find.text('Đón bạn sau khoảng 4 phút'), findsNothing);
    expect(repository.calls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Late old-session response cannot appear after account switch',
      (tester) async {
    final pending = Completer<TripEta>();
    repository.reply = (_, __) => pending.future;
    await tester.pumpWidget(_app('DRIVER_ACCEPTED', repository, session));
    await tester.pump();
    expect(repository.generations, [7]);
    generation = 8;
    pending.complete(_eta(clock));
    await tester.pump();
    await tester.pump();
    expect(find.text('Đón bạn sau khoảng 4 phút'), findsNothing);
    expect(find.text('Phiên đăng nhập đã thay đổi.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('403 stops ETA polling and never retains private estimate',
      (tester) async {
    repository.reply = (_, __) async =>
        throw const ServerException(message: 'Forbidden', statusCode: 403);
    await tester.pumpWidget(_app('DRIVER_ACCEPTED', repository, session));
    await tester.pump();
    expect(find.text('Phiên đăng nhập đã thay đổi.'), findsOneWidget);
    expect(find.textContaining('Đón bạn sau'), findsNothing);
    await tester.pump(const Duration(minutes: 11));
    expect(repository.calls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
