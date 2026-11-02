import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../../core/config/app_config.dart';

import '../../../../core/di/injection.dart';
import '../../../../core/storage/secure_storage_service.dart';
import '../../../../core/theme/app_motion.dart';
import '../../../trip/domain/repositories/road_route_repository.dart';
import '../../../trip/presentation/widgets/authorized_road_route.dart';
import '../../domain/models/quote.dart';
import '../../domain/repositories/geocoding_repository.dart';
import '../bloc/booking_cubit.dart';
import '../formatters.dart';
import 'booking_status_screen.dart';
import 'customer_map_canvas.dart';
import '../widgets/customer_premium_widgets.dart';

class QuoteReviewScreen extends StatefulWidget {
  final Quote quote;
  final DateTime Function()? now;
  final RoadRouteRepository? routeRepository;
  final SecureStorageService? routeSession;
  final GeocodingRepository? geocodingRepository;
  final String? pickupLabel;
  final String? dropoffLabel;
  const QuoteReviewScreen(
      {super.key,
      required this.quote,
      this.now,
      this.routeRepository,
      this.routeSession,
      this.geocodingRepository,
      this.pickupLabel,
      this.dropoffLabel});

  @override
  State<QuoteReviewScreen> createState() => _QuoteReviewScreenState();
}

class _QuoteReviewScreenState extends State<QuoteReviewScreen>
    with WidgetsBindingObserver {
  Timer? _timer;
  Timer? _expiryTimer;
  bool _fareVisible = false;
  String? _pickupAddress;
  String? _dropoffAddress;
  int _addressRequest = 0;
  int? _sessionGeneration;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pickupAddress = _cleanLabel(widget.pickupLabel);
    _dropoffAddress = _cleanLabel(widget.dropoffLabel);
    unawaited(_loadAddresses());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _fareVisible = true);
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    final now = widget.now?.call() ?? DateTime.now();
    final untilExpiry = widget.quote.expiresAt.difference(now);
    if (untilExpiry > Duration.zero) {
      // The countdown ticks once a second, but confirmation must disappear
      // at the exact server deadline rather than on the next tick.
      _expiryTimer = Timer(untilExpiry, () {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _addressRequest++;
    _timer?.cancel();
    _expiryTimer?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant QuoteReviewScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.quote.publicId != widget.quote.publicId ||
        oldWidget.quote.pickup.latitude != widget.quote.pickup.latitude ||
        oldWidget.quote.pickup.longitude != widget.quote.pickup.longitude ||
        oldWidget.quote.dropoff.latitude != widget.quote.dropoff.latitude ||
        oldWidget.quote.dropoff.longitude != widget.quote.dropoff.longitude) {
      _addressRequest++;
      _pickupAddress = _cleanLabel(widget.pickupLabel);
      _dropoffAddress = _cleanLabel(widget.dropoffLabel);
      unawaited(_loadAddresses());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _foreground = true;
      unawaited(_loadAddresses());
    } else {
      _foreground = false;
      _addressRequest++;
      setState(() {
        _pickupAddress = null;
        _dropoffAddress = null;
      });
    }
  }

  String? _cleanLabel(String? value) {
    final label = value?.trim();
    return label == null || label.isEmpty ? null : label;
  }

  String _stopLabel(String? address, Coordinates point) =>
      address ?? 'Vĩ độ ${point.latitude} · Kinh độ ${point.longitude}';

  Future<void> _loadAddresses() async {
    if (widget.geocodingRepository == null &&
        sl.isRegistered<AppConfig>() &&
        sl<AppConfig>().isMock) {
      return;
    }
    final repository = widget.geocodingRepository ??
        (sl.isRegistered<GeocodingRepository>()
            ? sl<GeocodingRepository>()
            : null);
    final session = widget.routeSession ??
        (sl.isRegistered<SecureStorageService>()
            ? sl<SecureStorageService>()
            : null);
    if (!_foreground || session == null) return;
    final request = ++_addressRequest;
    final quote = widget.quote;
    try {
      final snapshot = await session.getSession();
      if (!mounted ||
          !_foreground ||
          request != _addressRequest ||
          snapshot.accessToken == null) {
        return;
      }
      if (_sessionGeneration != null &&
          _sessionGeneration != snapshot.generation) {
        setState(() {
          _pickupAddress = null;
          _dropoffAddress = null;
        });
        return;
      }
      _sessionGeneration ??= snapshot.generation;
      if (repository == null ||
          (_pickupAddress != null && _dropoffAddress != null)) {
        return;
      }
      Future<String?> reverse(Coordinates point) async {
        try {
          final place = await repository.reverse(point,
              sessionGeneration: snapshot.generation);
          if (place == null ||
              place.coordinates.latitude != point.latitude ||
              place.coordinates.longitude != point.longitude) {
            return null;
          }
          return _cleanLabel(place.label);
        } catch (_) {
          return null;
        }
      }

      final pickup = _pickupAddress ?? await reverse(quote.pickup);
      final dropoff = _dropoffAddress ?? await reverse(quote.dropoff);
      if (!mounted ||
          !_foreground ||
          request != _addressRequest ||
          !await session.isCurrentSession(snapshot.generation)) {
        return;
      }
      setState(() {
        _pickupAddress = pickup;
        _dropoffAddress = dropoff;
      });
    } catch (_) {
      // An unavailable address must never block an accepted fare or route.
    }
  }

  Widget _fareLine(BuildContext context, String label, String amount) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(children: [
        Expanded(child: Text(label, style: textTheme.bodyMedium)),
        const SizedBox(width: 12),
        Flexible(
          child: Text(vnd(amount),
              textAlign: TextAlign.end, style: textTheme.bodyMedium),
        ),
      ]),
    );
  }

  String _discount(String amount) {
    if (RegExp(r'^0+(?:\.0+)?$').hasMatch(amount)) return amount;
    return amount.startsWith('-') ? amount : '-$amount';
  }

  int _remainingSeconds(DateTime now) {
    final remaining = widget.quote.expiresAt.difference(now).inMicroseconds;
    if (remaining <= 0) return 0;
    return (remaining + Duration.microsecondsPerSecond - 1) ~/
        Duration.microsecondsPerSecond;
  }

  @override
  Widget build(BuildContext context) {
    final quote = widget.quote;
    final now = widget.now?.call() ?? DateTime.now();
    final usable = quote.isUsableAt(now);
    final expired = !now.isBefore(quote.expiresAt);
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final reducedMotion = AppMotion.reduceMotion(context);
    final revealFare = _fareVisible || reducedMotion;
    final cardDuration = AppMotion.duration(context, AppMotion.card);
    final showRoutePreview = (widget.routeRepository != null ||
            sl.isRegistered<RoadRouteRepository>()) &&
        (widget.routeSession != null ||
            sl.isRegistered<SecureStorageService>());
    final routeAnimation = ModalRoute.of(context)?.animation;

    Widget buildRoutePreview() => SizedBox(
          height: 200,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: AuthorizedRoadRoute(
              publicId: quote.publicId,
              isQuote: true,
              pickup: quote.pickup,
              dropoff: quote.dropoff,
              repository: widget.routeRepository,
              session: widget.routeSession,
              builder: (context, route) => CustomerMapCanvas(
                pickup: quote.pickup,
                dropoff: quote.dropoff,
                route: route,
                onTap: (_) {},
                fullScreen: true,
                scrollablePreview: true,
              ),
            ),
          ),
        );

    return BlocListener<BookingCubit, BookingState>(
      listener: (context, state) {
        if (state.booking != null) {
          Navigator.of(context).pushReplacement(AppMotion.immediateRoute<void>(
              BookingStatusScreen(booking: state.booking!)));
        }
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Kiểm tra chuyến đi')),
        body: SafeArea(
          child: ListView(padding: const EdgeInsets.all(16), children: [
            AppMotion.entrance(
                context,
                CustomerPremiumSurface(
                  key: const ValueKey('quote-address-card'),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const CustomerSectionHeading(
                            icon: Icons.alt_route_rounded,
                            title: 'Hành trình của bạn'),
                        const SizedBox(height: 16),
                        CustomerJourneyTimeline(
                          pickup: _stopLabel(_pickupAddress, quote.pickup),
                          dropoff: _stopLabel(_dropoffAddress, quote.dropoff),
                          pickupMaxLines: _pickupAddress == null ? null : 2,
                          dropoffMaxLines: _dropoffAddress == null ? null : 2,
                        ),
                        if (_pickupAddress == null ||
                            _dropoffAddress == null) ...[
                          const SizedBox(height: 8),
                          Text(
                              'Chưa xác minh được địa chỉ. Hãy kiểm tra tọa độ trước khi đặt.',
                              style: textTheme.bodySmall),
                        ],
                        if (!showRoutePreview &&
                            (_pickupAddress != null || _dropoffAddress != null))
                          Text('© OpenStreetMap contributors',
                              style: textTheme.bodySmall),
                      ]),
                )),
            const SizedBox(height: 12),
            AnimatedOpacity(
              key: const ValueKey('quote-fare-reveal'),
              opacity: revealFare ? 1 : 0,
              duration: cardDuration,
              curve: AppMotion.enterCurve,
              alwaysIncludeSemantics: true,
              child: TweenAnimationBuilder<double>(
                tween: Tween<double>(
                    begin: reducedMotion ? 0 : AppMotion.cardTravel,
                    end: revealFare ? 0 : AppMotion.cardTravel),
                duration: cardDuration,
                curve: AppMotion.enterCurve,
                builder: (context, travel, child) => Transform.translate(
                  offset: Offset(0, travel),
                  child: child,
                ),
                child: CustomerPremiumSurface(
                  highlighted: true,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        CircleAvatar(
                          backgroundColor: colors.primaryContainer,
                          foregroundColor: colors.onPrimaryContainer,
                          child: Icon(quote.vehicleType == VehicleType.motorbike
                              ? Icons.two_wheeler
                              : Icons.directions_car),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(quote.vehicleType.label,
                                  style: textTheme.titleMedium),
                              const SizedBox(height: 2),
                              Text('Chuyến đi của bạn',
                                  style: textTheme.bodySmall),
                            ],
                          ),
                        ),
                      ]),
                      const SizedBox(height: 12),
                      Wrap(spacing: 8, runSpacing: 4, children: [
                        Chip(
                            avatar: const Icon(Icons.route, size: 18),
                            label: Text(distanceLabel(quote))),
                        Chip(
                            avatar: const Icon(Icons.schedule, size: 18),
                            label: Text(durationLabel(quote))),
                      ]),
                      const Divider(height: 24),
                      Text('Giá chuyến đi', style: textTheme.bodyMedium),
                      const SizedBox(height: 4),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(vnd(quote.finalFare),
                            style: textTheme.headlineMedium?.copyWith(
                                color: colors.primary,
                                fontWeight: FontWeight.bold)),
                      ),
                      const SizedBox(height: 4),
                      Text('Giá được báo trước, thanh toán bằng tiền mặt.',
                          style: textTheme.bodySmall),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (showRoutePreview) ...[
              const CustomerSectionHeading(
                icon: Icons.route_rounded,
                title: 'Tuyến đường dự kiến',
              ),
              const SizedBox(height: 8),
              // The route transition animates Flutter content only. Create
              // the native map once the transition has settled, and remove it
              // before the reverse transition starts.
              if (routeAnimation == null)
                buildRoutePreview()
              else
                AnimatedBuilder(
                  animation: routeAnimation,
                  builder: (context, _) =>
                      routeAnimation.status == AnimationStatus.completed
                          ? buildRoutePreview()
                          : const SizedBox(height: 200),
                ),
              const SizedBox(height: 12),
            ],
            Card(
              child: AnimatedContainer(
                key: const ValueKey('quote-lifetime-motion'),
                duration: AppMotion.duration(context, AppMotion.feedback),
                curve: AppMotion.standardCurve,
                decoration: BoxDecoration(
                  color:
                      usable ? colors.primaryContainer : colors.errorContainer,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(children: [
                    Icon(
                        usable
                            ? Icons.timer_outlined
                            : Icons.timer_off_outlined,
                        color: usable
                            ? colors.onPrimaryContainer
                            : colors.onErrorContainer),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            usable
                                ? 'Còn ${_remainingSeconds(now)} giây để xác nhận'
                                : expired
                                    ? 'Báo giá đã hết hạn'
                                    : 'Báo giá không còn hiệu lực',
                            style: textTheme.titleSmall?.copyWith(
                                color: usable
                                    ? colors.onPrimaryContainer
                                    : colors.onErrorContainer),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            usable
                                ? 'Xác nhận trước khi báo giá hết hạn.'
                                : 'Quay lại để lấy báo giá mới trước khi đặt xe.',
                            style: textTheme.bodySmall?.copyWith(
                                color: usable
                                    ? colors.onPrimaryContainer
                                    : colors.onErrorContainer),
                          ),
                        ],
                      ),
                    ),
                  ]),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: ExpansionTile(
                title: const Text('Chi tiết giá'),
                subtitle: const Text('Xem các khoản trong giá chuyến đi'),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  _fareLine(context, 'Giá mở cửa', quote.baseFare),
                  _fareLine(
                      context, 'Cước theo quãng đường', quote.distanceFare),
                  _fareLine(context, 'Cước theo thời gian', quote.timeFare),
                  _fareLine(context, 'Phụ phí', quote.surcharge),
                  _fareLine(context, 'Giờ cao điểm', quote.surgeAmount),
                  _fareLine(
                      context, 'Giảm giá', _discount(quote.discountAmount)),
                  _fareLine(
                      context, 'Điều chỉnh làm tròn', quote.roundingAdjustment),
                ],
              ),
            ),
          ]),
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: BlocBuilder<BookingCubit, BookingState>(
              builder: (context, state) {
                final pendingSameQuote =
                    state.pending?.quotePublicId == quote.publicId;
                final pendingOtherQuote =
                    state.pending != null && !pendingSameQuote;
                final canSubmit = !state.loading &&
                    !pendingOtherQuote &&
                    (usable || pendingSameQuote);
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (pendingOtherQuote)
                      Text(
                          'Có yêu cầu đặt xe khác đang chờ xác minh. Hãy xử lý yêu cầu đó trước.',
                          style: TextStyle(color: colors.error)),
                    if (state.error != null)
                      Text(state.error!, style: TextStyle(color: colors.error)),
                    CustomerPressableAction(
                      onPressed: canSubmit
                          ? () {
                              // A deadline can pass between countdown ticks.
                              // Recheck at the tap; same-intent retry remains
                              // possible even after quote expiry.
                              final atTap =
                                  widget.now?.call() ?? DateTime.now();
                              if (!pendingSameQuote &&
                                  !quote.isUsableAt(atTap)) {
                                setState(() {});
                                return;
                              }
                              context
                                  .read<BookingCubit>()
                                  .submit(quote.publicId);
                            }
                          : null,
                      child: AnimatedSwitcher(
                        duration:
                            AppMotion.duration(context, AppMotion.feedback),
                        child: state.loading
                            ? const SizedBox(
                                key: ValueKey('booking-loading'),
                                width: 20,
                                height: 20,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : Text(
                                pendingSameQuote
                                    ? 'Kiểm tra lại yêu cầu đặt xe'
                                    : 'Xác nhận đặt xe',
                                key: ValueKey(pendingSameQuote
                                    ? 'booking-retry'
                                    : 'booking-confirm')),
                      ),
                    ),
                    if (!usable) ...[
                      const SizedBox(height: 8),
                      OutlinedButton(
                          onPressed: () => Navigator.of(context).maybePop(),
                          child: const Text('Lấy báo giá mới')),
                    ],
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
