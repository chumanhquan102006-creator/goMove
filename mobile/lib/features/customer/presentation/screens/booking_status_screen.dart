import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../../core/config/app_config.dart';

import '../../../../core/di/injection.dart';
import '../../../../core/storage/secure_storage_service.dart';
import '../../../../core/theme/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../../auth/presentation/bloc/auth_state.dart';
import '../../../review/domain/rating_repository.dart';
import '../../../review/presentation/rating_panel.dart';
import '../../../trip/data/trip_realtime_client.dart';
import '../../../trip/domain/models/trip_models.dart';
import '../../../trip/domain/repositories/trip_repository.dart';
import '../../../trip/presentation/widgets/authorized_road_route.dart';
import '../../domain/models/booking.dart';
import '../../domain/models/quote.dart';
import '../../domain/repositories/geocoding_repository.dart';
import '../../domain/usecases/customer_usecases.dart';
import '../bloc/booking_status_cubit.dart';
import '../formatters.dart';
import '../widgets/customer_trip_tracking_map.dart';
import '../widgets/customer_premium_widgets.dart';
import '../widgets/customer_trip_eta.dart';

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
      'CANCELLED' => 'Chuyến đi đã được hủy.',
      'NO_DRIVER_AVAILABLE' => 'Không tìm được tài xế trong thời gian chờ.',
      _ => 'Đang xác minh trạng thái chuyến.',
    };

String customerRealtimeLabel(TripRealtimeConnectionState connection) =>
    switch (connection) {
      TripRealtimeConnectionState.connecting =>
        'Đang kết nối để theo dõi chuyến…',
      TripRealtimeConnectionState.connected => 'Vị trí đang được cập nhật',
      TripRealtimeConnectionState.reconnecting =>
        'Đang kết nối lại; thông tin chuyến vẫn được kiểm tra',
      TripRealtimeConnectionState.disconnected =>
        'Tạm mất kết nối trực tiếp; đang kiểm tra lại vị trí',
      TripRealtimeConnectionState.failed =>
        'Chưa có kết nối trực tiếp; thông tin chuyến vẫn được cập nhật',
    };

String _assignedVehicleLabel(String type) => switch (type) {
      'MOTORBIKE' => 'Xe máy',
      'CAR_4_SEAT' => 'Ô tô 4 chỗ',
      'CAR_7_SEAT' => 'Ô tô 7 chỗ',
      _ => type,
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
  Coordinates? _pickup;
  Coordinates? _dropoff;
  String? _pickupAddress;
  String? _dropoffAddress;
  int _pointsRequest = 0;
  String? _customerPublicId;

  @override
  void initState() {
    super.initState();
    try {
      final auth = context.read<AuthBloc>().state;
      if (auth is AuthenticatedState) _customerPublicId = auth.user.publicId;
    } catch (_) {
      // Isolated map/widget tests do not install the app authentication shell.
    }
    _cubit = BookingStatusCubit(
      sl<GetBookingUseCase>(),
      widget.booking,
      tripRepository: sl<TripRepository>(),
      session: sl<SecureStorageService>(),
      realtime: sl<TripRealtimeClient>(),
    )..start();
    WidgetsBinding.instance.addObserver(this);
    _loadPoints();
  }

  Future<void> _loadPoints() async {
    if (!sl.isRegistered<GetQuoteUseCase>() ||
        !sl.isRegistered<SecureStorageService>()) {
      return;
    }
    final request = ++_pointsRequest;
    final session = sl<SecureStorageService>();
    try {
      final snapshot = await session.getSession();
      if (!mounted ||
          request != _pointsRequest ||
          snapshot.accessToken == null) {
        return;
      }
      final quote = await sl<GetQuoteUseCase>()(widget.booking.quotePublicId);
      if (!mounted ||
          request != _pointsRequest ||
          !await session.isCurrentSession(snapshot.generation) ||
          quote.publicId != widget.booking.quotePublicId ||
          !quote.pickup.isValid ||
          !quote.dropoff.isValid) {
        return;
      }
      setState(() {
        _pickup = quote.pickup;
        _dropoff = quote.dropoff;
        _pickupAddress = null;
        _dropoffAddress = null;
      });
      if (!sl.isRegistered<GeocodingRepository>() ||
          sl.isRegistered<AppConfig>() && sl<AppConfig>().isMock) {
        return;
      }
      final repository = sl<GeocodingRepository>();
      Future<String?> reverse(Coordinates point) async {
        try {
          final place = await repository.reverse(point,
              sessionGeneration: snapshot.generation);
          if (place == null ||
              place.coordinates.latitude != point.latitude ||
              place.coordinates.longitude != point.longitude) {
            return null;
          }
          final label = place.label.trim();
          return label.isEmpty ? null : label;
        } catch (_) {
          return null;
        }
      }

      final pickupAddress = await reverse(quote.pickup);
      final dropoffAddress = await reverse(quote.dropoff);
      if (!mounted ||
          request != _pointsRequest ||
          !await session.isCurrentSession(snapshot.generation)) {
        return;
      }
      setState(() {
        _pickupAddress = pickupAddress;
        _dropoffAddress = dropoffAddress;
      });
    } catch (_) {
      // A failed authorized Quote read cannot block Booking or CASH details.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _cubit.start();
      setState(() {
        _pickup = null;
        _dropoff = null;
        _pickupAddress = null;
        _dropoffAddress = null;
      });
      _loadPoints();
    } else {
      _cubit.stop();
      _pointsRequest++;
      setState(() {
        _pickup = null;
        _dropoff = null;
        _pickupAddress = null;
        _dropoffAddress = null;
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pointsRequest++;
    _cubit.stop();
    super.dispose();
  }

  Future<void> _confirmCancel() async {
    if (!_cubit.state.canCancel) return;
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
              title: const Text('Hủy chuyến này?'),
              content: const Text(
                  'Chỉ có thể hủy trước khi đón khách. Chúng tôi sẽ xác nhận trạng thái với máy chủ.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialog, false),
                    child: const Text('Giữ chuyến')),
                FilledButton(
                    onPressed: () => Navigator.pop(dialog, true),
                    child: const Text('Xác nhận hủy')),
              ],
            ));
    if (confirmed == true && mounted && _cubit.state.canCancel) {
      await _cubit.cancel();
    }
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
                  child: AuthorizedRoadRoute(
                    key: ValueKey('customer-route-${booking.publicId}'),
                    publicId: booking.publicId,
                    expectedSourceQuotePublicId: booking.quotePublicId,
                    isQuote: false,
                    builder: (context, route) => hasRenderableLocation &&
                            location != null &&
                            widget.trackingMapBuilder != null
                        ? widget.trackingMapBuilder!(
                            context, location, state.realtimeState)
                        : (hasRenderableLocation ||
                                route?.available == true ||
                                _pickup?.isValid == true ||
                                _dropoff?.isValid == true)
                            ? CustomerTripTrackingMap(
                                key: ValueKey(
                                    'customer-trip-map-${booking.publicId}'),
                                bookingPublicId: booking.publicId,
                                searchingForDriver:
                                    state.status == 'SEARCHING_DRIVER',
                                enableMarkerInterpolation: true,
                                location:
                                    hasRenderableLocation ? location : null,
                                route: route,
                                pickup: _pickup,
                                dropoff: _dropoff,
                                connectionState: state.realtimeState,
                                fullBleed: true,
                              )
                            : ColoredBox(
                                color: colors.surfaceContainerHighest,
                                child: Center(
                                  child: Padding(
                                    padding: const EdgeInsets.all(24),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          isTerminalTripStatus(state.status)
                                              ? Icons.flag_circle_outlined
                                              : Icons.location_searching,
                                          size: 42,
                                          color: colors.primary,
                                        ),
                                        const SizedBox(height: 8),
                                        Text(
                                          isTerminalTripStatus(state.status)
                                              ? state.status == 'COMPLETED'
                                                  ? 'Chuyến đã hoàn thành; vị trí tài xế được ẩn.'
                                                  : 'Chuyến đã kết thúc; vị trí tài xế được ẩn.'
                                              : 'Bản đồ vị trí tài xế sẽ hiện khi có GPS được phép hiển thị.',
                                          textAlign: TextAlign.center,
                                        ),
                                      ],
                                    ),
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
                    snapSizes: const [.30, .58],
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
                          CustomerPremiumSurface(
                            surfaceKey:
                                const ValueKey('customer-status-surface'),
                            highlighted: true,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(children: [
                                  const Icon(Icons.near_me_rounded,
                                      color: AppColors.primary, size: 20),
                                  const SizedBox(width: 8),
                                  Expanded(
                                      child: Text('Hành trình của bạn',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context)
                                              .textTheme
                                              .labelLarge
                                              ?.copyWith(
                                                  color: AppColors.primary,
                                                  fontWeight:
                                                      FontWeight.w700))),
                                  if (state.status == 'COMPLETED')
                                    const Icon(Icons.verified_rounded,
                                        color: AppColors.success),
                                ]),
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
                                                        (1 - animation.value)),
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
                                const SizedBox(height: 6),
                                Text(
                                    'Thanh toán tiền mặt · ${vnd(booking.finalFare)}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleSmall
                                        ?.copyWith(
                                            color: AppColors.primaryDark)),
                                if (!isTerminalTripStatus(state.status)) ...[
                                  const SizedBox(height: 6),
                                  Text(
                                      customerRealtimeLabel(
                                          state.realtimeState),
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall),
                                ],
                                if (!isTerminalTripStatus(state.status)) ...[
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
                                if (state.canCancel) ...[
                                  const SizedBox(height: 12),
                                  OutlinedButton.icon(
                                    key: const ValueKey(
                                        'customer-cancel-booking'),
                                    onPressed: state.loading ||
                                            state.cancellationBusy ||
                                            state.cancellationUnresolved
                                        ? null
                                        : _confirmCancel,
                                    icon: const Icon(Icons.cancel_outlined),
                                    label: const Text('Hủy chuyến'),
                                  ),
                                ],
                                if (state.status == 'PASSENGER_ONBOARD' ||
                                    state.status == 'IN_PROGRESS')
                                  const Padding(
                                      padding: EdgeInsets.only(top: 8),
                                      child: Text(
                                          'Không thể tự hủy sau khi khách đã lên xe.')),
                                if (state.status == 'CANCELLED')
                                  Text(
                                      'Đã hủy lúc: ${_time(state.tracking?.cancelledAt ?? booking.cancelledAt)}'),
                                if (state.status == 'NO_DRIVER_AVAILABLE')
                                  Text(
                                      'Đã dừng tìm lúc: ${_time(state.tracking?.dispatchFailedAt ?? booking.dispatchFailedAt)}'),
                                const SizedBox(height: 8),
                                ExpansionTile(
                                  key: const ValueKey('customer-trip-support'),
                                  tilePadding: EdgeInsets.zero,
                                  childrenPadding: EdgeInsets.zero,
                                  leading:
                                      const Icon(Icons.support_agent_outlined),
                                  title: const Text('Cần hỗ trợ về chuyến đi?'),
                                  children: [
                                    const Align(
                                      alignment: Alignment.centerLeft,
                                      child: Text(
                                          'Cung cấp mã chuyến này khi cần được hỗ trợ.'),
                                    ),
                                    const SizedBox(height: 6),
                                    Align(
                                      alignment: Alignment.centerLeft,
                                      child: SelectableText(booking.publicId),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          CustomerTripEta(
                            key: ValueKey('customer-eta-${booking.publicId}'),
                            bookingPublicId: booking.publicId,
                            status: state.status,
                          ),
                          if (state.status == 'COMPLETED' &&
                              _customerPublicId != null &&
                              sl.isRegistered<RatingRepository>())
                            RatingPanel(
                              key: ValueKey('rating-${booking.publicId}'),
                              bookingPublicId: booking.publicId,
                              customerPublicId: _customerPublicId!,
                              autoPrompt: true,
                            ),
                          if (state.cancellationBusy)
                            const Padding(
                                padding: EdgeInsets.all(8),
                                child: Text(
                                    'Đang chờ máy chủ xác nhận hủy chuyến…')),
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
                                  title: const Text('Loại xe'),
                                  subtitle: Text(booking.vehicleType.label)),
                              ListTile(
                                  dense: true,
                                  title: const Text('Giá đã chấp nhận'),
                                  subtitle: Text('Thanh toán bằng tiền mặt',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall)),
                              ListTile(
                                  dense: true,
                                  title: const Text('Tạo lúc'),
                                  subtitle: Text(_time(booking.createdAt))),
                            ]),
                          ),
                          if (state.tracking?.bookingPublicId ==
                                  booking.publicId &&
                              state.tracking?.allowsLiveLocation == true &&
                              !isTerminalTripStatus(state.status) &&
                              state.tracking?.assignedDriver != null)
                            _assignedDriverCard(context, state.tracking!),
                          if (_pickup != null && _dropoff != null)
                            _bookingAddressCard(context, _pickup!, _dropoff!,
                                _pickupAddress, _dropoffAddress),
                          if (!isTerminalTripStatus(state.status)) ...[
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
                                  final time =
                                      _stepTime(state.tracking, step.$1);
                                  final reached = index <= progress;
                                  return ListTile(
                                    dense: true,
                                    leading: Icon(index == progress
                                        ? Icons.radio_button_checked
                                        : reached
                                            ? Icons.check_circle
                                            : Icons.radio_button_unchecked),
                                    iconColor: reached
                                        ? colors.primary
                                        : colors.outline,
                                    title: Text(step.$2),
                                    subtitle:
                                        time == null ? null : Text(_time(time)),
                                    enabled: reached,
                                  );
                                }),
                              ]),
                            ),
                          ],
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
                                        isTerminalTripStatus(state.status)
                                            ? state.status == 'COMPLETED'
                                                ? 'Chuyến đã hoàn thành; vị trí hiện tại của tài xế được ẩn.'
                                                : 'Chuyến đã kết thúc; vị trí hiện tại của tài xế được ẩn.'
                                            : customerRealtimeLabel(
                                                state.realtimeState),
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall),
                                    const Text(
                                        'Vị trí tài xế chỉ hiển thị trong chuyến đi đang hoạt động.'),
                                    if (!isTerminalTripStatus(state.status) &&
                                        !hasRenderableLocation)
                                      const Text(
                                          'Chưa có vị trí GPS được phép hiển thị.'),
                                    if (hasRenderableLocation &&
                                        location != null)
                                      Text(
                                          'Vị trí mới nhất: ${_time(location.updatedAt)}'),
                                  ]),
                            ),
                          ),
                          const SizedBox(height: 10),
                          if (state.status != 'CANCELLED' &&
                              state.status != 'NO_DRIVER_AVAILABLE')
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
                                            transitionBuilder: (child,
                                                    animation) =>
                                                reduceMotion
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
                                                  ? 'Đã thanh toán'
                                                  : 'Chờ xác nhận thanh toán',
                                              style: TextStyle(
                                                  color: payment.isPaid
                                                      ? colors.tertiary
                                                      : colors.primary,
                                                  fontWeight: FontWeight.w700)),
                                          const SizedBox(height: 4),
                                          Text(
                                              'Số tiền: ${vnd(payment.amount)}',
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
                                    .refresh(resolveCancellation: true),
                            icon: const Icon(Icons.refresh),
                            label: const Text('Cập nhật chuyến đi'),
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

Widget _assignedDriverCard(BuildContext context, TrackingSnapshot tracking) {
  final driver = tracking.assignedDriver!;
  final vehicle = tracking.assignedVehicle;
  final details = [vehicle?.brand, vehicle?.model]
      .whereType<String>()
      .where((value) => value.trim().isNotEmpty)
      .join(' ');
  return CustomerPremiumSurface(
    key: const ValueKey('customer-assigned-driver-card'),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const CustomerSectionHeading(
          icon: Icons.person_pin_circle_rounded, title: 'Tài xế đồng hành'),
      const SizedBox(height: 14),
      Row(children: [
        const CircleAvatar(
          radius: 24,
          backgroundColor: AppColors.paleViolet,
          child: Icon(Icons.person_rounded, color: AppColors.violet),
        ),
        const SizedBox(width: 12),
        Expanded(
            child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(driver.displayName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium),
            Text(driver.ratingCount == 0 || driver.ratingAverage == null
                ? 'Chưa có đánh giá'
                : '${driver.ratingAverage!.toStringAsFixed(2)} ★ · '
                    '${driver.ratingCount} đánh giá'),
          ],
        )),
      ]),
      if (vehicle != null) ...[
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.paleBlue,
            borderRadius: BorderRadius.circular(14),
          ),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
                '${_assignedVehicleLabel(vehicle.vehicleType)} · '
                '${vehicle.licensePlate}',
                style: Theme.of(context).textTheme.titleSmall),
            if (details.isNotEmpty) Text(details),
          ]),
        ),
      ],
      if (driver.phone?.trim().isNotEmpty == true) ...[
        const SizedBox(height: 8),
        Text('Điện thoại: ${driver.phone}'),
      ],
    ]),
  );
}

Widget _bookingAddressCard(BuildContext context, Coordinates pickup,
        Coordinates dropoff, String? pickupAddress, String? dropoffAddress) =>
    Card(
      key: const ValueKey('booking-address-card'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Điểm đón và điểm đến',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text('Điểm đón: ${pickupAddress ?? 'Địa chỉ chưa khả dụng'}'),
          if (pickupAddress == null)
            Text('${pickup.latitude}, ${pickup.longitude}',
                style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 4),
          Text('Điểm đến: ${dropoffAddress ?? 'Địa chỉ chưa khả dụng'}'),
          if (dropoffAddress == null)
            Text('${dropoff.latitude}, ${dropoff.longitude}',
                style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
    );
