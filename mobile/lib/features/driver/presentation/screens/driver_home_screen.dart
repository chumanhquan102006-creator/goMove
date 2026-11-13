import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/config/app_config.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_motion.dart';
import '../../../../core/widgets/premium_panel.dart';
import '../../../auth/domain/entities/user.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../../auth/presentation/bloc/auth_event.dart';
import '../../../auth/presentation/bloc/auth_state.dart';
import '../../../customer/presentation/formatters.dart';
import '../../../review/domain/review_repository.dart';
import '../../../review/presentation/driver_reputation_cubit.dart';
import '../../../review/presentation/driver_reputation_screen.dart';
import '../../domain/models/driver_models.dart';
import '../../domain/repositories/driver_earnings_repository.dart';
import '../bloc/driver_cubit.dart';
import '../bloc/driver_earnings_cubit.dart';
import 'driver_accepted_booking_screen.dart';

class DriverHomeScreen extends StatelessWidget {
  final User user;
  const DriverHomeScreen({super.key, required this.user});

  @override
  Widget build(BuildContext context) {
    final driver = BlocProvider<DriverCubit>(
      create: (_) => sl<DriverCubit>(param1: user.publicId)..initialize(),
      child: _DriverContent(user: user),
    );
    Widget screen = driver;
    if (sl.isRegistered<ReviewRepository>() && !AppConfig.instance.isMock) {
      screen = BlocProvider<DriverReputationCubit>(
        create: (_) => sl<DriverReputationCubit>(param1: user.publicId)..load(),
        child: screen,
      );
    }
    if (sl.isRegistered<DriverEarningsRepository>() &&
        !AppConfig.instance.isMock) {
      screen = BlocProvider<DriverEarningsCubit>(
        create: (_) => sl<DriverEarningsCubit>(param1: user.publicId)..load(),
        child: screen,
      );
    }
    return screen;
  }
}

class _DriverContent extends StatefulWidget {
  final User user;
  const _DriverContent({required this.user});

  @override
  State<_DriverContent> createState() => _DriverContentState();
}

class _DriverContentState extends State<_DriverContent>
    with WidgetsBindingObserver {
  Timer? _countdown;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startCountdown();
  }

  void _startCountdown() {
    _countdown?.cancel();
    _countdown = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && context.read<DriverCubit>().state.offer != null) {
        setState(() {});
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startCountdown();
      context.read<DriverCubit>().resume();
      if (sl.isRegistered<ReviewRepository>() && !AppConfig.instance.isMock) {
        context.read<DriverReputationCubit>().load();
      }
      if (sl.isRegistered<DriverEarningsRepository>() &&
          !AppConfig.instance.isMock) {
        context.read<DriverEarningsCubit>().load();
      }
    } else {
      _countdown?.cancel();
      _countdown = null;
      context.read<DriverCubit>().pause();
      if (sl.isRegistered<ReviewRepository>() && !AppConfig.instance.isMock) {
        context.read<DriverReputationCubit>().hideForBackground();
      }
      if (sl.isRegistered<DriverEarningsRepository>() &&
          !AppConfig.instance.isMock) {
        context.read<DriverEarningsCubit>().hideForBackground();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _countdown?.cancel();
    super.dispose();
  }

  void _addVehicle() {
    final plate = TextEditingController();
    final brand = TextEditingController();
    final model = TextEditingController();
    final color = TextEditingController();
    var type = 'MOTORBIKE';
    showDialog<void>(
        context: context,
        builder: (dialog) => StatefulBuilder(
            builder: (dialog, update) => AlertDialog(
                  title: const Text('Thêm xe'),
                  content: SingleChildScrollView(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextField(
                        controller: plate,
                        maxLength: 20,
                        decoration:
                            const InputDecoration(labelText: 'Biển số xe')),
                    DropdownButtonFormField<String>(
                        initialValue: type,
                        items: const [
                          DropdownMenuItem(
                              value: 'MOTORBIKE', child: Text('Xe máy')),
                          DropdownMenuItem(
                              value: 'CAR_4_SEAT', child: Text('Ô tô 4 chỗ')),
                          DropdownMenuItem(
                              value: 'CAR_7_SEAT', child: Text('Ô tô 7 chỗ')),
                        ],
                        onChanged: (value) =>
                            update(() => type = value ?? type)),
                    TextField(
                        controller: brand,
                        maxLength: 50,
                        decoration:
                            const InputDecoration(labelText: 'Hãng xe')),
                    TextField(
                        controller: model,
                        maxLength: 50,
                        decoration:
                            const InputDecoration(labelText: 'Dòng xe')),
                    TextField(
                        controller: color,
                        maxLength: 30,
                        decoration: const InputDecoration(labelText: 'Màu xe')),
                  ])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(dialog),
                        child: const Text('Hủy')),
                    FilledButton(
                        onPressed: () {
                          if (plate.text.trim().isEmpty) return;
                          context.read<DriverCubit>().addVehicle(VehicleDraft(
                              plate.text.trim(), type,
                              brand: brand.text.trim(),
                              model: model.text.trim(),
                              color: color.text.trim()));
                          Navigator.pop(dialog);
                        },
                        child: const Text('Lưu')),
                  ],
                )));
  }

  @override
  Widget build(BuildContext context) => BlocListener<AuthBloc, AuthState>(
        listener: (context, auth) {
          if (auth is! AuthenticatedState ||
              auth.user.publicId != widget.user.publicId) {
            _countdown?.cancel();
            _countdown = null;
            context.read<DriverCubit>().pause();
            if (sl.isRegistered<ReviewRepository>() &&
                !AppConfig.instance.isMock) {
              context.read<DriverReputationCubit>().invalidateSession();
            }
            if (sl.isRegistered<DriverEarningsRepository>() &&
                !AppConfig.instance.isMock) {
              context.read<DriverEarningsCubit>().invalidateSession();
            }
          }
        },
        child: BlocListener<DriverCubit, DriverState>(
          listenWhen: (previous, current) =>
              previous.acceptedOffer == null && current.acceptedOffer != null,
          listener: (context, state) {
            Navigator.of(context).push(AppMotion.immediateRoute<void>(
              DriverAcceptedBookingScreen(
                  offer: state.acceptedOffer!,
                  driverCubit: context.read<DriverCubit>()),
            ));
          },
          child: Scaffold(
            appBar: AppBar(title: const Text('GoMove Tài xế'), actions: [
              IconButton(
                  tooltip: 'Đăng xuất',
                  icon: const Icon(Icons.logout),
                  onPressed: () {
                    context.read<DriverCubit>().pause();
                    context.read<AuthBloc>().add(const AuthLogoutRequested());
                  }),
            ]),
            body: BlocBuilder<DriverCubit, DriverState>(
              builder: (context, state) {
                final offer = state.offer;
                final seconds = offer == null
                    ? 0
                    : remainingOfferSeconds(
                        offer.expiresAt, DateTime.now().toUtc());
                final canDecide = offer != null &&
                    seconds > 0 &&
                    !state.offerActionBusy &&
                    !state.actionBusy &&
                    !state.unresolvedDecision &&
                    state.foreground &&
                    state.operatingStatus == 'ONLINE';
                final scheme = Theme.of(context).colorScheme;
                return ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                  children: [
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 720),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text('Xin chào, ${widget.user.fullName}',
                                style:
                                    Theme.of(context).textTheme.headlineSmall),
                            const SizedBox(height: 4),
                            Text('GoMove - Chúc bạn lái xe an toàn!',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyMedium
                                    ?.copyWith(color: AppColors.textSecondary)),
                            const SizedBox(height: 18),
                            if (state.loading) const LinearProgressIndicator(),
                            if (state.actionBusy)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 8),
                                child: Text('Đang cập nhật với máy chủ…'),
                              ),
                            if (state.error != null) ...[
                              PremiumPanel(
                                tint: scheme.errorContainer,
                                child: Text(state.error!,
                                    style: TextStyle(
                                        color: scheme.onErrorContainer)),
                              ),
                              const SizedBox(height: 12),
                            ],
                            if (state.notice != null) ...[
                              PremiumPanel(child: Text(state.notice!)),
                              const SizedBox(height: 12),
                            ],
                            // A live offer or accepted trip must be visible
                            // before the informational dashboard cards.
                            if (state.acceptedOffer != null) ...[
                              _bookingPanel(state.acceptedOffer!),
                              const SizedBox(height: 14),
                            ],
                            if (offer != null &&
                                state.acceptedOffer == null) ...[
                              _offerPanel(
                                  context, state, offer, seconds, canDecide),
                              const SizedBox(height: 14),
                            ],
                            _statusPanel(context, state),
                            const SizedBox(height: 14),
                            if (sl.isRegistered<DriverEarningsRepository>() &&
                                !AppConfig.instance.isMock) ...[
                              _earningsPanel(context),
                              const SizedBox(height: 14),
                            ],
                            if (sl.isRegistered<ReviewRepository>() &&
                                !AppConfig.instance.isMock) ...[
                              _reputationPanel(context),
                              const SizedBox(height: 14),
                            ],
                            _vehiclesPanel(context, state),
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      );

  Widget _statusPanel(BuildContext context, DriverState state) {
    final cubit = context.read<DriverCubit>();
    final scheme = Theme.of(context).colorScheme;
    return PremiumPanel(
      key: const ValueKey('driver-home-status-panel'),
      highlighted: state.operatingStatus == 'ONLINE',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        PremiumSectionHeading(
          icon: state.operatingStatus == 'BUSY'
              ? Icons.route_outlined
              : Icons.power_settings_new,
          title: state.operatingStatus == 'BUSY'
              ? 'Đang phục vụ chuyến'
              : 'Trạng thái hoạt động',
          subtitle: 'Chỉ nhận đề nghị khi tài khoản, xe và GPS hợp lệ',
        ),
        const SizedBox(height: 14),
        Wrap(spacing: 8, runSpacing: 4, children: [
          _statusChip(
            icon: state.operatingStatus == 'ONLINE'
                ? Icons.radio_button_checked
                : Icons.radio_button_off,
            label: _operatingLabel(state.operatingStatus),
            active: state.operatingStatus == 'ONLINE',
          ),
          _statusChip(
            icon: state.approvalStatus == 'APPROVED'
                ? Icons.verified_outlined
                : Icons.info_outline,
            label: _approvalLabel(state.approvalStatus),
            active: state.approvalStatus == 'APPROVED',
          ),
        ]),
        const SizedBox(height: 14),
        _infoRow(
          Icons.two_wheeler_outlined,
          'Xe đang dùng',
          state.activeVehicle == null
              ? 'Chưa có xe hoạt động'
              : '${state.activeVehicle!.licensePlate} · '
                  '${_vehicleLabel(state.activeVehicle!.vehicleType)}',
        ),
        const SizedBox(height: 10),
        _infoRow(Icons.location_on_outlined, 'GPS', state.locationMessage),
        if (!state.foreground) ...[
          const SizedBox(height: 8),
          const Text('Ứng dụng nền: GPS sẽ không còn mới để nhận cuốc.'),
        ],
        if (state.locationProblem != null)
          TextButton.icon(
            onPressed: cubit.openLocationSettings,
            icon: const Icon(Icons.settings_outlined),
            label: const Text('Mở Cài đặt vị trí'),
          ),
        if (state.approvalStatus != null &&
            state.approvalStatus != 'APPROVED' &&
            state.operatingStatus != 'ONLINE') ...[
          const SizedBox(height: 8),
          Text('Cần được phê duyệt trước khi nhận cuốc.',
              style: TextStyle(color: scheme.onSurfaceVariant)),
        ],
        if (state.operatingStatus != 'BUSY') ...[
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: state.operatingStatus == 'ONLINE'
                ? OutlinedButton.icon(
                    onPressed: _canChangeStatus(state) ? cubit.goOffline : null,
                    icon: const Icon(Icons.pause_circle_outline),
                    label: const Text('Ngừng nhận chuyến'),
                  )
                : FilledButton.icon(
                    onPressed: _canChangeStatus(state) ? cubit.goOnline : null,
                    icon: const Icon(Icons.power_settings_new),
                    label: const Text('Bắt đầu nhận chuyến'),
                  ),
          ),
        ],
      ]),
    );
  }

  Widget _offerPanel(BuildContext context, DriverState state, DriverOffer offer,
      int seconds, bool canDecide) {
    final scheme = Theme.of(context).colorScheme;
    return TweenAnimationBuilder<double>(
      key: ValueKey('driver-offer-${offer.offerPublicId}'),
      tween: Tween(begin: 0, end: 1),
      duration: AppMotion.duration(context, AppMotion.card),
      curve: AppMotion.enterCurve,
      builder: (context, value, child) {
        if (AppMotion.reduceMotion(context)) return child!;
        return Transform.translate(
          offset: Offset(0, AppMotion.cardTravel * (1 - value)),
          child: Opacity(opacity: value, child: child),
        );
      },
      child: PremiumPanel(
        highlighted: true,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const PremiumSectionHeading(
            icon: Icons.notifications_active_outlined,
            title: 'Đề nghị nhận chuyến',
            subtitle: 'Xem hành trình trước khi quyết định',
          ),
          const SizedBox(height: 12),
          Text('Thời gian còn ${seconds > 0 ? seconds : 0} giây để phản hồi',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: seconds > 0 ? scheme.primary : scheme.error,
                  )),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: (seconds / 15).clamp(0.0, 1.0),
              minHeight: 6,
              semanticsLabel: 'Thời gian phản hồi đề nghị',
            ),
          ),
          const SizedBox(height: 16),
          _offerDetails(offer),
          if (seconds == 0) ...[
            const SizedBox(height: 8),
            const Text('Đề nghị đã hết hạn. Hãy chờ cuốc tiếp theo.'),
          ],
          if (state.offerActionBusy) ...[
            const SizedBox(height: 10),
            const Row(children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 8),
              Expanded(child: Text('Đang gửi quyết định đến máy chủ…')),
            ]),
          ],
          if (state.unresolvedDecision)
            TextButton(
              onPressed: context.read<DriverCubit>().reconcile,
              child: const Text('Kiểm tra lại kết quả'),
            ),
          const SizedBox(height: 14),
          LayoutBuilder(builder: (context, constraints) {
            final decline = OutlinedButton(
              onPressed: canDecide
                  ? () => context.read<DriverCubit>().decide(false)
                  : null,
              child: const Text('Từ chối'),
            );
            final accept = FilledButton(
              onPressed: canDecide
                  ? () => context.read<DriverCubit>().decide(true)
                  : null,
              child: const Text('Nhận chuyến'),
            );
            if (constraints.maxWidth < 270 ||
                MediaQuery.textScalerOf(context).scale(14) > 17) {
              return Column(children: [
                SizedBox(width: double.infinity, child: accept),
                const SizedBox(height: 8),
                SizedBox(width: double.infinity, child: decline),
              ]);
            }
            return Row(children: [
              Expanded(child: decline),
              const SizedBox(width: 8),
              Expanded(child: accept),
            ]);
          }),
        ]),
      ),
    );
  }

  Widget _bookingPanel(DriverOffer offer) => PremiumPanel(
        key: const ValueKey('driver-home-active-trip-panel'),
        highlighted: true,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const PremiumSectionHeading(
            icon: Icons.route_outlined,
            title: 'Đang phục vụ chuyến',
            subtitle: 'Tiếp tục hành trình đã nhận',
          ),
          const SizedBox(height: 14),
          _offerDetails(offer),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => Navigator.of(context).push(
                  AppMotion.immediateRoute<void>(DriverAcceptedBookingScreen(
                offer: offer,
                driverCubit: context.read<DriverCubit>(),
              ))),
              icon: const Icon(Icons.route_outlined),
              label: const Text('Xem chuyến đã nhận'),
            ),
          ),
        ]),
      );

  Widget _earningsPanel(BuildContext context) =>
      BlocBuilder<DriverEarningsCubit, DriverEarningsState>(
        builder: (context, state) {
          if (state.sessionEnded) return const SizedBox.shrink();
          final summary = state.summary;
          return PremiumPanel(
            key: const ValueKey('driver-home-earnings-panel'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const PremiumSectionHeading(
                  icon: Icons.payments_outlined,
                  title: 'Tổng kết tiền mặt',
                  subtitle: 'Các chuyến đã xác nhận thu tiền',
                ),
                if (state.loading) ...[
                  const SizedBox(height: 14),
                  const LinearProgressIndicator(),
                ],
                if (state.error != null) ...[
                  const SizedBox(height: 12),
                  Text(state.error!),
                  TextButton.icon(
                    onPressed: context.read<DriverEarningsCubit>().load,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Tải lại'),
                  ),
                ],
                if (summary != null) ...[
                  const SizedBox(height: 16),
                  Text('${summary.paidTripCount} chuyến đã xác nhận',
                      style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 12),
                  _amountRow(
                      'Tiền mặt đã thu', vnd(summary.cashCollectedAmount)),
                  _amountRow('Hoa hồng phải nộp', vnd(summary.commissionDue)),
                  const Divider(height: 24),
                  _amountRow('Giá trị sau hoa hồng',
                      vnd(summary.afterCommissionAmount),
                      emphasized: true),
                  const SizedBox(height: 10),
                  Text(
                    'Đây là tổng kết ghi nhận, không xác nhận hoa hồng đã được nộp.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppColors.textSecondary,
                        ),
                  ),
                ],
              ],
            ),
          );
        },
      );

  Widget _reputationPanel(BuildContext context) =>
      BlocBuilder<DriverReputationCubit, DriverReputationState>(
        builder: (context, state) {
          if (state.sessionEnded) return const SizedBox.shrink();
          final reputation = state.reputation;
          return PremiumPanel(
            key: const ValueKey('driver-home-reputation-panel'),
            padding: EdgeInsets.zero,
            child: InkWell(
              borderRadius: BorderRadius.circular(24),
              onTap: () => Navigator.of(context).push(
                AppMotion.immediateRoute<void>(DriverReputationScreen(
                    driverPublicId: widget.user.publicId)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const PremiumSectionHeading(
                      icon: Icons.workspace_premium_outlined,
                      title: 'Đánh giá và GoPoints',
                      subtitle: 'Điểm ghi nhận từ những chuyến đã đánh giá',
                    ),
                    if (state.loading) ...[
                      const SizedBox(height: 12),
                      const LinearProgressIndicator(),
                    ],
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(
                        child: Text(
                          reputation == null
                              ? state.loading
                                  ? 'Đang tải đánh giá…'
                                  : state.error != null
                                      ? 'Chưa tải được đánh giá'
                                      : 'Đang xác minh đánh giá'
                              : reputation.ratingCount == 0 ||
                                      reputation.average == null
                                  ? 'Chưa có đánh giá'
                                  : '${reputation.average!.toStringAsFixed(2)} ★ · '
                                      '${reputation.ratingCount} đánh giá',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      const Icon(Icons.chevron_right_rounded,
                          color: AppColors.primary),
                    ]),
                    const SizedBox(height: 4),
                    Text(
                      reputation == null
                          ? 'Xem đánh giá và GoPoints của bạn'
                          : '${reputation.availablePoints} GoPoints hiện có',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );

  Widget _vehiclesPanel(BuildContext context, DriverState state) {
    final scheme = Theme.of(context).colorScheme;
    final cubit = context.read<DriverCubit>();
    return PremiumPanel(
      key: const ValueKey('driver-home-vehicles-panel'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const PremiumSectionHeading(
          icon: Icons.directions_car_outlined,
          title: 'Xe của tôi',
          subtitle: 'Xe đang hoạt động cần được xác minh để nhận cuốc',
        ),
        const SizedBox(height: 12),
        if (state.vehicles.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child:
                Text('Chưa có xe. Thêm và kích hoạt xe trước khi trực tuyến.'),
          ),
        for (final vehicle in state.vehicles)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.directions_car_outlined,
                color:
                    vehicle.active ? scheme.primary : scheme.onSurfaceVariant),
            title: Text('${vehicle.licensePlate} · '
                '${_vehicleLabel(vehicle.vehicleType)}'),
            subtitle:
                Text(vehicle.active ? 'Đang kích hoạt' : 'Chưa kích hoạt'),
            trailing: vehicle.active
                ? const Icon(Icons.check_circle, color: AppColors.success)
                : TextButton(
                    onPressed: AppConfig.instance.isMock || state.actionBusy
                        ? null
                        : () => cubit.activateVehicle(vehicle.publicId),
                    child: const Text('Kích hoạt'),
                  ),
          ),
        const SizedBox(height: 4),
        OutlinedButton.icon(
          onPressed: AppConfig.instance.isMock || state.actionBusy
              ? null
              : _addVehicle,
          icon: const Icon(Icons.add),
          label: const Text('Thêm xe'),
        ),
      ]),
    );
  }

  Widget _offerDetails(DriverOffer offer) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _infoRow(Icons.trip_origin, 'Điểm đón',
              '${offer.pickupLatitude}, ${offer.pickupLongitude}'),
          const SizedBox(height: 10),
          _infoRow(Icons.location_on_outlined, 'Điểm đến',
              '${offer.dropoffLatitude}, ${offer.dropoffLongitude}'),
          const SizedBox(height: 12),
          Text(
              '${_vehicleLabel(offer.vehicleType)} · '
              'Giá đã chấp nhận: ${vnd(offer.finalFare)}',
              style: Theme.of(context).textTheme.titleMedium),
        ],
      );

  Widget _infoRow(IconData icon, String label, String value) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: AppColors.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color: AppColors.textSecondary,
                        )),
                const SizedBox(height: 2),
                Text(value, style: Theme.of(context).textTheme.bodyMedium),
              ],
            ),
          ),
        ],
      );

  Widget _amountRow(String label, String value, {bool emphasized = false}) =>
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: Text(label)),
        const SizedBox(width: 8),
        Flexible(
          child: Text(value,
              textAlign: TextAlign.end,
              style: emphasized
                  ? Theme.of(context).textTheme.titleMedium
                  : Theme.of(context).textTheme.bodyMedium),
        ),
      ]);

  bool _canChangeStatus(DriverState state) =>
      !AppConfig.instance.isMock &&
      !state.actionBusy &&
      !state.offerActionBusy &&
      !state.loading &&
      !state.unresolvedDecision &&
      state.acceptedOffer == null &&
      state.foreground &&
      (state.operatingStatus == 'ONLINE' ||
          ((state.approvalStatus == null ||
                  state.approvalStatus == 'APPROVED') &&
              state.activeVehicle != null));

  Widget _statusChip(
      {required IconData icon, required String label, required bool active}) {
    final scheme = Theme.of(context).colorScheme;
    return Chip(
      avatar: Icon(icon,
          size: 18,
          color: active ? scheme.onPrimaryContainer : scheme.onSurfaceVariant),
      label: Text(label),
      backgroundColor:
          active ? scheme.primaryContainer : scheme.surfaceContainerHighest,
      side: BorderSide.none,
    );
  }
}

String _operatingLabel(String? status) => switch (status) {
      'ONLINE' => 'Đang nhận chuyến',
      'OFFLINE' => 'Tạm nghỉ',
      'BUSY' => 'Đang phục vụ',
      _ => 'Chưa xác định',
    };

String _approvalLabel(String? status) => switch (status) {
      'APPROVED' => 'Đã duyệt',
      'PENDING' => 'Chờ duyệt',
      'REJECTED' => 'Từ chối',
      'SUSPENDED' => 'Tạm khóa',
      _ => 'Chưa xác định',
    };

String _vehicleLabel(String? type) => switch (type) {
      'MOTORBIKE' => 'Xe máy',
      'CAR_4_SEAT' => 'Ô tô 4 chỗ',
      'CAR_7_SEAT' => 'Ô tô 7 chỗ',
      _ => type ?? 'Chưa xác định',
    };
