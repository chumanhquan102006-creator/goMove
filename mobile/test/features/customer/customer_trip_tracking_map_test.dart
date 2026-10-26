import 'package:flutter/foundation.dart' show Factory;
import 'package:flutter/gestures.dart' show OneSequenceGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gomove_mobile/features/customer/presentation/bloc/booking_status_cubit.dart';
import 'package:gomove_mobile/features/customer/presentation/widgets/customer_trip_tracking_map.dart';
import 'package:gomove_mobile/features/trip/data/trip_realtime_client.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

void main() {
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

  testWidgets('Stationary newer GPS avoids idle marker writes', (tester) async {
    final points = <LatLng>[];
    final first = CustomerLiveLocation(21.1, 105.1, 4, 90, firstFix);
    final stationary = CustomerLiveLocation(21.1, 105.1, 3, 90, newerFix);
    final motion = CustomerMarkerMotion(
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

  testWidgets('Newer fix interrupts interpolation and snaps to latest',
      (tester) async {
    final points = <LatLng>[];
    final first = CustomerLiveLocation(21.1, 105.1, 4, 90, firstFix);
    final newer = CustomerLiveLocation(21.1001, 105.1001, 3, 95, newerFix);
    final latest = CustomerLiveLocation(
        21.1002, 105.1002, 3, 95, newerFix.add(const Duration(seconds: 5)));
    final motion = CustomerMarkerMotion(
        onPosition: points.add,
        now: () => latest.updatedAt.add(const Duration(seconds: 1)));
    addTearDown(motion.dispose);
    motion.accept(first, animate: true);
    motion.accept(newer, animate: true);
    await tester.pump(CustomerMarkerMotion.tick);
    motion.accept(latest, animate: true);
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

class _RecordingTrackingController extends Fake
    implements MapLibreMapController {
  int cameraMoves = 0;

  @override
  Future<Circle> addCircle(CircleOptions options,
          [Map<String, dynamic>? data]) async =>
      Circle('driver-location', options, data);

  @override
  Future<void> updateCircle(Circle circle, CircleOptions changes) async {}

  @override
  Future<bool?> animateCamera(CameraUpdate cameraUpdate,
      {Duration? duration}) async {
    cameraMoves++;
    return true;
  }
}
