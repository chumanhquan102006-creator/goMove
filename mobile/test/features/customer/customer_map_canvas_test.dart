import 'dart:math' show Point;

import 'package:flutter/foundation.dart' show Factory;
import 'package:flutter/gestures.dart' show OneSequenceGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gomove_mobile/features/customer/domain/models/quote.dart';
import 'package:gomove_mobile/features/customer/presentation/screens/customer_map_canvas.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

void main() {
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
