import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gomove_mobile/core/storage/secure_storage_service.dart';
import 'package:gomove_mobile/features/auth/domain/entities/user.dart';
import 'package:gomove_mobile/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:gomove_mobile/features/auth/presentation/bloc/auth_state.dart';
import 'package:gomove_mobile/features/review/domain/review_models.dart';
import 'package:gomove_mobile/features/review/domain/review_repository.dart';
import 'package:gomove_mobile/features/review/presentation/admin_quality_cubit.dart';
import 'package:gomove_mobile/features/review/presentation/admin_quality_screen.dart';
import 'package:mocktail/mocktail.dart';

const _adminId = 'admin-1';
const _admin = User(
    publicId: _adminId,
    phoneNumber: '0900000001',
    fullName: 'Quản trị',
    role: UserRole.admin);

class _Session extends Mock implements SecureStorageService {}

class _AuthBloc extends Mock implements AuthBloc {}

class _Review extends Mock implements ReviewRepository {}

void main() {
  late _Session session;
  late _AuthBloc auth;
  late _Review review;
  late QualityCase openCase;
  late QualityDetail detail;

  setUp(() {
    session = _Session();
    auth = _AuthBloc();
    review = _Review();
    openCase = QualityCase('case-1', 'driver-1', 'OPEN', 10, 2.5,
        'Điểm gần đây dưới ngưỡng', DateTime(2026, 11, 1),
        driverDisplayName: 'Tài xế Minh');
    detail = QualityDetail(openCase, [
      RatingEvidence(2, 'Cần cải thiện thái độ', DateTime(2026, 11, 1))
    ], [
      QualityAction('DISPUTE', 'Tôi đề nghị xem lại', DateTime(2026, 11, 2))
    ]);
    when(() => session.getSession()).thenAnswer(
        (_) async => const AuthSessionSnapshot(1, 'access', 'refresh'));
    when(() => session.getUserPublicId()).thenAnswer((_) async => _adminId);
    when(() => session.isCurrentSession(any())).thenAnswer((_) async => true);
    when(() => auth.state).thenReturn(const AuthenticatedState(_admin));
    when(() => auth.stream).thenAnswer((_) => const Stream<AuthState>.empty());
    when(() => review.adminCases(any(), any(), any()))
        .thenAnswer((_) async => ReviewPage([openCase], 0, false));
    when(() => review.adminDetail(any(), any()))
        .thenAnswer((_) async => detail);
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    final cubit = AdminQualityCubit(review, session, _adminId);
    await tester.pumpWidget(BlocProvider<AuthBloc>.value(
      value: auth,
      child: MaterialApp(
        home: AdminQualityScreen(adminPublicId: _adminId, cubit: cubit),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('Status filter uses the existing API and keeps pagination',
      (tester) async {
    final closed = QualityCase('case-2', 'driver-2', 'DISMISSED', 12, 3.1,
        'Đã rà soát', DateTime(2026, 11, 3),
        driverDisplayName: 'Tài xế Lan');
    final another = QualityCase('case-3', 'driver-3', 'DISMISSED', 15, 3.4,
        'Đã rà soát', DateTime(2026, 11, 4),
        driverDisplayName: 'Tài xế An');
    when(() => review.adminCases(any(), any(), any())).thenAnswer((call) async {
      final page = call.positionalArguments[0] as int;
      final filter = call.positionalArguments[1] as String?;
      if (filter == 'DISMISSED') {
        return page == 0
            ? ReviewPage([closed], 0, true)
            : ReviewPage([another], 1, false);
      }
      return ReviewPage([openCase], 0, false);
    });
    await pumpScreen(tester);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Đã đóng hồ sơ').last);
    await tester.pumpAndSettle();
    expect(find.text('Tài xế Lan'), findsOneWidget);
    await tester.tap(find.text('Xem thêm hồ sơ'));
    await tester.pumpAndSettle();
    expect(find.text('Tài xế An'), findsOneWidget);
    verify(() => review.adminCases(0, 'DISMISSED', 1)).called(1);
    verify(() => review.adminCases(1, 'DISMISSED', 1)).called(1);
  });

  testWidgets('Verified evidence, dispute and required-note decision render',
      (tester) async {
    final warned = QualityCase('case-1', 'driver-1', 'WARNED', 10, 2.5,
        openCase.reason, openCase.createdAt,
        driverDisplayName: 'Tài xế Minh');
    final decided = QualityDetail(warned, detail.evidence, [
      ...detail.actions,
      QualityAction('WARN', 'Cần cải thiện', DateTime(2026, 11, 3))
    ]);
    var actionSubmitted = false;
    when(() => review.adminAction(any(), any(), any(), any()))
        .thenAnswer((_) async {
      actionSubmitted = true;
      detail = decided;
      return decided;
    });
    await pumpScreen(tester);
    await tester.tap(find.text('Tài xế Minh').first);
    await tester.pumpAndSettle();
    expect(find.text('Cần cải thiện thái độ'), findsOneWidget);
    expect(find.text('Tôi đề nghị xem lại'), findsOneWidget);
    await tester.ensureVisible(find.text('Nhắc nhở'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nhắc nhở'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Xác nhận'))
            .onPressed,
        isNull);
    await tester.enterText(find.byType(TextField), 'Cần cải thiện');
    await tester.pump();
    await tester.tap(find.text('Xác nhận'));
    await tester.pumpAndSettle();
    expect(actionSubmitted, isTrue);
    verify(() => review.adminAction('case-1', 'WARN', 'Cần cải thiện', 1))
        .called(1);
    expect(find.text('Cần cải thiện'), findsOneWidget);
  });

  testWidgets('Background closes decision note and hides protected evidence',
      (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.text('Tài xế Minh').first);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Nhắc nhở'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nhắc nhở'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Ghi chú riêng');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(find.text('Ghi chú riêng'), findsNothing);
    expect(find.text('Cần cải thiện thái độ'), findsNothing);
    expect(find.text('Tài xế Minh'), findsNothing);
  });

  testWidgets('Role change removes quality evidence from the active screen',
      (tester) async {
    final authEvents = StreamController<AuthState>.broadcast();
    addTearDown(authEvents.close);
    AuthState current = const AuthenticatedState(_admin);
    when(() => auth.state).thenAnswer((_) => current);
    when(() => auth.stream).thenAnswer((_) => authEvents.stream);
    await pumpScreen(tester);
    await tester.tap(find.text('Tài xế Minh').first);
    await tester.pumpAndSettle();
    expect(find.text('Cần cải thiện thái độ'), findsOneWidget);
    current = const UnauthenticatedState();
    authEvents.add(current);
    await tester.pumpAndSettle();
    expect(find.text('Phiên quản trị đã thay đổi.'), findsOneWidget);
    expect(find.text('Cần cải thiện thái độ'), findsNothing);
    expect(find.text('Tài xế Minh'), findsNothing);
  });

  testWidgets(
      'Quality screen fits narrow and tablet viewports with less motion',
      (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final cubit = AdminQualityCubit(review, session, _adminId);
    await tester.pumpWidget(BlocProvider<AuthBloc>.value(
      value: auth,
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!),
        home: AdminQualityScreen(adminPublicId: _adminId, cubit: cubit),
      ),
    ));
    await tester.pumpAndSettle();
    final narrowError = tester.takeException();
    expect(narrowError, isNull, reason: narrowError?.toString());
    await tester.tap(find.text('Tài xế Minh').first);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Nhắc nhở'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(1000, 900);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
