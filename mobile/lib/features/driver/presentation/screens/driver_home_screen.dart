import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../../core/config/app_config.dart';
import '../../../../core/di/injection.dart';
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
              builder: (_) =>
                  DriverAcceptedBookingScreen(offer: state.acceptedOffer!),
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
                  !state.unresolvedDecision;
              return ListView(padding: const EdgeInsets.all(16), children: [
                Text('Xin chào, ${widget.user.fullName}',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                if (state.loading) const LinearProgressIndicator(),
                if (state.error != null)
                  Card(
                      color: Colors.red.shade50,
                      child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(state.error!))),
                if (state.notice != null)
                  Card(
                      child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(state.notice!))),
                Card(
                    child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                                'Trạng thái: ${state.operatingStatus ?? 'Chưa xác định'}'),
                            Text(
                                'Phê duyệt: ${state.approvalStatus ?? 'Chưa xác định'}'),
                            Text(
                                'Xe đang dùng: ${state.activeVehicle?.licensePlate ?? 'Chưa có'} '
                                '(${state.activeVehicle?.vehicleType ?? '—'})'),
                            Text('GPS: ${state.locationMessage}'),
                            if (!state.foreground)
                              const Text(
                                  'Ứng dụng nền: GPS sẽ không còn mới để nhận cuốc.'),
                            if (state.locationProblem != null)
                              TextButton(
                                  onPressed: cubit.openLocationSettings,
                                  child: const Text('Mở Cài đặt vị trí')),
                            const SizedBox(height: 8),
                            if (state.operatingStatus != 'BUSY')
                              FilledButton(
                                onPressed: AppConfig.instance.isMock ||
                                        state.actionBusy ||
                                        state.offerActionBusy ||
                                        state.loading ||
                                        state.acceptedOffer != null
                                    ? null
                                    : state.operatingStatus == 'ONLINE'
                                        ? cubit.goOffline
                                        : cubit.goOnline,
                                child: Text(state.operatingStatus == 'ONLINE'
                                    ? 'Ngừng nhận cuốc · OFFLINE'
                                    : 'Bắt đầu nhận cuốc · ONLINE'),
                              ),
                          ],
                        ))),
                const SizedBox(height: 8),
                Text('Xe của tôi',
                    style: Theme.of(context).textTheme.titleMedium),
                for (final vehicle in state.vehicles)
                  ListTile(
                      title: Text(
                          '${vehicle.licensePlate} · ${vehicle.vehicleType}'),
                      subtitle: Text(
                          vehicle.active ? 'Đang kích hoạt' : 'Chưa kích hoạt'),
                      trailing: vehicle.active
                          ? const Icon(Icons.check_circle)
                          : TextButton(
                              onPressed: AppConfig.instance.isMock ||
                                      state.actionBusy
                                  ? null
                                  : () =>
                                      cubit.activateVehicle(vehicle.publicId),
                              child: const Text('Kích hoạt'))),
                OutlinedButton.icon(
                    onPressed: AppConfig.instance.isMock || state.actionBusy
                        ? null
                        : _addVehicle,
                    icon: const Icon(Icons.add),
                    label: const Text('Thêm xe')),
                if (state.acceptedOffer != null)
                  _bookingCard(state.acceptedOffer!),
                if (offer != null && state.acceptedOffer == null)
                  Card(
                    color: Colors.blue.shade50,
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                              'Đề nghị nhận chuyến · còn ${seconds > 0 ? seconds : 0} giây',
                              style: Theme.of(context).textTheme.titleMedium),
                          _offerDetails(offer),
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
                          const Text(
                              'Thời hạn do máy chủ quyết định; có thể nhận lỗi 409.'),
                        ],
                      ),
                    ),
                  ),
              ]);
            }),
          ),
        ),
      );

  Widget _bookingCard(DriverOffer offer) => Card(
        color: Colors.green.shade50,
        child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Đã nhận chuyến · BUSY',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                Text('Booking UUID: ${offer.bookingPublicId}'),
                _offerDetails(offer),
                TextButton(
                    onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                            builder: (_) =>
                                DriverAcceptedBookingScreen(offer: offer))),
                    child: const Text('Xem chuyến đã nhận')),
                const Text('Các bước chuyến đi sẽ được triển khai ở M3.'),
              ],
            )),
      );

  Widget _offerDetails(DriverOffer offer) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Điểm đón: ${offer.pickupLatitude}, ${offer.pickupLongitude}'),
          Text('Điểm đến: ${offer.dropoffLatitude}, ${offer.dropoffLongitude}'),
          Text('Loại xe: ${offer.vehicleType}'),
          Text('Giá: ${vnd(offer.finalFare)}'),
        ],
      );
}
