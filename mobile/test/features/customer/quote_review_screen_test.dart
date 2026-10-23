import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gomove_mobile/features/customer/domain/models/booking_intent.dart';
import 'package:gomove_mobile/features/customer/domain/models/quote.dart';
import 'package:gomove_mobile/features/customer/presentation/bloc/booking_cubit.dart';
import 'package:gomove_mobile/features/customer/presentation/formatters.dart';
import 'package:gomove_mobile/features/customer/presentation/screens/quote_review_screen.dart';
import 'package:mocktail/mocktail.dart';

const _quoteId = '550e8400-e29b-41d4-a716-446655440001';

class _MockBookingCubit extends MockCubit<BookingState>
    implements BookingCubit {}

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

void main() {
  late _MockBookingCubit cubit;

  setUp(() {
    cubit = _MockBookingCubit();
    when(() => cubit.state).thenReturn(const BookingState());
    when(() => cubit.stream)
        .thenAnswer((_) => const Stream<BookingState>.empty());
    when(() => cubit.submit(any())).thenAnswer((_) async {});
  });

  Widget screen(Quote quote, DateTime Function() now) => MaterialApp(
        home: BlocProvider<BookingCubit>.value(
            value: cubit, child: QuoteReviewScreen(quote: quote, now: now)),
      );

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
    expect(find.text('Còn 60 giây để xác nhận'), findsOneWidget);
    expect(find.text('Xác nhận đặt xe'), findsOneWidget);

    await tester.tap(find.text('Chi tiết giá'));
    await tester.pumpAndSettle();
    expect(find.text('4.500,50 VND'), findsOneWidget);
    expect(find.text('-500 VND'), findsOneWidget);
    expect(find.text('-0,50 VND'), findsOneWidget);
    await tester.tap(find.text('Xác nhận đặt xe'));
    verify(() => cubit.submit(_quoteId)).called(1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Countdown reaches strict expiry and offers new Quote',
      (tester) async {
    var now = DateTime.utc(2026, 10, 22, 12);
    final quote = _quote(now.add(const Duration(seconds: 2)));
    await tester.pumpWidget(screen(quote, () => now));
    expect(find.text('Còn 2 giây để xác nhận'), findsOneWidget);

    now = quote.expiresAt;
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Báo giá đã hết hạn'), findsOneWidget);
    expect(find.text('Lấy báo giá mới'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
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

    expect(find.text('Báo giá đã hết hạn'), findsOneWidget);
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

    expect(find.textContaining('yêu cầu đặt xe khác đang chờ xác minh'),
        findsOneWidget);
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
    expect(find.text('Xác nhận đặt xe'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Chi tiết giá'), 180,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Chi tiết giá'));
    await tester.pumpAndSettle();
    expect(find.text('Điều chỉnh làm tròn'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
