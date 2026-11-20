import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show Factory;
import 'package:flutter/gestures.dart' show OneSequenceGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gomove_mobile/core/theme/app_theme.dart';
import 'package:gomove_mobile/features/customer/presentation/bloc/booking_status_cubit.dart';
import 'package:gomove_mobile/features/customer/domain/models/quote.dart';
import 'package:gomove_mobile/features/customer/presentation/widgets/customer_trip_tracking_map.dart';
import 'package:gomove_mobile/features/customer/presentation/widgets/customer_map_source.dart';
import 'package:gomove_mobile/features/trip/data/trip_realtime_client.dart';
import 'package:gomove_mobile/features/trip/domain/models/road_route.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

DateTime? _clockStart;
Duration _elapsed(WidgetTester tester) {
  _clockStart ??= tester.binding.clock.now();
  return tester.binding.clock.now().difference(_clockStart!);
}

DateTime _wallNow(WidgetTester tester) =>
    DateTime.utc(2026, 10, 16, 10, 11, 11).add(_elapsed(tester));

void main() {
  setUpAll(_loadTrackingTestFonts);
  setUp(() => _clockStart = null);
  final firstFix = DateTime.utc(2026, 10, 16, 10, 11);
  final newerFix = firstFix.add(const Duration(seconds: 5));

  test('Tracking map accepts only valid, strictly newer GPS fixes', () {
    final first = CustomerLiveLocation(21.1, 105.1, 4, 90, firstFix);
    expect(CustomerTripTrackingMap.isRenderable(first), isTrue);
    expect(
        CustomerTripTrackingMap.shouldAcceptNewFix(
            first, CustomerLiveLocation(22, 106, null, null, firstFix)),
        isFalse);
    expect(
        CustomerTripTrackingMap.shouldAcceptNewFix(
            first,
            CustomerLiveLocation(22, 106, null, null,
                firstFix.subtract(const Duration(seconds: 1)))),
        isFalse);
    expect(
        CustomerTripTrackingMap.shouldAcceptNewFix(
            first, CustomerLiveLocation(22, 106, null, null, newerFix)),
        isTrue);
    expect(
        CustomerTripTrackingMap.shouldAcceptNewFix(
            first, CustomerLiveLocation(double.nan, 106, null, null, newerFix)),
        isFalse);
    expect(
        CustomerTripTrackingMap.isRenderable(
            CustomerLiveLocation(91, 105, null, null, firstFix)),
        isFalse);
  });

  test('Interpolation rejects stale gaps, implausible jumps and old samples',
      () {
    final first = CustomerLiveLocation(21.1, 105.1, 4, 90, firstFix);
    final nearby = CustomerLiveLocation(21.1001, 105.1001, 3, 90, newerFix);
    expect(
        CustomerMarkerMotion.canInterpolate(
            first, nearby, newerFix.add(const Duration(seconds: 1))),
        isTrue);
    expect(
        CustomerMarkerMotion.canInterpolate(
            first, nearby, newerFix.add(const Duration(minutes: 1))),
        isFalse);
    expect(
        CustomerMarkerMotion.canInterpolate(
            first, nearby, newerFix.subtract(const Duration(seconds: 10))),
        isFalse);
    expect(
        CustomerMarkerMotion.canInterpolate(
            first,
            CustomerLiveLocation(21.1001, 105.1001, 3, 90,
                firstFix.add(const Duration(microseconds: 1))),
            firstFix.add(const Duration(seconds: 1))),
        isFalse);
    expect(
        CustomerMarkerMotion.canInterpolate(
            first,
            CustomerLiveLocation(21.1001, 105.1001, 3, 90,
                firstFix.add(const Duration(seconds: 30))),
            firstFix.add(const Duration(seconds: 31))),
        isFalse);
    expect(
        CustomerMarkerMotion.canInterpolate(
            first,
            CustomerLiveLocation(22, 106, 3, 90, newerFix),
            newerFix.add(const Duration(seconds: 1))),
        isFalse);
    expect(
        CustomerMarkerMotion.canInterpolate(first, first, newerFix), isFalse);
    expect(
        CustomerMarkerMotion.canInterpolate(
            first,
            CustomerLiveLocation(
                first.latitude, first.longitude, 3, 90, newerFix),
            newerFix.add(const Duration(seconds: 1))),
        isFalse);
  });

  test('Bearing takes the short arc between verified samples', () {
    expect(CustomerMarkerMotion.bearingAt(350, 10, .5), closeTo(0, .001));
    expect(CustomerMarkerMotion.bearingAt(10, 350, .5), closeTo(0, .001));
    expect(CustomerMarkerMotion.bearingAt(null, 45, .5), 45);
    expect(CustomerMarkerMotion.bearingAt(45, null, .5), isNull);
    expect(CustomerMarkerMotion.bearingAt(45, 370, .5), isNull);
  });

  testWidgets(
      'Pickup radar runs only for authoritative search and pauses in background',
      (tester) async {
    const channel = MethodChannel('plugins.flutter.io/maplibre_gl');
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final originalFactory = MapLibrePlatform.createInstance;
    MapLibrePlatform.createInstance = _FakeMapLibrePlatform.new;
    addTearDown(() => MapLibrePlatform.createInstance = originalFactory);
    final controller = _RecordingTrackingController();

    Future<void> show(bool searching) async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SizedBox.expand(
        child: CustomerTripTrackingMap(
          motionElapsed: () => _elapsed(tester),
          motionNow: () => _wallNow(tester),
          bookingPublicId: 'booking-radar',
          pickup: const Coordinates(21.0287, 105.8524),
          searchingForDriver: searching,
          location: null,
          connectionState: TripRealtimeConnectionState.connected,
        ),
      ))));
      await tester.pump();
    }

    await show(true);
    final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    map.onMapCreated!(controller);
    map.onStyleLoadedCallback!();
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.circles.length, 4); // Pickup + three real-point waves.
    final updates = controller.circleUpdates;
    expect(updates, greaterThan(0));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 1));
    expect(controller.circleUpdates, updates);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await show(false); // Confirmed match stops and removes the radar.
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.circles.length, 1);
    expect(controller.cameraMoves, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Stationary newer GPS avoids idle marker writes', (tester) async {
    final points = <LatLng>[];
    final first = CustomerLiveLocation(21.1, 105.1, 4, 90, firstFix);
    final stationary = CustomerLiveLocation(21.1, 105.1, 3, 90, newerFix);
    final motion = CustomerMarkerMotion(
        elapsed: () => _elapsed(tester),
        onPosition: points.add,
        now: () => newerFix.add(const Duration(seconds: 1)));
    addTearDown(motion.dispose);
    motion.accept(first, animate: false);
    motion.accept(stationary, animate: true);
    expect(motion.isAnimating, isFalse);
    await tester.pump(const Duration(seconds: 1));
    expect(points, hasLength(1));
    expect(points.single, LatLng(first.latitude, first.longitude));
  });

  testWidgets('Marker motion uses three bounded steps and ends on real fix',
      (tester) async {
    final points = <LatLng>[];
    final first = CustomerLiveLocation(21.1, 105.1, 4, 90, firstFix);
    final newer = CustomerLiveLocation(21.1001, 105.1001, 3, 95, newerFix);
    final motion = CustomerMarkerMotion(
        elapsed: () => _elapsed(tester),
        onPosition: points.add,
        now: () => newerFix.add(const Duration(seconds: 1)));
    addTearDown(motion.dispose);
    motion.accept(first, animate: true);
    motion.accept(newer, animate: true);
    expect(points.length, 1);
    expect(motion.isAnimating, isTrue);

    await tester.pump(CustomerMarkerMotion.tick);
    expect(points.length, 2);
    expect(points.last.latitude, greaterThan(first.latitude));
    expect(points.last.latitude, lessThan(newer.latitude));
    await tester.pump(CustomerMarkerMotion.tick);
    expect(points.length, 3);
    await tester.pump(CustomerMarkerMotion.tick);
    expect(points.length, 4);
    expect(points.last.latitude, newer.latitude);
    expect(points.last.longitude, newer.longitude);
    expect(motion.isAnimating, isFalse);
    await tester.pump(const Duration(seconds: 1));
    expect(points.length, 4, reason: 'No timer or native writes while idle');
  });

  testWidgets('Newer fix retargets from the rendered point without jumping',
      (tester) async {
    final points = <LatLng>[];
    final first = CustomerLiveLocation(21.1, 105.1, 4, 90, firstFix);
    final newer = CustomerLiveLocation(21.1001, 105.1001, 3, 95, newerFix);
    final latest = CustomerLiveLocation(
        21.1002, 105.1002, 3, 95, newerFix.add(const Duration(seconds: 5)));
    final motion = CustomerMarkerMotion(
        elapsed: () => _elapsed(tester),
        onPosition: points.add,
        now: () => latest.updatedAt.add(const Duration(seconds: 1)));
    addTearDown(motion.dispose);
    motion.accept(first, animate: true);
    motion.accept(newer, animate: true);
    await tester.pump(CustomerMarkerMotion.tick);
    final rendered = points.last;
    motion.accept(latest, animate: true);
    expect(points.last, rendered);
    expect(motion.isAnimating, isTrue);
    await tester.pump(CustomerMarkerMotion.duration);
    expect(points.last.latitude, latest.latitude);
    expect(points.last.longitude, closeTo(latest.longitude, 1e-9));
    expect(motion.isAnimating, isFalse);
    final count = points.length;
    await tester.pump(const Duration(seconds: 1));
    expect(points.length, count);
    motion.accept(newer, animate: true);
    expect(points.length, count, reason: 'Older samples cannot replay');
  });

  testWidgets('Snap, reduced motion and disposal cancel pending steps',
      (tester) async {
    final points = <LatLng>[];
    final first = CustomerLiveLocation(21.1, 105.1, 4, 90, firstFix);
    final newer = CustomerLiveLocation(21.1001, 105.1001, 3, 95, newerFix);
    final motion = CustomerMarkerMotion(
        elapsed: () => _elapsed(tester),
        onPosition: points.add,
        now: () => newerFix.add(const Duration(seconds: 1)));
    motion.accept(first, animate: false);
    motion.accept(newer, animate: false);
    expect(points.last.latitude, newer.latitude);
    expect(motion.isAnimating, isFalse);
    final third = CustomerLiveLocation(
        21.1002, 105.1002, 3, 95, newerFix.add(const Duration(seconds: 5)));
    motion.accept(third, animate: true);
    expect(motion.isAnimating, isTrue);
    motion.snap();
    expect(points.last.latitude, third.latitude);
    final count = points.length;
    await tester.pump(const Duration(seconds: 1));
    expect(points.length, count);
    motion.dispose();
    expect(motion.isAnimating, isFalse);
  });

  testWidgets('Native map setup failure preserves GPS text and attribution',
      (tester) async {
    const channel = MethodChannel('plugins.flutter.io/maplibre_gl');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'map-unavailable'),
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CustomerTripTrackingMap(
          motionElapsed: () => _elapsed(tester),
          motionNow: () => _wallNow(tester),
          location: CustomerLiveLocation(21.1, 105.1, 4, 90, firstFix),
          connectionState: TripRealtimeConnectionState.failed,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(MapLibreMap), findsNothing);
    expect(find.textContaining('Không thể khởi tạo bản đồ'), findsOneWidget);
    expect(find.textContaining('Vị trí GPS bằng chữ'), findsOneWidget);
    expect(find.text('Vị trí tài xế'), findsOneWidget);
    expect(find.text('Realtime không khả dụng'), findsOneWidget);
    expect(find.textContaining('±4.0 m'), findsOneWidget);
    expect(find.textContaining('OpenFreeMap'), findsOneWidget);
  });

  testWidgets('Only a newer fix updates the mounted tracking map state',
      (tester) async {
    const channel = MethodChannel('plugins.flutter.io/maplibre_gl');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'map-unavailable'),
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));

    Future<void> show(CustomerLiveLocation location) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: CustomerTripTrackingMap(
            motionElapsed: () => _elapsed(tester),
            motionNow: () => _wallNow(tester),
            location: location,
            connectionState: TripRealtimeConnectionState.connected,
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    await show(CustomerLiveLocation(21.1, 105.1, 4, 90, firstFix));
    expect(find.textContaining(firstFix.toLocal().toString()), findsOneWidget);
    await show(CustomerLiveLocation(21.2, 105.2, 3, 95, newerFix));
    expect(find.textContaining(newerFix.toLocal().toString()), findsOneWidget);
    await show(CustomerLiveLocation(21.0, 105.0, 9, 0, firstFix));
    expect(find.textContaining(newerFix.toLocal().toString()), findsOneWidget);
    expect(find.textContaining(firstFix.toLocal().toString()), findsNothing);
  });

  testWidgets('Invalid GPS never creates a native map', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CustomerTripTrackingMap(
          motionElapsed: () => _elapsed(tester),
          motionNow: () => _wallNow(tester),
          location:
              CustomerLiveLocation(double.nan, 105.1, null, null, firstFix),
          connectionState: TripRealtimeConnectionState.disconnected,
        ),
      ),
    ));
    await tester.pump();
    expect(find.byType(MapLibreMap), findsNothing);
    expect(find.textContaining('Chưa có tọa độ GPS hợp lệ'), findsOneWidget);
  });

  testWidgets('Full-bleed map keeps one platform-view state across GPS updates',
      (tester) async {
    const channel = MethodChannel('plugins.flutter.io/maplibre_gl');
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final originalFactory = MapLibrePlatform.createInstance;
    MapLibrePlatform.createInstance = _FakeMapLibrePlatform.new;
    addTearDown(() => MapLibrePlatform.createInstance = originalFactory);
    final positions = <LatLng>[];

    Future<void> show(String bookingId, CustomerLiveLocation location) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox.expand(
            child: CustomerTripTrackingMap(
              motionElapsed: () => _elapsed(tester),
              motionNow: () => _wallNow(tester),
              bookingPublicId: bookingId,
              fullBleed: true,
              location: location,
              connectionState: TripRealtimeConnectionState.connected,
              onVisualPosition: positions.add,
            ),
          ),
        ),
      ));
      await tester.pump();
    }

    await show('booking-a', CustomerLiveLocation(21.1, 105.1, 4, 90, firstFix));
    expect(
        tester
            .widget<CustomerTripTrackingMap>(
                find.byType(CustomerTripTrackingMap))
            .enableMarkerInterpolation,
        isFalse);
    final controller = _RecordingTrackingController();
    final initialMap = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    initialMap.onMapCreated!(controller);
    initialMap.onStyleLoadedCallback!();
    await tester.pump();
    expect(find.textContaining('Nền bản đồ:'), findsOneWidget);
    final mapState = tester.state(find.byType(MapLibreMap));
    final firstCamera = tester
        .widget<MapLibreMap>(find.byType(MapLibreMap))
        .initialCameraPosition!
        .target;
    await show(
        'booking-a', CustomerLiveLocation(21.1001, 105.1001, 3, 95, newerFix));
    expect(positions.last.latitude, closeTo(21.1001, 1e-9));
    final directWrites = positions.length;
    await tester.pump(const Duration(seconds: 1));
    expect(positions, hasLength(directWrites),
        reason: 'Default tracking keeps one direct update per valid fix');
    expect(controller.cameraMoves, 0,
        reason: 'A newer GPS fix must not recenter a panned map');
    await tester.tap(find.text('Tìm tài xế'));
    await tester.pump();
    expect(controller.cameraMoves, 1,
        reason: 'Only the explicit recenter control moves the camera');
    expect(tester.state(find.byType(MapLibreMap)), same(mapState));
    expect(
        tester
            .widget<MapLibreMap>(find.byType(MapLibreMap))
            .initialCameraPosition!
            .target,
        firstCamera,
        reason: 'New GPS does not retarget camera after a user pan');
    expect(find.text('Tìm tài xế'), findsOneWidget);

    await show('booking-b', CustomerLiveLocation(22, 106, 3, 95, newerFix));
    expect(find.byType(MapLibreMap), findsNothing);
    expect(find.textContaining('Phiên theo dõi đã thay đổi'), findsOneWidget);
  });

  testWidgets('Completed trip covers native GPS until removal and keeps route',
      (tester) async {
    const channel = MethodChannel('plugins.flutter.io/maplibre_gl');
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final originalFactory = MapLibrePlatform.createInstance;
    MapLibrePlatform.createInstance = _FakeMapLibrePlatform.new;
    addTearDown(() => MapLibrePlatform.createInstance = originalFactory);
    final route = RoadRoute.fromJson({
      'sourceQuotePublicId': 'quote-a',
      'bookingPublicId': 'booking-a',
      'availability': 'AVAILABLE',
      'geometryFormat': 'GEOJSON_LINESTRING',
      'geometry': {
        'type': 'LineString',
        'coordinates': [
          [105.8524, 21.0287],
          [105.8551, 21.0261],
          [105.8576, 21.0245],
        ],
      },
    });
    final controller = _RecordingTrackingController();
    controller.delayRemoval = Completer<void>();

    Future<void> show(CustomerLiveLocation? location) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox.expand(
            child: CustomerTripTrackingMap(
              motionElapsed: () => _elapsed(tester),
              motionNow: () => _wallNow(tester),
              bookingPublicId: 'booking-a',
              fullBleed: true,
              location: location,
              route: route,
              pickup: const Coordinates(21.0287, 105.8524),
              dropoff: const Coordinates(21.0245, 105.8576),
              connectionState: TripRealtimeConnectionState.connected,
            ),
          ),
        ),
      ));
      await tester.pump();
    }

    await show(CustomerLiveLocation(21.03, 105.85, 4, 90, firstFix));
    final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    map.onMapCreated!(controller);
    map.onStyleLoadedCallback!();
    await tester.pump();
    await tester.pump();
    expect(controller.circles, hasLength(3));
    expect(controller.lines, hasLength(1));
    final mapState = tester.state(find.byType(MapLibreMap));

    await show(null);
    expect(find.text('Tìm tài xế'), findsNothing);
    expect(
        find.byWidgetPredicate((widget) =>
            widget is ColoredBox && widget.color == const Color(0xFFF8F9FA)),
        findsOneWidget,
        reason: 'Native GPS must be hidden while removeCircle is pending');
    expect(controller.removalStarted.isCompleted, isTrue);
    expect(tester.state(find.byType(MapLibreMap)), same(mapState));

    controller.delayRemoval!.complete();
    await tester.pump();
    await tester.pump();
    expect(
        find.byWidgetPredicate((widget) =>
            widget is ColoredBox && widget.color == const Color(0xFFF8F9FA)),
        findsNothing);
    expect(controller.circles, hasLength(2));
    expect(controller.lines, hasLength(1));
    expect(tester.state(find.byType(MapLibreMap)), same(mapState));
  });

  testWidgets('Static marker redraw leaves exactly one native direction arrow',
      (tester) async {
    _installFakeMapLibre(tester);
    final controller = _RecordingTrackingController();
    final fix = CustomerLiveLocation(21.03, 105.85, 4, 90, firstFix);

    Future<void> show(Coordinates pickup, Coordinates dropoff) async {
      await _showNativeTrackingMap(tester,
          location: fix, pickup: pickup, dropoff: dropoff);
    }

    await show(const Coordinates(21.0287, 105.8524),
        const Coordinates(21.0245, 105.8576));
    final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    expect(map.annotationOrder, contains(AnnotationType.symbol));
    map.onMapCreated!(controller);
    map.onStyleLoadedCallback!();
    await _flushNativeWrites(tester);
    expect(controller.symbols, hasLength(1));
    expect(controller.circles, hasLength(3));
    final mapState = tester.state(find.byType(MapLibreMap));

    await show(const Coordinates(21.029, 105.853),
        const Coordinates(21.0245, 105.8576));
    await _flushNativeWrites(tester);
    expect(controller.symbols, hasLength(1));
    await show(
        const Coordinates(21.029, 105.853), const Coordinates(21.025, 105.858));
    await _flushNativeWrites(tester);
    expect(controller.symbols, hasLength(1));
    expect(controller.symbolAdds, 3);
    expect(controller.symbolClears, greaterThanOrEqualTo(3));
    expect(controller.circles, hasLength(3));
    expect(tester.state(find.byType(MapLibreMap)), same(mapState));
    expect(controller.cameraMoves, 0);
  });

  testWidgets(
      'New GPS fixes update arrow position and bearing without duplicates',
      (tester) async {
    _installFakeMapLibre(tester);
    final controller = _RecordingTrackingController();
    final first = CustomerLiveLocation(21.03, 105.85, 4, 90, firstFix);
    final next = CustomerLiveLocation(21.0301, 105.8501, 4, 145, newerFix);
    await _showNativeTrackingMap(tester, location: first);
    final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    map.onMapCreated!(controller);
    map.onStyleLoadedCallback!();
    await _flushNativeWrites(tester);
    expect(controller.symbols.single.options.textRotate, 90);

    await _showNativeTrackingMap(tester, location: next);
    await _flushNativeWrites(tester);
    expect(controller.symbols, hasLength(1));
    expect(controller.symbolAdds, 1);
    expect(controller.symbolUpdates, greaterThan(0));
    expect(controller.symbols.single.options.geometry,
        const LatLng(21.0301, 105.8501));
    expect(controller.symbols.single.options.textRotate, 145);
    expect(controller.cameraMoves, 0);

    await _showNativeTrackingMap(tester,
        location: CustomerLiveLocation(21.0302, 105.8502, 4, null,
            newerFix.add(const Duration(seconds: 5))));
    await _flushNativeWrites(tester);
    expect(controller.symbols, isEmpty);
    expect(controller.symbolRemovals, 1);
    expect(controller.circles, hasLength(1));
  });

  for (final terminal in ['CANCELLED', 'COMPLETED']) {
    testWidgets('$terminal clears an in-flight arrow after static redraw',
        (tester) async {
      _installFakeMapLibre(tester);
      final controller = _RecordingTrackingController();
      final fix = CustomerLiveLocation(21.03, 105.85, 4, 90, firstFix);
      await _showNativeTrackingMap(tester,
          location: fix, pickup: const Coordinates(21.0287, 105.8524));
      final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
      map.onMapCreated!(controller);
      map.onStyleLoadedCallback!();
      await _flushNativeWrites(tester);
      expect(controller.symbols, hasLength(1));

      controller.delaySymbolAddition = Completer<void>();
      await _showNativeTrackingMap(tester,
          location: fix, pickup: const Coordinates(21.029, 105.853));
      await _flushNativeWrites(tester);
      expect(controller.symbolAdditionStarted.isCompleted, isTrue);
      expect(controller.symbols, isEmpty,
          reason: 'Static redraw must clear the prior native arrow');

      // The parent passes no GPS for either terminal Booking status.
      await _showNativeTrackingMap(tester,
          location: null, pickup: const Coordinates(21.029, 105.853));
      expect(
          find.byWidgetPredicate((widget) =>
              widget is ColoredBox && widget.color == const Color(0xFFF8F9FA)),
          findsOneWidget,
          reason: 'Native annotations stay covered until deletion completes');
      controller.delaySymbolAddition!.complete();
      await _flushNativeWrites(tester);
      expect(controller.symbols, isEmpty);
      expect(controller.symbolRemovals, 1,
          reason: 'A late native add is removed as soon as it returns');
      expect(controller.circles, hasLength(1));
      expect(controller.symbolClears, greaterThanOrEqualTo(2));
      expect(
          find.byWidgetPredicate((widget) =>
              widget is ColoredBox && widget.color == const Color(0xFFF8F9FA)),
          findsNothing);
      expect(controller.cameraMoves, 0);
    });
  }

  testWidgets(
      'Style reload rebuilds one arrow and disposal stops queued writes',
      (tester) async {
    _installFakeMapLibre(tester);
    final controller = _RecordingTrackingController();
    final fix = CustomerLiveLocation(21.03, 105.85, 4, 90, firstFix);
    await _showNativeTrackingMap(tester,
        location: fix, pickup: const Coordinates(21.0287, 105.8524));
    final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    map.onMapCreated!(controller);
    map.onStyleLoadedCallback!();
    await _flushNativeWrites(tester);
    expect(controller.symbols, hasLength(1));

    controller.simulateStyleReload();
    map.onStyleLoadedCallback!();
    await _flushNativeWrites(tester);
    expect(controller.symbols, hasLength(1));
    expect(controller.symbolAdds, 2);

    controller.delaySymbolAddition = Completer<void>();
    await _showNativeTrackingMap(tester,
        location: fix, pickup: const Coordinates(21.029, 105.853));
    await _flushNativeWrites(tester);
    expect(controller.symbolAdditionStarted.isCompleted, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.simulateNativeDisposal();
    final addsAtDisposal = controller.symbolAdds;
    controller.delaySymbolAddition!.complete();
    await _flushNativeWrites(tester);
    expect(controller.symbols, isEmpty);
    expect(controller.symbolAdds, addsAtDisposal);
    expect(controller.symbolUpdates, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Pause, style reload and disposal stop in-flight marker motion',
      (tester) async {
    const channel = MethodChannel('plugins.flutter.io/maplibre_gl');
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final originalFactory = MapLibrePlatform.createInstance;
    MapLibrePlatform.createInstance = _FakeMapLibrePlatform.new;
    addTearDown(() => MapLibrePlatform.createInstance = originalFactory);
    final positions = <LatLng>[];
    final thirdFix = newerFix.add(const Duration(seconds: 5));

    Future<void> show(CustomerLiveLocation location) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox.expand(
            child: CustomerTripTrackingMap(
              motionElapsed: () => _elapsed(tester),
              bookingPublicId: 'booking-a',
              fullBleed: true,
              enableMarkerInterpolation: true,
              location: location,
              connectionState: TripRealtimeConnectionState.connected,
              motionNow: () => thirdFix.add(const Duration(seconds: 1)),
              onVisualPosition: positions.add,
            ),
          ),
        ),
      ));
      await tester.pump();
    }

    await show(CustomerLiveLocation(21.1, 105.1, 4, 90, firstFix));
    tester
        .widget<MapLibreMap>(find.byType(MapLibreMap))
        .onStyleLoadedCallback!();
    await tester.pump();
    await show(CustomerLiveLocation(21.1001, 105.1001, 3, 95, newerFix));
    await tester.pump(CustomerMarkerMotion.tick);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(positions.last.latitude, 21.1001);
    final afterPause = positions.length;
    await tester.pump(const Duration(seconds: 1));
    expect(positions.length, afterPause);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await show(CustomerLiveLocation(21.1002, 105.1002, 3, 95, thirdFix));
    await tester.pump(CustomerMarkerMotion.tick);
    tester
        .widget<MapLibreMap>(find.byType(MapLibreMap))
        .onStyleLoadedCallback!();
    await tester.pump();
    expect(positions.last.latitude, 21.1002);
    final afterStyle = positions.length;
    await tester.pump(const Duration(seconds: 1));
    expect(positions.length, afterStyle);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(positions.length, afterStyle);
  });
  testWidgets(
      'GPS expires at 20s without a frame and keeps native map and route',
      (tester) async {
    _installFakeMapLibre(tester);
    final stamp = _wallNow(tester);
    final route = RoadRoute.fromJson({
      'sourceQuotePublicId': 'quote-a',
      'bookingPublicId': 'booking-a',
      'availability': 'AVAILABLE',
      'geometryFormat': 'GEOJSON_LINESTRING',
      'geometry': {
        'type': 'LineString',
        'coordinates': [
          [105.85, 21.03],
          [105.86, 21.04]
        ]
      },
    });
    final stale = <bool>[];
    await _showNativeTrackingMap(tester,
        location: CustomerLiveLocation(21.03, 105.85, 4, 90, stamp),
        route: route,
        onStale: stale.add);
    final native = tester.state(find.byType(MapLibreMap));
    final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    final controller = _RecordingTrackingController();
    map.onMapCreated!(controller);
    map.onStyleLoadedCallback!();
    await _flushNativeWrites(tester);
    expect(controller.circles, hasLength(1));
    await tester.pump(const Duration(seconds: 19));
    expect(controller.circles, hasLength(1));
    await tester.pump(const Duration(seconds: 1));
    await _flushNativeWrites(tester);
    expect(controller.circles, isEmpty);
    expect(controller.symbols, isEmpty);
    expect(controller.circleRemovals, 1);
    expect(controller.lines, hasLength(1));
    expect(stale.last, isTrue);
    expect(find.text('Vị trí tài xế chưa được cập nhật.'), findsOneWidget);
    expect(find.text('Tìm tài xế'), findsNothing);
    expect(tester.state(find.byType(MapLibreMap)), same(native));
    controller.simulateStyleReload();
    map.onStyleLoadedCallback!();
    await _flushNativeWrites(tester);
    expect(controller.circles, isEmpty);
    expect(controller.symbols, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final scenario in [
    ('tablet portrait', const Size(800, 1280), 1.0),
    ('tablet landscape', const Size(1280, 800), 1.0),
    ('small phone', const Size(320, 568), 1.0),
    ('small phone 200% text', const Size(320, 568), 2.0),
    ('small phone 300% text', const Size(320, 568), 3.0),
  ]) {
    testWidgets(
        'Compact GPS warning fits ${scenario.$1} and clears on fresh GPS',
        (tester) async {
      tester.view.physicalSize = scenario.$2;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      _installFakeMapLibre(tester);
      const message = 'Vị trí tài xế chưa được cập nhật.';
      final warning = find.byKey(const ValueKey('customer-gps-stale-warning'));
      final route = _warningTestRoute();
      await _showNativeTrackingMap(tester,
          location:
              CustomerLiveLocation(21.03, 105.85, 4, 90, _wallNow(tester)),
          route: route,
          theme: AppTheme.light,
          textScale: scenario.$3);
      final native = tester.state(find.byType(MapLibreMap));
      final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
      map.onMapCreated!(_RecordingTrackingController());
      map.onStyleLoadedCallback!();
      await _flushNativeWrites(tester);
      expect(warning, findsNothing);

      await tester.pump(CustomerLiveLocation.displayTtl);
      await _flushNativeWrites(tester);
      expect(warning, findsOneWidget);
      expect(find.text(message), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
      final mapRect = tester.getRect(find.byType(MapLibreMap));
      final warningRect = tester.getRect(warning);
      expect(warningRect.left, closeTo(mapRect.left + 12, .1));
      expect(warningRect.top, greaterThanOrEqualTo(mapRect.top + 112));
      expect(warningRect.right, lessThanOrEqualTo(mapRect.right - 12));
      expect(warningRect.bottom, lessThanOrEqualTo(mapRect.bottom));
      if (scenario.$2.width >= 800) {
        expect(warningRect.width, closeTo(scenario.$2.width * .25, .1));
      }
      final routeButton = find.ancestor(
          of: find.text('Xem tuyến'), matching: find.byType(TextButton));
      expect(routeButton.hitTestable(), findsOneWidget);
      expect(warningRect.overlaps(tester.getRect(routeButton)), isFalse);
      expect(
          warningRect.overlaps(
              tester.getRect(find.text(CustomerMapSource.visibleAttribution))),
          isFalse);
      final paragraph =
          tester.renderObject<RenderParagraph>(find.text(message));
      final text = TextPainter(
          text: paragraph.text,
          textDirection: TextDirection.ltr,
          textScaler: TextScaler.linear(scenario.$3))
        ..layout(maxWidth: paragraph.size.width);
      expect(text.computeLineMetrics().length, lessThanOrEqualTo(3),
          reason: 'The whole message must fit without truncation.');
      text.dispose();
      expect(tester.takeException(), isNull);

      await _showNativeTrackingMap(tester,
          location:
              CustomerLiveLocation(21.0301, 105.8501, 4, 95, _wallNow(tester)),
          route: route,
          theme: AppTheme.light,
          textScale: scenario.$3);
      await _flushNativeWrites(tester);
      expect(warning, findsNothing);
      expect(tester.state(find.byType(MapLibreMap)), same(native));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('Compact GPS warning passes taps and drags through to the map',
      (tester) async {
    _installFakeMapLibre(tester);
    var taps = 0;
    var drags = 0;
    MapLibrePlatform.createInstance =
        () => _InteractiveTrackingPlatform(() => taps++, (_) => drags++);
    await _showNativeTrackingMap(tester,
        location: CustomerLiveLocation(21.03, 105.85, 4, 90, _wallNow(tester)),
        route: _warningTestRoute());
    final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    final controller = _RecordingTrackingController();
    map.onMapCreated!(controller);
    map.onStyleLoadedCallback!();
    await _flushNativeWrites(tester);
    await tester.pump(CustomerLiveLocation.displayTtl);
    await _flushNativeWrites(tester);
    final warning = find.byKey(const ValueKey('customer-gps-stale-warning'));
    final center = tester.getCenter(warning);
    await tester.tapAt(center);
    expect(taps, 1);
    await tester.dragFrom(center, const Offset(0, 40));
    expect(drags, greaterThan(0));
    final cameraMoves = controller.cameraMoves;
    await tester.tap(find.text('Xem tuyến'));
    await tester.pump();
    expect(controller.cameraMoves, cameraMoves + 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('New fix replaces the deadline and the old timer cannot erase it',
      (tester) async {
    _installFakeMapLibre(tester);
    final first = CustomerLiveLocation(21.03, 105.85, 4, 90, _wallNow(tester));
    await _showNativeTrackingMap(tester, location: first);
    final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    final controller = _RecordingTrackingController();
    map.onMapCreated!(controller);
    map.onStyleLoadedCallback!();
    await _flushNativeWrites(tester);
    await tester.pump(const Duration(seconds: 10));
    await _showNativeTrackingMap(tester,
        location:
            CustomerLiveLocation(21.0301, 105.8501, 4, 95, _wallNow(tester)));
    await tester.pump(const Duration(seconds: 10));
    await _flushNativeWrites(tester);
    expect(controller.circles, hasLength(1));
    expect(find.text('Vị trí tài xế chưa được cập nhật.'), findsNothing);
    await tester.pump(const Duration(seconds: 10));
    await _flushNativeWrites(tester);
    expect(controller.circles, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Unknown or over-100m accuracy cannot start interpolation',
      (tester) async {
    for (final accuracy in <double?>[null, 101]) {
      final points = <LatLng>[];
      final first = CustomerLiveLocation(21.03, 105.85, 4, 90, firstFix);
      final next =
          CustomerLiveLocation(21.0301, 105.8501, accuracy, 95, newerFix);
      final motion = CustomerMarkerMotion(
          onPosition: points.add,
          now: () => newerFix,
          elapsed: () => _elapsed(tester));
      motion.accept(first, animate: false);
      motion.accept(next, animate: true);
      expect(motion.isAnimating, isFalse);
      expect(points.last, const LatLng(21.0301, 105.8501));
      motion.dispose();
      expect(
          CustomerMarkerMotion.canInterpolate(
              next,
              CustomerLiveLocation(21.0302, 105.8502, 4, 95,
                  newerFix.add(const Duration(seconds: 1))),
              newerFix.add(const Duration(seconds: 1))),
          isFalse);
    }
  });

  testWidgets('A delayed tick uses elapsed time and lands on the real endpoint',
      (tester) async {
    var elapsed = Duration.zero;
    final points = <LatLng>[];
    final motion = CustomerMarkerMotion(
        onPosition: points.add, now: () => newerFix, elapsed: () => elapsed);
    motion.accept(CustomerLiveLocation(21.03, 105.85, 4, 350, firstFix),
        animate: false);
    motion.accept(CustomerLiveLocation(21.0301, 105.8501, 4, 10, newerFix),
        animate: true);
    elapsed = const Duration(milliseconds: 900);
    await tester.pump(CustomerMarkerMotion.tick);
    expect(points, hasLength(2));
    expect(points.last, const LatLng(21.0301, 105.8501));
    expect(motion.isAnimating, isFalse);
    await tester.pump(const Duration(seconds: 1));
    expect(points, hasLength(2));
    motion.dispose();
  });

  testWidgets('Retarget keeps the currently rendered bearing on the short arc',
      (tester) async {
    final headings = <double?>[];
    final points = <LatLng>[];
    final motion = CustomerMarkerMotion(
        onPosition: points.add,
        onBearing: headings.add,
        now: () => newerFix.add(const Duration(seconds: 5)),
        elapsed: () => _elapsed(tester));
    motion.accept(CustomerLiveLocation(21.03, 105.85, 4, 350, firstFix),
        animate: false);
    motion.accept(CustomerLiveLocation(21.0301, 105.8501, 4, 10, newerFix),
        animate: true);
    await tester.pump(CustomerMarkerMotion.tick);
    final visual = points.last;
    final bearing = headings.last;
    motion.accept(
        CustomerLiveLocation(
            21.0302, 105.8502, 4, 20, newerFix.add(const Duration(seconds: 5))),
        animate: true);
    expect(points.last, visual);
    expect(headings.last, bearing);
    await tester.pump(CustomerMarkerMotion.duration);
    expect(headings.last, 20);
    expect(points.last, const LatLng(21.0302, 105.8502));
    motion.dispose();
  });

  testWidgets(
      'Stationary heading writes only symbol; identical samples write nothing',
      (tester) async {
    _installFakeMapLibre(tester);
    final stamp = _wallNow(tester);
    await _showNativeTrackingMap(tester,
        location: CustomerLiveLocation(21.03, 105.85, 4, 90, stamp));
    final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    final controller = _RecordingTrackingController();
    map.onMapCreated!(controller);
    map.onStyleLoadedCallback!();
    await _flushNativeWrites(tester);
    await _showNativeTrackingMap(tester,
        location: CustomerLiveLocation(
            21.03, 105.85, 4, 95, stamp.add(const Duration(seconds: 1))));
    await _flushNativeWrites(tester);
    expect(controller.circleUpdates, 0);
    expect(controller.symbolUpdates, 1);
    await _showNativeTrackingMap(tester,
        location: CustomerLiveLocation(
            21.03, 105.85, 4, 95, stamp.add(const Duration(seconds: 2))));
    await _flushNativeWrites(tester);
    expect(controller.circleUpdates, 0);
    expect(controller.symbolUpdates, 1);
    await _showNativeTrackingMap(tester,
        location: CustomerLiveLocation(
            21.03, 105.85, 4, null, stamp.add(const Duration(seconds: 3))));
    await _flushNativeWrites(tester);
    expect(controller.circleUpdates, 0);
    expect(controller.symbolRemovals, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Burst GPS is latest-wins with one native operation in flight',
      (tester) async {
    _installFakeMapLibre(tester);
    final stamp = _wallNow(tester).subtract(const Duration(seconds: 10));
    await _showNativeTrackingMap(tester,
        location: CustomerLiveLocation(21.03, 105.85, 4, 90, stamp));
    final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    final controller = _RecordingTrackingController();
    map.onMapCreated!(controller);
    map.onStyleLoadedCallback!();
    await _flushNativeWrites(tester);
    controller.delayCircleUpdate = Completer<void>();
    for (var i = 1; i <= 100; i++) {
      await _showNativeTrackingMap(tester,
          location: CustomerLiveLocation(21.03 + i * .000001, 105.85, 4, 90,
              stamp.add(Duration(milliseconds: i * 10))));
    }
    expect(controller.circleUpdates, 1);
    controller.delayCircleUpdate!.complete();
    await _flushNativeWrites(tester);
    expect(controller.circleUpdates, lessThanOrEqualTo(2));
    expect(controller.symbolUpdates, lessThanOrEqualTo(2));
    expect(controller.circleAdds, 1);
    expect(controller.symbolAdds, 1);
    expect(controller.circles.single.options.geometry!.latitude,
        closeTo(21.0301, 1e-9));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'Expiry covers a late addSymbol until every GPS annotation is removed',
      (tester) async {
    _installFakeMapLibre(tester);
    final stamp = _wallNow(tester);
    await _showNativeTrackingMap(tester,
        location: CustomerLiveLocation(21.03, 105.85, 4, 90, stamp));
    final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    final controller = _RecordingTrackingController()
      ..delaySymbolAddition = Completer<void>();
    map.onMapCreated!(controller);
    map.onStyleLoadedCallback!();
    await _flushNativeWrites(tester);
    expect(controller.symbolAdditionStarted.isCompleted, isTrue);
    await tester.pump(CustomerLiveLocation.displayTtl);
    expect(find.byWidgetPredicate((w) => w is AbsorbPointer && w.absorbing),
        findsOneWidget);
    controller.delaySymbolAddition!.complete();
    await _flushNativeWrites(tester);
    expect(controller.symbols, isEmpty);
    expect(controller.circles, isEmpty);
    expect(controller.symbolRemovals, 1);
    expect(find.byWidgetPredicate((w) => w is AbsorbPointer && w.absorbing),
        findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Resume after TTL hides old GPS and a new fix does not replay it',
      (tester) async {
    _installFakeMapLibre(tester);
    final stamp = _wallNow(tester);
    await _showNativeTrackingMap(tester,
        location: CustomerLiveLocation(21.03, 105.85, 4, 90, stamp),
        interpolation: true);
    final native = tester.state(find.byType(MapLibreMap));
    final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    final controller = _RecordingTrackingController();
    map.onMapCreated!(controller);
    map.onStyleLoadedCallback!();
    await _flushNativeWrites(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 30));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _flushNativeWrites(tester);
    expect(controller.circles, isEmpty);
    await _showNativeTrackingMap(tester,
        location:
            CustomerLiveLocation(21.0301, 105.8501, 4, 95, _wallNow(tester)),
        interpolation: true);
    await _flushNativeWrites(tester);
    expect(controller.circles.single.options.geometry,
        const LatLng(21.0301, 105.8501));
    final writes = controller.circleUpdates;
    await tester.pump(CustomerMarkerMotion.duration);
    expect(controller.circleUpdates, writes);
    expect(tester.state(find.byType(MapLibreMap)), same(native));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'Flag true animates a reliable pair without remounting or camera moves',
      (tester) async {
    _installFakeMapLibre(tester);
    final stamp = _wallNow(tester);
    await _showNativeTrackingMap(tester,
        location: CustomerLiveLocation(
            21.03, 105.85, 4, 350, stamp.subtract(const Duration(seconds: 5))),
        interpolation: true);
    final native = tester.state(find.byType(MapLibreMap));
    final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    final controller = _RecordingTrackingController();
    map.onMapCreated!(controller);
    map.onStyleLoadedCallback!();
    await _flushNativeWrites(tester);
    await _showNativeTrackingMap(tester,
        location: CustomerLiveLocation(21.0301, 105.8501, 4, 10, stamp),
        interpolation: true);
    expect(controller.circleUpdates, 0);
    await tester.pump(CustomerMarkerMotion.tick);
    await _flushNativeWrites(tester);
    expect(controller.circles.single.options.geometry!.latitude,
        inExclusiveRange(21.03, 21.0301));
    await tester.pump(CustomerMarkerMotion.duration);
    await _flushNativeWrites(tester);
    expect(controller.circles.single.options.geometry,
        const LatLng(21.0301, 105.8501));
    expect(controller.symbols.single.options.textRotate, 10);
    expect(controller.circleUpdates, lessThanOrEqualTo(3));
    expect(controller.cameraMoves, 0);
    expect(tester.state(find.byType(MapLibreMap)), same(native));
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
      'Failed expiry deletion keeps the privacy cover without a retry loop',
      (tester) async {
    _installFakeMapLibre(tester);
    final stamp = _wallNow(tester);
    await _showNativeTrackingMap(tester,
        location: CustomerLiveLocation(21.03, 105.85, 4, 90, stamp));
    final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    final controller = _RecordingTrackingController();
    map.onMapCreated!(controller);
    map.onStyleLoadedCallback!();
    await _flushNativeWrites(tester);
    controller.failSymbolClear = true;
    await tester.pump(CustomerLiveLocation.displayTtl);
    await _flushNativeWrites(tester);
    expect(find.byWidgetPredicate((w) => w is AbsorbPointer && w.absorbing),
        findsOneWidget);
    final clears = controller.symbolClears;
    await tester.pump(const Duration(seconds: 1));
    expect(controller.symbolClears, clears);
    controller.failSymbolClear = false;
    controller.simulateStyleReload();
    map.onStyleLoadedCallback!();
    await _flushNativeWrites(tester);
    expect(controller.circles, isEmpty);
    expect(controller.symbols, isEmpty);
    expect(find.byWidgetPredicate((w) => w is AbsorbPointer && w.absorbing),
        findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('A future map input cannot poison subsequent normal fixes',
      (tester) async {
    _installFakeMapLibre(tester);
    final stamp = _wallNow(tester);
    await _showNativeTrackingMap(tester,
        location: CustomerLiveLocation(21.03, 105.85, 4, 90, stamp));
    final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    final controller = _RecordingTrackingController();
    map.onMapCreated!(controller);
    map.onStyleLoadedCallback!();
    await _flushNativeWrites(tester);
    await _showNativeTrackingMap(tester,
        location: CustomerLiveLocation(
            22, 106, 4, 90, stamp.add(const Duration(seconds: 6))));
    await _flushNativeWrites(tester);
    expect(controller.circleUpdates, 0);
    await _showNativeTrackingMap(tester,
        location: CustomerLiveLocation(
            21.0301, 105.8501, 4, 95, stamp.add(const Duration(seconds: 1))));
    await _flushNativeWrites(tester);
    expect(controller.circles.single.options.geometry,
        const LatLng(21.0301, 105.8501));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Style reload during expiry cleanup does not strand the cover',
      (tester) async {
    _installFakeMapLibre(tester);
    await _showNativeTrackingMap(tester,
        location: CustomerLiveLocation(21.03, 105.85, 4, 90, _wallNow(tester)));
    final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    final controller = _RecordingTrackingController();
    map.onMapCreated!(controller);
    map.onStyleLoadedCallback!();
    await _flushNativeWrites(tester);
    controller.delayRemoval = Completer<void>();
    await tester.pump(CustomerLiveLocation.displayTtl);
    await _flushNativeWrites(tester);
    expect(controller.removalStarted.isCompleted, isTrue);
    controller.simulateStyleReload();
    map.onStyleLoadedCallback!();
    controller.delayRemoval!.complete();
    await _flushNativeWrites(tester);
    expect(controller.circles, isEmpty);
    expect(controller.symbols, isEmpty);
    expect(find.byWidgetPredicate((w) => w is AbsorbPointer && w.absorbing),
        findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Disposal during radar add stops subsequent native operations',
      (tester) async {
    _installFakeMapLibre(tester);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: CustomerTripTrackingMap(
                location: null,
                pickup: const Coordinates(21.03, 105.85),
                searchingForDriver: true,
                motionNow: () => _wallNow(tester),
                motionElapsed: () => _elapsed(tester),
                connectionState: TripRealtimeConnectionState.connected))));
    await tester.pump();
    final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    final controller = _RecordingTrackingController()
      ..delayRadarAddition = Completer<void>();
    map.onMapCreated!(controller);
    map.onStyleLoadedCallback!();
    await _flushNativeWrites(tester);
    expect(controller.radarAdditionStarted.isCompleted, isTrue);
    final adds = controller.circleAdds;
    await tester.pumpWidget(const SizedBox.shrink());
    controller.simulateNativeDisposal();
    controller.delayRadarAddition!.complete();
    await _flushNativeWrites(tester);
    expect(controller.circleAdds, adds);
    expect(controller.circles, isEmpty);
  });
}

class _FakeMapLibrePlatform extends Fake implements MapLibrePlatform {
  @override
  Widget buildView(
    Map<String, dynamic> creationParams,
    OnPlatformViewCreatedCallback onPlatformViewCreated,
    Set<Factory<OneSequenceGestureRecognizer>>? gestureRecognizers,
  ) =>
      const ColoredBox(color: Colors.white);

  @override
  void dispose() {}
}

class _InteractiveTrackingPlatform extends _FakeMapLibrePlatform {
  _InteractiveTrackingPlatform(this.onTap, this.onPanUpdate);
  final VoidCallback onTap;
  final GestureDragUpdateCallback onPanUpdate;

  @override
  Widget buildView(
          Map<String, dynamic> creationParams,
          OnPlatformViewCreatedCallback onPlatformViewCreated,
          Set<Factory<OneSequenceGestureRecognizer>>? gestureRecognizers) =>
      GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onPanUpdate: onPanUpdate,
        child: const ColoredBox(color: Colors.white),
      );
}

Future<void> _loadTrackingTestFonts() async {
  // Ahem's square glyphs do not represent Android wrapping or accessibility.
  // Use fonts already supplied by Flutter; no downloaded test dependency.
  final sdk = Platform.environment['FLUTTER_ROOT'] ??
      File(Platform.resolvedExecutable)
          .parent
          .parent
          .parent
          .parent
          .parent
          .parent
          .path;
  for (final font in [
    ('Roboto', 'roboto-regular.ttf'),
    ('MaterialIcons', 'materialicons-regular.otf'),
  ]) {
    final file = File.fromUri(Directory(sdk)
        .uri
        .resolve('bin/cache/artifacts/material_fonts/${font.$2}'));
    final loader = FontLoader(font.$1)
      ..addFont(file.readAsBytes().then(ByteData.sublistView));
    await loader.load();
  }
}

RoadRoute _warningTestRoute() => RoadRoute.fromJson({
      'sourceQuotePublicId': 'quote-a',
      'bookingPublicId': 'booking-symbol-lifecycle',
      'availability': 'AVAILABLE',
      'geometryFormat': 'GEOJSON_LINESTRING',
      'geometry': {
        'type': 'LineString',
        'coordinates': [
          [105.85, 21.03],
          [105.86, 21.04]
        ]
      },
    });

void _installFakeMapLibre(WidgetTester tester) {
  const channel = MethodChannel('plugins.flutter.io/maplibre_gl');
  tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (_) async => null);
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));
  final originalFactory = MapLibrePlatform.createInstance;
  MapLibrePlatform.createInstance = _FakeMapLibrePlatform.new;
  addTearDown(() => MapLibrePlatform.createInstance = originalFactory);
}

Future<void> _showNativeTrackingMap(WidgetTester tester,
    {required CustomerLiveLocation? location,
    Coordinates? pickup,
    Coordinates? dropoff,
    RoadRoute? route,
    bool interpolation = false,
    ThemeData? theme,
    double textScale = 1,
    ValueChanged<bool>? onStale}) async {
  await tester.pumpWidget(MaterialApp(
      theme: theme,
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!),
      home: Scaffold(
          body: SizedBox.expand(
              child: CustomerTripTrackingMap(
        motionElapsed: () => _elapsed(tester),
        motionNow: () => _wallNow(tester),
        bookingPublicId: 'booking-symbol-lifecycle',
        fullBleed: true,
        route: route,
        enableMarkerInterpolation: interpolation,
        onGpsStaleChanged: onStale,
        location: location,
        pickup: pickup,
        dropoff: dropoff,
        connectionState: TripRealtimeConnectionState.connected,
      )))));
  await tester.pump();
}

Future<void> _flushNativeWrites(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump();
  }
}

class _RecordingTrackingController extends Fake
    implements MapLibreMapController {
  int cameraMoves = 0;
  int circleUpdates = 0;
  int circleAdds = 0;
  int circleRemovals = 0;
  int circleClears = 0;
  int symbolAdds = 0;
  int symbolUpdates = 0;
  int symbolRemovals = 0;
  int symbolClears = 0;
  bool failSymbolClear = false;
  int _nextCircle = 0;
  int _nextSymbol = 0;
  bool _nativeDisposed = false;
  @override
  final circles = <Circle>{};
  @override
  final symbols = <Symbol>{};
  @override
  final lines = <Line>{};
  Completer<void>? delayRemoval;
  final removalStarted = Completer<void>();
  Completer<void>? delaySymbolAddition;
  final symbolAdditionStarted = Completer<void>();
  Completer<void>? delayCircleUpdate;
  final circleUpdateStarted = Completer<void>();
  Completer<void>? delayRadarAddition;
  final radarAdditionStarted = Completer<void>();

  void simulateStyleReload() {
    circles.clear();
    symbols.clear();
    lines.clear();
  }

  void simulateNativeDisposal() {
    _nativeDisposed = true;
    simulateStyleReload();
  }

  @override
  Future<Symbol> addSymbol(SymbolOptions options,
      [Map<String, dynamic>? data]) async {
    final symbol = Symbol('symbol-${_nextSymbol++}', options, data);
    symbolAdds++;
    if (delaySymbolAddition != null) {
      if (!symbolAdditionStarted.isCompleted) symbolAdditionStarted.complete();
      await delaySymbolAddition!.future;
    }
    if (!_nativeDisposed) symbols.add(symbol);
    return symbol;
  }

  @override
  Future<void> updateSymbol(Symbol symbol, SymbolOptions changes) async {
    symbol.options = symbol.options.copyWith(changes);
    symbolUpdates++;
  }

  @override
  Future<void> removeSymbol(Symbol symbol) async {
    symbolRemovals++;
    symbols.remove(symbol);
  }

  @override
  Future<void> clearSymbols() async {
    symbolClears++;
    if (failSymbolClear) throw StateError('native clear failed');
    symbols.clear();
  }

  @override
  Future<Circle> addCircle(CircleOptions options,
      [Map<String, dynamic>? data]) async {
    final circle = Circle('circle-${_nextCircle++}', options, data);
    circleAdds++;
    if (options.circleOpacity == .12 && delayRadarAddition != null) {
      if (!radarAdditionStarted.isCompleted) radarAdditionStarted.complete();
      await delayRadarAddition!.future;
    }
    if (!_nativeDisposed) circles.add(circle);
    return circle;
  }

  @override
  Future<void> clearCircles() async {
    circleClears++;
    circles.clear();
  }

  @override
  Future<void> removeCircle(Circle circle) async {
    circleRemovals++;
    if (!removalStarted.isCompleted) removalStarted.complete();
    await delayRemoval?.future;
    circles.remove(circle);
  }

  @override
  Future<void> clearLines() async => lines.clear();

  @override
  Future<Line> addLine(LineOptions options,
      [Map<String, dynamic>? data]) async {
    final line = Line('line-1', options, data);
    lines.add(line);
    return line;
  }

  @override
  Future<void> updateCircle(Circle circle, CircleOptions changes) async {
    circleUpdates++;
    if (!circleUpdateStarted.isCompleted) circleUpdateStarted.complete();
    await delayCircleUpdate?.future;
    if (!_nativeDisposed) circle.options = circle.options.copyWith(changes);
  }

  @override
  Future<bool?> animateCamera(CameraUpdate cameraUpdate,
      {Duration? duration}) async {
    cameraMoves++;
    return true;
  }
}
