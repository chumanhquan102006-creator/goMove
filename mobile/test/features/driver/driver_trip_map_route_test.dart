import 'package:flutter/foundation.dart' show Factory;
import 'package:flutter/gestures.dart' show OneSequenceGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gomove_mobile/features/driver/domain/models/driver_models.dart';
import 'package:gomove_mobile/features/driver/presentation/screens/driver_trip_map.dart';
import 'package:gomove_mobile/features/trip/domain/models/road_route.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

void main() {
  testWidgets(
      'Assigned Driver route adds a street line without remount or camera follow',
      (tester) async {
    const channel = MethodChannel('plugins.flutter.io/maplibre_gl');
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final originalFactory = MapLibrePlatform.createInstance;
    MapLibrePlatform.createInstance = _FakeMapLibrePlatform.new;
    addTearDown(() => MapLibrePlatform.createInstance = originalFactory);
    final offer = DriverOffer(
      offerPublicId: 'offer-1',
      bookingPublicId: 'booking-1',
      pickupLatitude: 21.0287,
      pickupLongitude: 105.8524,
      dropoffLatitude: 21.0245,
      dropoffLongitude: 105.8576,
      vehicleType: 'MOTORBIKE',
      currency: 'VND',
      finalFare: '16500',
      expiresAt: DateTime.utc(2026, 10, 16, 10, 0, 15),
    );
    RoadRoute route(List<List<double>> coordinates) => RoadRoute.fromJson({
          'sourceQuotePublicId': 'quote-1',
          'bookingPublicId': 'booking-1',
          'availability': 'AVAILABLE',
          'geometryFormat': 'GEOJSON_LINESTRING',
          'geometry': {'type': 'LineString', 'coordinates': coordinates},
        });
    final valid = route([
      [105.8524, 21.0287],
      [105.8551, 21.0261],
      [105.8576, 21.0245],
    ]);
    final reversed = route([
      [105.8576, 21.0245],
      [105.8551, 21.0261],
      [105.8524, 21.0287],
    ]);
    Future<void> show(RoadRoute? current) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox.expand(
              child: DriverTripMap(offer: offer, route: current)),
        ),
      ));
      await tester.pump();
    }

    await show(null);
    final controller = _RecordingMapController();
    final initial = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    initial.onMapCreated!(controller);
    initial.onStyleLoadedCallback!();
    await tester.pump();
    await tester.pump();
    final mapState = tester.state(find.byType(MapLibreMap));
    expect(controller.recordedCircles, hasLength(2));
    expect(controller.recordedLines, isEmpty);
    final initialCameraMoves = controller.cameraMoves;

    await show(valid);
    await tester.pump();
    expect(tester.state(find.byType(MapLibreMap)), same(mapState));
    expect(controller.recordedCircles, hasLength(2));
    expect(controller.recordedLines, hasLength(1));
    expect(controller.recordedLines.single.geometry![1].latitude, 21.0261);
    expect(controller.recordedLines.single.geometry![1].longitude, 105.8551);
    expect(controller.cameraMoves, initialCameraMoves);

    await show(reversed);
    await tester.pump();
    expect(controller.recordedCircles, hasLength(2));
    expect(controller.recordedLines, isEmpty);
    expect(tester.state(find.byType(MapLibreMap)), same(mapState));
    expect(controller.cameraMoves, initialCameraMoves);
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

class _RecordingMapController extends Fake implements MapLibreMapController {
  final recordedCircles = <CircleOptions>[];
  final recordedLines = <LineOptions>[];
  int cameraMoves = 0;

  @override
  Future<void> clearCircles() async => recordedCircles.clear();

  @override
  Future<Circle> addCircle(CircleOptions options,
      [Map<String, dynamic>? data]) async {
    recordedCircles.add(options);
    return Circle('circle-${recordedCircles.length}', options, data);
  }

  @override
  Future<void> clearLines() async => recordedLines.clear();

  @override
  Future<Line> addLine(LineOptions options,
      [Map<String, dynamic>? data]) async {
    recordedLines.add(options);
    return Line('line-${recordedLines.length}', options, data);
  }

  @override
  Future<bool?> animateCamera(CameraUpdate cameraUpdate,
      {Duration? duration}) async {
    cameraMoves++;
    return true;
  }
}
