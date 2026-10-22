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
}
