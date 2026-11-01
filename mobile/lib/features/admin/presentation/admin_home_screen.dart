import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/di/injection.dart';
import '../../auth/domain/entities/user.dart';
import '../../auth/presentation/bloc/auth_bloc.dart';
import '../../auth/presentation/bloc/auth_event.dart';
import '../../auth/presentation/bloc/auth_state.dart';
import '../domain/admin_models.dart';
import 'admin_cubit.dart';

class AdminHomeScreen extends StatefulWidget {
  final String adminPublicId;
  final AdminCubit? cubit;

  const AdminHomeScreen({super.key, required this.adminPublicId, this.cubit});

  @override
  State<AdminHomeScreen> createState() => _AdminHomeScreenState();
}

class _AdminHomeScreenState extends State<AdminHomeScreen>
    with WidgetsBindingObserver {
  late final AdminCubit _cubit;
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _cubit = widget.cubit ?? sl<AdminCubit>(param1: widget.adminPublicId);
    _cubit.load();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _cubit.load();
    } else {
      _search.clear();
      _cubit.hideForBackground();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _search.dispose();
    _cubit.close();
    super.dispose();
  }

  bool _authorized(AuthState state) =>
      state is AuthenticatedState &&
      state.user.role == UserRole.admin &&
      state.user.publicId == widget.adminPublicId;

  @override
  Widget build(BuildContext context) => BlocProvider.value(
      value: _cubit,
      child: BlocConsumer<AuthBloc, AuthState>(
        listener: (context, auth) {
          if (!_authorized(auth)) {
            _search.clear();
            _cubit.invalidateSession();
          }
        },
        builder: (context, auth) {
          if (!_authorized(auth)) {
            return const Scaffold(
                body: Center(child: Text('Phiên quản trị đã thay đổi.')));
          }
          return BlocConsumer<AdminCubit, AdminState>(
            listener: (context, state) {
              if (state.sessionEnded &&
                  _authorized(context.read<AuthBloc>().state)) {
                context
                    .read<AuthBloc>()
                    .add(AuthForceUnauthenticated(widget.adminPublicId));
              }
            },
            builder: (context, state) => Scaffold(
              appBar: AppBar(title: const Text('Quản trị GoMove'), actions: [
                IconButton(
                    tooltip: 'Làm mới',
                    onPressed: state.sessionEnded ? null : _cubit.load,
                    icon: const Icon(Icons.refresh)),
                IconButton(
                    tooltip: 'Đăng xuất',
                    onPressed: () => context
                        .read<AuthBloc>()
                        .add(const AuthLogoutRequested()),
                    icon: const Icon(Icons.logout)),
              ]),
              body: state.sessionEnded
                  ? const Center(child: Text('Phiên quản trị đã kết thúc.'))
                  : SafeArea(
                      child: Center(
                          child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 900),
                              child: _content(context, state)))),
              bottomNavigationBar: NavigationBar(
                selectedIndex: state.tab.index,
                onDestinationSelected: state.sessionEnded
                    ? null
                    : (index) {
                        _search.clear();
                        _cubit.selectTab(AdminTab.values[index]);
                      },
                destinations: const [
                  NavigationDestination(
                      icon: Icon(Icons.dashboard_outlined), label: 'Tổng quan'),
                  NavigationDestination(
                      icon: Icon(Icons.drive_eta_outlined), label: 'Tài xế'),
                  NavigationDestination(
                      icon: Icon(Icons.people_outline), label: 'Tài khoản'),
                  NavigationDestination(
                      icon: Icon(Icons.receipt_long_outlined), label: 'Chuyến'),
                ],
              ),
            ),
          );
        },
      ));

  Widget _content(BuildContext context, AdminState state) {
    final children = <Widget>[];
    if (state.tab != AdminTab.dashboard) {
      children.add(_queryBar(state));
    }
    if (state.notice != null) {
      children.add(Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Card(
            child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(state.notice!),
        )),
      ));
    }
    if (state.loading) {
      children.add(const Padding(
          padding: EdgeInsets.all(40),
          child: Center(child: CircularProgressIndicator())));
    } else if (state.error != null) {
      children.add(Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(state.error!, textAlign: TextAlign.center),
            TextButton(onPressed: _cubit.load, child: const Text('Thử lại')),
          ])));
    } else {
      switch (state.tab) {
        case AdminTab.dashboard:
          children.addAll(_dashboard(context, state.dashboard));
          break;
        case AdminTab.drivers:
          children.addAll(_drivers(context, state));
          break;
        case AdminTab.accounts:
          children.addAll(_accounts(context, state));
          break;
        case AdminTab.bookings:
          children.addAll(_bookings(state));
          break;
      }
    }
    return ListView(padding: const EdgeInsets.all(16), children: children);
  }

  Widget _queryBar(AdminState state) {
    final options = switch (state.tab) {
      AdminTab.drivers => const [
          'PENDING',
          'APPROVED',
          'REJECTED',
          'SUSPENDED'
        ],
      AdminTab.accounts => const ['CUSTOMER', 'DRIVER', 'ADMIN'],
      AdminTab.bookings => const [
          'REQUESTED',
          'SEARCHING_DRIVER',
          'DRIVER_ACCEPTED',
          'DRIVER_ARRIVED',
          'PASSENGER_ONBOARD',
          'IN_PROGRESS',
          'COMPLETED',
          'CANCELLED',
          'NO_DRIVER_AVAILABLE'
        ],
      AdminTab.dashboard => const <String>[],
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(children: [
        if (state.tab != AdminTab.bookings)
          TextField(
            key: const Key('admin-search'),
            controller: _search,
            maxLength: 80,
            onSubmitted: (value) =>
                _cubit.setQuery(filter: state.filter, search: value),
            decoration: InputDecoration(
              labelText: 'Tìm theo tên, điện thoại hoặc mã',
              suffixIcon: IconButton(
                tooltip: 'Tìm kiếm',
                onPressed: () =>
                    _cubit.setQuery(filter: state.filter, search: _search.text),
                icon: const Icon(Icons.search),
              ),
            ),
          ),
        DropdownButtonFormField<String>(
          key: ValueKey('admin-filter-${state.tab.name}-${state.filter}'),
          initialValue: state.filter ?? '',
          decoration:
              const InputDecoration(labelText: 'Lọc trạng thái / vai trò'),
          items: [
            const DropdownMenuItem(value: '', child: Text('Tất cả')),
            for (final option in options)
              DropdownMenuItem(value: option, child: Text(option)),
          ],
          onChanged: (value) => _cubit.setQuery(
              filter: value == '' ? null : value, search: _search.text),
        ),
      ]),
    );
  }

  List<Widget> _dashboard(BuildContext context, AdminDashboard? data) {
    if (data == null) return [const Text('Chưa có dữ liệu tổng quan.')];
    const labels = <String, String>{
      'customers': 'Khách hàng',
      'drivers': 'Tài xế',
      'pendingApprovals': 'Chờ duyệt',
      'driversOnline': 'Tài xế ONLINE',
      'driversOffline': 'Tài xế OFFLINE',
      'driversBusy': 'Tài xế BUSY',
      'activeBookings': 'Chuyến đang hoạt động',
      'completedBookings': 'Chuyến hoàn thành',
      'cancelledBookings': 'Chuyến đã hủy',
      'noDriverAvailableBookings': 'Không có tài xế',
      'paidCashPayments': 'CASH đã thu',
      'collectiblePendingCashPayments': 'CASH chờ thu hợp lệ',
      'voidCashPayments': 'CASH không thu (VOID)',
    };
    return [
      Text('Hoạt động toàn thời gian',
          style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 12),
      Wrap(spacing: 10, runSpacing: 10, children: [
        for (final entry in labels.entries)
          SizedBox(
              width: 185,
              child: Card(
                  child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(entry.value),
                      Text('${data.counts[entry.key] ?? 0}',
                          style: Theme.of(context).textTheme.headlineSmall),
                    ]),
              ))),
      ]),
      const SizedBox(height: 16),
      Text('CASH chờ thu từ chuyến hoàn thành: ${data.collectibleAmount} VND'),
      Text('Giá trị placeholder không thu: ${data.voidAmount} VND'),
    ];
  }

  List<Widget> _drivers(BuildContext context, AdminState state) {
    final page = state.drivers;
    if (page == null) {
      return [
        if (state.driverDetail != null) _driverDetail(context, state),
        const Text(
            'Chưa có danh sách tài xế mới. Dùng Làm mới để kiểm tra trạng thái.'),
      ];
    }
    return [
      if (state.driverDetail != null) _driverDetail(context, state),
      if (page.items.isEmpty)
        const Center(child: Text('Không có tài xế phù hợp.')),
      for (final driver in page.items)
        Card(
            child: ListTile(
          key: ValueKey('admin-driver-${driver.publicId}'),
          title: Text(driver.fullName),
          subtitle: Text(
              '${driver.approvalStatus} · ${driver.operatingStatus} · ${driver.licenseNumber}'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _cubit.openDriver(driver.publicId),
        )),
      _pager(page.page, page.hasNext),
    ];
  }

  Widget _driverDetail(BuildContext context, AdminState state) {
    final driver = state.driverDetail!;
    return Card(
        child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(driver.fullName, style: Theme.of(context).textTheme.titleLarge),
        Text('Điện thoại: ${driver.phone}'),
        Text('Bằng lái: ${driver.licenseNumber}'),
        Text(
            'Duyệt: ${driver.approvalStatus} · Hoạt động: ${driver.operatingStatus}'),
        Text('Số chuyến: ${driver.totalTrips}'),
        if (driver.unreleasedBooking)
          const Text(
              'Đang có chuyến chưa giải phóng; không thể từ chối hoặc tạm đình chỉ.'),
        const SizedBox(height: 8),
        Text('Xe đã đăng ký', style: Theme.of(context).textTheme.titleMedium),
        if (driver.vehicles.isEmpty) const Text('Chưa đăng ký xe.'),
        for (final vehicle in driver.vehicles)
          Text('${vehicle.plate} · ${vehicle.type} · ${vehicle.description}'
              '${vehicle.active ? ' · Đang dùng' : ''}'),
        Wrap(spacing: 8, children: [
          for (final target in const ['APPROVED', 'REJECTED', 'SUSPENDED'])
            OutlinedButton(
              key: ValueKey('admin-approval-$target'),
              onPressed: state.working ||
                      state.approvalUncertain ||
                      state.approvalNeedsRefresh ||
                      driver.approvalStatus == target ||
                      (driver.unreleasedBooking && target != 'APPROVED')
                  ? null
                  : () => _confirmApproval(context, driver, target),
              child: Text(switch (target) {
                'APPROVED' => 'Phê duyệt',
                'REJECTED' => 'Từ chối',
                _ => 'Tạm đình chỉ',
              }),
            ),
        ]),
      ]),
    ));
  }

  Future<void> _confirmApproval(
      BuildContext context, AdminDriver driver, String target) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Xác nhận thay đổi duyệt tài xế'),
        content: Text('Đổi trạng thái của ${driver.fullName} '
            'từ ${driver.approvalStatus} sang $target?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Không')),
          FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Xác nhận')),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _cubit.setApproval(driver.publicId, target);
    }
  }

  List<Widget> _accounts(BuildContext context, AdminState state) {
    final page = state.accounts;
    if (page == null) return [const Text('Chưa có dữ liệu tài khoản.')];
    return [
      if (state.accountDetail != null)
        _accountDetail(context, state.accountDetail!),
      if (page.items.isEmpty)
        const Center(child: Text('Không có tài khoản phù hợp.')),
      for (final account in page.items)
        Card(
            child: ListTile(
          key: ValueKey('admin-account-${account.publicId}'),
          title: Text(account.fullName),
          subtitle: Text('${account.role} · ${account.status}'
              '${account.activeBooking ? ' · Đang có chuyến' : ''}'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _cubit.openAccount(account.publicId),
        )),
      _pager(page.page, page.hasNext),
    ];
  }

  Widget _accountDetail(BuildContext context, AdminAccount account) => Card(
          child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(account.fullName, style: Theme.of(context).textTheme.titleLarge),
          Text('Điện thoại: ${account.phone}'),
          if (account.email != null) Text('Email: ${account.email}'),
          Text('Vai trò: ${account.role} · Trạng thái: ${account.status}'),
          if (account.driverApprovalStatus != null)
            Text('Tài xế: ${account.driverApprovalStatus} · '
                '${account.driverOperatingStatus}'),
          Text(account.activeBooking
              ? 'Có chuyến đang hoạt động'
              : 'Không có chuyến đang hoạt động'),
          if (account.lastBookingAt != null)
            Text('Lần tạo/nhận chuyến gần nhất: ${account.lastBookingAt}'),
        ]),
      ));

  List<Widget> _bookings(AdminState state) {
    final page = state.bookings;
    if (page == null) return [const Text('Chưa có dữ liệu chuyến.')];
    return [
      if (page.items.isEmpty)
        const Center(child: Text('Không có chuyến phù hợp.')),
      for (final booking in page.items)
        Card(
            child: ListTile(
          key: ValueKey('admin-booking-${booking.publicId}'),
          title: Text(booking.status),
          subtitle: Text('${booking.publicId}\n${booking.vehicleType} · '
              '${booking.fare} VND · CASH ${booking.cashStatus}'),
          isThreeLine: true,
        )),
      _pager(page.page, page.hasNext),
    ];
  }

  Widget _pager(int page, bool hasNext) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
              tooltip: 'Trang trước',
              onPressed: page == 0 ? null : () => _cubit.goToPage(page - 1),
              icon: const Icon(Icons.chevron_left)),
          Text('Trang ${page + 1}'),
          IconButton(
              tooltip: 'Trang tiếp',
              onPressed: hasNext ? () => _cubit.goToPage(page + 1) : null,
              icon: const Icon(Icons.chevron_right)),
        ],
      );
}
