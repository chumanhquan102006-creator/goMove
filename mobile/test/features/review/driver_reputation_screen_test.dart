import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gomove_mobile/core/di/injection.dart';
import 'package:gomove_mobile/core/storage/secure_storage_service.dart';
import 'package:gomove_mobile/features/auth/domain/entities/user.dart';
import 'package:gomove_mobile/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:gomove_mobile/features/auth/presentation/bloc/auth_state.dart';
import 'package:gomove_mobile/features/review/domain/review_models.dart';
import 'package:gomove_mobile/features/review/domain/review_repository.dart';
import 'package:gomove_mobile/features/review/presentation/driver_reputation_cubit.dart';
import 'package:gomove_mobile/features/review/presentation/driver_reputation_screen.dart';
import 'package:mocktail/mocktail.dart';

class _Session extends Mock implements SecureStorageService {}

class _AuthBloc extends Mock implements AuthBloc {}

class _ReviewRepository extends Mock implements ReviewRepository {}

const _driver = User(
    publicId: 'driver-user-1',
    phoneNumber: '0900000001',
    fullName: 'Tài xế A',
    role: UserRole.driver);
const _other = User(
    publicId: 'driver-user-2',
    phoneNumber: '0900000002',
    fullName: 'Tài xế B',
    role: UserRole.driver);

void main() {
  late _Session session;
  late _AuthBloc auth;
  late _ReviewRepository repository;
  late DriverReputationCubit screenCubit;
  late StreamController<AuthState> authEvents;
  late AuthState authState;
  var rewardPageRequests = 0;

  setUp(() async {
    await sl.reset();
    session = _Session();
    auth = _AuthBloc();
    repository = _ReviewRepository();
    authEvents = StreamController<AuthState>.broadcast();
    authState = const AuthenticatedState(_driver);
    rewardPageRequests = 0;
    when(() => auth.state).thenAnswer((_) => authState);
    when(() => auth.stream).thenAnswer((_) => authEvents.stream);
    when(() => session.getSession()).thenAnswer(
        (_) async => const AuthSessionSnapshot(1, 'access', 'refresh'));
    when(() => session.getUserPublicId())
        .thenAnswer((_) async => _driver.publicId);
    when(() => session.isCurrentSession(any())).thenAnswer((_) async => true);
    when(() => repository.reputation(any()))
        .thenAnswer((_) async => const DriverReputation(4.5, 2, 5, 0, 5, []));
    when(() => repository.rewards(any(), any())).thenAnswer((call) async {
      final page = call.positionalArguments.first as int;
      rewardPageRequests++;
      return ReviewPage([
        RewardEvent('reward-$page', page == 0 ? 4 : 5, page == 0 ? 5 : 10,
            DateTime.utc(2026, 10, 20 + page))
      ], page, page == 0);
    });
    when(() => repository.myCases(any(), any()))
        .thenAnswer((_) async => ReviewPage([
              QualityCase('case-1', _driver.publicId, 'OPEN', 10, 2.5,
                  'Cần rà soát đánh giá gần đây', DateTime.utc(2026, 10, 21))
            ], 0, false));
    sl.registerFactoryParam<DriverReputationCubit, String, void>((publicId, _) {
      screenCubit = DriverReputationCubit(repository, session, publicId);
      return screenCubit;
    });
  });

  tearDown(() async {
    await authEvents.close();
    await sl.reset();
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(BlocProvider<AuthBloc>.value(
      value: auth,
      child: MaterialApp(
        home: DriverReputationScreen(driverPublicId: _driver.publicId),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('Narrow Driver reputation shows verified points and pagination',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpScreen(tester);
    expect(find.text('4.50 ★ · 2 chuyến được đánh giá'), findsOneWidget);
    expect(find.text('5 GoPoints'), findsOneWidget);
    expect(find.text('Đã cộng 5 · Đã trừ 0'), findsOneWidget);
    expect(find.textContaining('không phải tiền mặt'), findsOneWidget);
    expect(find.text('4 sao'), findsOneWidget);
    expect(find.text('+5 GoPoints'), findsOneWidget);
    expect(screenCubit.state.hasMoreRewards, isTrue);
    await tester.ensureVisible(find.text('Xem thêm lịch sử GoPoints'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(
                OutlinedButton, 'Xem thêm lịch sử GoPoints'))
            .onPressed,
        isNotNull);
    await tester.tap(find.text('Xem thêm lịch sử GoPoints'));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(rewardPageRequests, 2);
    expect(find.text('5 sao'), findsOneWidget);
    await tester.ensureVisible(find.text('Phản hồi'));
    await tester.pumpAndSettle();
    expect(find.text('Cần rà soát đánh giá gần đây'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Background and account change hide private reputation',
      (tester) async {
    await pumpScreen(tester);
    expect(find.text('5 GoPoints'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpAndSettle();
    expect(screenCubit.state.reputation, isNull);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('5 GoPoints'), findsOneWidget);
    authState = const AuthenticatedState(_other);
    authEvents.add(authState);
    await tester.pumpAndSettle();
    expect(find.text('5 GoPoints'), findsNothing);
    expect(find.text('Phiên đăng nhập đã thay đổi.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Failed reputation load offers retry without a false empty state',
      (tester) async {
    when(() => repository.reputation(any())).thenThrow(StateError('offline'));
    await pumpScreen(tester);
    expect(find.textContaining('Chưa tải được đánh giá'), findsOneWidget);
    expect(find.text('Chưa có lần cộng hoặc trừ điểm.'), findsNothing);
    expect(find.text('Chưa có hồ sơ cần rà soát.'), findsNothing);
    when(() => repository.reputation(any()))
        .thenAnswer((_) async => const DriverReputation(4.5, 2, 5, 0, 5, []));
    await tester.tap(find.text('Tải lại'));
    await tester.pumpAndSettle();
    expect(find.text('5 GoPoints'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
