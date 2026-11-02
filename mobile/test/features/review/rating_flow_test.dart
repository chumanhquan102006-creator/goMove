import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gomove_mobile/core/di/injection.dart';
import 'package:gomove_mobile/core/error/exceptions.dart';
import 'package:gomove_mobile/core/storage/secure_storage_service.dart';
import 'package:gomove_mobile/core/theme/app_motion.dart';
import 'package:gomove_mobile/features/review/domain/rating_models.dart';
import 'package:gomove_mobile/features/review/domain/rating_repository.dart';
import 'package:gomove_mobile/features/review/presentation/rating_cubit.dart';
import 'package:gomove_mobile/features/review/presentation/rating_panel.dart';
import 'package:mocktail/mocktail.dart';

const bookingId = '550e8400-e29b-41d4-a716-446655440010';
const customerA = '550e8400-e29b-41d4-a716-446655440011';
const customerB = '550e8400-e29b-41d4-a716-446655440012';

class _Session extends Mock implements SecureStorageService {}

class _Ratings implements RatingRepository {
  TripRating? saved;
  int submitCalls = 0;
  int lookupCalls = 0;
  Completer<TripRating>? pendingSubmit;
  Completer<RatingLookup>? pendingLookup;
  Object? submitError;

  @override
  Future<RatingLookup> lookup(String bookingPublicId, int generation) async {
    lookupCalls++;
    if (pendingLookup case final pending?) return pending.future;
    return RatingLookup(saved);
  }

  @override
  Future<TripRating> submit(String bookingPublicId, int stars, String? comment,
      int generation) async {
    submitCalls++;
    if (pendingSubmit case final pending?) return pending.future;
    if (submitError case final error?) throw error;
    return saved = TripRating(
        'rating-1', bookingPublicId, stars, comment, DateTime.utc(2026, 11, 1));
  }
}

void main() {
  late _Session session;
  late _Ratings ratings;
  var generation = 1;
  String? owner = customerA;

  setUp(() {
    generation = 1;
    owner = customerA;
    session = _Session();
    ratings = _Ratings();
    when(() => session.getSession()).thenAnswer(
        (_) async => AuthSessionSnapshot(generation, 'access', 'refresh'));
    when(() => session.getUserPublicId()).thenAnswer((_) async => owner);
    when(() => session.isCurrentSession(any()))
        .thenAnswer((call) async => call.positionalArguments[0] == generation);
  });

  tearDown(() async => sl.reset());

  test('Skipping is optional and does not send a rating', () async {
    final cubit = RatingCubit(ratings, session, customerA, bookingId);
    await cubit.load();
    cubit.skip();
    expect(cubit.state.skipped, isTrue);
    expect(cubit.state.rating, isNull);
    expect(ratings.submitCalls, 0);
    await cubit.close();
  });

  test('One to five stars and 500 character bound are checked before POST',
      () async {
    final cubit = RatingCubit(ratings, session, customerA, bookingId);
    await cubit.load();
    await cubit.submit(0, null);
    await cubit.submit(6, null);
    await cubit.submit(5, 'a' * 501);
    expect(ratings.submitCalls, 0);
    await cubit.submit(5, '  Chuyến tốt  ');
    expect(cubit.state.rating?.stars, 5);
    expect(cubit.state.rating?.comment, 'Chuyến tốt');
    await cubit.submit(1, null);
    expect(ratings.submitCalls, 1);
    await cubit.close();
  });

  test('Lost POST response reconciles with GET and never repeats POST',
      () async {
    final cubit = RatingCubit(ratings, session, customerA, bookingId);
    await cubit.load();
    ratings.saved =
        TripRating('rating-1', bookingId, 4, null, DateTime.utc(2026, 11, 1));
    ratings.submitError = const NetworkException('timeout');
    await cubit.submit(4, null);
    expect(cubit.state.rating?.stars, 4);
    expect(ratings.submitCalls, 1);
    await cubit.close();
  });

  test('Uncertain POST outcome blocks retry until an authorized read',
      () async {
    final cubit = RatingCubit(ratings, session, customerA, bookingId);
    ratings.submitError = const NetworkException('timeout');
    await cubit.load();
    await cubit.submit(3, null);
    expect(cubit.state.uncertain, isTrue);
    await cubit.submit(3, null);
    expect(ratings.submitCalls, 1);
    ratings.submitError = null;
    await cubit.load();
    expect(cubit.state.uncertain, isFalse);
    await cubit.submit(3, null);
    expect(ratings.submitCalls, 2);
    await cubit.close();
  });

  test('Old account response cannot restore rating after session replacement',
      () async {
    final cubit = RatingCubit(ratings, session, customerA, bookingId);
    final pending = ratings.pendingLookup = Completer<RatingLookup>();
    final load = cubit.load();
    await Future<void>.delayed(Duration.zero);
    generation = 2;
    owner = customerB;
    pending.complete(RatingLookup(TripRating(
        'rating-a', bookingId, 5, 'private', DateTime.utc(2026, 11, 1))));
    await load;
    expect(cubit.state.rating, isNull);
    expect(cubit.state.sessionEnded, isTrue);
    await cubit.close();
  });

  test('Background clears rating and late refresh cannot reveal it', () async {
    final cubit = RatingCubit(ratings, session, customerA, bookingId);
    final pending = ratings.pendingLookup = Completer<RatingLookup>();
    final load = cubit.load();
    await Future<void>.delayed(Duration.zero);
    cubit.hideForBackground();
    pending.complete(RatingLookup(TripRating(
        'rating-a', bookingId, 5, 'private', DateTime.utc(2026, 11, 1))));
    await load;
    expect(cubit.state.rating, isNull);
    await cubit.close();
  });

  testWidgets('Completed-trip sheet supports stars, skip and later submission',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    sl.registerSingleton<RatingRepository>(ratings);
    sl.registerSingleton<SecureStorageService>(session);
    sl.registerFactoryParam<RatingCubit, String, String>((booking, customer) =>
        RatingCubit(ratings, session, customer, booking));
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: RatingPanel(
                bookingPublicId: bookingId,
                customerPublicId: customerA,
                autoPrompt: true))));
    await tester.pumpAndSettle();
    expect(find.text('Chuyến đi của bạn thế nào?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('rating-skip')));
    await tester.pumpAndSettle();
    expect(ratings.submitCalls, 0);
    await tester.tap(find.text('Đánh giá tài xế').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rating-star-4')));
    await tester.pump();
    expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('rating-submit')))
            .onPressed,
        isNotNull);
    await tester.tap(find.byKey(const ValueKey('rating-submit')));
    await tester.pumpAndSettle();
    expect(find.text('Cảm ơn bạn đã đánh giá'), findsOneWidget);
    expect(ratings.submitCalls, 1);
  });

  testWidgets('Star feedback honors reduced motion on tablet', (tester) async {
    tester.view.physicalSize = const Size(800, 1280);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    sl.registerSingleton<RatingRepository>(ratings);
    sl.registerSingleton<SecureStorageService>(session);
    sl.registerFactoryParam<RatingCubit, String, String>((booking, customer) =>
        RatingCubit(ratings, session, customer, booking));
    await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!),
        home: const Scaffold(
            body: RatingPanel(
                bookingPublicId: bookingId, customerPublicId: customerA))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Đánh giá tài xế').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rating-star-5')));
    await tester.pump();
    final scale = tester.widget<AnimatedScale>(find.byType(AnimatedScale).last);
    expect(scale.duration, Duration.zero);
    expect(
        AppMotion.reduceMotion(tester.element(find.byType(AnimatedScale).last)),
        isTrue);
  });
}
