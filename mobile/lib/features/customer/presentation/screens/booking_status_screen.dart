import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/di/injection.dart';
import '../../../../core/storage/secure_storage_service.dart';
import '../../../../core/theme/app_motion.dart';
import '../../../trip/data/trip_realtime_client.dart';
import '../../../trip/domain/models/trip_models.dart';
import '../../../trip/domain/repositories/trip_repository.dart';
import '../../domain/models/booking.dart';
import '../../domain/models/quote.dart';
import '../../domain/usecases/customer_usecases.dart';
import '../bloc/booking_status_cubit.dart';
import '../formatters.dart';
import '../widgets/customer_map_source.dart';
import '../widgets/customer_trip_tracking_map.dart';

typedef CustomerTripMapBuilder = Widget Function(BuildContext context,
    CustomerLiveLocation location, TripRealtimeConnectionState connectionState);

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

String _time(DateTime? value) {
  if (value == null) return 'Chưa có';
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${two(local.day)}/${two(local.month)}/${local.year} '
      '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

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
  final CustomerTripMapBuilder? trackingMapBuilder;

  const BookingStatusScreen(
      {super.key, required this.booking, this.trackingMapBuilder});

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
            final hasRenderableLocation = state.hasLiveLocation &&
                CustomerTripTrackingMap.isRenderable(location);
            final progress = _progress(state.status);
            final colors = Theme.of(context).colorScheme;
            final motionDuration = AppMotion.duration(context, AppMotion.card);
            final cashDuration = AppMotion.duration(context, AppMotion.cash);
            final reduceMotion = AppMotion.reduceMotion(context);
            return SafeArea(
              child: Stack(children: [
                Positioned.fill(
                  child: hasRenderableLocation && location != null
                      ? (widget.trackingMapBuilder
                              ?.call(context, location, state.realtimeState) ??
                          CustomerTripTrackingMap(
                            key: ValueKey(
                                'customer-trip-map-${booking.publicId}'),
                            bookingPublicId: booking.publicId,
                            location: location,
                            connectionState: state.realtimeState,
                            fullBleed: true,
                          ))
                      : ColoredBox(
                          color: colors.surfaceContainerHighest,
                          child: Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    state.status == 'COMPLETED'
                                        ? Icons.flag_circle_outlined
                                        : Icons.location_searching,
                                    size: 42,
                                    color: colors.primary,
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    state.status == 'COMPLETED'
                                        ? 'Chuyến đã hoàn thành; vị trí tài xế được ẩn.'
                                        : 'Bản đồ vị trí tài xế sẽ hiện khi có GPS được phép hiển thị.',
                                    textAlign: TextAlign.center,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                ),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: DraggableScrollableSheet(
                    key: const ValueKey('customer-trip-sheet'),
                    expand: false,
                    snap: !reduceMotion,
                    minChildSize: .30,
                    initialChildSize: .30,
                    maxChildSize: .86,
                    builder: (context, sheetController) => Material(
                      color: colors.surface,
                      elevation: 8,
                      borderRadius:
                          const BorderRadius.vertical(top: Radius.circular(24)),
                      clipBehavior: Clip.antiAlias,
                      child: ListView(
                        controller: sheetController,
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
                        children: [
                          Center(
                            child: Container(
                              key: const ValueKey('customer-trip-sheet-handle'),
                              width: 42,
                              height: 5,
                              decoration: BoxDecoration(
                                color: colors.outlineVariant,
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('TRẠNG THÁI CHUYẾN ĐI',
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelMedium
                                          ?.copyWith(
                                              color: colors.primary,
                                              fontWeight: FontWeight.w700,
                                              letterSpacing: 0.7)),
                                  const SizedBox(height: 8),
                                  AnimatedSwitcher(
                                    key: const ValueKey(
                                        'customer-status-switcher'),
                                    duration: motionDuration,
                                    switchInCurve: AppMotion.enterCurve,
                                    switchOutCurve: AppMotion.exitCurve,
                                    transitionBuilder: (child, animation) =>
                                        reduceMotion
                                            ? child
                                            : AnimatedBuilder(
                                                animation: animation,
                                                child: child,
                                                builder: (context, child) =>
                                                    Transform.translate(
                                                  offset: Offset(
                                                      0,
                                                      AppMotion.cardTravel *
                                                          (1 -
                                                              animation.value)),
                                                  child: Opacity(
                                                    opacity: animation.value,
                                                    child: child,
                                                  ),
                                                ),
                                              ),
                                    child: Text(
                                        customerTripStatusLabel(state.status),
                                        key: ValueKey(state.status),
                                        style: Theme.of(context)
                                            .textTheme
                                            .headlineSmall),
                                  ),
                                  if (hasRenderableLocation) ...[
                                    const SizedBox(height: 6),
                                    Text(
                                        customerRealtimeLabel(
                                            state.realtimeState),
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall),
                                  ],
                                  const SizedBox(height: 14),
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: TweenAnimationBuilder<double>(
                                      key: const ValueKey(
                                          'customer-trip-progress'),
                                      tween: Tween<double>(
                                        begin:
                                            (_progress(widget.booking.status) +
                                                    1) /
                                                _timeline.length,
                                        end: (progress + 1) / _timeline.length,
                                      ),
                                      duration: motionDuration,
                                      curve: AppMotion.standardCurve,
                                      builder: (context, value, child) =>
                                          LinearProgressIndicator(
                                        value: value,
                                        minHeight: 7,
                                        semanticsLabel: 'Tiến độ chuyến đi',
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          // Keep later sliver children at stable indices while polling so
                          // the native map is not torn down and rebuilt every refresh.
                          Column(children: [
                            if (state.loading) ...[
                              const SizedBox(height: 8),
                              const LinearProgressIndicator(
                                  semanticsLabel: 'Đang cập nhật từ máy chủ'),
                            ],
                            if (state.error != null) ...[
                              const SizedBox(height: 12),
                              Semantics(
                                liveRegion: true,
                                child: Row(children: [
                                  Icon(Icons.error_outline,
                                      color: colors.error),
                                  const SizedBox(width: 8),
                                  Expanded(
                                      child: Text(state.error!,
                                          style:
                                              TextStyle(color: colors.error))),
                                ]),
                              ),
                            ],
                          ]),
                          const SizedBox(height: 12),
                          Card(
                            child: Column(children: [
                              Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(16, 16, 16, 0),
                                child: Row(children: [
                                  Icon(Icons.receipt_long_outlined,
                                      color: colors.primary),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text('Chi tiết chuyến',
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium),
                                  ),
                                ]),
                              ),
                              ListTile(
                                  dense: true,
                                  title: const Text('Mã Booking'),
                                  subtitle: SelectableText(booking.publicId)),
                              ListTile(
                                  dense: true,
                                  title: const Text('Loại xe'),
                                  subtitle: Text(booking.vehicleType.label)),
                              ListTile(
                                  dense: true,
                                  title: const Text('Giá đã chấp nhận'),
                                  subtitle: Text(vnd(booking.finalFare),
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleLarge
                                          ?.copyWith(color: colors.primary))),
                              ListTile(
                                  dense: true,
                                  title: const Text('Tạo lúc'),
                                  subtitle: Text(_time(booking.createdAt))),
                              if ((state.tracking?.driverPublicId ??
                                      booking.driverPublicId) !=
                                  null)
                                ListTile(
                                    dense: true,
                                    title: const Text('Mã tài xế'),
                                    subtitle: SelectableText(
                                        state.tracking?.driverPublicId ??
                                            booking.driverPublicId!)),
                              if (booking.vehiclePublicId != null)
                                ListTile(
                                    dense: true,
                                    title: const Text('Mã xe'),
                                    subtitle: SelectableText(
                                        booking.vehiclePublicId!)),
                            ]),
                          ),
                          const SizedBox(height: 14),
                          Card(
                            child: Column(children: [
                              Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(16, 16, 16, 4),
                                child: Row(children: [
                                  Icon(Icons.route_outlined,
                                      color: colors.primary),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text('Tiến trình chuyến đi',
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium),
                                  ),
                                ]),
                              ),
                              ...List.generate(_timeline.length, (index) {
                                final step = _timeline[index];
                                final time = _stepTime(state.tracking, step.$1);
                                final reached = index <= progress;
                                return ListTile(
                                  dense: true,
                                  leading: Icon(index == progress
                                      ? Icons.radio_button_checked
                                      : reached
                                          ? Icons.check_circle
                                          : Icons.radio_button_unchecked),
                                  iconColor:
                                      reached ? colors.primary : colors.outline,
                                  title: Text(step.$2),
                                  subtitle:
                                      time == null ? null : Text(_time(time)),
                                  enabled: reached,
                                );
                              }),
                            ]),
                          ),
                          const SizedBox(height: 10),
                          Card(
                            key: const ValueKey('customer-live-tracking-card'),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(children: [
                                      Icon(Icons.location_on_outlined,
                                          color: colors.primary),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text('Theo dõi vị trí',
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleMedium),
                                      ),
                                    ]),
                                    const SizedBox(height: 6),
                                    Text(
                                        state.status == 'COMPLETED'
                                            ? 'Chuyến đã hoàn thành; vị trí hiện tại của tài xế được ẩn.'
                                            : customerRealtimeLabel(
                                                state.realtimeState),
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall),
                                    if (state.status != 'COMPLETED' &&
                                        !hasRenderableLocation)
                                      const Text(
                                          'Chưa có vị trí GPS được phép hiển thị.'),
                                    if (hasRenderableLocation &&
                                        location != null) ...[
                                      const SizedBox(height: 10),
                                      Text('Vĩ độ: ${location.latitude}'),
                                      Text('Kinh độ: ${location.longitude}'),
                                      if (location.accuracy != null)
                                        Text(
                                            'Độ chính xác: ${location.accuracy} m'),
                                      if (location.bearing != null)
                                        Text('Hướng: ${location.bearing}°'),
                                      Text(
                                          'Cập nhật: ${_time(location.updatedAt)}'),
                                      Text(CustomerMapSource.visibleAttribution,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall),
                                    ],
                                    if (state.status != 'COMPLETED')
                                      Text(
                                          'REST là nguồn trạng thái bền vững khi mất realtime.',
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall),
                                  ]),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Card(
                            child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(children: [
                                        AnimatedSwitcher(
                                          key: const ValueKey(
                                              'customer-cash-switcher'),
                                          duration: cashDuration,
                                          switchInCurve: AppMotion.enterCurve,
                                          switchOutCurve: AppMotion.exitCurve,
                                          transitionBuilder:
                                              (child, animation) => reduceMotion
                                                  ? child
                                                  : FadeTransition(
                                                      opacity: animation,
                                                      child: child),
                                          child: Icon(
                                            payment?.isPaid == true
                                                ? Icons.check_circle_outline
                                                : Icons.payments_outlined,
                                            key: ValueKey(
                                                payment?.isPaid == true),
                                            color: payment?.isPaid == true
                                                ? colors.tertiary
                                                : colors.primary,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text('Thanh toán tiền mặt',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleMedium),
                                        ),
                                      ]),
                                      const SizedBox(height: 8),
                                      if (payment == null)
                                        const Text(
                                            'Đang chờ xác minh thanh toán từ máy chủ.')
                                      else ...[
                                        Text(
                                            payment.isPaid
                                                ? 'Đã thanh toán (PAID)'
                                                : 'Chưa thanh toán (PENDING)',
                                            style: TextStyle(
                                                color: payment.isPaid
                                                    ? colors.tertiary
                                                    : colors.primary,
                                                fontWeight: FontWeight.w700)),
                                        const SizedBox(height: 4),
                                        Text('Số tiền: ${vnd(payment.amount)}',
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleMedium),
                                        if (payment.paidAt != null)
                                          Text(
                                              'Đã trả lúc: ${_time(payment.paidAt)}'),
                                      ],
                                    ])),
                          ),
                          const SizedBox(height: 16),
                          OutlinedButton.icon(
                            onPressed: state.loading
                                ? null
                                : () => context
                                    .read<BookingStatusCubit>()
                                    .refresh(),
                            icon: const Icon(Icons.refresh),
                            label: const Text('Cập nhật từ máy chủ'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ]),
            );
          }),
        ),
      );
}
