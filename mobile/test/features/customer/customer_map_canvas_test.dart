import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gomove_mobile/features/customer/domain/models/quote.dart';
import 'package:gomove_mobile/features/customer/presentation/screens/customer_map_canvas.dart';

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
}

void _ignoreTap(Coordinates _) {}
