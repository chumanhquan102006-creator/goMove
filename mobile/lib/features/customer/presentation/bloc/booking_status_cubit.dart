import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/error/exceptions.dart';
import '../../../../core/storage/secure_storage_service.dart';
import '../../../trip/data/trip_realtime_client.dart';
import '../../../trip/domain/models/trip_models.dart';
import '../../../trip/domain/repositories/trip_repository.dart';
import '../../domain/models/booking.dart';
import '../../domain/usecases/customer_usecases.dart';
import 'quote_cubit.dart';

const _tripStages = <String>[
  'REQUESTED',
  'SEARCHING_DRIVER',
  'DRIVER_ACCEPTED',
  'DRIVER_ARRIVED',
  'PASSENGER_ONBOARD',
  'IN_PROGRESS',
  'COMPLETED',
  'CANCELLED',
  'NO_DRIVER_AVAILABLE',
];
int _stage(String status) => _tripStages.indexOf(status);

class CustomerLiveLocation {
  final double latitude;
  final double longitude;
  final double? accuracy;
  final double? bearing;
  final DateTime updatedAt;

  const CustomerLiveLocation(this.latitude, this.longitude, this.accuracy,
      this.bearing, this.updatedAt);

  static CustomerLiveLocation? valid(double latitude, double longitude,
      double? accuracy, double? bearing, DateTime updatedAt) {
    if (!latitude.isFinite ||
        !longitude.isFinite ||
        latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180 ||
        !updatedAt
            .isAfter(DateTime.fromMillisecondsSinceEpoch(0, isUtc: true))) {
      return null;
    }
    return CustomerLiveLocation(
        latitude,
        longitude,
        accuracy != null && accuracy.isFinite && accuracy >= 0
            ? accuracy
            : null,
        bearing != null && bearing.isFinite && bearing >= 0 && bearing < 360
            ? bearing
            : null,
        updatedAt);
  }

  static CustomerLiveLocation? fromTracking(TrackingSnapshot tracking) {
    if (!tracking.allowsLiveLocation ||
        tracking.latitude == null ||
        tracking.longitude == null ||
        tracking.locationUpdatedAt == null) {
      return null;
    }
    return valid(tracking.latitude!, tracking.longitude!, tracking.accuracy,
        tracking.bearing, tracking.locationUpdatedAt!);
  }
}

class BookingStatusState {
  static const _unchanged = Object();
  final Booking booking;
  final TrackingSnapshot? tracking;
  final CashPayment? payment;
  final CustomerLiveLocation? liveLocation;
  final String? eventStatus;
  final TripRealtimeConnectionState realtimeState;
  final bool loading;
  final bool cancellationBusy;
  final bool cancellationUnresolved;
  final bool sessionEnded;
  final String? error;

  const BookingStatusState(this.booking,
      {this.tracking,
      this.payment,
      this.liveLocation,
      this.eventStatus,
      this.realtimeState = TripRealtimeConnectionState.disconnected,
      this.loading = false,
      this.cancellationBusy = false,
      this.cancellationUnresolved = false,
      this.sessionEnded = false,
      this.error});

  String get status {
    final durable = tracking?.status ?? booking.status;
    final event = eventStatus;
    return event != null && _stage(event) > _stage(durable) ? event : durable;
  }

  bool get hasLiveLocation =>
      !sessionEnded &&
      const {
        'DRIVER_ACCEPTED',
        'DRIVER_ARRIVED',
        'PASSENGER_ONBOARD',
        'IN_PROGRESS'
      }.contains(status) &&
      liveLocation != null;

  bool get canCancel =>
      !sessionEnded &&
      !cancellationBusy &&
      !cancellationUnresolved &&
      const {
        'REQUESTED',
        'SEARCHING_DRIVER',
        'DRIVER_ACCEPTED',
        'DRIVER_ARRIVED'
      }.contains(status);

  BookingStatusState copyWith(
          {Booking? booking,
          Object? tracking = _unchanged,
          Object? payment = _unchanged,
          Object? liveLocation = _unchanged,
          Object? eventStatus = _unchanged,
          TripRealtimeConnectionState? realtimeState,
          bool? loading,
          bool? cancellationBusy,
          bool? cancellationUnresolved,
          bool? sessionEnded,
          Object? error = _unchanged}) =>
      BookingStatusState(booking ?? this.booking,
          tracking: identical(tracking, _unchanged)
              ? this.tracking
              : tracking as TrackingSnapshot?,
          payment: identical(payment, _unchanged)
              ? this.payment
              : payment as CashPayment?,
          liveLocation: identical(liveLocation, _unchanged)
              ? this.liveLocation
              : liveLocation as CustomerLiveLocation?,
          eventStatus: identical(eventStatus, _unchanged)
              ? this.eventStatus
              : eventStatus as String?,
          realtimeState: realtimeState ?? this.realtimeState,
          loading: loading ?? this.loading,
          cancellationBusy: cancellationBusy ?? this.cancellationBusy,
          cancellationUnresolved:
              cancellationUnresolved ?? this.cancellationUnresolved,
          sessionEnded: sessionEnded ?? this.sessionEnded,
          error: identical(error, _unchanged) ? this.error : error as String?);
}

/// REST owns durable trip/payment state; STOMP is an optional foreground hint.
class BookingStatusCubit extends Cubit<BookingStatusState> {
  final GetBookingUseCase getBooking;
  final TripRepository? tripRepository;
  final SecureStorageService? session;
  final TripRealtimeClient? realtime;
  final Duration pollInterval;

  Timer? _timer;
  // Cancelled by _disconnectRealtime from stop() and close().
  // ignore: cancel_subscriptions
  StreamSubscription<TripRealtimeEvent>? _events;
  // ignore: cancel_subscriptions
  StreamSubscription<TripRealtimeConnectionState>? _connectionStates;
  TripRealtimeSubscription? _tripSubscription;
  bool _busy = false;
  bool _queued = false;
  bool _active = false;
  Completer<void>? _refreshDone;
  int _epoch = 0;
  int? _generation;
  int _trackingSyncRevision = 0;
  int _terminalEventRevision = 0;

  BookingStatusCubit(this.getBooking, Booking initial,
      {this.tripRepository,
      this.session,
      this.realtime,
      this.pollInterval = const Duration(seconds: 5)})
      : assert((tripRepository == null) == (session == null)),
        super(BookingStatusState(initial));

  bool get _hasTrip => tripRepository != null;

  void start() {
    if (_active || isClosed || state.sessionEnded) {
      return;
    }
    if (state.status == 'CANCELLED' ||
        state.status == 'NO_DRIVER_AVAILABLE' ||
        (state.status == 'COMPLETED' &&
            (!_hasTrip || state.payment?.isPaid == true))) {
      return;
    }
    _active = true;
    final epoch = ++_epoch;
    _timer = Timer.periodic(pollInterval, (_) => unawaited(refresh()));
    if (_hasTrip) {
      unawaited(_startTrip(epoch));
    }
  }

  Future<void> _startTrip(int epoch) async {
    try {
      final snapshot = await session!.getSession();
      if (!_active || isClosed || epoch != _epoch) {
        return;
      }
      if (snapshot.accessToken == null) {
        _endSession();
        return;
      }
      _generation = snapshot.generation;
      await refresh();
      if (!await _current(epoch)) {
        return;
      }
      _connect(epoch);
    } catch (error) {
      if (_active && !isClosed && epoch == _epoch) {
        emit(state.copyWith(error: customerError(error), loading: false));
      }
    }
  }

  Future<bool> _current(int epoch) async {
    if (!_active || isClosed || epoch != _epoch || _generation == null) {
      return false;
    }
    final valid = await session!.isCurrentSession(_generation!);
    if (!valid && !isClosed && _active && epoch == _epoch) {
      _endSession();
      return false;
    }
    return valid && _active && !isClosed && epoch == _epoch;
  }

  void _endSession({String? message}) {
    stop();
    if (!isClosed) {
      emit(state.copyWith(
          tracking: null,
          payment: null,
          liveLocation: null,
          eventStatus: null,
          sessionEnded: true,
          loading: false,
          cancellationBusy: false,
          cancellationUnresolved: false,
          error: message ??
              'Phiên đăng nhập đã thay đổi. Hãy mở lại chuyến từ tài khoản hiện tại.'));
    }
  }

  void _connect(int epoch) {
    if (realtime == null ||
        !_active ||
        isClosed ||
        epoch != _epoch ||
        isTerminalTripStatus(state.status) ||
        _tripSubscription != null) {
      return;
    }
    final subscription = realtime!.listen(
        bookingPublicId: state.booking.publicId,
        sessionGeneration: _generation!,
        driver: false,
        reconcileBeforeEvents: () async {
          if (!await _current(epoch)) {
            throw StateError('Phiên theo dõi không còn hiệu lực');
          }
          final before = _trackingSyncRevision;
          await refresh();
          if (!await _current(epoch) || _trackingSyncRevision == before) {
            throw StateError('Chưa thể đồng bộ tracking từ REST');
          }
        });
    _tripSubscription = subscription;
    emit(state.copyWith(realtimeState: subscription.state));
    // Both subscriptions are cancelled by _disconnectRealtime on stop/close.
    // ignore: cancel_subscriptions
    _connectionStates = subscription.connectionStates.listen((connection) {
      unawaited(_handleConnection(connection, epoch));
    });
    // ignore: cancel_subscriptions
    _events = subscription.events.listen((event) {
      unawaited(_handleEvent(event, epoch));
    });
  }

  Future<void> _handleConnection(
      TripRealtimeConnectionState connection, int epoch) async {
    if (!await _current(epoch)) {
      return;
    }
    emit(state.copyWith(realtimeState: connection));
  }

  Future<void> _handleEvent(TripRealtimeEvent event, int epoch) async {
    if (event.bookingPublicId != state.booking.publicId ||
        !await _current(epoch)) {
      return;
    }
    if (event is TripStatusChangedEvent) {
      if (isTerminalTripStatus(event.status)) {
        if (isTerminalTripStatus(state.status)) return;
        _terminalEventRevision++;
        emit(state.copyWith(
            tracking: state.tracking?.withoutPrivateLiveData(),
            payment: null,
            eventStatus: event.status,
            liveLocation: null,
            cancellationBusy: false,
            cancellationUnresolved: false));
        _disconnectRealtime();
        unawaited(refresh());
        return;
      }
      if (_stage(event.status) <= _stage(state.status)) {
        return;
      }
      emit(state.copyWith(
          eventStatus: event.status, liveLocation: state.liveLocation));
      unawaited(refresh());
    } else if (event is TripDriverLocationEvent &&
        const {
          'DRIVER_ACCEPTED',
          'DRIVER_ARRIVED',
          'PASSENGER_ONBOARD',
          'IN_PROGRESS'
        }.contains(state.status)) {
      final prior = state.liveLocation?.updatedAt;
      if (prior != null && !event.recordedAt.isAfter(prior)) {
        return;
      }
      final location = CustomerLiveLocation.valid(event.latitude,
          event.longitude, event.accuracy, event.bearing, event.recordedAt);
      if (location != null) {
        emit(state.copyWith(liveLocation: location));
      }
    }
  }

  void _disconnectRealtime() {
    final events = _events;
    final connectionStates = _connectionStates;
    if (events != null) {
      unawaited(events.cancel());
    }
    if (connectionStates != null) {
      unawaited(connectionStates.cancel());
    }
    _events = null;
    _connectionStates = null;
    final subscription = _tripSubscription;
    _tripSubscription = null;
    if (subscription != null) {
      unawaited(subscription.dispose());
    }
    if (!isClosed) {
      emit(state.copyWith(
          realtimeState: TripRealtimeConnectionState.disconnected));
    }
  }

  void stop() {
    _active = false;
    _epoch++;
    _timer?.cancel();
    _timer = null;
    // A foreground return must revalidate contact details and the last GPS fix.
    final tracking = state.tracking;
    if (!isClosed) {
      emit(state.copyWith(
          tracking: tracking?.withoutParticipantDetails(), liveLocation: null));
      if (state.cancellationBusy) {
        emit(state.copyWith(
            cancellationBusy: false,
            cancellationUnresolved: true,
            error:
                'Chưa rõ kết quả hủy chuyến. Kết nối lại để kiểm tra với máy chủ.'));
      }
    }
    _disconnectRealtime();
  }

  Future<void> refresh({bool resolveCancellation = false}) async {
    if (isClosed || !_active || state.sessionEnded) {
      return;
    }
    if (_busy) {
      _queued = true;
      await _refreshDone?.future;
      return;
    }
    final epoch = _epoch;
    final terminalAtStart = _terminalEventRevision;
    _busy = true;
    final done = Completer<void>();
    _refreshDone = done;
    emit(state.copyWith(
        loading: true,
        error: state.cancellationUnresolved ? state.error : null));
    try {
      if (!_hasTrip) {
        final booking = await getBooking(state.booking.publicId);
        if (!_active || isClosed || epoch != _epoch) {
          return;
        }
        emit(state.copyWith(booking: booking, loading: false));
        if (isTerminalTripStatus(booking.status)) {
          stop();
        }
        return;
      }
      if (!await _current(epoch)) {
        return;
      }
      final tracking =
          await tripRepository!.tracking(state.booking.publicId, _generation!);
      if (!await _current(epoch)) {
        return;
      }
      if (terminalAtStart != _terminalEventRevision) {
        return;
      }
      if (tracking.bookingPublicId != state.booking.publicId) {
        throw const FormatException('Tracking không khớp Booking');
      }
      if (isTerminalTripStatus(state.status) &&
          !isTerminalTripStatus(tracking.status)) {
        emit(state.copyWith(
            tracking: state.tracking?.withoutPrivateLiveData(),
            payment: null,
            liveLocation: null,
            loading: false));
        return;
      }
      _trackingSyncRevision++;
      // A stale REST response must not resurrect a completed trip or its GPS.
      final previousStatus = state.status;
      final newerPreviousStatus = !isTerminalTripStatus(tracking.status) &&
          _stage(previousStatus) > _stage(tracking.status);
      final effectiveStatus =
          newerPreviousStatus ? previousStatus : tracking.status;
      final previousTracking = state.tracking;
      final displayTracking = !isTerminalTripStatus(tracking.status) &&
              previousTracking != null &&
              _stage(previousTracking.status) > _stage(tracking.status)
          ? previousTracking
          : tracking;
      final freshLocation = CustomerLiveLocation.fromTracking(tracking);
      final currentLocation = state.liveLocation;
      final preferredLocation = freshLocation == null
          ? currentLocation
          : currentLocation != null &&
                  !freshLocation.updatedAt.isAfter(currentLocation.updatedAt)
              ? currentLocation
              : freshLocation;
      emit(state.copyWith(
          tracking: isTerminalTripStatus(effectiveStatus)
              ? displayTracking.withoutPrivateLiveData()
              : displayTracking,
          eventStatus: newerPreviousStatus ? previousStatus : null,
          liveLocation:
              isTerminalTripStatus(effectiveStatus) ? null : preferredLocation,
          payment: isTerminalTripStatus(effectiveStatus) &&
                  effectiveStatus != 'COMPLETED'
              ? null
              : state.payment,
          cancellationUnresolved: isTerminalTripStatus(effectiveStatus)
              ? false
              : resolveCancellation
                  ? false
                  : state.cancellationUnresolved,
          loading: false));
      if (isTerminalTripStatus(effectiveStatus)) {
        _disconnectRealtime();
      }

      if (effectiveStatus == 'CANCELLED' ||
          effectiveStatus == 'NO_DRIVER_AVAILABLE') {
        stop();
        return;
      }

      try {
        final payment =
            await tripRepository!.payment(state.booking.publicId, _generation!);
        if (!await _current(epoch)) {
          return;
        }
        if (terminalAtStart != _terminalEventRevision) {
          return;
        }
        if (payment.bookingPublicId != state.booking.publicId) {
          throw const FormatException('Thanh toán không khớp Booking');
        }
        emit(state.copyWith(
            payment: payment,
            error: state.cancellationUnresolved ? state.error : null));
        if (effectiveStatus == 'COMPLETED' && payment.isPaid) {
          stop();
        }
      } catch (error) {
        if (!await _current(epoch)) {
          return;
        }
        if ((error is ServerException &&
                const {401, 403, 404}.contains(error.statusCode)) ||
            error is UnauthorizedException) {
          _endSession(message: customerError(error));
        } else {
          emit(state.copyWith(error: customerError(error)));
        }
      }
    } catch (error) {
      if (_hasTrip && !await _current(epoch)) {
        return;
      }
      if (!_active || isClosed || epoch != _epoch) {
        return;
      }
      if ((error is ServerException &&
              const {401, 403, 404}.contains(error.statusCode)) ||
          error is UnauthorizedException) {
        _endSession(message: customerError(error));
      } else {
        emit(state.copyWith(loading: false, error: customerError(error)));
      }
    } finally {
      _busy = false;
      if (identical(_refreshDone, done)) {
        _refreshDone = null;
      }
      done.complete();
      if (_queued && _active && !isClosed) {
        _queued = false;
        unawaited(refresh());
      }
    }
  }

  Future<void> cancel() async {
    if (!_active || !_hasTrip || !state.canCancel || _generation == null) {
      return;
    }
    final epoch = _epoch;
    if (!await _current(epoch)) return;
    emit(state.copyWith(cancellationBusy: true, error: null));
    try {
      final result = await tripRepository!
          .cancelCustomer(state.booking.publicId, _generation!);
      if (!await _current(epoch)) return;
      if (result.bookingPublicId != state.booking.publicId ||
          result.status != 'CANCELLED') {
        throw const FormatException('Phản hồi hủy chuyến không khớp Booking');
      }
      _terminalEventRevision++;
      emit(state.copyWith(
          tracking: state.tracking?.withoutPrivateLiveData(),
          payment: null,
          liveLocation: null,
          eventStatus: 'CANCELLED',
          cancellationBusy: false,
          cancellationUnresolved: false,
          error: null));
      _disconnectRealtime();
      await refresh();
    } catch (error) {
      if (!await _current(epoch)) return;
      if ((error is ServerException &&
              const {401, 403, 404}.contains(error.statusCode)) ||
          error is UnauthorizedException) {
        _endSession(message: customerError(error));
        return;
      }
      final uncertain = error is NetworkException ||
          error is ServerException && error.statusCode == 503;
      emit(state.copyWith(
          cancellationBusy: false,
          cancellationUnresolved: uncertain,
          error: uncertain
              ? 'Chưa rõ kết quả hủy chuyến. Đang đối chiếu với máy chủ.'
              : customerError(error)));
      if (uncertain || error is ServerException && error.statusCode == 409) {
        await refresh(resolveCancellation: !uncertain);
      }
    }
  }

  @override
  Future<void> close() async {
    stop();
    await super.close();
  }
}
