import 'dart:async';
import 'dart:math' show Point;

import 'package:flutter/foundation.dart' show Factory;
import 'package:flutter/gestures.dart'
    show
        EagerGestureRecognizer,
        HorizontalDragGestureRecognizer,
        OneSequenceGestureRecognizer,
        TapGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gomove_mobile/features/customer/domain/models/quote.dart';
import 'package:gomove_mobile/features/customer/presentation/screens/customer_map_canvas.dart';
import 'package:gomove_mobile/features/customer/presentation/widgets/customer_map_source.dart';
import 'package:gomove_mobile/features/trip/domain/models/road_route.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

void main() {
  testWidgets('Quote map preview permits vertical page drag and one credit',
      (tester) async {
    const channel = MethodChannel('plugins.flutter.io/maplibre_gl');
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final originalFactory = MapLibrePlatform.createInstance;
    MapLibrePlatform.createInstance = _FakeMapLibrePlatform.new;
    addTearDown(() => MapLibrePlatform.createInstance = originalFactory);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(children: const [
          SizedBox(
            height: 200,
            child: CustomerMapCanvas(
              pickup: Coordinates(21.0287, 105.8524),
              dropoff: Coordinates(21.0245, 105.8576),
              onTap: _ignoreTap,
              fullScreen: true,
              scrollablePreview: true,
            ),
          ),
          SizedBox(height: 900),
        ]),
      ),
    ));
    await tester.pump();
    final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    final gestureTypes = map.gestureRecognizers!.map((e) => e.type).toSet();
    expect(map.trackCameraPosition, isFalse);
    expect(gestureTypes, contains(HorizontalDragGestureRecognizer));
    expect(gestureTypes, contains(TapGestureRecognizer));
    expect(gestureTypes, isNot(contains(EagerGestureRecognizer)));
    expect(find.text(CustomerMapSource.visibleAttribution), findsOneWidget);
    final scrollable =
        tester.state<ScrollableState>(find.byType(Scrollable).first);
    await tester.dragFrom(tester.getCenter(find.byType(CustomerMapCanvas)),
        const Offset(0, -150));
    await tester.pumpAndSettle();
    expect(scrollable.position.pixels, greaterThan(0));
  });

  testWidgets('Map request setup failure keeps coordinate fallback guidance',
      (tester) async {
    const channel = MethodChannel('plugins.flutter.io/maplibre_gl');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'map-unavailable'),
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: CustomerMapCanvas(
          pickup: Coordinates(21.0287, 105.8524),
          dropoff: Coordinates(21.0245, 105.8576),
          onTap: _ignoreTap,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('Không thể khởi tạo bản đồ'), findsOneWidget);
    expect(find.textContaining('nhập tọa độ thủ công'), findsOneWidget);
  });

  testWidgets('Map becomes shorter when keyboard is open on a small screen',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    const channel = MethodChannel('plugins.flutter.io/maplibre_gl');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'map-unavailable'),
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(
          children: const [
            CustomerMapCanvas(
              pickup: Coordinates(21.0287, 105.8524),
              dropoff: Coordinates(21.0245, 105.8576),
              onTap: _ignoreTap,
            )
          ],
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final clip = tester.widget<ClipRRect>(find.descendant(
        of: find.byType(CustomerMapCanvas), matching: find.byType(ClipRRect)));
    expect((clip.child! as SizedBox).height, 170);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('nhập tọa độ thủ công'), findsOneWidget);
  });

  testWidgets('Timed-out map blocks stale clicks until the style loads',
      (tester) async {
    const channel = MethodChannel('plugins.flutter.io/maplibre_gl');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => null,
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    // Avoid a native platform view while exercising the real map callbacks.
    final originalFactory = MapLibrePlatform.createInstance;
    MapLibrePlatform.createInstance = _FakeMapLibrePlatform.new;
    addTearDown(() => MapLibrePlatform.createInstance = originalFactory);

    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CustomerMapCanvas(
          pickup: null,
          dropoff: null,
          onTap: (_) => taps++,
        ),
      ),
    ));
    await tester.pump();

    var map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    map.onMapClick!(const Point(0, 0), const LatLng(21.0287, 105.8524));
    expect(taps, 0, reason: 'No map click is trusted before style load');

    await tester.pump(const Duration(seconds: 12));
    expect(find.text('Nền bản đồ tạm thời không tải được.'), findsOneWidget);
    final blockingOverlay = find.byWidgetPredicate(
        (widget) => widget is AbsorbPointer && widget.absorbing);
    expect(blockingOverlay, findsOneWidget);
    map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    map.onMapClick!(const Point(0, 0), const LatLng(21.0287, 105.8524));
    expect(taps, 0, reason: 'Timed-out map cannot change selected points');

    map.onStyleLoadedCallback!();
    await tester.pump();
    expect(find.text('Nền bản đồ tạm thời không tải được.'), findsNothing);
    expect(blockingOverlay, findsNothing);
    map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    map.onMapClick!(const Point(0, 0), const LatLng(21.0287, 105.8524));
    expect(taps, 1, reason: 'A late valid style restores map selection');
  });

  testWidgets('Known points create markers, never a fabricated road line',
      (tester) async {
    const channel = MethodChannel('plugins.flutter.io/maplibre_gl');
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final originalFactory = MapLibrePlatform.createInstance;
    MapLibrePlatform.createInstance = _FakeMapLibrePlatform.new;
    addTearDown(() => MapLibrePlatform.createInstance = originalFactory);

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: CustomerMapCanvas(
          fullScreen: true,
          pickup: Coordinates(21.0287, 105.8524),
          dropoff: Coordinates(21.0245, 105.8576),
          onTap: _ignoreTap,
        ),
      ),
    ));
    await tester.pump();
    final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    final controller = _RecordingMapController();
    map.onMapCreated!(controller);
    map.onStyleLoadedCallback!();
    await tester.pump();
    await tester.pump();

    expect(controller.recordedCircles, hasLength(2));
    expect(controller.lineCalls, 0);
    expect(find.byType(MapLibreMap), findsOneWidget);
  });

  testWidgets(
      'Authorized road geometry draws in lon/lat order without remount or camera move',
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
      'sourceQuotePublicId': 'quote-1',
      'bookingPublicId': null,
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

    Future<void> show(RoadRoute? currentRoute) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: CustomerMapCanvas(
            fullScreen: true,
            pickup: const Coordinates(21.0287, 105.8524),
            dropoff: const Coordinates(21.0245, 105.8576),
            route: currentRoute,
            onTap: _ignoreTap,
          ),
        ),
      ));
      await tester.pump();
    }

    await show(null);
    final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    final controller = _RecordingMapController();
    map.onMapCreated!(controller);
    map.onStyleLoadedCallback!();
    await tester.pump();
    await tester.pump();
    final nativeState = tester.state(find.byType(MapLibreMap));
    expect(controller.recordedCircles, hasLength(2));
    expect(controller.recordedLines, isEmpty);

    await show(route);
    await tester.pump();
    expect(tester.state(find.byType(MapLibreMap)), same(nativeState));
    expect(controller.recordedCircles, hasLength(2));
    expect(controller.recordedLines, hasLength(1));
    final line = controller.recordedLines.single.geometry!;
    expect(line, hasLength(3));
    expect(line[1].latitude, 21.0261);
    expect(line[1].longitude, 105.8551);
    expect(controller.cameraMoves, 0);

    final reversed = RoadRoute.fromJson({
      'sourceQuotePublicId': 'quote-1',
      'bookingPublicId': null,
      'availability': 'AVAILABLE',
      'geometryFormat': 'GEOJSON_LINESTRING',
      'geometry': {
        'type': 'LineString',
        'coordinates': [
          [105.8576, 21.0245],
          [105.8551, 21.0261],
          [105.8524, 21.0287],
        ],
      },
    });
    await show(reversed);
    await tester.pump();
    expect(controller.recordedLines, isEmpty);
    expect(controller.recordedCircles, hasLength(2));
    expect(tester.state(find.byType(MapLibreMap)), same(nativeState));
    expect(controller.cameraMoves, 0);
    await tester.tap(find.byTooltip('Xem 2 điểm'));
    await tester.pump();
    expect(controller.cameraMoves, 1);
  });

  testWidgets('Fit points respects the visible map height above the keyboard',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    const channel = MethodChannel('plugins.flutter.io/maplibre_gl');
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final originalFactory = MapLibrePlatform.createInstance;
    MapLibrePlatform.createInstance = _FakeMapLibrePlatform.new;
    addTearDown(() => MapLibrePlatform.createInstance = originalFactory);

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: CustomerMapCanvas(
          fullScreen: true,
          pickup: Coordinates(21.0287, 105.8524),
          dropoff: Coordinates(21.0245, 105.8576),
          onTap: _ignoreTap,
        ),
      ),
    ));
    await tester.pump();
    final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    final controller = _RecordingMapController();
    map.onMapCreated!(controller);
    map.onStyleLoadedCallback!();
    await tester.pump();
    await tester.tap(find.byTooltip('Xem 2 điểm'));
    await tester.pump();

    final update = controller.lastCameraUpdate!.toJson() as List<dynamic>;
    final mapHeight = tester.getSize(find.byType(CustomerMapCanvas)).height;
    expect(update.first, 'newLatLngBounds');
    expect(update[5] as double, lessThanOrEqualTo(mapHeight - 160));
    expect((update[3] as double) + (update[5] as double), lessThan(mapHeight));
  });
  testWidgets(
      'Picker projects the visible pin tip using Android DPR and keeps native state',
      (tester) async {
    _mockMapPlatform(tester);
    tester.view.physicalSize = const Size(640, 1280);
    tester.view.devicePixelRatio = 2;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    Future<void> show(CustomerMapPickerBinding? picker) async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: CustomerMapCanvas(
                  pickup: const Coordinates(21.03, 105.85),
                  dropoff: null,
                  onTap: _ignoreTap,
                  fullScreen: true,
                  picker: picker))));
      await tester.pump();
    }

    await show(null);
    final native = tester.state(find.byType(MapLibreMap));
    final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    final controller = _RecordingMapController()..idle = map.onCameraIdle;
    map.onMapCreated!(controller);
    map.onStyleLoadedCallback!();
    await tester.pump();
    final points = <Coordinates>[];
    var unavailable = 0;
    CustomerMapPickerBinding binding(double height) => CustomerMapPickerBinding(
        epoch: 1,
        initialPoint: const Coordinates(21.03, 105.85),
        pickup: true,
        suspended: false,
        panelHeight: height,
        onMoving: (_) {},
        onIdle: (_, point) => points.add(point),
        onUnavailable: () => unavailable++);
    await show(binding(180));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.state(find.byType(MapLibreMap)), same(native));
    final pin = find.byKey(const ValueKey('location-picker-pin'));
    final mapOrigin = tester.getTopLeft(find.byType(MapLibreMap));
    final tip = tester.getTopLeft(pin) + const Offset(20, 48) - mapOrigin;
    expect(controller.lastProjectionPoint!.x, closeTo(tip.dx * 2, .001));
    expect(controller.lastProjectionPoint!.y, closeTo(tip.dy * 2, .001));
    expect(points.last.latitude, 21.04,
        reason: 'Commit source is the pin projection, not the camera target');
    expect(unavailable, 0);
    expect(controller.recordedCircles, isEmpty,
        reason:
            'The edited committed marker is replaced by the fixed preview pin');
    expect(controller.lastPadding!.bottom, 192);
    await show(binding(220));
    await tester.pumpAndSettle();
    expect(controller.lastPadding!.bottom, 232);
    expect(tester.state(find.byType(MapLibreMap)), same(native));
    await show(null);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    expect(controller.lastPadding, EdgeInsets.zero);
    expect(controller.recordedCircles, hasLength(1));
    expect(find.byKey(const ValueKey('location-picker-pin')), findsNothing);
    expect(tester.state(find.byType(MapLibreMap)), same(native));
    await tester.pumpWidget(const SizedBox());
    expect(controller.listeners, isEmpty);
  });

  testWidgets('Late pin projection after cancel cannot update a new epoch',
      (tester) async {
    _mockMapPlatform(tester);
    final events = <int>[];
    Future<void> show(int? epoch) async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: CustomerMapCanvas(
                  pickup: null,
                  dropoff: null,
                  onTap: _ignoreTap,
                  fullScreen: true,
                  picker: epoch == null
                      ? null
                      : CustomerMapPickerBinding(
                          epoch: epoch,
                          initialPoint: const Coordinates(21.03, 105.85),
                          pickup: false,
                          suspended: false,
                          panelHeight: 180,
                          onMoving: (_) {},
                          onIdle: (_, __) => events.add(epoch),
                          onUnavailable: () {})))));
      await tester.pump();
    }

    await show(null);
    final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    final oldProjection = Completer<LatLng>();
    final controller = _RecordingMapController()
      ..idle = map.onCameraIdle
      ..projection = oldProjection;
    map.onMapCreated!(controller);
    map.onStyleLoadedCallback!();
    await tester.pump();
    await show(1);
    await tester.pumpAndSettle();
    expect(events, isEmpty);
    await show(null);
    controller.projection = null;
    await show(2);
    await tester.pumpAndSettle();
    oldProjection.complete(const LatLng(20, 104));
    await tester.pump();
    expect(events, isNotEmpty);
    expect(events.every((epoch) => epoch == 2), isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('Pin projection timeout is unavailable rather than confirmable',
      (tester) async {
    _mockMapPlatform(tester);
    var unavailable = 0;
    var selected = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: CustomerMapCanvas(
                pickup: null,
                dropoff: null,
                onTap: _ignoreTap,
                fullScreen: true,
                picker: CustomerMapPickerBinding(
                    epoch: 1,
                    initialPoint: const Coordinates(21.03, 105.85),
                    pickup: true,
                    suspended: false,
                    panelHeight: 180,
                    onMoving: (_) {},
                    onIdle: (_, __) => selected++,
                    onUnavailable: () => unavailable++)))));
    await tester.pump();
    final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    final pending = Completer<LatLng>();
    final controller = _RecordingMapController()
      ..idle = map.onCameraIdle
      ..projection = pending;
    map.onMapCreated!(controller);
    map.onStyleLoadedCallback!();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
    expect(unavailable, greaterThan(0));
    expect(selected, 0);
    await tester.pumpWidget(const SizedBox());
    pending.complete(const LatLng(21.04, 105.86));
    await tester.pump();
    map.onCameraIdle!();
    map.onCameraMove!(const CameraPosition(target: LatLng(21, 105), zoom: 16));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(selected, 0);
  });

  testWidgets(
      'Animation Future alone cannot authorize a pin; reduced motion is immediate',
      (tester) async {
    _mockMapPlatform(tester);
    var selected = 0;
    await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!),
        home: Scaffold(
            body: CustomerMapCanvas(
                pickup: null,
                dropoff: null,
                onTap: _ignoreTap,
                fullScreen: true,
                picker: CustomerMapPickerBinding(
                    epoch: 1,
                    initialPoint: const Coordinates(21.03, 105.85),
                    pickup: true,
                    suspended: false,
                    panelHeight: 180,
                    onMoving: (_) {},
                    onIdle: (_, __) => selected++,
                    onUnavailable: () {})))));
    await tester.pump();
    final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    final controller = _RecordingMapController();
    map.onMapCreated!(controller);
    map.onStyleLoadedCallback!();
    await tester.pumpAndSettle();
    expect(selected, 0,
        reason: 'A completed move Future is not a camera idle event');
    expect(controller.cameraMoves, 1);
    map.onCameraIdle!();
    await tester.pumpAndSettle();
    expect(selected, 1);
    controller.moving = true;
    map.onCameraMove!(
        const CameraPosition(target: LatLng(21.04, 105.86), zoom: 16));
    await tester.pump();
    final pinMotion = find.descendant(
        of: find.byKey(const ValueKey('location-picker-pin')),
        matching: find.byType(AnimatedSlide));
    expect(tester.widget<AnimatedSlide>(pinMotion).duration, Duration.zero);
    expect(tester.widget<AnimatedSlide>(pinMotion).offset, Offset.zero);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Cancel during the initial camera query always releases the map',
      (tester) async {
    _mockMapPlatform(tester);
    Future<void> show(bool picking) async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: CustomerMapCanvas(
                  pickup: null,
                  dropoff: null,
                  onTap: _ignoreTap,
                  fullScreen: true,
                  picker: !picking
                      ? null
                      : CustomerMapPickerBinding(
                          epoch: 1,
                          initialPoint: const Coordinates(21.03, 105.85),
                          pickup: true,
                          suspended: false,
                          panelHeight: 180,
                          onMoving: (_) {},
                          onIdle: (_, __) {},
                          onUnavailable: () {})))));
      await tester.pump();
    }

    await show(false);
    final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    final pending = Completer<CameraPosition?>();
    final controller = _RecordingMapController()..cameraQuery = pending;
    map.onMapCreated!(controller);
    map.onStyleLoadedCallback!();
    await tester.pump();
    await show(true);
    await tester.pump();
    await show(false);
    pending.complete(
        const CameraPosition(target: LatLng(21.03, 105.85), zoom: 16));
    await tester.pumpAndSettle();
    expect(controller.lastPadding, EdgeInsets.zero);
    expect(
        find.byWidgetPredicate(
            (widget) => widget is AbsorbPointer && widget.absorbing),
        findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}

void _mockMapPlatform(WidgetTester tester) {
  const channel = MethodChannel('plugins.flutter.io/maplibre_gl');
  tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (_) async => null);
  final factory = MapLibrePlatform.createInstance;
  MapLibrePlatform.createInstance = _FakeMapLibrePlatform.new;
  addTearDown(() {
    MapLibrePlatform.createInstance = factory;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
}

void _ignoreTap(Coordinates _) {}

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

class _RecordingMapController extends Fake implements MapLibreMapController {
  final listeners = <VoidCallback>[];
  void Function()? idle;
  Point? lastProjectionPoint;
  EdgeInsets? lastPadding;
  bool moving = false;
  Completer<LatLng>? projection;
  Completer<CameraPosition?>? cameraQuery;

  @override
  void addListener(VoidCallback listener) => listeners.add(listener);
  @override
  void removeListener(VoidCallback listener) => listeners.remove(listener);
  @override
  bool get isCameraMoving => moving;
  @override
  Future<CameraPosition?> queryCameraPosition() async => cameraQuery == null
      ? const CameraPosition(target: LatLng(21.03, 105.85), zoom: 16)
      : await cameraQuery!.future;
  @override
  Future<LatLng> toLatLng(Point location) async {
    lastProjectionPoint = location;
    return projection == null
        ? const LatLng(21.04, 105.86)
        : await projection!.future;
  }

  @override
  Future<void> setPadding(
      {double left = 0,
      double top = 0,
      double right = 0,
      double bottom = 0,
      bool animated = false}) async {
    lastPadding = EdgeInsets.fromLTRB(left, top, right, bottom);
    idle?.call();
  }

  @override
  Future<bool?> moveCamera(CameraUpdate update) async {
    cameraMoves++;
    lastCameraUpdate = update;
    idle?.call();
    return true;
  }

  final recordedCircles = <CircleOptions>[];
  final recordedLines = <LineOptions>[];
  int lineCalls = 0;
  int cameraMoves = 0;
  CameraUpdate? lastCameraUpdate;

  @override
  Future<bool?> animateCamera(CameraUpdate cameraUpdate,
      {Duration? duration}) async {
    cameraMoves++;
    lastCameraUpdate = cameraUpdate;
    idle?.call();
    return true;
  }

  @override
  Future<void> clearCircles() async => recordedCircles.clear();

  @override
  Future<Circle> addCircle(CircleOptions options,
      [Map<String, dynamic>? data]) async {
    recordedCircles.add(options);
    return Circle('test-circle-${recordedCircles.length}', options, data);
  }

  @override
  Future<Line> addLine(LineOptions options,
      [Map<String, dynamic>? data]) async {
    lineCalls++;
    recordedLines.add(options);
    return Line('test-line-$lineCalls', options, data);
  }

  @override
  Future<void> clearLines() async => recordedLines.clear();
}
