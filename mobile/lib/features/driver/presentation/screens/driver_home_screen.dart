import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../../core/config/app_config.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/theme/app_motion.dart';
import '../../../auth/domain/entities/user.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../../auth/presentation/bloc/auth_event.dart';
import '../../../auth/presentation/bloc/auth_state.dart';
import '../../../customer/presentation/formatters.dart';
import '../../domain/models/driver_models.dart';
import '../bloc/driver_cubit.dart';
import 'driver_accepted_booking_screen.dart';

class DriverHomeScreen extends StatelessWidget {
  final User user;
  const DriverHomeScreen({super.key, required this.user});

  @override
  Widget build(BuildContext context) => BlocProvider(
        create: (_) => sl<DriverCubit>(param1: user.publicId)..initialize(),
        child: _DriverContent(user: user),
      );
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
    } else {
      _countdown?.cancel();
      _countdown = null;
      context.read<DriverCubit>().pause();
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
          }
        },
        child: BlocListener<DriverCubit, DriverState>(
          listenWhen: (previous, current) =>
              previous.acceptedOffer == null && current.acceptedOffer != null,
          listener: (context, state) {
            Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => DriverAcceptedBookingScreen(
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
              final cubit = context.read<DriverCubit>();
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
              return ListView(padding: const EdgeInsets.all(16), children: [
                Text('Xin chào, ${widget.user.fullName}',
                    style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 4),
                Text('Quản lý trạng thái và chuyến đi của bạn',
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: scheme.onSurfaceVariant)),
                const SizedBox(height: 16),
                if (state.loading) const LinearProgressIndicator(),
                if (state.actionBusy)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text('Đang cập nhật với máy chủ…'),
                  ),
                if (state.error != null)
                  Card(
                      color: scheme.errorContainer,
                      child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(state.error!,
                              style:
                                  TextStyle(color: scheme.onErrorContainer)))),
                if (state.notice != null)
                  Card(
                      child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(state.notice!))),
                Card(
                    child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                                state.operatingStatus == 'BUSY'
                                    ? 'Đang phục vụ chuyến'
                                    : 'Trạng thái hoạt động',
                                style: Theme.of(context).textTheme.titleMedium),
                            const SizedBox(height: 10),
                            Wrap(spacing: 8, runSpacing: 4, children: [
                              _statusChip(
                                  icon: state.operatingStatus == 'ONLINE'
                                      ? Icons.radio_button_checked
                                      : Icons.radio_button_off,
                                  label:
                                      'Trạng thái: ${_operatingLabel(state.operatingStatus)}',
                                  active: state.operatingStatus == 'ONLINE'),
                              _statusChip(
                                  icon: state.approvalStatus == 'APPROVED'
                                      ? Icons.verified_outlined
                                      : Icons.info_outline,
                                  label:
                                      'Phê duyệt: ${_approvalLabel(state.approvalStatus)}',
                                  active: state.approvalStatus == 'APPROVED'),
                            ]),
                            const SizedBox(height: 12),
                            Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(Icons.two_wheeler_outlined,
                                      color: scheme.primary),
                                  const SizedBox(width: 10),
                                  Expanded(
                                      child: Text(
                                          'Xe đang dùng: ${state.activeVehicle?.licensePlate ?? 'Chưa có'} '
                                          '(${_vehicleLabel(state.activeVehicle?.vehicleType)})')),
                                ]),
                            const SizedBox(height: 8),
                            Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(Icons.location_on_outlined,
                                      color: scheme.onSurfaceVariant),
                                  const SizedBox(width: 10),
                                  Expanded(
                                      child: Text(
                                          'GPS: ${state.locationMessage}')),
                                ]),
                            if (!state.foreground)
                              const Text(
                                  'Ứng dụng nền: GPS sẽ không còn mới để nhận cuốc.'),
                            if (state.locationProblem != null)
                              TextButton(
                                  onPressed: cubit.openLocationSettings,
                                  child: const Text('Mở Cài đặt vị trí')),
                            if (state.approvalStatus != null &&
                                state.approvalStatus != 'APPROVED' &&
                                state.operatingStatus != 'ONLINE')
                              const Padding(
                                  padding: EdgeInsets.only(top: 8),
                                  child: Text(
                                      'Cần được phê duyệt trước khi nhận cuốc.')),
                            const SizedBox(height: 12),
                            if (state.operatingStatus != 'BUSY')
                              SizedBox(
                                  width: double.infinity,
                                  child: state.operatingStatus == 'ONLINE'
                                      ? OutlinedButton.icon(
                                          onPressed: _canChangeStatus(state)
                                              ? cubit.goOffline
                                              : null,
                                          icon: const Icon(
                                              Icons.pause_circle_outline),
                                          label: const Text(
                                              'Ngừng nhận cuốc · OFFLINE'))
                                      : FilledButton.icon(
                                          onPressed: _canChangeStatus(state)
                                              ? cubit.goOnline
                                              : null,
                                          icon: const Icon(
                                              Icons.power_settings_new),
                                          label: const Text(
                                              'Bắt đầu nhận cuốc · ONLINE'))),
                          ],
                        ))),
                const SizedBox(height: 16),
                Text('Xe của tôi',
                    style: Theme.of(context).textTheme.titleMedium),
                if (state.vehicles.isEmpty)
                  const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                          'Chưa có xe. Thêm và kích hoạt xe trước khi trực tuyến.')),
                for (final vehicle in state.vehicles)
                  Card(
                      child: ListTile(
                          leading: Icon(Icons.directions_car_outlined,
                              color: vehicle.active
                                  ? scheme.primary
                                  : scheme.onSurfaceVariant),
                          title: Text(
                              '${vehicle.licensePlate} · ${_vehicleLabel(vehicle.vehicleType)}'),
                          subtitle: Text(vehicle.active
                              ? 'Đang kích hoạt'
                              : 'Chưa kích hoạt'),
                          trailing: vehicle.active
                              ? const Icon(Icons.check_circle)
                              : TextButton(
                                  onPressed: AppConfig.instance.isMock ||
                                          state.actionBusy
                                      ? null
                                      : () => cubit
                                          .activateVehicle(vehicle.publicId),
                                  child: const Text('Kích hoạt')))),
                OutlinedButton.icon(
                    onPressed: AppConfig.instance.isMock || state.actionBusy
                        ? null
                        : _addVehicle,
                    icon: const Icon(Icons.add),
                    label: const Text('Thêm xe')),
                if (state.acceptedOffer != null)
                  _bookingCard(state.acceptedOffer!),
                if (offer != null && state.acceptedOffer == null)
                  TweenAnimationBuilder<double>(
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
                    child: Card(
                      color: scheme.primaryContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Đề nghị nhận chuyến',
                                style: Theme.of(context).textTheme.titleMedium),
                            Text(
                                'Thời gian còn ${seconds > 0 ? seconds : 0} giây để phản hồi',
                                style: Theme.of(context).textTheme.bodyMedium),
                            const SizedBox(height: 12),
                            _offerDetails(offer),
                            if (state.offerActionBusy)
                              const Padding(
                                padding: EdgeInsets.only(top: 8, bottom: 8),
                                child: Row(children: [
                                  SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  ),
                                  SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                        'Đang gửi quyết định đến máy chủ…'),
                                  ),
                                ]),
                              ),
                            if (state.unresolvedDecision)
                              TextButton(
                                  onPressed: cubit.reconcile,
                                  child: const Text('Kiểm tra lại kết quả')),
                            Row(children: [
                              Expanded(
                                  child: OutlinedButton(
                                      onPressed: canDecide
                                          ? () => cubit.decide(false)
                                          : null,
                                      child: const Text('Từ chối'))),
                              const SizedBox(width: 8),
                              Expanded(
                                  child: FilledButton(
                                      onPressed: canDecide
                                          ? () => cubit.decide(true)
                                          : null,
                                      child: const Text('Nhận chuyến'))),
                            ]),
                            const SizedBox(height: 4),
                            const Text(
                                'Thời hạn do máy chủ quyết định. Nếu đề nghị hết hạn, hãy chờ cuốc tiếp theo.'),
                          ],
                        ),
                      ),
                    ),
                  ),
              ]);
            }),
          ),
        ),
      );

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
            color:
                active ? scheme.onPrimaryContainer : scheme.onSurfaceVariant),
        label: Text(label),
        backgroundColor:
            active ? scheme.primaryContainer : scheme.surfaceContainerHighest,
        side: BorderSide.none);
  }

  Widget _bookingCard(DriverOffer offer) => Card(
        color: Theme.of(context).colorScheme.secondaryContainer,
        child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Đã nhận chuyến · BUSY',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text('Booking UUID: ${offer.bookingPublicId}',
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 12),
                _offerDetails(offer),
                const SizedBox(height: 12),
                SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                        onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                                builder: (_) => DriverAcceptedBookingScreen(
                                    offer: offer,
                                    driverCubit: context.read<DriverCubit>()))),
                        icon: const Icon(Icons.route_outlined),
                        label: const Text('Xem chuyến đã nhận'))),
              ],
            )),
      );

  Widget _offerDetails(DriverOffer offer) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _routeLine(Icons.trip_origin,
              'Điểm đón: ${offer.pickupLatitude}, ${offer.pickupLongitude}'),
          const SizedBox(height: 8),
          _routeLine(Icons.location_on_outlined,
              'Điểm đến: ${offer.dropoffLatitude}, ${offer.dropoffLongitude}'),
          const SizedBox(height: 8),
          Text('Loại xe: ${_vehicleLabel(offer.vehicleType)}'),
          const SizedBox(height: 4),
          Text('Giá đã chấp nhận: ${vnd(offer.finalFare)}',
              style: Theme.of(context).textTheme.titleMedium),
        ],
      );

  Widget _routeLine(IconData icon, String label) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(child: Text(label)),
        ],
      );
}

String _operatingLabel(String? status) => switch (status) {
      'ONLINE' => 'ONLINE',
      'OFFLINE' => 'OFFLINE',
      'BUSY' => 'BUSY',
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
