import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/storage/secure_storage_service.dart';
import '../../../customer/presentation/formatters.dart';
import '../../../trip/data/trip_realtime_client.dart';
import '../../../trip/domain/models/trip_models.dart';
import '../../../trip/domain/repositories/trip_repository.dart';
import '../../data/location/driver_location_source.dart';
import '../../domain/models/driver_models.dart';
import '../bloc/driver_cubit.dart';
import '../bloc/driver_trip_cubit.dart';

class DriverAcceptedBookingScreen extends StatefulWidget {
  final DriverOffer offer;
  final DriverCubit? driverCubit;
  final DriverTripCubit? tripCubit;

  const DriverAcceptedBookingScreen(
      {super.key, required this.offer, this.driverCubit, this.tripCubit});

  @override
  State<DriverAcceptedBookingScreen> createState() =>
      _DriverAcceptedBookingScreenState();
}

class _DriverAcceptedBookingScreenState
    extends State<DriverAcceptedBookingScreen> with WidgetsBindingObserver {
  late final DriverTripCubit _cubit;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _cubit = widget.tripCubit ??
        DriverTripCubit(
          bookingPublicId: widget.offer.bookingPublicId,
          repository: sl<TripRepository>(),
          session: sl<SecureStorageService>(),
          realtime: sl<TripRealtimeClient>(),
          location: sl<DriverLocationSource>(),
          onCompleted: widget.driverCubit?.markTripCompleted,
          onSettled: widget.driverCubit?.finishSettledBooking,
        );
    unawaited(_cubit.initialize());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_cubit.resume());
    } else {
      widget.driverCubit?.setTripChannelActive(false);
      unawaited(_cubit.pause());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.driverCubit?.setTripChannelActive(false);
    unawaited(_cubit.close());
    super.dispose();
  }

  Future<void> _confirmCash() async {
    final payment = _cubit.state.payment;
    if (payment == null || !_cubit.state.canConfirmCash) return;
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
              title: const Text('Xác nhận đã thu tiền mặt?'),
              content: Text(
                  'Chỉ xác nhận khi bạn đã thực sự nhận ${vnd(payment.amount)} '
                  'tiền mặt từ khách. Thao tác này ghi nhận khoản hoa hồng phải nộp '
                  'nền tảng và giải phóng tài xế.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialog, false),
                    child: const Text('Chưa thu tiền')),
                FilledButton(
                    onPressed: () => Navigator.pop(dialog, true),
                    child: const Text('Tôi đã thu tiền mặt')),
              ],
            ));
    if (confirmed == true && mounted) await _cubit.confirmCash();
  }

  @override
  Widget build(BuildContext context) => BlocProvider.value(
        value: _cubit,
        child: BlocListener<DriverTripCubit, DriverTripState>(
          listenWhen: (before, after) => before.realtime != after.realtime,
          listener: (_, state) => widget.driverCubit?.setTripChannelActive(
              state.realtime == TripRealtimeConnectionState.connected &&
                  state.tracking?.allowsLiveLocation == true),
          child: Scaffold(
            appBar: AppBar(title: const Text('Chuyến đã nhận')),
            body: BlocBuilder<DriverTripCubit, DriverTripState>(
              builder: (context, state) => state.sessionEnded
                  ? Center(
                      child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                              state.error ?? 'Phiên đăng nhập đã thay đổi.')))
                  : ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        if (state.loading)
                          const Padding(
                              padding: EdgeInsets.only(bottom: 12),
                              child: Text('Đang tải chuyến đi từ máy chủ…')),
                        if (state.loading || state.operationBusy)
                          const LinearProgressIndicator(),
                        _statusCard(context, state),
                        if (state.error != null)
                          Card(
                              color:
                                  Theme.of(context).colorScheme.errorContainer,
                              child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Text(state.error!,
                                      style: TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onErrorContainer)))),
                        if (state.notice != null)
                          Card(
                              child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Text(state.notice!))),
                        _routeCard(context),
                        const SizedBox(height: 8),
                        _timeline(context, state.tracking),
                        const SizedBox(height: 8),
                        _gpsCard(context, state),
                        const SizedBox(height: 8),
                        if (state.payment != null)
                          _paymentCard(context, state.payment!),
                        if (state.receipt != null)
                          Card(
                              color: Theme.of(context)
                                  .colorScheme
                                  .secondaryContainer,
                              child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text('Biên nhận CASH · PAID',
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleMedium),
                                        const SizedBox(height: 8),
                                        Text(
                                            'Đã thu: ${vnd(state.receipt!.cashCollectedAmount)}'),
                                        Text(
                                            'Đã thu lúc: ${_time(state.receipt!.paidAt)}'),
                                        Text('Hoa hồng phải nộp nền tảng: '
                                            '${vnd(state.receipt!.commissionAmount)}'),
                                        const Text(
                                            'Đây là khoản phải thu; không có nghĩa hoa hồng '
                                            'đã được nộp cho nền tảng.'),
                                        Text('Tài xế được giải phóng lúc: '
                                            '${_time(state.receipt!.driverReleasedAt)}'),
                                      ]))),
                        const SizedBox(height: 16),
                        if (state.availableAction != null)
                          FilledButton.icon(
                            onPressed: state.foreground
                                ? () => _cubit.perform(state.availableAction!)
                                : null,
                            icon: Icon(_actionIcon(state.availableAction!)),
                            label: Text(_actionLabel(state.availableAction!)),
                          ),
                        if (state.canConfirmCash)
                          FilledButton.icon(
                            onPressed: state.foreground ? _confirmCash : null,
                            icon: const Icon(Icons.payments_outlined),
                            label: const Text('Xác nhận đã thu tiền mặt'),
                          ),
                        if (state.canRecoverReceipt)
                          OutlinedButton(
                            onPressed:
                                state.foreground ? _cubit.recoverReceipt : null,
                            child: const Text('Lấy lại biên nhận đã xác nhận'),
                          ),
                        OutlinedButton.icon(
                          onPressed: state.operationBusy
                              ? null
                              : () => _cubit.refresh(manual: true),
                          icon: const Icon(Icons.refresh),
                          label: const Text('Cập nhật từ máy chủ'),
                        ),
                        const SizedBox(height: 8),
                      ],
                    ),
            ),
          ),
        ),
      );

  Widget _statusCard(BuildContext context, DriverTripState state) {
    final scheme = Theme.of(context).colorScheme;
    final completed = state.status == 'COMPLETED';
    return Card(
      color: completed ? scheme.secondaryContainer : scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(completed ? Icons.check_circle_outline : Icons.route_outlined,
                color: completed
                    ? scheme.onSecondaryContainer
                    : scheme.onPrimaryContainer),
            const SizedBox(width: 10),
            Expanded(
                child: Text(_statusLabel(state.status),
                    style: Theme.of(context).textTheme.titleLarge)),
          ]),
          const SizedBox(height: 8),
          Text(state.status == null
              ? 'Đang xác minh trạng thái với máy chủ.'
              : 'Trạng thái chuyến đi do máy chủ xác nhận.'),
          if (completed && state.payment?.status != 'PAID') ...[
            const SizedBox(height: 8),
            const Text('Chuyến đã hoàn thành nhưng tài xế vẫn BUSY '
                'cho đến khi tiền mặt được xác nhận.'),
          ],
        ]),
      ),
    );
  }

  Widget _routeCard(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Thông tin chuyến đi',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text('Booking UUID: ${widget.offer.bookingPublicId}',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            _routeLine(context, Icons.trip_origin,
                'Điểm đón: ${widget.offer.pickupLatitude}, ${widget.offer.pickupLongitude}'),
            const SizedBox(height: 10),
            _routeLine(context, Icons.location_on_outlined,
                'Điểm đến: ${widget.offer.dropoffLatitude}, ${widget.offer.dropoffLongitude}'),
            const SizedBox(height: 12),
            Text('Loại xe: ${_vehicleLabel(widget.offer.vehicleType)}'),
            const SizedBox(height: 4),
            Text('Giá đã chấp nhận: ${vnd(widget.offer.finalFare)}',
                style: Theme.of(context).textTheme.titleMedium),
          ]),
        ),
      );

  Widget _routeLine(BuildContext context, IconData icon, String label) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(child: Text(label)),
        ],
      );

  Widget _gpsCard(BuildContext context, DriverTripState state) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(
                  state.realtime == TripRealtimeConnectionState.connected
                      ? Icons.wifi
                      : Icons.wifi_off,
                  color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(
                  child: Text('Theo dõi GPS: ${_realtimeLabel(state.realtime)}',
                      style: Theme.of(context).textTheme.titleSmall)),
            ]),
            const SizedBox(height: 6),
            const Text(
                'Khi mất kết nối trực tiếp, ứng dụng vẫn đối chiếu trạng thái bằng REST.'),
            if (!state.foreground)
              const Text('Ứng dụng đang nền: đã dừng gửi GPS chuyến đi.'),
          ]),
        ),
      );

  Widget _paymentCard(BuildContext context, CashPayment payment) {
    final paid = payment.status == 'PAID';
    final pending = payment.status == 'PENDING';
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: paid ? scheme.secondaryContainer : scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Thanh toán tiền mặt',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
              'Tiền mặt: ${paid ? 'Đã thu' : pending ? 'Chưa xác nhận thu' : 'Đang xác minh'}',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          Text('Số tiền: ${vnd(payment.amount)}'),
          if (payment.paidAt != null)
            Text('Đã thu lúc: ${_time(payment.paidAt)}'),
          if (pending)
            const Text('Chỉ xác nhận sau khi đã thực sự nhận tiền từ khách.'),
        ]),
      ),
    );
  }

  Widget _timeline(BuildContext context, TrackingSnapshot? tracking) {
    final steps = <(String, DateTime?)>[
      ('Tài xế nhận chuyến', tracking?.driverAcceptedAt),
      ('Đã đến điểm đón', tracking?.driverArrivedAt),
      ('Đã đón khách', tracking?.passengerOnboardAt),
      ('Bắt đầu chuyến', tracking?.tripStartedAt),
      ('Hoàn thành chuyến', tracking?.tripCompletedAt),
    ];
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(14),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Tiến trình chuyến đi',
                  style: Theme.of(context).textTheme.titleMedium),
              for (final step in steps)
                ListTile(
                  dense: true,
                  leading: Icon(
                      step.$2 == null
                          ? Icons.radio_button_unchecked
                          : Icons.check_circle,
                      color: step.$2 == null
                          ? Theme.of(context).colorScheme.onSurfaceVariant
                          : Theme.of(context).colorScheme.primary),
                  title: Text(step.$1),
                  subtitle: step.$2 == null ? null : Text(_time(step.$2)),
                ),
            ])));
  }
}

String _time(DateTime? date) =>
    date == null ? 'Chưa có' : date.toLocal().toString();

String _statusLabel(String? status) => switch (status) {
      'DRIVER_ACCEPTED' => 'Tài xế đã nhận chuyến',
      'DRIVER_ARRIVED' => 'Đã đến điểm đón',
      'PASSENGER_ONBOARD' => 'Đã đón khách',
      'IN_PROGRESS' => 'Chuyến đi đang diễn ra',
      'COMPLETED' => 'Chuyến đi đã hoàn thành',
      _ => 'Đang tải chuyến đi',
    };

String _actionLabel(TripAction action) => switch (action) {
      TripAction.arrive => 'Đã đến điểm đón',
      TripAction.onboard => 'Đã đón khách',
      TripAction.start => 'Bắt đầu chuyến',
      TripAction.complete => 'Hoàn thành chuyến',
    };

IconData _actionIcon(TripAction action) => switch (action) {
      TripAction.arrive => Icons.location_on_outlined,
      TripAction.onboard => Icons.person_add_alt_1_outlined,
      TripAction.start => Icons.play_arrow,
      TripAction.complete => Icons.flag_outlined,
    };

String _vehicleLabel(String type) => switch (type) {
      'MOTORBIKE' => 'Xe máy',
      'CAR_4_SEAT' => 'Ô tô 4 chỗ',
      'CAR_7_SEAT' => 'Ô tô 7 chỗ',
      _ => type,
    };

String _realtimeLabel(TripRealtimeConnectionState state) => switch (state) {
      TripRealtimeConnectionState.connecting => 'Đang kết nối',
      TripRealtimeConnectionState.connected => 'Đã kết nối',
      TripRealtimeConnectionState.reconnecting => 'Đang kết nối lại',
      TripRealtimeConnectionState.disconnected => 'Ngoại tuyến · dùng REST',
      TripRealtimeConnectionState.failed => 'Kết nối lỗi · dùng REST',
    };
