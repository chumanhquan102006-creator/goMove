import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/di/injection.dart';
import '../../../../core/error/exceptions.dart';
import '../../../../core/storage/secure_storage_service.dart';
import '../../../trip/domain/models/trip_eta.dart';
import '../../../trip/domain/repositories/trip_eta_repository.dart';
import '../formatters.dart';

/// Reads the Backend's short-lived road ETA without touching the native map.
/// The server owns GPS validation and routing; this widget only presents the
/// result while it matches the Booking, session, status and expiry.
class CustomerTripEta extends StatefulWidget {
  final String bookingPublicId;
  final String status;
  final TripEtaRepository? repository;
  final SecureStorageService? session;
  final Duration refreshInterval;

  const CustomerTripEta({
    super.key,
    required this.bookingPublicId,
    required this.status,
    this.repository,
    this.session,
    this.refreshInterval = const Duration(seconds: 15),
  });

  @override
  State<CustomerTripEta> createState() => _CustomerTripEtaState();
}

class _CustomerTripEtaState extends State<CustomerTripEta>
    with WidgetsBindingObserver {
  Timer? _refreshTimer;
  Timer? _expiryTimer;
  TripEta? _eta;
  Stopwatch? _displayWatch;
  Duration? _displayTtl;
  int _request = 0;
  int? _originGeneration;
  bool _active = true;
  bool _loading = false;
  bool _sessionEnded = false;

  bool get _eligible =>
      widget.status == 'DRIVER_ACCEPTED' || widget.status == 'IN_PROGRESS';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  void _start() {
    _refreshTimer?.cancel();
    if (!_active || !_eligible || _sessionEnded) return;
    _refreshTimer = Timer.periodic(widget.refreshInterval, (_) => _load());
    unawaited(_load());
  }

  void _invalidate() {
    _request++;
    _refreshTimer?.cancel();
    _expiryTimer?.cancel();
    _displayWatch?.stop();
    _displayWatch = null;
    _displayTtl = null;
    _eta = null;
    _loading = false;
  }

  @override
  void didUpdateWidget(covariant CustomerTripEta oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bookingPublicId != widget.bookingPublicId ||
        oldWidget.status != widget.status ||
        oldWidget.repository != widget.repository ||
        oldWidget.session != widget.session ||
        oldWidget.refreshInterval != widget.refreshInterval) {
      _invalidate();
      if (oldWidget.bookingPublicId != widget.bookingPublicId ||
          oldWidget.session != widget.session) {
        _originGeneration = null;
        _sessionEnded = false;
      }
      _start();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _active = true;
      _invalidate();
      setState(() {});
      _start();
    } else {
      _active = false;
      _invalidate();
      if (mounted) setState(() {});
    }
  }

  Future<void> _load() async {
    if (!_active || !_eligible || _sessionEnded || _loading || !mounted) {
      return;
    }
    final repository = widget.repository ??
        (sl.isRegistered<TripEtaRepository>() ? sl<TripEtaRepository>() : null);
    final session = widget.session ??
        (sl.isRegistered<SecureStorageService>()
            ? sl<SecureStorageService>()
            : null);
    if (repository == null || session == null) return;
    final request = ++_request;
    final bookingId = widget.bookingPublicId;
    final status = widget.status;
    final requestWatch = Stopwatch()..start();
    _loading = true;
    try {
      final snapshot = await session.getSession();
      if (!_current(request, bookingId, status)) return;
      if (snapshot.accessToken == null ||
          (_originGeneration != null &&
              snapshot.generation != _originGeneration)) {
        _sessionEnded = true;
        _invalidate();
        setState(() {});
        return;
      }
      _originGeneration ??= snapshot.generation;
      final result = await repository.booking(bookingId, snapshot.generation);
      if (!_current(request, bookingId, status)) return;
      if (!await session.isCurrentSession(snapshot.generation)) {
        _sessionEnded = true;
        _invalidate();
        setState(() {});
        return;
      }
      final expectedPhase =
          status == 'DRIVER_ACCEPTED' ? 'PICKUP' : 'DESTINATION';
      final remaining = result.remainingAfter(requestWatch.elapsed);
      _eta = result.bookingPublicId == bookingId &&
              result.status == status &&
              result.phase == expectedPhase &&
              (result.availability != 'AVAILABLE' ||
                  (result.isAvailableFor(bookingId, status) &&
                      remaining != null))
          ? result
          : null;
      _scheduleExpiry(remaining);
    } catch (error) {
      if (_current(request, bookingId, status)) {
        if (error is UnauthorizedException ||
            (error is ServerException &&
                const {401, 403, 404}.contains(error.statusCode))) {
          // The server no longer authorizes this resource for this session.
          _sessionEnded = true;
          _invalidate();
          setState(() {});
        } else {
          // A REST failure never preserves an unverified estimate.
          _eta = null;
          _expiryTimer?.cancel();
          _displayWatch?.stop();
          _displayWatch = null;
          _displayTtl = null;
        }
      }
    } finally {
      requestWatch.stop();
      if (_current(request, bookingId, status)) {
        _loading = false;
        setState(() {});
      }
    }
  }

  bool _current(int request, String bookingId, String status) =>
      mounted &&
      _active &&
      request == _request &&
      widget.bookingPublicId == bookingId &&
      widget.status == status;

  void _scheduleExpiry(Duration? remaining) {
    _expiryTimer?.cancel();
    _displayWatch?.stop();
    _displayWatch = null;
    _displayTtl = null;
    if (_eta?.availability != 'AVAILABLE' || remaining == null) return;
    _displayWatch = Stopwatch()..start();
    _displayTtl = remaining;
    _expiryTimer = Timer(remaining, () {
      if (!mounted || !_active) return;
      _eta = null;
      _displayWatch?.stop();
      _displayWatch = null;
      _displayTtl = null;
      setState(() {});
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _active = false;
    _invalidate();
    super.dispose();
  }

  String _updatedLabel(DateTime at) {
    final local = at.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }

  String _unavailableLabel() => switch (_eta?.reason) {
        'GPS_UNAVAILABLE' => 'Đang chờ vị trí GPS của tài xế.',
        'GPS_STALE' => 'Vị trí GPS đã cũ; đang chờ cập nhật mới.',
        'GPS_INACCURATE' => 'Vị trí GPS chưa đủ chính xác để ước tính.',
        'ROUTING_UNAVAILABLE' => 'Tạm thời chưa tính được tuyến đường.',
        _ => 'Chưa có ước tính đáng tin cậy.',
      };

  @override
  Widget build(BuildContext context) {
    if (!_eligible || !_active) return const SizedBox.shrink();
    final eta = _eta;
    final valid =
        eta?.isAvailableFor(widget.bookingPublicId, widget.status) == true &&
            _displayWatch != null &&
            _displayTtl != null &&
            _displayWatch!.elapsed < _displayTtl!;
    final colors = Theme.of(context).colorScheme;
    final pickup = widget.status == 'DRIVER_ACCEPTED';
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Card(
        key: const ValueKey('customer-trip-eta-card'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(pickup ? Icons.directions_bike : Icons.route_outlined,
                    color: colors.primary),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(
                        pickup ? 'Ước tính đón khách' : 'Ước tính đến nơi',
                        style: Theme.of(context).textTheme.titleMedium)),
              ]),
              const SizedBox(height: 8),
              Text(
                valid
                    ? pickup
                        ? 'Đón bạn sau khoảng ${roadDurationLabel(eta!.durationSeconds!)}'
                        : 'Dự kiến đến nơi trong khoảng ${roadDurationLabel(eta!.durationSeconds!)}'
                    : _sessionEnded
                        ? 'Phiên đăng nhập đã thay đổi.'
                        : _unavailableLabel(),
                style: Theme.of(context).textTheme.titleLarge,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              if (valid) ...[
                const SizedBox(height: 4),
                Text(pickup
                    ? 'Cách điểm đón khoảng ${roadDistanceLabel(eta!.distanceMeters!)}'
                    : 'Còn khoảng ${roadDistanceLabel(eta!.distanceMeters!)} theo đường phố'),
                const SizedBox(height: 6),
                Text(
                    'Ước tính cập nhật lúc ${_updatedLabel(eta.calculatedAt!)} · Có thể thay đổi.',
                    style: Theme.of(context).textTheme.bodySmall),
              ] else if (_loading) ...[
                const SizedBox(height: 4),
                Text('Đang kiểm tra tuyến đường và GPS…',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
