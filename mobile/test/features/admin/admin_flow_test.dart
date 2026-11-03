import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gomove_mobile/core/error/exceptions.dart';
import 'package:gomove_mobile/core/storage/secure_storage_service.dart';
import 'package:gomove_mobile/features/admin/domain/admin_models.dart';
import 'package:gomove_mobile/features/admin/domain/admin_repository.dart';
import 'package:gomove_mobile/features/admin/presentation/admin_cubit.dart';
import 'package:gomove_mobile/features/admin/presentation/admin_home_screen.dart';
import 'package:gomove_mobile/features/auth/domain/entities/user.dart';
import 'package:gomove_mobile/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:gomove_mobile/features/auth/presentation/bloc/auth_state.dart';
import 'package:gomove_mobile/features/auth/presentation/screens/role_home.dart';
import 'package:mocktail/mocktail.dart';

const _adminId = '550e8400-e29b-41d4-a716-446655440001';
const _otherId = '550e8400-e29b-41d4-a716-446655440002';
const _driverId = '550e8400-e29b-41d4-a716-446655440003';
const _secondDriverId = '550e8400-e29b-41d4-a716-446655440004';
const _account = User(
    publicId: _adminId,
    phoneNumber: '0900000001',
    fullName: 'Admin A',
    role: UserRole.admin);

class _Session extends Mock implements SecureStorageService {}

class _AuthBloc extends Mock implements AuthBloc {}

class _Repository implements AdminRepository {
  final calls = <String>[];
  final approvals = <String>[];
  String approval = 'PENDING';
  String secondApproval = 'PENDING';
  bool fail = false;
  bool unauthorized = false;
  bool empty = false;
  Object? approvalError;
  Object? detailError;
  Object? driverPageError;
  Completer<AdminApprovalResult>? delayedApproval;
  Completer<AdminPage<AdminDriver>>? delayedDrivers;
  Completer<AdminPage<AdminAccount>>? delayedAccounts;
  Completer<AdminPage<AdminBooking>>? delayedBookings;
  List<AdminBooking>? bookingItems;

  AdminDriver get item => AdminDriver(_driverId, 'Tài xế A', '0900000002',
          'GPLX-1', approval, 'OFFLINE', 2, false, const [
        AdminVehicle('vehicle-1', '29A-12345', 'MOTORBIKE', 'Honda Wave', true)
      ]);

  AdminDriver get secondItem => AdminDriver(_secondDriverId, 'Tài xế B',
      '0900000004', 'GPLX-2', secondApproval, 'OFFLINE', 0, false, const []);

  @override
  Future<AdminDashboard> dashboard(int generation) async {
    calls.add('dashboard:$generation');
    if (unauthorized) throw const UnauthorizedException('expired');
    if (fail) throw const NetworkException('offline');
    return const AdminDashboard({
      'customers': 4,
      'drivers': 2,
      'pendingApprovals': 1,
      'driversOnline': 1,
      'driversOffline': 1,
      'driversBusy': 0,
      'activeBookings': 3,
      'completedBookings': 5,
      'cancelledBookings': 1,
      'noDriverAvailableBookings': 1,
      'paidCashPayments': 4,
      'collectiblePendingCashPayments': 1,
      'voidCashPayments': 2,
    }, '16500.00', '33000.00');
  }

  @override
  Future<AdminPage<AdminDriver>> drivers(
      int page, String? approval, String? search, int generation) async {
    calls.add('drivers:$page:$approval:$search:$generation');
    if (driverPageError != null) throw driverPageError!;
    if (fail) throw const NetworkException('offline');
    if (delayedDrivers != null) return delayedDrivers!.future;
    return AdminPage(
        empty || page > 0 ? const [] : [item], page, 20, empty ? 0 : 21);
  }

  @override
  Future<AdminDriver> driver(String publicId, int generation) async {
    calls.add('driver:$publicId:$generation');
    if (detailError != null) throw detailError!;
    return publicId == _secondDriverId ? secondItem : item;
  }

  @override
  Future<AdminApprovalResult> setApproval(
      String publicId, String status, int generation) async {
    calls.add('approval:$publicId:$status:$generation');
    if (approvalError != null) throw approvalError!;
    if (delayedApproval != null) return delayedApproval!.future;
    approvals.add(status);
    if (publicId == _secondDriverId) {
      secondApproval = status;
    } else {
      approval = status;
    }
    return const AdminApprovalResult.confirmed();
  }

  @override
  Future<AdminPage<AdminAccount>> accounts(
      int page, String? role, String? search, int generation) async {
    calls.add('accounts:$page:$role:$search:$generation');
    if (delayedAccounts != null) return delayedAccounts!.future;
    if (fail) throw const NetworkException('offline');
    return AdminPage(
        empty
            ? const []
            : [
                const AdminAccount(_otherId, 'Khách A', '0900000003', null,
                    'CUSTOMER', 'ACTIVE', null, null, true, null)
              ],
        page,
        20,
        empty ? 0 : 1);
  }

  @override
  Future<AdminAccount> account(String publicId, int generation) async =>
      const AdminAccount(_otherId, 'Khách A', '0900000003', null, 'CUSTOMER',
          'ACTIVE', null, null, true, null);

  @override
  Future<AdminPage<AdminBooking>> bookings(
      int page, String? status, int generation) async {
    calls.add('bookings:$page:$status:$generation');
    if (delayedBookings != null) return delayedBookings!.future;
    if (fail) throw const NetworkException('offline');
    return AdminPage(
        empty
            ? const []
            : bookingItems ??
                [
                  const AdminBooking('booking-1', 'COMPLETED', 'MOTORBIKE',
                      '16500.00', 'PENDING')
                ],
        page,
        20,
        empty ? 0 : 1);
  }
}

void main() {
  late _Session session;
  late _Repository repository;
  late _AuthBloc auth;
  var generation = 7;
  var owner = _adminId;

  setUp(() {
    generation = 7;
    owner = _adminId;
    session = _Session();
    repository = _Repository();
    auth = _AuthBloc();
    when(() => session.getSession()).thenAnswer(
        (_) async => AuthSessionSnapshot(generation, 'access', 'refresh'));
    when(() => session.getUserPublicId()).thenAnswer((_) async => owner);
    when(() => session.isCurrentSession(any())).thenAnswer(
        (call) async => call.positionalArguments.first == generation);
    when(() => session.clearIfCurrent(any())).thenAnswer((_) async => true);
    when(() => auth.state).thenReturn(const AuthenticatedState(_account));
    when(() => auth.stream).thenAnswer((_) => const Stream<AuthState>.empty());
  });

  test('Admin role routes to Admin UI; Customer does not', () {
    expect(homeForRole(_account), isA<AdminHomeScreen>());
    expect(
        homeForRole(const User(
            publicId: _otherId,
            phoneNumber: '0900000003',
            fullName: 'Customer',
            role: UserRole.customer)),
        isNot(isA<AdminHomeScreen>()));
  });

  test('Dashboard uses backend counts and clears on background', () async {
    final cubit = AdminCubit(repository, session, _adminId);
    await cubit.load();
    expect(cubit.state.dashboard?.counts['customers'], 4);
    cubit.hideForBackground();
    expect(cubit.state.dashboard, isNull);
    await cubit.load();
    expect(cubit.state.dashboard?.counts['voidCashPayments'], 2);
    await cubit.close();
  });

  test('Search, filter and pagination are sent to server', () async {
    final cubit = AdminCubit(repository, session, _adminId);
    cubit.selectTab(AdminTab.drivers);
    await pumpEventQueue();
    cubit.goToPage(1);
    await pumpEventQueue();
    cubit.setQuery(filter: 'PENDING', search: 'GPLX-1');
    await pumpEventQueue();
    expect(repository.calls, contains('drivers:0:null:null:7'));
    expect(repository.calls, contains('drivers:1:null:null:7'));
    expect(repository.calls, contains('drivers:0:PENDING:GPLX-1:7'));
    expect(cubit.state.page, 0);
    await cubit.close();
  });

  test('Empty, error and retry do not retain old Admin data', () async {
    final cubit = AdminCubit(repository, session, _adminId);
    cubit.selectTab(AdminTab.accounts);
    await pumpEventQueue();
    expect(cubit.state.accounts?.items, hasLength(1));
    repository.fail = true;
    await cubit.load();
    expect(cubit.state.accounts, isNull);
    expect(cubit.state.error, isNotNull);
    repository.fail = false;
    repository.empty = true;
    await cubit.load();
    expect(cubit.state.error, isNull);
    expect(cubit.state.accounts?.items, isEmpty);
    await cubit.close();
  });

  test('Expired Admin JWT ends the screen session without retaining data',
      () async {
    final cubit = AdminCubit(repository, session, _adminId);
    await cubit.load();
    expect(cubit.state.dashboard, isNotNull);
    repository.unauthorized = true;
    await cubit.load();
    expect(cubit.state.sessionEnded, isTrue);
    expect(cubit.state.dashboard, isNull);
    verify(() => session.clearIfCurrent(7)).called(1);
    await cubit.close();
  });

  test('Approval conflict reports unreleased Booking without changing Driver',
      () async {
    final cubit = AdminCubit(repository, session, _adminId);
    cubit.selectTab(AdminTab.drivers);
    await pumpEventQueue();
    await cubit.openDriver(_driverId);
    repository.approvalError = const ServerException(
        message: 'conflict',
        statusCode: 409,
        errorCode: 'DRIVER_HAS_UNRELEASED_BOOKING');
    await cubit.setApproval(_driverId, 'SUSPENDED');
    expect(cubit.state.error, contains('chuyến chưa giải phóng'));
    expect(repository.approvals, isEmpty);
    await cubit.close();
  });

  test('Late Admin response cannot restore data after account switch',
      () async {
    repository.delayedDrivers = Completer<AdminPage<AdminDriver>>();
    final cubit = AdminCubit(repository, session, _adminId);
    cubit.selectTab(AdminTab.drivers);
    await pumpEventQueue();
    owner = _otherId;
    generation = 8;
    repository.delayedDrivers!.complete(AdminPage([repository.item], 0, 20, 1));
    await pumpEventQueue();
    expect(cubit.state.sessionEnded, isTrue);
    expect(cubit.state.drivers, isNull);
    expect(cubit.state.driverDetail, isNull);
    await cubit.close();
  });

  test('Delayed approval cannot reopen Driver or cancel a newer Accounts load',
      () async {
    final cubit = AdminCubit(repository, session, _adminId);
    cubit.selectTab(AdminTab.drivers);
    await pumpEventQueue();
    await cubit.openDriver(_driverId);
    repository.delayedApproval = Completer<AdminApprovalResult>();
    final operation = cubit.setApproval(_driverId, 'APPROVED');
    await pumpEventQueue();
    expect(repository.calls.where((call) => call.startsWith('approval:')),
        hasLength(1));
    repository.delayedAccounts = Completer<AdminPage<AdminAccount>>();
    cubit.selectTab(AdminTab.accounts);
    await pumpEventQueue();
    repository.delayedApproval!.complete(const AdminApprovalResult.confirmed());
    await operation;
    repository.delayedAccounts!.complete(const AdminPage([
      AdminAccount(_otherId, 'Khách A', '0900000003', null, 'CUSTOMER',
          'ACTIVE', null, null, true, null)
    ], 0, 20, 1));
    await pumpEventQueue();
    expect(cubit.state.tab, AdminTab.accounts);
    expect(cubit.state.accounts?.items.single.publicId, _otherId);
    expect(cubit.state.driverDetail, isNull);
    expect(repository.calls.where((call) => call.startsWith('driver:')),
        hasLength(1));
    await cubit.close();
  });

  test('Refresh during PATCH releases busy only after the result and readback',
      () async {
    final cubit = AdminCubit(repository, session, _adminId);
    cubit.selectTab(AdminTab.drivers);
    await pumpEventQueue();
    await cubit.openDriver(_driverId);
    repository.delayedApproval = Completer<AdminApprovalResult>();
    final operation = cubit.setApproval(_driverId, 'APPROVED');
    await pumpEventQueue();
    expect(cubit.state.working, isTrue);
    expect(cubit.state.notice, isNull);

    await cubit.load();
    expect(cubit.state.working, isTrue);
    expect(cubit.state.driverDetail, isNull);
    expect(repository.calls.where((call) => call.startsWith('approval:')),
        hasLength(1));

    repository.driverPageError = const NetworkException('read unavailable');
    await cubit.load();
    expect(cubit.state.working, isTrue);
    expect(cubit.state.approvalNeedsRefresh, isTrue);
    repository.driverPageError = null;

    repository.approval = 'APPROVED';
    repository.delayedApproval!.complete(const AdminApprovalResult.confirmed());
    await operation;
    expect(cubit.state.working, isFalse);
    expect(cubit.state.approvalNeedsRefresh, isTrue);
    expect(cubit.state.driverDetail, isNull);
    expect(cubit.state.notice, contains('đã xác nhận'));

    repository.detailError = const NetworkException('read unavailable');
    await cubit.load();
    expect(cubit.state.working, isFalse);
    expect(cubit.state.approvalNeedsRefresh, isTrue);
    expect(repository.calls.where((call) => call.startsWith('approval:')),
        hasLength(1));

    repository.detailError = null;
    await cubit.load();
    expect(cubit.state.approvalNeedsRefresh, isFalse);
    await cubit.openDriver(_driverId);
    expect(cubit.state.driverDetail?.approvalStatus, 'APPROVED');
    repository.delayedApproval = null;
    await cubit.setApproval(_driverId, 'SUSPENDED');
    expect(repository.calls.where((call) => call.startsWith('approval:')),
        hasLength(2));
    expect(repository.approvals, ['SUSPENDED']);
    expect(cubit.state.working, isFalse);
    await cubit.close();
  });

  test('Opening another Driver during PATCH preserves that selection',
      () async {
    final cubit = AdminCubit(repository, session, _adminId);
    cubit.selectTab(AdminTab.drivers);
    await pumpEventQueue();
    await cubit.openDriver(_driverId);
    repository.delayedApproval = Completer<AdminApprovalResult>();
    final operation = cubit.setApproval(_driverId, 'APPROVED');
    await pumpEventQueue();

    await cubit.openDriver(_secondDriverId);
    expect(cubit.state.driverDetail?.publicId, _secondDriverId);
    expect(cubit.state.working, isTrue);
    await cubit.setApproval(_secondDriverId, 'APPROVED');
    expect(repository.calls.where((call) => call.startsWith('approval:')),
        hasLength(1));
    expect(cubit.state.notice, isNull);

    repository.approval = 'APPROVED';
    repository.delayedApproval!.complete(const AdminApprovalResult.confirmed());
    await operation;
    expect(cubit.state.working, isFalse);
    expect(cubit.state.approvalNeedsRefresh, isTrue);
    expect(cubit.state.driverDetail?.publicId, _secondDriverId);
    expect(cubit.state.driverDetail?.approvalStatus, 'PENDING');
    await cubit.setApproval(_secondDriverId, 'APPROVED');
    expect(repository.calls.where((call) => call.startsWith('approval:')),
        hasLength(1));

    await cubit.load();
    expect(cubit.state.approvalNeedsRefresh, isFalse);
    await cubit.openDriver(_secondDriverId);
    repository.delayedApproval = null;
    await cubit.setApproval(_secondDriverId, 'APPROVED');
    expect(repository.calls.where((call) => call.startsWith('approval:')),
        hasLength(2));
    expect(repository.secondApproval, 'APPROVED');
    expect(cubit.state.driverDetail?.publicId, _secondDriverId);
    await cubit.close();
  });

  test('Old post-PATCH read cannot unlock a newer approval', () async {
    final cubit = AdminCubit(repository, session, _adminId);
    cubit.selectTab(AdminTab.drivers);
    await pumpEventQueue();
    await cubit.openDriver(_driverId);
    repository.delayedDrivers = Completer<AdminPage<AdminDriver>>();
    final oldOperation = cubit.setApproval(_driverId, 'APPROVED');
    await pumpEventQueue();
    expect(repository.approvals, ['APPROVED']);

    final oldRead = repository.delayedDrivers!;
    repository.delayedDrivers = null;
    await cubit.load();
    expect(cubit.state.approvalNeedsRefresh, isFalse);
    await cubit.openDriver(_driverId);
    repository.delayedApproval = Completer<AdminApprovalResult>();
    final newOperation = cubit.setApproval(_driverId, 'SUSPENDED');
    await pumpEventQueue();
    expect(cubit.state.working, isTrue);

    oldRead.complete(AdminPage([repository.item], 0, 20, 1));
    await oldOperation;
    expect(cubit.state.working, isTrue);
    expect(cubit.state.approvalNeedsRefresh, isFalse);
    expect(repository.calls.where((call) => call.startsWith('approval:')),
        hasLength(2));

    repository.approval = 'SUSPENDED';
    repository.delayedApproval!.complete(const AdminApprovalResult.confirmed());
    await newOperation;
    expect(cubit.state.working, isFalse);
    expect(cubit.state.driverDetail?.approvalStatus, 'SUSPENDED');
    await cubit.close();
  });

  test('Delayed post-PATCH read cannot invalidate a newer Bookings request',
      () async {
    final cubit = AdminCubit(repository, session, _adminId);
    cubit.selectTab(AdminTab.drivers);
    await pumpEventQueue();
    await cubit.openDriver(_driverId);
    repository.delayedDrivers = Completer<AdminPage<AdminDriver>>();
    final operation = cubit.setApproval(_driverId, 'SUSPENDED');
    await pumpEventQueue();
    expect(repository.approvals, ['SUSPENDED']);
    repository.delayedBookings = Completer<AdminPage<AdminBooking>>();
    cubit.selectTab(AdminTab.bookings);
    await pumpEventQueue();
    repository.delayedDrivers!.complete(AdminPage([repository.item], 0, 20, 1));
    await operation;
    repository.delayedBookings!.complete(const AdminPage([
      AdminBooking('booking-1', 'COMPLETED', 'MOTORBIKE', '16500.00', 'PENDING')
    ], 0, 20, 1));
    await pumpEventQueue();
    expect(cubit.state.tab, AdminTab.bookings);
    expect(cubit.state.bookings?.items.single.publicId, 'booking-1');
    expect(repository.calls.where((call) => call.startsWith('driver:')),
        hasLength(1));
    await cubit.close();
  });

  test('Confirmed PATCH remains confirmed when detail refresh fails', () async {
    final cubit = AdminCubit(repository, session, _adminId);
    cubit.selectTab(AdminTab.drivers);
    await pumpEventQueue();
    await cubit.openDriver(_driverId);
    repository.detailError = const NetworkException('offline');
    await cubit.setApproval(_driverId, 'APPROVED');
    expect(repository.approvals, ['APPROVED']);
    expect(cubit.state.notice, contains('đã xác nhận'));
    expect(cubit.state.error, contains('chưa tải lại'));
    expect(cubit.state.driverDetail, isNull);
    expect(cubit.state.approvalNeedsRefresh, isTrue);
    await cubit.load(); // Read-only retry; never PATCH again.
    expect(repository.approvals, ['APPROVED']);
    expect(cubit.state.approvalNeedsRefresh, isTrue);
    repository.detailError = null;
    await cubit.load();
    expect(cubit.state.approvalNeedsRefresh, isFalse);
    await cubit.close();
  });

  test('Uncertain approval disables actions until a fresh read', () async {
    final cubit = AdminCubit(repository, session, _adminId);
    cubit.selectTab(AdminTab.drivers);
    await pumpEventQueue();
    await cubit.openDriver(_driverId);
    repository.delayedApproval = Completer<AdminApprovalResult>();
    final operation = cubit.setApproval(_driverId, 'SUSPENDED');
    await pumpEventQueue();
    repository.delayedApproval!
        .complete(AdminApprovalResult.uncertain(repository.item));
    await operation;
    expect(cubit.state.approvalUncertain, isTrue);
    expect(cubit.state.notice, contains('Chưa xác định'));
    expect(repository.calls.where((call) => call.startsWith('approval:')),
        hasLength(1));
    await cubit.setApproval(_driverId, 'SUSPENDED');
    expect(repository.calls.where((call) => call.startsWith('approval:')),
        hasLength(1));
    await cubit.load();
    expect(cubit.state.approvalUncertain, isFalse);
    await cubit.close();
  });

  test('Background clears PII query and ignores its late search response',
      () async {
    final cubit = AdminCubit(repository, session, _adminId);
    cubit.selectTab(AdminTab.accounts);
    await pumpEventQueue();
    repository.delayedAccounts = Completer<AdminPage<AdminAccount>>();
    cubit.setQuery(search: 'admin@example.test');
    await pumpEventQueue();
    expect(cubit.state.search, 'admin@example.test');
    cubit.hideForBackground();
    repository.delayedAccounts!.complete(const AdminPage([
      AdminAccount(_otherId, 'Khách A', '0900000003', null, 'CUSTOMER',
          'ACTIVE', null, null, true, null)
    ], 0, 20, 1));
    await pumpEventQueue();
    expect(cubit.state.search, isNull);
    expect(cubit.state.filter, isNull);
    expect(cubit.state.accounts, isNull);
    repository.delayedAccounts = null;
    await cubit.load();
    expect(repository.calls.last, 'accounts:0:null:null:7');
    await cubit.close();
  });

  testWidgets('Dashboard renders and confirmation gates approval',
      (tester) async {
    final cubit = AdminCubit(repository, session, _adminId);
    await tester.pumpWidget(BlocProvider<AuthBloc>.value(
        value: auth,
        child: MaterialApp(
            home: AdminHomeScreen(adminPublicId: _adminId, cubit: cubit))));
    await tester.pumpAndSettle();
    expect(find.text('Khách hàng'), findsOneWidget);
    await tester.scrollUntilVisible(
        find.text('CASH PENDING của chuyến hoàn thành'), 300);
    expect(find.text('CASH PENDING của chuyến hoàn thành'), findsOneWidget);
    expect(find.text('16.500 VND'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Lượt CASH đã xác nhận'), 300);
    expect(find.text('Lượt CASH đã xác nhận'), findsOneWidget);
    expect(find.text('Tiền mặt đã thu'), findsNothing);
    await tester.tap(find.descendant(
        of: find.byType(NavigationBar), matching: find.text('Tài xế')));
    await tester.pumpAndSettle();
    expect(find.text('Tài xế A'), findsOneWidget);
    await tester.tap(find.text('Tài xế A'));
    await tester.pumpAndSettle();
    expect(find.textContaining('29A-12345'), findsOneWidget);
    await tester.ensureVisible(find.text('Phê duyệt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Phê duyệt'));
    await tester.pumpAndSettle();
    expect(repository.approvals, isEmpty);
    expect(find.text('Xác nhận thay đổi duyệt tài xế'), findsOneWidget);
    expect(find.textContaining('từ Chờ duyệt sang Đã duyệt'), findsOneWidget);
    await tester.tap(find.text('Xác nhận'));
    await tester.pumpAndSettle();
    expect(repository.approvals, ['APPROVED']);
    expect(find.textContaining('Đã duyệt'), findsWidgets);
  });

  testWidgets('Background clears unsent phone and submitted email search text',
      (tester) async {
    final cubit = AdminCubit(repository, session, _adminId);
    await tester.pumpWidget(BlocProvider<AuthBloc>.value(
        value: auth,
        child: MaterialApp(
            home: AdminHomeScreen(adminPublicId: _adminId, cubit: cubit))));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byType(NavigationBar), matching: find.text('Tài khoản')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('admin-search')), 'admin@example.test');
    await tester.tap(find.byTooltip('Tìm kiếm'));
    await tester.pumpAndSettle();
    expect(cubit.state.search, 'admin@example.test');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(cubit.state.search, isNull);
    expect(
        tester
            .widget<TextField>(find.byKey(const Key('admin-search')))
            .controller!
            .text,
        isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(repository.calls.last, 'accounts:0:null:null:7');
    await tester.enterText(
        find.byKey(const Key('admin-search')), '09000000123');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(
        tester
            .widget<TextField>(find.byKey(const Key('admin-search')))
            .controller!
            .text,
        isEmpty);
    expect(cubit.state.search, isNull);
  });

  testWidgets(
      'Booking cards separate trip and CASH states and reveal server IDs',
      (tester) async {
    repository.bookingItems = [
      AdminBooking('booking-1', 'COMPLETED', 'MOTORBIKE', '16500.00', 'PENDING',
          currencyCode: 'VND',
          customerPublicId: 'customer-1',
          driverPublicId: 'driver-1',
          createdAt: DateTime(2026, 11, 1, 8, 30)),
      const AdminBooking(
          'booking-2', 'COMPLETED', 'CAR_4_SEAT', '20000.00', 'PAID'),
      const AdminBooking(
          'booking-3', 'CANCELLED', 'MOTORBIKE', '12000.00', 'VOID'),
    ];
    final cubit = AdminCubit(repository, session, _adminId);
    await tester.pumpWidget(BlocProvider<AuthBloc>.value(
        value: auth,
        child: MaterialApp(
            home: AdminHomeScreen(adminPublicId: _adminId, cubit: cubit))));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byType(NavigationBar), matching: find.text('Chuyến')));
    await tester.pumpAndSettle();
    expect(find.text('CASH chờ xác nhận'), findsOneWidget);
    expect(find.textContaining('16.500 VND'), findsOneWidget);
    expect(find.text('CASH đã xác nhận'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('CASH VOID · không thu'), 250);
    expect(find.text('CASH VOID · không thu'), findsOneWidget);
    await tester
        .ensureVisible(find.byKey(const ValueKey('admin-booking-booking-1')));
    await tester.tap(find.byKey(const ValueKey('admin-booking-booking-1')));
    await tester.pumpAndSettle();
    expect(find.text('customer-1'), findsOneWidget);
    expect(find.text('driver-1'), findsOneWidget);
    expect(find.text('01/11/2026 08:30'), findsOneWidget);
    expect(repository.calls.where((call) => call.startsWith('bookings:')),
        hasLength(1));
  });

  testWidgets('Backend currency VND appears on the Admin Booking card',
      (tester) async {
    repository.bookingItems = [
      AdminBooking.fromJson({
        'publicId': 'booking-vnd',
        'customerPublicId': 'customer-1',
        'driverPublicId': null,
        'status': 'COMPLETED',
        'vehicleType': 'MOTORBIKE',
        'finalFare': '16500.00',
        'currency': 'VND',
        'cashStatus': 'PENDING',
        'createdAt': '2026-11-01T08:30:00Z',
      }),
    ];
    final cubit = AdminCubit(repository, session, _adminId);
    await tester.pumpWidget(BlocProvider<AuthBloc>.value(
        value: auth,
        child: MaterialApp(
            home: AdminHomeScreen(adminPublicId: _adminId, cubit: cubit))));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byType(NavigationBar), matching: find.text('Chuyến')));
    await tester.pumpAndSettle();
    expect(find.text('Xe máy · 16.500 VND'), findsOneWidget);
  });

  testWidgets('Account empty, error and retry keep authorized pagination',
      (tester) async {
    repository.empty = true;
    final cubit = AdminCubit(repository, session, _adminId);
    await tester.pumpWidget(BlocProvider<AuthBloc>.value(
        value: auth,
        child: MaterialApp(
            home: AdminHomeScreen(adminPublicId: _adminId, cubit: cubit))));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byType(NavigationBar), matching: find.text('Tài khoản')));
    await tester.pumpAndSettle();
    expect(find.text('Không có tài khoản phù hợp'), findsOneWidget);
    repository.fail = true;
    await tester.tap(find.byTooltip('Làm mới'));
    await tester.pumpAndSettle();
    expect(find.text('Chưa tải được dữ liệu'), findsOneWidget);
    repository.fail = false;
    repository.empty = false;
    await tester.tap(find.text('Thử lại'));
    await tester.pumpAndSettle();
    expect(find.text('Khách A'), findsOneWidget);
    expect(repository.calls.last, 'accounts:0:null:null:7');
  });

  testWidgets('Approval dialog and Driver PII disappear on background',
      (tester) async {
    final cubit = AdminCubit(repository, session, _adminId);
    await tester.pumpWidget(BlocProvider<AuthBloc>.value(
        value: auth,
        child: MaterialApp(
            home: AdminHomeScreen(adminPublicId: _adminId, cubit: cubit))));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byType(NavigationBar), matching: find.text('Tài xế')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tài xế A'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Từ chối'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Từ chối'));
    await tester.pumpAndSettle();
    expect(find.text('Xác nhận thay đổi duyệt tài xế'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(find.text('Xác nhận thay đổi duyệt tài xế'), findsNothing);
    expect(find.text('0900000002'), findsNothing);
    expect(repository.approvals, isEmpty);
  });

  testWidgets('Premium Admin layouts fit 320 px and tablet with reduced motion',
      (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final cubit = AdminCubit(repository, session, _adminId);
    await tester.pumpWidget(BlocProvider<AuthBloc>.value(
        value: auth,
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!),
          home: AdminHomeScreen(adminPublicId: _adminId, cubit: cubit),
        )));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.descendant(
        of: find.byType(NavigationBar), matching: find.text('Tài xế')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Tài xế A'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Tạm đình chỉ'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.descendant(
        of: find.byType(NavigationBar), matching: find.text('Tài khoản')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Khách A'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.descendant(
        of: find.byType(NavigationBar), matching: find.text('Chuyến')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('admin-booking-booking-1')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(1000, 900);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
