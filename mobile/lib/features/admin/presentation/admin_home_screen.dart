import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/di/injection.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/widgets/premium_panel.dart';
import '../../auth/domain/entities/user.dart';
import '../../auth/presentation/bloc/auth_bloc.dart';
import '../../auth/presentation/bloc/auth_event.dart';
import '../../auth/presentation/bloc/auth_state.dart';
import '../../review/domain/review_repository.dart';
import '../../review/presentation/admin_quality_screen.dart';
import '../../customer/presentation/formatters.dart';
import '../domain/admin_models.dart';
import 'admin_cubit.dart';
import 'widgets/admin_premium_widgets.dart';

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
  BuildContext? _approvalDialog;

  void _dismissApprovalDialog() {
    final dialog = _approvalDialog;
    _approvalDialog = null;
    if (dialog?.mounted == true && ModalRoute.of(dialog!)?.isCurrent == true) {
      Navigator.of(dialog).pop();
    }
  }

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
      _dismissApprovalDialog();
      _search.clear();
      _cubit.hideForBackground();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _dismissApprovalDialog();
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
            _dismissApprovalDialog();
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
    final children = <Widget>[
      AppMotion.entrance(
        context,
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_tabTitle(state.tab),
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
            const SizedBox(height: 3),
            Text(_tabDescription(state.tab),
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: AppColors.textSecondary)),
          ]),
        ),
      ),
    ];
    if (state.tab != AdminTab.dashboard) {
      children.add(_queryBar(state));
    }
    if (state.notice != null) {
      children.add(Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: PremiumPanel(
          tint: state.approvalUncertain || state.approvalNeedsRefresh
              ? const Color(0xFFFFF4DD)
              : AppColors.paleBlue,
          child: Text(state.notice!),
        ),
      ));
    }
    if (state.loading) {
      children.add(const PremiumPanel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Đang tải dữ liệu quản trị…'),
          SizedBox(height: 14),
          LinearProgressIndicator(),
        ]),
      ));
    } else if (state.error != null) {
      children.add(AdminEmptyPanel(
          icon: Icons.cloud_off_outlined,
          title: 'Chưa tải được dữ liệu',
          message: state.error!,
          onRetry: _cubit.load));
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
          children.addAll(_bookings(context, state));
          break;
      }
    }
    return RefreshIndicator(
      onRefresh: _cubit.load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: children,
      ),
    );
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
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
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
          isExpanded: true,
          initialValue: state.filter ?? '',
          decoration: InputDecoration(
              labelText: switch (state.tab) {
            AdminTab.drivers => 'Trạng thái phê duyệt',
            AdminTab.accounts => 'Vai trò tài khoản',
            AdminTab.bookings => 'Trạng thái chuyến',
            AdminTab.dashboard => 'Bộ lọc',
          }),
          items: [
            const DropdownMenuItem(value: '', child: Text('Tất cả')),
            for (final option in options)
              DropdownMenuItem(
                  value: option, child: Text(_filterLabel(state.tab, option))),
          ],
          onChanged: (value) => _cubit.setQuery(
              filter: value == '' ? null : value, search: _search.text),
        ),
      ]),
    );
  }

  List<Widget> _dashboard(BuildContext context, AdminDashboard? data) {
    if (data == null) {
      return [
        const AdminEmptyPanel(
            icon: Icons.dashboard_outlined,
            title: 'Chưa có dữ liệu tổng quan',
            message: 'Kéo xuống để tải lại số liệu quản trị.')
      ];
    }
    return [
      const PremiumSectionHeading(
          icon: Icons.people_outline,
          title: 'Tài khoản và tài xế',
          subtitle: 'Số lượng tại thời điểm tải dữ liệu'),
      const SizedBox(height: 10),
      AdminMetricGrid(children: [
        _metric(data, 'customers', 'Khách hàng', Icons.person_outline),
        _metric(data, 'drivers', 'Tài xế đăng ký', Icons.drive_eta_outlined),
        _metric(data, 'pendingApprovals', 'Tài xế chờ duyệt',
            Icons.pending_actions_outlined,
            tone: AdminTone.warning),
        _metric(data, 'driversOnline', 'Tài xế sẵn sàng',
            Icons.wifi_tethering_outlined,
            tone: AdminTone.success),
        _metric(data, 'driversOffline', 'Tài xế tạm nghỉ',
            Icons.offline_bolt_outlined),
        _metric(
            data, 'driversBusy', 'Tài xế đang phục vụ', Icons.route_outlined),
      ]),
      const SizedBox(height: 22),
      const PremiumSectionHeading(
          icon: Icons.receipt_long_outlined,
          title: 'Chuyến đi',
          subtitle: 'Số lượt tích lũy; trạng thái đang hoạt động là hiện tại'),
      const SizedBox(height: 10),
      AdminMetricGrid(children: [
        _metric(data, 'activeBookings', 'Chuyến đang hoạt động',
            Icons.directions_car_outlined),
        _metric(data, 'completedBookings', 'Chuyến hoàn thành',
            Icons.task_alt_outlined,
            tone: AdminTone.success),
        _metric(
            data, 'cancelledBookings', 'Chuyến đã hủy', Icons.cancel_outlined,
            tone: AdminTone.warning),
        _metric(data, 'noDriverAvailableBookings', 'Không có tài xế',
            Icons.person_off_outlined,
            tone: AdminTone.warning),
      ]),
      const SizedBox(height: 22),
      const PremiumSectionHeading(
          icon: Icons.payments_outlined,
          title: 'Thanh toán CASH',
          subtitle: 'Số lượt và số tiền được hiển thị riêng'),
      const SizedBox(height: 10),
      AdminMetricGrid(children: [
        _metric(data, 'paidCashPayments', 'Lượt CASH đã xác nhận',
            Icons.check_circle_outline,
            tone: AdminTone.success),
        _metric(data, 'collectiblePendingCashPayments',
            'Lượt CASH chờ xác nhận', Icons.hourglass_bottom_outlined,
            tone: AdminTone.warning),
        _metric(data, 'voidCashPayments', 'Lượt CASH VOID',
            Icons.money_off_outlined,
            tone: AdminTone.neutral),
      ]),
      const SizedBox(height: 10),
      PremiumPanel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const AdminInfoRow(
            'CASH PENDING của chuyến hoàn thành', 'Giá trị có thể thu'),
        Text(vnd(data.collectibleAmount),
            style: Theme.of(context).textTheme.titleLarge),
        const Divider(height: 24),
        const AdminInfoRow('CASH VOID', 'Giá trị không thu tiền'),
        Text(vnd(data.voidAmount),
            style: Theme.of(context).textTheme.titleLarge),
      ])),
      const SizedBox(height: 22),
      const PremiumSectionHeading(
          icon: Icons.fact_check_outlined,
          title: 'Chất lượng dịch vụ',
          subtitle: 'Dựa trên đánh giá và hồ sơ đã ghi nhận'),
      const SizedBox(height: 10),
      AdminMetricGrid(children: [
        _metric(data, 'ratedTrips', 'Chuyến được đánh giá', Icons.star_outline),
        _metric(
            data, 'flaggedDrivers', 'Tài xế cần rà soát', Icons.flag_outlined,
            tone: AdminTone.warning),
        _metric(data, 'goPointsAwarded', 'GoPoints đã cộng',
            Icons.add_circle_outline,
            tone: AdminTone.success),
        _metric(data, 'goPointsDeducted', 'GoPoints đã trừ',
            Icons.remove_circle_outline,
            tone: AdminTone.warning),
      ]),
      const SizedBox(height: 12),
      if (sl.isRegistered<ReviewRepository>())
        FilledButton.icon(
          onPressed: () => Navigator.of(context).push(
              AppMotion.immediateRoute<void>(
                  AdminQualityScreen(adminPublicId: widget.adminPublicId))),
          icon: const Icon(Icons.fact_check_outlined),
          label: const Text('Rà soát chất lượng tài xế'),
        ),
    ];
  }

  Widget _metric(AdminDashboard data, String key, String label, IconData icon,
          {AdminTone tone = AdminTone.info}) =>
      AdminMetricCard(
          label: label,
          value: data.counts[key]?.toString() ?? '—',
          icon: icon,
          tone: tone);

  List<Widget> _drivers(BuildContext context, AdminState state) {
    final page = state.drivers;
    if (page == null) {
      return [
        if (state.driverDetail != null) _driverDetail(context, state),
        const AdminEmptyPanel(
            icon: Icons.drive_eta_outlined,
            title: 'Chưa có danh sách tài xế',
            message: 'Kéo xuống để tải dữ liệu mới nhất.'),
      ];
    }
    return [
      if (state.driverDetail != null) _driverDetail(context, state),
      PremiumSectionHeading(
          icon: Icons.drive_eta_outlined,
          title: 'Tài xế đăng ký',
          subtitle: '${page.total} hồ sơ phù hợp'),
      const SizedBox(height: 10),
      if (page.items.isEmpty)
        const AdminEmptyPanel(
            icon: Icons.person_search_outlined,
            title: 'Không có tài xế phù hợp',
            message: 'Thử chọn trạng thái khác hoặc thay đổi từ khóa.'),
      for (final driver in page.items)
        Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: PremiumPanel(
                padding: EdgeInsets.zero,
                child: ListTile(
                  key: ValueKey('admin-driver-${driver.publicId}'),
                  title: Text(driver.fullName),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 7),
                    child: Wrap(spacing: 6, runSpacing: 6, children: [
                      AdminStatusBadge(_approval(driver.approvalStatus),
                          tone: _approvalTone(driver.approvalStatus)),
                      AdminStatusBadge(_operating(driver.operatingStatus),
                          tone: driver.operatingStatus == 'ONLINE'
                              ? AdminTone.success
                              : AdminTone.neutral),
                    ]),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _cubit.openDriver(driver.publicId),
                ))),
      _pager(page.page, page.hasNext),
    ];
  }

  Widget _driverDetail(BuildContext context, AdminState state) {
    final driver = state.driverDetail!;
    return Padding(
        padding: const EdgeInsets.only(bottom: 18),
        child: PremiumPanel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(driver.fullName,
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, children: [
              AdminStatusBadge(_approval(driver.approvalStatus),
                  tone: _approvalTone(driver.approvalStatus)),
              AdminStatusBadge(_operating(driver.operatingStatus),
                  tone: driver.operatingStatus == 'ONLINE'
                      ? AdminTone.success
                      : AdminTone.neutral),
            ]),
            const Divider(height: 24),
            const Text('Đăng ký và hoạt động'),
            AdminInfoRow('Điện thoại', driver.phone),
            AdminInfoRow('Số bằng lái', driver.licenseNumber),
            AdminInfoRow('Số chuyến', '${driver.totalTrips}'),
            AdminInfoRow(
                'Đánh giá',
                driver.ratingCount == 0 || driver.ratingAverage == null
                    ? 'Chưa có đánh giá từ khách hàng'
                    : '${driver.ratingAverage!.toStringAsFixed(2)} ★ · '
                        '${driver.ratingCount} đánh giá'),
            AdminInfoRow('GoPoints hiện có', '${driver.availablePoints}'),
            if (driver.qualityFlagged)
              const AdminStatusBadge('Cần rà soát chất lượng',
                  tone: AdminTone.warning),
            if (driver.unreleasedBooking)
              const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('Tài xế còn chuyến đang được gán. '
                      'Chưa thể từ chối hoặc tạm đình chỉ.')),
            const Divider(height: 24),
            Text('Xe đã đăng ký',
                style: Theme.of(context).textTheme.titleMedium),
            if (driver.vehicles.isEmpty) const Text('Chưa đăng ký xe.'),
            for (final vehicle in driver.vehicles)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(vehicle.plate,
                          style: Theme.of(context).textTheme.titleSmall),
                      Text(
                          '${_vehicle(vehicle.type)} · ${vehicle.description}'),
                      if (vehicle.active)
                        const AdminStatusBadge('Xe đang sử dụng',
                            tone: AdminTone.success),
                    ]),
              ),
            const Divider(height: 24),
            Text('Quyết định phê duyệt',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final target in const ['APPROVED', 'REJECTED', 'SUSPENDED'])
                if (target == 'APPROVED')
                  FilledButton(
                    key: ValueKey('admin-approval-$target'),
                    onPressed: state.working ||
                            state.approvalUncertain ||
                            state.approvalNeedsRefresh ||
                            driver.approvalStatus == target
                        ? null
                        : () => _confirmApproval(context, driver, target),
                    child: const Text('Phê duyệt'),
                  )
                else
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
      builder: (dialog) {
        _approvalDialog = dialog;
        return AlertDialog(
          title: const Text('Xác nhận thay đổi duyệt tài xế'),
          content: Text('Đổi trạng thái của ${driver.fullName} '
              'từ ${_approval(driver.approvalStatus)} sang ${_approval(target)}?'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialog, false),
                child: const Text('Không')),
            FilledButton(
                onPressed: () => Navigator.pop(dialog, true),
                child: const Text('Xác nhận')),
          ],
        );
      },
    );
    _approvalDialog = null;
    if (confirmed == true && mounted) {
      await _cubit.setApproval(driver.publicId, target);
    }
  }

  List<Widget> _accounts(BuildContext context, AdminState state) {
    final page = state.accounts;
    if (page == null) {
      return [
        const AdminEmptyPanel(
            icon: Icons.people_outline,
            title: 'Chưa có dữ liệu tài khoản',
            message: 'Kéo xuống để tải danh sách tài khoản.')
      ];
    }
    return [
      if (state.accountDetail != null)
        _accountDetail(context, state.accountDetail!),
      PremiumSectionHeading(
          icon: Icons.people_outline,
          title: 'Tài khoản',
          subtitle: '${page.total} tài khoản phù hợp · chỉ xem'),
      const SizedBox(height: 10),
      if (page.items.isEmpty)
        const AdminEmptyPanel(
            icon: Icons.person_search_outlined,
            title: 'Không có tài khoản phù hợp',
            message: 'Thử vai trò khác hoặc thay đổi từ khóa.'),
      for (final account in page.items)
        Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: PremiumPanel(
                padding: EdgeInsets.zero,
                child: ListTile(
                  key: ValueKey('admin-account-${account.publicId}'),
                  title: Text(account.fullName),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 7),
                    child: Wrap(spacing: 6, runSpacing: 6, children: [
                      AdminStatusBadge(_role(account.role)),
                      AdminStatusBadge(_accountStatus(account.status),
                          tone: account.status == 'ACTIVE'
                              ? AdminTone.success
                              : AdminTone.warning),
                      if (account.activeBooking)
                        const AdminStatusBadge('Đang có chuyến',
                            tone: AdminTone.info),
                    ]),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _cubit.openAccount(account.publicId),
                ))),
      _pager(page.page, page.hasNext),
    ];
  }

  Widget _accountDetail(BuildContext context, AdminAccount account) => Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: PremiumPanel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(account.fullName, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            AdminStatusBadge(_role(account.role)),
            AdminStatusBadge(_accountStatus(account.status),
                tone: account.status == 'ACTIVE'
                    ? AdminTone.success
                    : AdminTone.warning),
          ]),
          const Divider(height: 24),
          AdminInfoRow('Điện thoại', account.phone),
          if (account.email != null) AdminInfoRow('Email', account.email!),
          if (account.driverApprovalStatus != null)
            AdminInfoRow(
                'Tình trạng tài xế',
                '${_approval(account.driverApprovalStatus!)} · '
                    '${_operating(account.driverOperatingStatus)}'),
          AdminInfoRow(
              'Chuyến đang hoạt động', account.activeBooking ? 'Có' : 'Không'),
          if (account.lastBookingAt != null)
            AdminInfoRow('Lần tạo/nhận chuyến gần nhất',
                _date(DateTime.tryParse(account.lastBookingAt!))),
        ]),
      ));

  List<Widget> _bookings(BuildContext context, AdminState state) {
    final page = state.bookings;
    if (page == null) {
      return [
        const AdminEmptyPanel(
            icon: Icons.receipt_long_outlined,
            title: 'Chưa có dữ liệu chuyến',
            message: 'Kéo xuống để tải danh sách chuyến.')
      ];
    }
    return [
      PremiumSectionHeading(
          icon: Icons.receipt_long_outlined,
          title: 'Chuyến đi',
          subtitle: '${page.total} chuyến phù hợp'),
      const SizedBox(height: 10),
      if (page.items.isEmpty)
        const AdminEmptyPanel(
            icon: Icons.route_outlined,
            title: 'Không có chuyến phù hợp',
            message: 'Thử chọn trạng thái chuyến khác.'),
      for (final booking in page.items)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: PremiumPanel(
              padding: EdgeInsets.zero,
              child: ExpansionTile(
                key: ValueKey('admin-booking-${booking.publicId}'),
                tilePadding: const EdgeInsets.symmetric(horizontal: 16),
                expansionAnimationStyle: AnimationStyle(
                    duration: AppMotion.duration(context, AppMotion.card)),
                title: Text(_bookingStatus(booking.status)),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 7),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${_vehicle(booking.vehicleType)} · '
                            '${_bookingFare(booking)}'),
                        const SizedBox(height: 6),
                        Wrap(spacing: 6, runSpacing: 6, children: [
                          AdminStatusBadge(_bookingStatus(booking.status),
                              tone: _bookingTone(booking.status)),
                          AdminStatusBadge(_cash(booking.cashStatus),
                              tone: _cashTone(booking.cashStatus)),
                        ]),
                      ]),
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Divider(),
                          AdminInfoRow('Mã chuyến', booking.publicId),
                          AdminInfoRow('Mã khách hàng',
                              booking.customerPublicId ?? 'Chưa khả dụng'),
                          AdminInfoRow('Mã tài xế',
                              booking.driverPublicId ?? 'Chưa được gán'),
                          if (booking.createdAt != null)
                            AdminInfoRow(
                                'Thời điểm tạo', _date(booking.createdAt)),
                        ]),
                  ),
                ],
              )),
        ),
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

String _approval(String? value) => switch (value) {
      'PENDING' => 'Chờ duyệt',
      'APPROVED' => 'Đã duyệt',
      'REJECTED' => 'Đã từ chối',
      'SUSPENDED' => 'Tạm ngừng',
      _ => 'Chưa xác định',
    };

String _operating(String? value) => switch (value) {
      'ONLINE' => 'Sẵn sàng',
      'OFFLINE' => 'Tạm nghỉ',
      'BUSY' => 'Đang phục vụ',
      _ => 'Chưa xác định',
    };

String _role(String value) => switch (value) {
      'CUSTOMER' => 'Khách hàng',
      'DRIVER' => 'Tài xế',
      'ADMIN' => 'Quản trị',
      _ => 'Chưa xác định',
    };

String _accountStatus(String value) => switch (value) {
      'ACTIVE' => 'Đang hoạt động',
      'LOCKED' => 'Tạm khóa',
      'DISABLED' => 'Ngừng hoạt động',
      _ => value,
    };

String _bookingStatus(String value) => switch (value) {
      'REQUESTED' => 'Đã yêu cầu chuyến',
      'SEARCHING_DRIVER' => 'Đang tìm tài xế',
      'DRIVER_ACCEPTED' => 'Tài xế đã nhận chuyến',
      'DRIVER_ARRIVED' => 'Tài xế đã đến điểm đón',
      'PASSENGER_ONBOARD' => 'Đã đón khách',
      'IN_PROGRESS' => 'Đang di chuyển',
      'COMPLETED' => 'Đã hoàn thành',
      'CANCELLED' => 'Đã hủy',
      'NO_DRIVER_AVAILABLE' => 'Không tìm được tài xế',
      _ => 'Chưa xác định',
    };

String _vehicle(String value) => switch (value) {
      'MOTORBIKE' => 'Xe máy',
      'CAR_4_SEAT' => 'Ô tô 4 chỗ',
      'CAR_7_SEAT' => 'Ô tô 7 chỗ',
      _ => value,
    };

String _cash(String value) => switch (value) {
      'PAID' => 'CASH đã xác nhận',
      'PENDING' => 'CASH chờ xác nhận',
      'VOID' => 'CASH VOID · không thu',
      _ => 'Chưa có thông tin CASH',
    };

String _bookingFare(AdminBooking booking) => switch (booking.currencyCode) {
      'VND' => vnd(booking.fare),
      final code? => '${booking.fare} $code',
      null => booking.fare,
    };

String _tabTitle(AdminTab tab) => switch (tab) {
      AdminTab.dashboard => 'Tổng quan',
      AdminTab.drivers => 'Quản lý tài xế',
      AdminTab.accounts => 'Tài khoản',
      AdminTab.bookings => 'Theo dõi chuyến',
    };

String _tabDescription(AdminTab tab) => switch (tab) {
      AdminTab.dashboard => 'Số liệu thật từ hệ thống GoMove',
      AdminTab.drivers => 'Xem hồ sơ và quyết định phê duyệt',
      AdminTab.accounts => 'Tra cứu tài khoản được cấp quyền xem',
      AdminTab.bookings => 'Trạng thái chuyến và thanh toán CASH',
    };

String _filterLabel(AdminTab tab, String value) => switch (tab) {
      AdminTab.drivers => _approval(value),
      AdminTab.accounts => _role(value),
      AdminTab.bookings => _bookingStatus(value),
      AdminTab.dashboard => value,
    };

AdminTone _approvalTone(String status) => switch (status) {
      'APPROVED' => AdminTone.success,
      'PENDING' => AdminTone.warning,
      'REJECTED' || 'SUSPENDED' => AdminTone.danger,
      _ => AdminTone.neutral,
    };

AdminTone _bookingTone(String status) => switch (status) {
      'COMPLETED' => AdminTone.success,
      'CANCELLED' || 'NO_DRIVER_AVAILABLE' => AdminTone.warning,
      _ => AdminTone.info,
    };

AdminTone _cashTone(String status) => switch (status) {
      'PAID' => AdminTone.success,
      'PENDING' => AdminTone.warning,
      _ => AdminTone.neutral,
    };

String _date(DateTime? value) {
  if (value == null) return 'Chưa khả dụng';
  final local = value.toLocal();
  String two(int part) => part.toString().padLeft(2, '0');
  return '${two(local.day)}/${two(local.month)}/${local.year} '
      '${two(local.hour)}:${two(local.minute)}';
}
