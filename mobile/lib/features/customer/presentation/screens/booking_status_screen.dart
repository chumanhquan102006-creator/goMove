import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/di/injection.dart';
import '../../../../core/storage/secure_storage_service.dart';
import '../../../trip/data/trip_realtime_client.dart';
import '../../../trip/domain/models/trip_models.dart';
import '../../../trip/domain/repositories/trip_repository.dart';
import '../../domain/models/booking.dart';
import '../../domain/models/quote.dart';
import '../../domain/usecases/customer_usecases.dart';
import '../bloc/booking_status_cubit.dart';
import '../formatters.dart';

const _timeline = <(String, String)>[
  ('SEARCHING_DRIVER', 'Đang tìm tài xế'),
  ('DRIVER_ACCEPTED', 'Tài xế đã nhận chuyến'),
  ('DRIVER_ARRIVED', 'Tài xế đã đến điểm đón'),
  ('PASSENGER_ONBOARD', 'Đã đón khách'),
  ('IN_PROGRESS', 'Chuyến đi đang diễn ra'),
  ('COMPLETED', 'Chuyến đi đã hoàn thành'),
];

String customerTripStatusLabel(String status) => switch (status) {
      'REQUESTED' || 'SEARCHING_DRIVER' => 'Đang tìm tài xế.',
      'DRIVER_ACCEPTED' => 'Tài xế đã nhận chuyến.',
      'DRIVER_ARRIVED' => 'Tài xế đã đến điểm đón.',
      'PASSENGER_ONBOARD' => 'Đã đón khách.',
      'IN_PROGRESS' => 'Chuyến đi đang diễn ra.',
      'COMPLETED' => 'Chuyến đi đã hoàn thành.',
      _ => 'Đang xác minh trạng thái chuyến.',
    };

String customerRealtimeLabel(TripRealtimeConnectionState connection) =>
    switch (connection) {
      TripRealtimeConnectionState.connecting => 'Đang kết nối realtime…',
      TripRealtimeConnectionState.connected => 'Realtime đã kết nối',
      TripRealtimeConnectionState.reconnecting =>
        'Đang kết nối lại realtime; REST vẫn được cập nhật',
      TripRealtimeConnectionState.disconnected =>
        'Realtime chưa kết nối; đang dựa vào REST',
      TripRealtimeConnectionState.failed =>
        'Realtime không khả dụng; đang dựa vào REST',
    };

String _time(DateTime? value) =>
    value == null ? 'Chưa có' : value.toLocal().toString();

DateTime? _stepTime(TrackingSnapshot? tracking, String status) {
  if (tracking == null) return null;
  return switch (status) {
    'DRIVER_ACCEPTED' => tracking.driverAcceptedAt,
    'DRIVER_ARRIVED' => tracking.driverArrivedAt,
    'PASSENGER_ONBOARD' => tracking.passengerOnboardAt,
    'IN_PROGRESS' => tracking.tripStartedAt,
    'COMPLETED' => tracking.tripCompletedAt,
    _ => null,
  };
}

int _progress(String status) {
  if (status == 'REQUESTED') return 0;
  final index = _timeline.indexWhere((entry) => entry.$1 == status);
  return index < 0 ? 0 : index;
}

class BookingStatusScreen extends StatefulWidget {
  final Booking booking;
  const BookingStatusScreen({super.key, required this.booking});

  @override
  State<BookingStatusScreen> createState() => _BookingStatusScreenState();
}

class _BookingStatusScreenState extends State<BookingStatusScreen>
    with WidgetsBindingObserver {
  late final BookingStatusCubit _cubit;

  @override
  void initState() {
    super.initState();
    _cubit = BookingStatusCubit(
      sl<GetBookingUseCase>(),
      widget.booking,
      tripRepository: sl<TripRepository>(),
      session: sl<SecureStorageService>(),
      realtime: sl<TripRealtimeClient>(),
    )..start();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _cubit.start();
    } else {
      _cubit.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cubit.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => BlocProvider(
        create: (_) => _cubit,
        child: Scaffold(
          appBar: AppBar(title: const Text('Theo dõi chuyến đi')),
          body: BlocBuilder<BookingStatusCubit, BookingStatusState>(
              builder: (context, state) {
            if (state.sessionEnded) {
              return Center(
                  child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(state.error ??
                    'Phiên đăng nhập đã thay đổi. Hãy mở lại chuyến từ tài khoản hiện tại.'),
              ));
            }
            final booking = state.booking;
            final payment = state.payment;
            final location = state.liveLocation;
            final progress = _progress(state.status);
            return ListView(padding: const EdgeInsets.all(20), children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: Text(customerTripStatusLabel(state.status),
                    key: ValueKey(state.status),
                    style: Theme.of(context).textTheme.headlineSmall),
              ),
              const SizedBox(height: 10),
              LinearProgressIndicator(
                value: (progress + 1) / _timeline.length,
                minHeight: 6,
                semanticsLabel: 'Tiến độ chuyến đi',
              ),
              if (state.loading) ...[
                const SizedBox(height: 8),
                const LinearProgressIndicator(
                    semanticsLabel: 'Đang cập nhật từ máy chủ'),
              ],
              if (state.error != null) ...[
                const SizedBox(height: 12),
                Text(state.error!, style: const TextStyle(color: Colors.red)),
              ],
              const SizedBox(height: 12),
              Card(
                child: Column(children: [
                  ListTile(
                      title: const Text('Mã Booking'),
                      subtitle: SelectableText(booking.publicId)),
                  ListTile(
                      title: const Text('Loại xe'),
                      subtitle: Text(booking.vehicleType.label)),
                  ListTile(
                      title: const Text('Giá đã chấp nhận'),
                      subtitle: Text(vnd(booking.finalFare))),
                  ListTile(
                      title: const Text('Tạo lúc'),
                      subtitle: Text(_time(booking.createdAt))),
                  if ((state.tracking?.driverPublicId ??
                          booking.driverPublicId) !=
                      null)
                    ListTile(
                        title: const Text('Mã tài xế'),
                        subtitle: SelectableText(
                            state.tracking?.driverPublicId ??
                                booking.driverPublicId!)),
                  if (booking.vehiclePublicId != null)
                    ListTile(
                        title: const Text('Mã xe'),
                        subtitle: SelectableText(booking.vehiclePublicId!)),
                ]),
              ),
              const SizedBox(height: 14),
              Text('Tiến trình chuyến đi',
                  style: Theme.of(context).textTheme.titleLarge),
              ...List.generate(_timeline.length, (index) {
                final step = _timeline[index];
                final time = _stepTime(state.tracking, step.$1);
                final reached = index <= progress;
                return ListTile(
                  leading: Icon(index == progress
                      ? Icons.radio_button_checked
                      : reached
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked),
                  title: Text(step.$2),
                  subtitle: time == null ? null : Text(_time(time)),
                  enabled: reached,
                );
              }),
              const SizedBox(height: 10),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Theo dõi vị trí',
                            style: Theme.of(context).textTheme.titleMedium),
                        Text(state.status == 'COMPLETED'
                            ? 'Chuyến đã hoàn thành; vị trí hiện tại của tài xế được ẩn.'
                            : customerRealtimeLabel(state.realtimeState)),
                        if (state.status != 'COMPLETED' &&
                            !state.hasLiveLocation)
                          const Text('Chưa có vị trí GPS được phép hiển thị.'),
                        if (state.hasLiveLocation && location != null) ...[
                          Text('Vĩ độ: ${location.latitude}'),
                          Text('Kinh độ: ${location.longitude}'),
                          if (location.accuracy != null)
                            Text('Độ chính xác: ${location.accuracy} m'),
                          if (location.bearing != null)
                            Text('Hướng: ${location.bearing}°'),
                          Text('Cập nhật: ${_time(location.updatedAt)}'),
                        ],
                        if (state.status != 'COMPLETED')
                          const Text(
                              'REST là nguồn trạng thái bền vững khi mất realtime.'),
                      ]),
                ),
              ),
              const SizedBox(height: 10),
              Card(
                child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Thanh toán tiền mặt',
                              style: Theme.of(context).textTheme.titleMedium),
                          if (payment == null)
                            const Text(
                                'Đang chờ xác minh thanh toán từ máy chủ.')
                          else ...[
                            Text(payment.isPaid
                                ? 'Đã thanh toán (PAID)'
                                : 'Chưa thanh toán (PENDING)'),
                            Text('Số tiền: ${vnd(payment.amount)}'),
                            if (payment.paidAt != null)
                              Text('Đã trả lúc: ${_time(payment.paidAt)}'),
                          ],
                        ])),
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: state.loading
                    ? null
                    : () => context.read<BookingStatusCubit>().refresh(),
                icon: const Icon(Icons.refresh),
                label: const Text('Cập nhật từ máy chủ'),
              ),
            ]);
          }),
        ),
      );
}
