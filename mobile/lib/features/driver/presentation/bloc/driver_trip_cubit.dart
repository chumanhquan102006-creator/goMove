import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../../core/error/exceptions.dart';
import '../../../../core/storage/secure_storage_service.dart';
import '../../../trip/data/trip_realtime_client.dart';
import '../../../trip/domain/models/trip_models.dart';
import '../../../trip/domain/repositories/trip_repository.dart';
import '../../data/location/driver_location_source.dart';

class DriverTripState {
  static const _same = Object();
  final TrackingSnapshot? tracking;
  final CashPayment? payment;
  final TripTransition? transition;
  final CashReceipt? receipt;
  final bool loading;
  final bool operationBusy;
  final bool unresolved;
  final bool foreground;
  final bool sessionEnded;
  final TripRealtimeConnectionState realtime;
  final String? error;
  final String? notice;

  const DriverTripState(
      {this.tracking,
      this.payment,
      this.transition,
      this.receipt,
      this.loading = false,
      this.operationBusy = false,
      this.unresolved = false,
      this.foreground = true,
      this.sessionEnded = false,
      this.realtime = TripRealtimeConnectionState.disconnected,
      this.error,
      this.notice});

  String? get status => transition?.status ?? tracking?.status;
  TripAction? get availableAction => sessionEnded || unresolved || operationBusy
      ? null
      : actionForTripStatus(status ?? '');
  bool get canConfirmCash =>
      status == 'COMPLETED' &&
      payment?.method == 'CASH' &&
      payment?.status == 'PENDING' &&
      receipt == null &&
      !sessionEnded &&
      !operationBusy &&
      !unresolved;
  bool get canRecoverReceipt =>
      status == 'COMPLETED' &&
      payment?.status == 'PAID' &&
      receipt == null &&
      !sessionEnded &&
      !operationBusy;

  DriverTripState copy(
          {Object? tracking = _same,
          Object? payment = _same,
          Object? transition = _same,
          Object? receipt = _same,
          bool? loading,
          bool? operationBusy,
          bool? unresolved,
          bool? foreground,
          bool? sessionEnded,
          TripRealtimeConnectionState? realtime,
          Object? error = _same,
          Object? notice = _same}) =>
      DriverTripState(
        tracking: identical(tracking, _same)
            ? this.tracking
            : tracking as TrackingSnapshot?,
        payment:
            identical(payment, _same) ? this.payment : payment as CashPayment?,
        transition: identical(transition, _same)
            ? this.transition
            : transition as TripTransition?,
        receipt:
            identical(receipt, _same) ? this.receipt : receipt as CashReceipt?,
        loading: loading ?? this.loading,
        operationBusy: operationBusy ?? this.operationBusy,
        unresolved: unresolved ?? this.unresolved,
        foreground: foreground ?? this.foreground,
        sessionEnded: sessionEnded ?? this.sessionEnded,
        realtime: realtime ?? this.realtime,
        error: identical(error, _same) ? this.error : error as String?,
        notice: identical(notice, _same) ? this.notice : notice as String?,
      );
}

class DriverTripCubit extends Cubit<DriverTripState> {
  final String bookingPublicId;
  final TripRepository _repository;
  final SecureStorageService _session;
  final TripRealtimeClient _realtime;
  final DriverLocationSource _location;
  final void Function(String bookingPublicId)? onCompleted;
  final Future<void> Function(CashReceipt receipt)? onSettled;
  final Duration pollInterval;
  final Duration gpsInterval;
  int? _generation;
  int _revision = 0;
  int _connectionRevision = 0;
  bool _syncing = false;
  Completer<void>? _queuedRefresh;
  bool _queuedRefreshManual = false;
  int _confirmedOperationRevision = 0;
  bool _sendingGps = false;
  Timer? _pollTimer;
  Timer? _gpsTimer;
  TripRealtimeSubscription? _subscription;
  StreamSubscription<TripRealtimeConnectionState>? _connectionStates;
  StreamSubscription<TripRealtimeEvent>? _events;

  DriverTripCubit(
      {required this.bookingPublicId,
      required TripRepository repository,
      required SecureStorageService session,
      required TripRealtimeClient realtime,
      required DriverLocationSource location,
      this.onCompleted,
      this.onSettled,
      this.pollInterval = const Duration(seconds: 10),
      this.gpsInterval = const Duration(seconds: 9)})
      : _repository = repository,
        _session = session,
        _realtime = realtime,
        _location = location,
        super(const DriverTripState());

  Future<bool> _current(int revision) async {
    if (isClosed ||
        revision != _revision ||
        _generation == null ||
        state.sessionEnded) {
      return false;
    }
    final valid = await _session.isCurrentSession(_generation!);
    if (!valid && !isClosed && revision == _revision) {
      _revision++;
      _pollTimer?.cancel();
      _pollTimer = null;
      unawaited(_disconnect());
      emit(state.copy(
          tracking: null,
          payment: null,
          transition: null,
          receipt: null,
          sessionEnded: true,
          operationBusy: false,
          loading: false,
          error: 'Phiên đăng nhập đã thay đổi. Mở lại chuyến '
              'bằng tài khoản hiện tại.'));
      return false;
    }
    return valid && !isClosed && revision == _revision;
  }

  void _endAccess(Object error) {
    if (isClosed || state.sessionEnded) return;
    _revision++;
    _pollTimer?.cancel();
    _pollTimer = null;
    emit(state.copy(
        tracking: null,
        payment: null,
        transition: null,
        receipt: null,
        sessionEnded: true,
        operationBusy: false,
        loading: false,
        unresolved: false,
        error: _message(error)));
    unawaited(_disconnect());
  }

  Future<void> initialize() async {
    final revision = ++_revision;
    _generation = (await _session.getSession()).generation;
    if (!await _current(revision)) return;
    emit(state.copy(loading: true, error: null));
    await refresh();
    if (!await _current(revision) || !state.foreground) return;
    _startPoll();
    await _connect();
  }

  Future<void> refresh({bool manual = false}) async {
    final revision = _revision;
    if (_generation == null || !await _current(revision)) return;
    if (_syncing) {
      _queuedRefreshManual |= manual;
      await (_queuedRefresh ??= Completer<void>()).future;
      return;
    }
    _syncing = true;
    final confirmedAtStart = _confirmedOperationRevision;
    try {
      final tracking =
          await _repository.tracking(bookingPublicId, _generation!);
      if (!await _current(revision)) return;
      final payment = await _repository.payment(bookingPublicId, _generation!);
      if (!await _current(revision)) return;
      // A poll started before a confirmed POST must not overwrite its newer
      // transition or PAID receipt with the poll's older REST snapshot.
      if (confirmedAtStart != _confirmedOperationRevision) return;
      final previous = state.tracking;
      final status = tracking.status;
      emit(state.copy(
          tracking: tracking,
          payment: payment,
          transition: null,
          loading: false,
          unresolved: manual ? false : state.unresolved,
          error: state.unresolved && !manual ? state.error : null));
      if (status == 'COMPLETED') {
        _stopGps();
        if (previous?.status != 'COMPLETED') {
          onCompleted?.call(bookingPublicId);
        }
        await _disconnect();
      } else if (tracking.allowsLiveLocation &&
          state.foreground &&
          _subscription == null) {
        await _connect();
      }
    } catch (error) {
      if (await _current(revision)) {
        if (_accessError(error)) {
          _endAccess(error);
          return;
        }
        emit(state.copy(loading: false, error: _message(error)));
      }
    } finally {
      _syncing = false;
      final queued = _queuedRefresh;
      final queuedManual = _queuedRefreshManual;
      _queuedRefresh = null;
      _queuedRefreshManual = false;
      if (queued != null) {
        unawaited(refresh(manual: queuedManual).then((_) => queued.complete(),
            onError: (Object error, StackTrace stack) =>
                queued.completeError(error, stack)));
      }
    }
  }

  Future<void> perform(TripAction action) async {
    if (state.operationBusy ||
        state.unresolved ||
        state.status != action.fromStatus ||
        _generation == null) {
      return;
    }
    final revision = _revision;
    emit(state.copy(operationBusy: true, error: null, notice: null));
    try {
      final response =
          await _repository.transition(bookingPublicId, action, _generation!);
      if (!await _current(revision)) return;
      _confirmedOperationRevision++;
      emit(state.copy(
          transition: response,
          operationBusy: false,
          unresolved: false,
          notice: 'Máy chủ đã xác nhận ${response.status}.'));
      if (response.status == 'COMPLETED') {
        _stopGps();
        onCompleted?.call(bookingPublicId);
        await _disconnect();
      }
      await refresh();
    } catch (error) {
      if (!await _current(revision)) return;
      if (_accessError(error)) {
        _endAccess(error);
        return;
      }
      final uncertain = error is NetworkException ||
          error is ServerException && error.statusCode == 503;
      emit(state.copy(
          operationBusy: false,
          unresolved: uncertain,
          error: uncertain
              ? 'Chưa xác định kết quả. Đang đối chiếu trạng thái máy chủ; không tự gửi lại.'
              : _message(error)));
      if (uncertain || error is ServerException && error.statusCode == 409) {
        await refresh();
        if (uncertain &&
            await _current(revision) &&
            state.tracking?.status == action.toStatus) {
          emit(state.copy(
              unresolved: false,
              error: null,
              notice: 'Đã đối chiếu: máy chủ xác nhận ${action.toStatus}.'));
        } else if (!uncertain && await _current(revision)) {
          emit(state.copy(error: _message(error)));
        }
      }
    }
  }

  Future<void> confirmCash() async {
    if (!state.canConfirmCash || _generation == null) return;
    await _requestReceipt();
  }

  /// An explicit replay after GET payment proves PAID only retrieves the
  /// Backend's original durable receipt; it does not settle a second time.
  Future<void> recoverReceipt() async {
    if (!state.canRecoverReceipt || _generation == null) return;
    await _requestReceipt();
  }

  Future<void> _requestReceipt() async {
    final revision = _revision;
    emit(state.copy(operationBusy: true, error: null, notice: null));
    try {
      final receipt =
          await _repository.confirmCash(bookingPublicId, _generation!);
      if (!await _current(revision)) return;
      _confirmedOperationRevision++;
      emit(state.copy(
          payment: CashPayment(
              paymentPublicId: receipt.paymentPublicId,
              bookingPublicId: receipt.bookingPublicId,
              method: receipt.paymentMethod,
              status: receipt.paymentStatus,
              amount: receipt.cashCollectedAmount,
              currency: receipt.currency,
              paidAt: receipt.paidAt),
          receipt: receipt,
          operationBusy: false,
          unresolved: false,
          notice: 'Máy chủ xác nhận đã thu tiền mặt và giải phóng tài xế.'));
      if (onSettled != null) {
        await onSettled!(receipt);
      }
      if (!await _current(revision)) return;
      await refresh();
    } catch (error) {
      if (!await _current(revision)) return;
      if (_accessError(error)) {
        _endAccess(error);
        return;
      }
      final uncertain = error is NetworkException ||
          error is ServerException && error.statusCode == 503;
      emit(state.copy(
          operationBusy: false,
          unresolved: uncertain,
          error: uncertain
              ? 'Chưa rõ kết quả thu tiền. Đang kiểm tra khoản thanh toán; không tự xác nhận lại.'
              : _message(error)));
      if (uncertain || error is ServerException && error.statusCode == 409) {
        await refresh();
      }
    }
  }

  Future<void> _connect() async {
    final revision = _revision;
    if (_subscription != null ||
        !state.foreground ||
        state.tracking?.allowsLiveLocation != true ||
        _generation == null ||
        !await _current(revision)) {
      return;
    }
    final connectionRevision = ++_connectionRevision;
    final subscription = _realtime.listen(
        bookingPublicId: bookingPublicId,
        sessionGeneration: _generation!,
        driver: true,
        reconcileBeforeEvents: () async {
          await refresh();
          if (!await _current(revision) || state.tracking == null) {
            throw StateError('Không thể đối chiếu tracking');
          }
        });
    _subscription = subscription;
    _connectionStates = subscription.connectionStates.listen((connection) {
      unawaited(_handleConnection(connection, revision, connectionRevision));
    });
    _events = subscription.events.listen((event) {
      unawaited(_handleEvent(event, revision, connectionRevision));
    });
  }

  Future<void> _handleConnection(TripRealtimeConnectionState connection,
      int revision, int connectionRevision) async {
    if (connectionRevision != _connectionRevision ||
        !await _current(revision)) {
      return;
    }
    emit(state.copy(realtime: connection));
    if (kDebugMode) {
      debugPrint('GoMoveGPS source=trip-STOMP connection=$connection '
          'trackingStatus=${state.tracking?.status}');
    }
    if (connection == TripRealtimeConnectionState.connected &&
        state.tracking?.allowsLiveLocation == true) {
      _startGps();
    } else {
      _stopGps();
    }
  }

  Future<void> _handleEvent(
      TripRealtimeEvent event, int revision, int connectionRevision) async {
    if (connectionRevision != _connectionRevision ||
        event.bookingPublicId != bookingPublicId ||
        !await _current(revision)) {
      return;
    }
    if (event is TripStatusChangedEvent) {
      if (event.status == 'COMPLETED') {
        _stopGps();
        onCompleted?.call(bookingPublicId);
      }
      await refresh();
    }
  }

  void _startPoll() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(pollInterval, (_) => unawaited(refresh()));
  }

  void _startGps() {
    if (_gpsTimer != null) return;
    _gpsTimer = Timer.periodic(gpsInterval, (_) => unawaited(sendGpsOnce()));
    unawaited(sendGpsOnce());
  }

  void _stopGps() {
    _gpsTimer?.cancel();
    _gpsTimer = null;
  }

  Future<void> sendGpsOnce() async {
    final revision = _revision;
    final connectionRevision = _connectionRevision;
    final subscription = _subscription;
    if (_sendingGps ||
        subscription == null ||
        subscription.state != TripRealtimeConnectionState.connected ||
        !state.foreground ||
        state.tracking?.allowsLiveLocation != true ||
        !await _current(revision)) {
      return;
    }
    _sendingGps = true;
    try {
      final point = await _location.current();
      if (!await _current(revision) ||
          connectionRevision != _connectionRevision ||
          !state.foreground ||
          state.tracking?.allowsLiveLocation != true ||
          point.sampledAt == null) {
        if (kDebugMode) {
          debugPrint('GoMoveGPS source=trip-STOMP result=skipped '
              'reason=${point.sampledAt == null ? 'missing_sample_time' : 'session_or_connection_changed'} '
              'connection=${subscription.state} '
              'sampledAt=${point.sampledAt?.toUtc().toIso8601String()}');
        }
        return;
      }
      final sent =
          await subscription.sendLocation(point, sampledAt: point.sampledAt!);
      if (kDebugMode) {
        debugPrint(
            'GoMoveGPS source=trip-STOMP result=${sent ? 'transport_sent' : 'skipped'} '
            'lat=${point.latitude} lon=${point.longitude} '
            'sampledAt=${point.sampledAt!.toUtc().toIso8601String()} '
            'ageMs=${DateTime.now().toUtc().difference(point.sampledAt!.toUtc()).inMilliseconds} '
            'connection=${subscription.state}');
      }
      if (!sent && await _current(revision)) {
        emit(state.copy(
            notice: 'GPS chưa được gửi; chờ vị trí mới hoặc kết nối lại.'));
      }
    } on DriverLocationException catch (error) {
      if (kDebugMode) {
        debugPrint('GoMoveGPS source=trip-STOMP result=skipped '
            'reason=location_${error.problem.name} '
            'connection=${subscription.state}');
      }
      if (await _current(revision)) {
        emit(state.copy(
            error: 'Cần bật GPS và cấp quyền vị trí để theo dõi chuyến.'));
      }
    } catch (error) {
      if (kDebugMode) {
        debugPrint('GoMoveGPS source=trip-STOMP result=failed '
            'errorType=${error.runtimeType} '
            'connection=${subscription.state}');
      }
      if (await _current(revision)) {
        emit(state.copy(
            error: 'Không gửi được GPS chuyến đi; đang dùng tracking REST.'));
      }
    } finally {
      _sendingGps = false;
    }
  }

  Future<void> _disconnect() async {
    _connectionRevision++;
    _stopGps();
    await _connectionStates?.cancel();
    await _events?.cancel();
    _connectionStates = null;
    _events = null;
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) {
      await subscription.dispose();
    }
    if (!isClosed) {
      emit(state.copy(realtime: TripRealtimeConnectionState.disconnected));
    }
  }

  Future<void> pause() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    if (!isClosed) emit(state.copy(foreground: false));
    await _disconnect();
  }

  Future<void> resume() async {
    if (isClosed || state.foreground || state.sessionEnded) return;
    emit(state.copy(foreground: true));
    await refresh(manual: true);
    if (!isClosed && !state.sessionEnded) {
      _startPoll();
      await _connect();
    }
  }

  @override
  Future<void> close() async {
    _revision++;
    _pollTimer?.cancel();
    _pollTimer = null;
    await _disconnect();
    await super.close();
  }

  bool _accessError(Object error) =>
      error is UnauthorizedException ||
      error is ServerException &&
          const {401, 403, 404}.contains(error.statusCode);

  String _message(Object error) {
    if (error is UnauthorizedException) {
      return 'Phiên đăng nhập đã hết hạn. Hãy đăng nhập lại.';
    }
    if (error is NetworkException) {
      return 'Không kết nối được; kết quả chưa xác định.';
    }
    if (error is ServerException) {
      return switch (error.statusCode) {
        401 => 'Phiên đăng nhập đã hết hạn. Hãy đăng nhập lại.',
        403 => 'Tài khoản không được phép thực hiện thao tác này.',
        404 => 'Không tìm thấy chuyến được phân công cho tài xế.',
        409 =>
          'Trạng thái chuyến hoặc thanh toán đã thay đổi. Hãy cập nhật lại.',
        503 => 'Máy chủ đang bận. Hãy kiểm tra trạng thái trước khi thử lại.',
        _ => 'Máy chủ chưa xử lý được yêu cầu. Hãy thử lại sau.',
      };
    }
    if (error is FormatException) return error.message;
    return 'Không thể hoàn tất thao tác. Hãy thử lại.';
  }
}
