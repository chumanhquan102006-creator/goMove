import 'package:bloc_test/bloc_test.dart';
import 'package:gomove_mobile/core/storage/secure_storage_service.dart';
import 'package:gomove_mobile/features/customer/domain/models/place_search_result.dart';
import 'package:gomove_mobile/features/customer/domain/repositories/geocoding_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gomove_mobile/core/theme/app_motion.dart';
import 'package:gomove_mobile/features/customer/domain/models/booking_intent.dart';
import 'package:gomove_mobile/features/customer/domain/models/quote.dart';
import 'package:gomove_mobile/features/customer/presentation/bloc/booking_cubit.dart';
import 'package:gomove_mobile/features/customer/presentation/formatters.dart';
import 'package:gomove_mobile/features/customer/presentation/screens/quote_review_screen.dart';
import 'package:gomove_mobile/features/customer/presentation/screens/customer_map_canvas.dart';
import 'package:gomove_mobile/features/customer/presentation/widgets/customer_map_source.dart';
import 'package:gomove_mobile/features/trip/domain/models/road_route.dart';
import 'package:gomove_mobile/features/trip/domain/repositories/road_route_repository.dart';
import 'package:mocktail/mocktail.dart';

const _quoteId = '550e8400-e29b-41d4-a716-446655440001';
const _pickupCoordinates = 'Vĩ độ 21.0287 · Kinh độ 105.8524';
const _dropoffCoordinates = 'Vĩ độ 21.0245 · Kinh độ 105.8576';

class _MockBookingCubit extends MockCubit<BookingState>
    implements BookingCubit {}

class _Session extends Mock implements SecureStorageService {}

class _Geocoder implements GeocodingRepository {
  Future<PlaceSearchResult?> Function(Coordinates point)? reply;
  int reverseCalls = 0;

  @override
  Future<List<PlaceSearchResult>> search(String query,
          {int? sessionGeneration}) async =>
      const [];

  @override
  Future<PlaceSearchResult?> reverse(Coordinates point,
      {int? sessionGeneration}) {
    reverseCalls++;
    return reply?.call(point) ?? Future.value(null);
  }
}

class _UnavailableRouteRepo implements RoadRouteRepository {
  @override
  Future<RoadRoute> quote(String quotePublicId, int sessionGeneration) async =>
      RoadRoute.fromJson({
        'sourceQuotePublicId': quotePublicId,
        'availability': 'UNAVAILABLE',
      });

  @override
  Future<RoadRoute> booking(String bookingPublicId, int sessionGeneration) =>
      throw UnimplementedError();
}

Quote _quote(DateTime expiresAt) => Quote(
      publicId: _quoteId,
      pickup: const Coordinates(21.0287, 105.8524),
      dropoff: const Coordinates(21.0245, 105.8576),
      vehicleType: VehicleType.motorbike,
      distanceMeters: '1000.111',
      durationSeconds: '300',
      currency: 'VND',
      baseFare: '12000.00',
      distanceFare: '4500.50',
      timeFare: '0.00',
      surcharge: '0.00',
      surgeAmount: '500.00',
      discountAmount: '500.00',
      roundingAdjustment: '-0.50',
      finalFare: '16500.00',
      status: 'ISSUED',
      issuedAt: expiresAt.subtract(const Duration(minutes: 1)),
      expiresAt: expiresAt,
    );

Future<void> _showText(WidgetTester tester, String value) async {
  await tester.scrollUntilVisible(find.text(value), 120,
      scrollable: find.byType(Scrollable).first);
  if (value == 'Chi tiết giá') {
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
  }
  await tester.pumpAndSettle();
}

void main() {
  late _MockBookingCubit cubit;

  setUp(() {
    cubit = _MockBookingCubit();
    when(() => cubit.state).thenReturn(const BookingState());
    when(() => cubit.stream)
        .thenAnswer((_) => const Stream<BookingState>.empty());
    when(() => cubit.submit(any())).thenAnswer((_) async {});
  });

  Widget screen(Quote quote, DateTime Function() now,
          {bool reducedMotion = false,
          GeocodingRepository? geocodingRepository,
          SecureStorageService? addressSession,
          RoadRouteRepository? routeRepository,
          String? pickupLabel,
          String? dropoffLabel}) =>
      MaterialApp(
        builder: (context, child) => reducedMotion
            ? MediaQuery(
                data: MediaQuery.of(context).copyWith(disableAnimations: true),
                child: child!,
              )
            : child!,
        home: BlocProvider<BookingCubit>.value(
            value: cubit,
            child: QuoteReviewScreen(
                quote: quote,
                now: now,
                geocodingRepository: geocodingRepository,
                routeSession: addressSession,
                routeRepository: routeRepository,
                pickupLabel: pickupLabel,
                dropoffLabel: dropoffLabel)),
      );

  testWidgets('Quote shows selected address labels without changing fare',
      (tester) async {
    final now = DateTime.utc(2026, 10, 22, 12);
    final session = _Session();
    final geocoder = _Geocoder();
    when(() => session.getSession()).thenAnswer(
        (_) async => const AuthSessionSnapshot(1, 'access', 'refresh'));
    await tester.pumpWidget(screen(
        _quote(now.add(const Duration(seconds: 60))), () => now,
        geocodingRepository: geocoder,
        addressSession: session,
        pickupLabel: 'Hồ Hoàn Kiếm',
        dropoffLabel: 'Bến xe Mỹ Đình'));
    expect(find.text('Hồ Hoàn Kiếm'), findsOneWidget);
    expect(find.text('Bến xe Mỹ Đình'), findsOneWidget);
    expect(find.text(_pickupCoordinates), findsNothing);
    expect(find.text(_dropoffCoordinates), findsNothing);
    expect(find.text('16.500 VND'), findsOneWidget);
    expect(geocoder.reverseCalls, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'Quote shows actual pickup coordinates when its address is missing',
      (tester) async {
    final now = DateTime.utc(2026, 10, 22, 12);
    await tester.pumpWidget(screen(
        _quote(now.add(const Duration(seconds: 60))), () => now,
        dropoffLabel: 'Bến xe Mỹ Đình'));
    expect(find.text(_pickupCoordinates), findsOneWidget);
    expect(find.text('Bến xe Mỹ Đình'), findsOneWidget);
    expect(find.text(_dropoffCoordinates), findsNothing);
    expect(find.text('Địa chỉ chưa khả dụng'), findsNothing);
  });

  testWidgets(
      'Quote shows actual dropoff coordinates when its address is missing',
      (tester) async {
    final now = DateTime.utc(2026, 10, 22, 12);
    await tester.pumpWidget(screen(
        _quote(now.add(const Duration(seconds: 60))), () => now,
        pickupLabel: 'Hồ Hoàn Kiếm'));
    expect(find.text('Hồ Hoàn Kiếm'), findsOneWidget);
    expect(find.text(_pickupCoordinates), findsNothing);
    expect(find.text(_dropoffCoordinates), findsOneWidget);
    expect(find.text('Địa chỉ chưa khả dụng'), findsNothing);
  });

  testWidgets('Quote shows both actual coordinates without verified addresses',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final now = DateTime.utc(2026, 10, 22, 12);
    await tester.pumpWidget(
        screen(_quote(now.add(const Duration(seconds: 60))), () => now));
    expect(find.text(_pickupCoordinates), findsOneWidget);
    expect(find.text(_dropoffCoordinates), findsOneWidget);
    expect(tester.widget<Text>(find.text(_pickupCoordinates)).maxLines, isNull);
    expect(
        tester.widget<Text>(find.text(_dropoffCoordinates)).maxLines, isNull);
    expect(find.text('Địa chỉ chưa khả dụng'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Quote keeps a long Vietnamese address without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final now = DateTime.utc(2026, 10, 22, 12);
    const longAddress = 'Ngõ 123, Đường Trần Duy Hưng, Phường Trung Hòa, '
        'Quận Cầu Giấy, Thành phố Hà Nội, Việt Nam';
    await tester.pumpWidget(screen(
        _quote(now.add(const Duration(seconds: 60))), () => now,
        pickupLabel: longAddress, dropoffLabel: 'Hồ Hoàn Kiếm'));
    final label = find.text(longAddress);
    expect(label, findsOneWidget);
    expect(tester.widget<Text>(label).maxLines, 2);
    expect(find.text(_pickupCoordinates), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Quote ignores reverse results for different coordinates',
      (tester) async {
    final now = DateTime.utc(2026, 10, 22, 12);
    final session = _Session();
    final geocoder = _Geocoder();
    when(() => session.getSession()).thenAnswer(
        (_) async => const AuthSessionSnapshot(1, 'access', 'refresh'));
    when(() => session.isCurrentSession(1)).thenAnswer((_) async => true);
    geocoder.reply = (point) async => PlaceSearchResult(
        label: point.latitude == 21.0287 ? 'Sai tọa độ' : 'Điểm đến thật',
        coordinates:
            point.latitude == 21.0287 ? const Coordinates(21.0, 105.0) : point);
    await tester.pumpWidget(screen(
        _quote(now.add(const Duration(seconds: 60))), () => now,
        geocodingRepository: geocoder, addressSession: session));
    await tester.pump();
    await tester.pump();
    expect(find.text('Sai tọa độ'), findsNothing);
    expect(find.text('Điểm đến thật'), findsOneWidget);
    expect(find.text(_pickupCoordinates), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Quote hides old address after background and session change',
      (tester) async {
    final now = DateTime.utc(2026, 10, 22, 12);
    final session = _Session();
    final geocoder = _Geocoder();
    var generation = 1;
    when(() => session.getSession()).thenAnswer(
        (_) async => AuthSessionSnapshot(generation, 'access', 'refresh'));
    when(() => session.isCurrentSession(any())).thenAnswer((_) async => true);
    await tester.pumpWidget(screen(
        _quote(now.add(const Duration(seconds: 60))), () => now,
        geocodingRepository: geocoder,
        addressSession: session,
        pickupLabel: 'Điểm đón A'));
    await tester.pump();
    expect(find.text('Điểm đón A'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(find.text('Điểm đón A'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    generation = 2;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.text('Điểm đón A'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('VND groups whole totals and preserves server fractional precision', () {
    expect(vnd('18520.00'), '18.520 VND');
    expect(vnd('3704'), '3.704 VND');
    expect(vnd('4500.50'), '4.500,50 VND');
    expect(vnd('-0.50'), '-0,50 VND');
    expect(vnd('9007199254740993.1250'), '9.007.199.254.740.993,1250 VND');
  });

  testWidgets('Quote highlights server final fare and shows precise lines',
      (tester) async {
    final now = DateTime.utc(2026, 10, 22, 12);
    await tester.pumpWidget(
        screen(_quote(now.add(const Duration(seconds: 60))), () => now));

    expect(find.text('Xe máy'), findsOneWidget);
    expect(find.text('1.00 km'), findsOneWidget);
    expect(find.text('5 phút'), findsOneWidget);
    expect(find.text('16.500 VND'), findsOneWidget);
    await _showText(tester, 'Còn 60 giây để xác nhận');
    expect(find.text('Còn 60 giây để xác nhận'), findsOneWidget);
    await _showText(tester, 'Xác nhận đặt xe');
    expect(find.text('Xác nhận đặt xe'), findsOneWidget);

    await _showText(tester, 'Chi tiết giá');
    await tester.tap(find.text('Chi tiết giá'));
    await tester.pumpAndSettle();
    expect(find.text('Cước theo quãng đường'), findsOneWidget);
    expect(find.text('Cước theo thời gian'), findsOneWidget);
    expect(find.text('Quãng đường'), findsNothing);
    expect(find.text('Thời gian'), findsNothing);
    expect(find.text('4.500,50 VND'), findsOneWidget);
    expect(find.text('-500 VND'), findsOneWidget);
    expect(find.text('-0,50 VND'), findsOneWidget);
    await _showText(tester, 'Xác nhận đặt xe');
    await tester.tap(find.text('Xác nhận đặt xe'));
    verify(() => cubit.submit(_quoteId)).called(1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Countdown reaches strict expiry and offers new Quote',
      (tester) async {
    var now = DateTime.utc(2026, 10, 22, 12);
    final quote = _quote(now.add(const Duration(seconds: 2)));
    await tester.pumpWidget(screen(quote, () => now));
    await _showText(tester, 'Còn 2 giây để xác nhận');
    expect(find.text('Còn 2 giây để xác nhận'), findsOneWidget);

    now = quote.expiresAt;
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Báo giá đã hết hạn'), findsOneWidget);
    await _showText(tester, 'Lấy báo giá mới');
    expect(find.text('Lấy báo giá mới'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Server fare reveals once without submitting a Booking',
      (tester) async {
    final now = DateTime.utc(2026, 10, 22, 12);
    await tester.pumpWidget(
        screen(_quote(now.add(const Duration(seconds: 60))), () => now));

    final reveal = find.byKey(const ValueKey('quote-fare-reveal'));
    expect(tester.widget<AnimatedOpacity>(reveal).opacity, 0);
    expect(tester.widget<AnimatedOpacity>(reveal).duration, AppMotion.card);
    await tester.pump();
    expect(tester.widget<AnimatedOpacity>(reveal).opacity, 1);
    await tester.pump(AppMotion.card);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('16.500 VND'), findsOneWidget);
    verifyNever(() => cubit.submit(any()));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Expiry warning updates at deadline before countdown tick',
      (tester) async {
    var now = DateTime.utc(2026, 10, 22, 12);
    final quote = _quote(now.add(const Duration(milliseconds: 250)));
    await tester.pumpWidget(screen(quote, () => now));
    await _showText(tester, 'Còn 1 giây để xác nhận');
    expect(find.text('Còn 1 giây để xác nhận'), findsOneWidget);

    now = quote.expiresAt;
    await tester.pump(const Duration(milliseconds: 250));
    await _showText(tester, 'Báo giá đã hết hạn');
    expect(find.text('Báo giá đã hết hạn'), findsOneWidget);
    await _showText(tester, 'Lấy báo giá mới');
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    verifyNever(() => cubit.submit(any()));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Tap rechecks strict expiry even before the warning rebuilds',
      (tester) async {
    var now = DateTime.utc(2026, 10, 22, 12);
    final quote = _quote(now.add(const Duration(milliseconds: 500)));
    await tester.pumpWidget(screen(quote, () => now));
    await _showText(tester, 'Xác nhận đặt xe');
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull);

    now = quote.expiresAt;
    await tester.tap(find.text('Xác nhận đặt xe'));
    await tester.pump();
    await _showText(tester, 'Báo giá đã hết hạn');
    expect(find.text('Báo giá đã hết hạn'), findsOneWidget);
    verifyNever(() => cubit.submit(any()));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Reduced motion keeps authoritative fare immediately visible',
      (tester) async {
    final now = DateTime.utc(2026, 10, 22, 12);
    await tester.pumpWidget(screen(
        _quote(now.add(const Duration(seconds: 60))), () => now,
        reducedMotion: true));
    final reveal = tester.widget<AnimatedOpacity>(
        find.byKey(const ValueKey('quote-fare-reveal')));
    expect(reveal.opacity, 1);
    expect(reveal.duration, Duration.zero);
    expect(find.text('16.500 VND'), findsOneWidget);
    verifyNever(() => cubit.submit(any()));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Expired Quote retains same-key Booking retry', (tester) async {
    final now = DateTime.utc(2026, 10, 22, 12);
    when(() => cubit.state).thenReturn(const BookingState(
        pending: BookingIntent(
            customerPublicId: 'customer-id',
            quotePublicId: _quoteId,
            idempotencyKey: 'original-key')));
    await tester.pumpWidget(
        screen(_quote(now.subtract(const Duration(seconds: 1))), () => now));

    await _showText(tester, 'Báo giá đã hết hạn');
    expect(find.text('Báo giá đã hết hạn'), findsOneWidget);
    await _showText(tester, 'Kiểm tra lại yêu cầu đặt xe');
    expect(find.text('Kiểm tra lại yêu cầu đặt xe'), findsOneWidget);
    await tester.tap(find.text('Kiểm tra lại yêu cầu đặt xe'));
    verify(() => cubit.submit(_quoteId)).called(1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Different pending Booking intent blocks new confirmation',
      (tester) async {
    final now = DateTime.utc(2026, 10, 22, 12);
    when(() => cubit.state).thenReturn(const BookingState(
        pending: BookingIntent(
            customerPublicId: 'customer-id',
            quotePublicId: 'different-quote',
            idempotencyKey: 'original-key')));
    await tester.pumpWidget(
        screen(_quote(now.add(const Duration(seconds: 60))), () => now));

    await tester.scrollUntilVisible(
        find.textContaining('yêu cầu đặt xe khác đang chờ xác minh'), 120,
        scrollable: find.byType(Scrollable).first);
    expect(find.textContaining('yêu cầu đặt xe khác đang chờ xác minh'),
        findsOneWidget);
    await _showText(tester, 'Xác nhận đặt xe');
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    verifyNever(() => cubit.submit(any()));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Narrow phone can expand breakdown without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final now = DateTime.utc(2026, 10, 22, 12);
    await tester.pumpWidget(
        screen(_quote(now.add(const Duration(seconds: 60))), () => now));
    expect(tester.takeException(), isNull);
    await _showText(tester, 'Xác nhận đặt xe');
    expect(find.text('Xác nhận đặt xe'), findsOneWidget);
    await _showText(tester, 'Chi tiết giá');
    await tester.tap(find.text('Chi tiết giá'));
    await tester.pumpAndSettle();
    expect(find.text('Điều chỉnh làm tròn'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Quote route preview scrolls and keeps one visible map credit',
      (tester) async {
    const channel = MethodChannel('plugins.flutter.io/maplibre_gl');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel, (_) async => throw PlatformException(code: 'offline'));
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final session = _Session();
    when(() => session.getSession()).thenAnswer(
        (_) async => const AuthSessionSnapshot(1, 'access', 'refresh'));
    when(() => session.isCurrentSession(1)).thenAnswer((_) async => true);
    final now = DateTime.utc(2026, 10, 22, 12);
    await tester.pumpWidget(screen(
        _quote(now.add(const Duration(seconds: 60))), () => now,
        pickupLabel: 'Hồ Hoàn Kiếm',
        dropoffLabel: 'Bến xe Mỹ Đình',
        addressSession: session,
        routeRepository: _UnavailableRouteRepo()));
    await tester.pump();
    final canvas = find.byType(CustomerMapCanvas);
    await tester.scrollUntilVisible(canvas, 160,
        scrollable: find.byType(Scrollable).first);
    expect(tester.widget<CustomerMapCanvas>(canvas).scrollablePreview, isTrue);
    expect(find.text(CustomerMapSource.visibleAttribution), findsOneWidget);
    expect(find.text('© OpenStreetMap contributors'), findsNothing);
    await tester.ensureVisible(canvas);
    await tester.pump();
    final scrollable =
        tester.state<ScrollableState>(find.byType(Scrollable).first);
    final before = scrollable.position.pixels;
    await tester.dragFrom(tester.getCenter(canvas), const Offset(0, 150));
    await tester.pump();
    expect(scrollable.position.pixels, lessThan(before));
    expect(find.text('Xác nhận đặt xe'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Quote page transition never animates the native map preview',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1280);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    const channel = MethodChannel('plugins.flutter.io/maplibre_gl');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel, (_) async => throw PlatformException(code: 'offline'));
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final session = _Session();
    when(() => session.getSession()).thenAnswer(
        (_) async => const AuthSessionSnapshot(1, 'access', 'refresh'));
    when(() => session.isCurrentSession(1)).thenAnswer((_) async => true);
    final now = DateTime.utc(2026, 10, 22, 12);
    await tester.pumpWidget(BlocProvider<BookingCubit>.value(
      value: cubit,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                AppMotion.contentRoute<void>(
                  context,
                  QuoteReviewScreen(
                    quote: _quote(now.add(const Duration(seconds: 60))),
                    now: () => now,
                    routeRepository: _UnavailableRouteRepo(),
                    routeSession: session,
                  ),
                ),
              ),
              child: const Text('Mở báo giá'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Mở báo giá'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(QuoteReviewScreen), findsOneWidget);
    expect(find.byType(CustomerMapCanvas), findsNothing);
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(CustomerMapCanvas), findsOneWidget);
    await tester.pageBack();
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.byType(CustomerMapCanvas), findsNothing);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
