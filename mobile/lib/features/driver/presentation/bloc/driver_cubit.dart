import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../../core/error/exceptions.dart';
import '../../../../core/storage/secure_storage_service.dart';
import '../../data/accepted_booking_store.dart';
import '../../data/location/driver_location_source.dart';
import '../../domain/models/driver_models.dart';
import '../../domain/usecases/driver_usecases.dart';
import '../../../trip/domain/repositories/trip_repository.dart';
import '../../../trip/domain/models/trip_models.dart';

class DriverState {
  static const _unchanged = Object();
  final String? operatingStatus;
  final String? approvalStatus;
  final String? driverPublicId;
  final List<DriverVehicle> vehicles;
  final DriverOffer? offer;
  final DriverOffer? acceptedOffer;
  final bool loading;
  final bool actionBusy;
  final bool offerActionBusy;
  final bool foreground;
  final String locationMessage;
  final DriverLocationProblem? locationProblem;
  final DateTime? lastLocationUpload;
  final String? error;
  final String? notice;
  final bool unresolvedDecision;
  final bool completedAwaitingSettlement;
  // Every explicit write gets a distinct identity, even for equal messages.
  // Copies which do not write feedback retain its identity.
  final Object? _errorWrite;
  final Object? _noticeWrite;

  const DriverState(
      {this.operatingStatus,
      this.approvalStatus,
      this.driverPublicId,
      this.vehicles = const [],
      this.offer,
      this.acceptedOffer,
      this.loading = false,
      this.actionBusy = false,
      this.offerActionBusy = false,
      this.foreground = true,
      this.locationMessage = 'Chưa gửi GPS',
      this.locationProblem,
      this.lastLocationUpload,
      this.error,
      this.notice,
      this.unresolvedDecision = false,
      this.completedAwaitingSettlement = false})
      : _errorWrite = null,
        _noticeWrite = null;

  DriverState._feedback(DriverState value, this._errorWrite, this._noticeWrite)
      : operatingStatus = value.operatingStatus,
        approvalStatus = value.approvalStatus,
        driverPublicId = value.driverPublicId,
        vehicles = value.vehicles,
        offer = value.offer,
        acceptedOffer = value.acceptedOffer,
        loading = value.loading,
        actionBusy = value.actionBusy,
        offerActionBusy = value.offerActionBusy,
        foreground = value.foreground,
        locationMessage = value.locationMessage,
        locationProblem = value.locationProblem,
        lastLocationUpload = value.lastLocationUpload,
        error = value.error,
        notice = value.notice,
        unresolvedDecision = value.unresolvedDecision,
        completedAwaitingSettlement = value.completedAwaitingSettlement;

  DriverVehicle? get activeVehicle {
    for (final vehicle in vehicles) {
      if (vehicle.active) return vehicle;
    }
    return null;
  }

  DriverState copy(
      {Object? operatingStatus = _unchanged,
      Object? approvalStatus = _unchanged,
      Object? driverPublicId = _unchanged,
      List<DriverVehicle>? vehicles,
      Object? offer = _unchanged,
      Object? acceptedOffer = _unchanged,
      bool? loading,
      bool? actionBusy,
      bool? offerActionBusy,
      bool? foreground,
      String? locationMessage,
      Object? locationProblem = _unchanged,
      Object? lastLocationUpload = _unchanged,
      Object? error = _unchanged,
      Object? notice = _unchanged,
      bool? unresolvedDecision,
      bool? completedAwaitingSettlement}) {
    final value = DriverState(
        operatingStatus: identical(operatingStatus, _unchanged)
            ? this.operatingStatus
            : operatingStatus as String?,
        approvalStatus: identical(approvalStatus, _unchanged)
            ? this.approvalStatus
            : approvalStatus as String?,
        driverPublicId: identical(driverPublicId, _unchanged)
            ? this.driverPublicId
            : driverPublicId as String?,
        vehicles: vehicles ?? this.vehicles,
        offer:
            identical(offer, _unchanged) ? this.offer : offer as DriverOffer?,
        acceptedOffer: identical(acceptedOffer, _unchanged)
            ? this.acceptedOffer
            : acceptedOffer as DriverOffer?,
        loading: loading ?? this.loading,
        actionBusy: actionBusy ?? this.actionBusy,
        offerActionBusy: offerActionBusy ?? this.offerActionBusy,
        foreground: foreground ?? this.foreground,
        locationMessage: locationMessage ?? this.locationMessage,
        locationProblem: identical(locationProblem, _unchanged)
            ? this.locationProblem
            : locationProblem as DriverLocationProblem?,
        lastLocationUpload: identical(lastLocationUpload, _unchanged)
            ? this.lastLocationUpload
            : lastLocationUpload as DateTime?,
        error: identical(error, _unchanged) ? this.error : error as String?,
        notice: identical(notice, _unchanged) ? this.notice : notice as String?,
        unresolvedDecision: unresolvedDecision ?? this.unresolvedDecision,
        completedAwaitingSettlement:
            completedAwaitingSettlement ?? this.completedAwaitingSettlement);
    return DriverState._feedback(
        value,
        identical(error, _unchanged) ? _errorWrite : Object(),
        identical(notice, _unchanged) ? _noticeWrite : Object());
  }
}

class DriverCubit extends Cubit<DriverState> {
  static const offerPollInterval = Duration(seconds: 2);
  static const locationHeartbeatInterval = Duration(seconds: 9);
  static const locationFreshness = Duration(seconds: 30);
  static const _offlineNotice = 'Máy chủ đã xác nhận OFFLINE.';
  static const _offlineGps = 'Đã ngừng gửi GPS khi tài xế OFFLINE.';
  static const _staleGps = 'GPS quá 30 giây; đang chờ vị trí mới.';

  final DriverUseCases _useCases;
  final DriverLocationSource _location;
  final SecureStorageService _session;
  final AcceptedBookingStore _acceptedStore;
  final TripRepository? _tripRepository;
  final String userPublicId;
  final bool isMock;
  final DateTime Function() _now;
  final Duration pollInterval;
  final Duration heartbeatInterval;
  Timer? _pollTimer;
  Timer? _locationTimer;
  bool _polling = false;
  bool _uploading = false;
  bool _reconciling = false;
  int _offerRevision = 0;
  int _activityRevision = 0;
  int? _generation;
  int _revision = 0;
  bool _tripChannelActive = false;
  DateTime? _lastUploadedSampleAt;
  String? _locationFailure;
  // A source owns the exact committed write token, not its message. Any
  // independent writer changes that token atomically through DriverState.copy.
  Object? _pollErrorOwner;
  Object? _statusErrorOwner;
  Object? _vehicleLoadErrorOwner;
  Object? _vehicleActionErrorOwner;
  Object? _bookingErrorOwner;
  Object? _offlineNoticeOwner;
  Object? _pauseNoticeOwner;
  int _vehicleLoadRevision = 0;
  int _statusRevision = 0;
  int _resumeRevision = 0;
  String? _pendingStatus;
  String? _resumeStatus;
  Completer<void>? _vehicleAction;
  Timer? _activeResumeTimer;
  Object? _activeResumeRun;
  bool _checkingActiveResume = false;

  DriverCubit(
      {required DriverUseCases useCases,
      required DriverLocationSource location,
      required SecureStorageService session,
      required AcceptedBookingStore acceptedStore,
      TripRepository? tripRepository,
      required this.userPublicId,
      required this.isMock,
      DateTime Function()? now,
      this.pollInterval = offerPollInterval,
      this.heartbeatInterval = locationHeartbeatInterval})
      : _useCases = useCases,
        _location = location,
        _session = session,
        _acceptedStore = acceptedStore,
        _tripRepository = tripRepository,
        _now = now ?? DateTime.now,
        super(const DriverState());

  Future<bool> _current(int revision) async {
    if (isClosed || revision != _revision || _generation == null) return false;
    final current = await _session.isCurrentSession(_generation!);
    return current && !isClosed && revision == _revision;
  }

  int get _sessionId => _generation!;

  Object? _clearError(Object? owner) =>
      owner != null && identical(state._errorWrite, owner)
          ? null
          : DriverState._unchanged;

  Object? _clearNotice(Object? owner) =>
      owner != null && identical(state._noticeWrite, owner)
          ? null
          : DriverState._unchanged;

  void _emitBookingError(DriverState next) {
    emit(next);
    _bookingErrorOwner = state._errorWrite;
  }

  Future<void> initialize() async {
    if (isMock) {
      emit(state.copy(
          notice:
              'Chế độ mock không gọi API tài xế. Hãy chạy MOCK_ENABLED=false.'));
      return;
    }
    final revision = ++_revision;
    _statusRevision++;
    _resumeRevision++;
    _pendingStatus = null;
    _resumeStatus = null;
    final snapshot = await _session.getSession();
    if (isClosed || revision != _revision) return;
    _generation = snapshot.generation;
    if (!await _current(revision)) return;
    emit(state.copy(loading: true, error: null, notice: null));
    try {
      final authenticatedUser = await _session.getUserPublicId();
      if (!await _current(revision)) return;
      if (authenticatedUser != userPublicId) {
        _generation = null;
        _stopForeground();
        emit(state.copy(
            loading: false,
            error: 'Tài khoản đã thay đổi. Mở lại màn hình tài xế.'));
        return;
      }
      final loadRequest = ++_vehicleLoadRevision;
      try {
        final vehicles = await _useCases.vehicles(_sessionId);
        if (!await _current(revision)) return;
        if (loadRequest == _vehicleLoadRevision) {
          emit(state.copy(vehicles: vehicles, loading: false));
        }
      } catch (error) {
        if (!await _current(revision)) return;
        // Vehicle listing is not a prerequisite for recovering an accepted
        // Booking; tracking/payment are independently authorized endpoints.
        if (loadRequest == _vehicleLoadRevision) {
          emit(state.copy(loading: false, error: _message(error)));
          _vehicleLoadErrorOwner = state._errorWrite;
        }
      }
      if (!await _current(revision)) return;
      final saved = await _acceptedStore.read(userPublicId);
      if (saved == null || !await _current(revision)) return;
      if (saved.pendingAcceptance) {
        _stopForeground();
        emit(state.copy(
            driverPublicId: saved.driverPublicId,
            offer: saved.offer,
            unresolvedDecision: true,
            notice:
                'Đang đối chiếu quyết định nhận chuyến đã lưu với máy chủ.'));
        await reconcile();
        return;
      }
      final tracking =
          await _useCases.tracking(saved.offer.bookingPublicId, _sessionId);
      if (!await _current(revision)) return;
      if (tracking.bookingPublicId == saved.offer.bookingPublicId &&
          tracking.driverPublicId == saved.driverPublicId &&
          const {
            'DRIVER_ACCEPTED',
            'DRIVER_ARRIVED',
            'PASSENGER_ONBOARD',
            'IN_PROGRESS',
            'COMPLETED'
          }.contains(tracking.status)) {
        String? paymentNotice;
        if (tracking.status == 'COMPLETED' && _tripRepository != null) {
          // Completion does not settle cash or release the Driver. Recheck the
          // authorized payment before restoring the handoff.
          try {
            final payment = await _tripRepository.payment(
                saved.offer.bookingPublicId, _sessionId);
            if (!await _current(revision)) return;
            if (payment.method != 'CASH' ||
                !const {'PENDING', 'PAID'}.contains(payment.status)) {
              throw const FormatException('Trạng thái thanh toán không hợp lệ');
            }
            paymentNotice = payment.status == 'PAID'
                ? 'Máy chủ báo PAID; mở chuyến để lấy lại biên nhận giải phóng.'
                : 'Chuyến đã hoàn thành; tiền mặt vẫn đang chờ xác nhận.';
          } catch (error) {
            if (!await _current(revision)) return;
            paymentNotice =
                'Đã xác minh chuyến nhưng chưa đọc được thanh toán. '
                'Mở chuyến và cập nhật lại trước khi thao tác.';
          }
        }
        emit(state.copy(
            driverPublicId: saved.driverPublicId,
            operatingStatus: 'BUSY',
            acceptedOffer: saved.offer,
            completedAwaitingSettlement: tracking.status == 'COMPLETED',
            notice: tracking.status == 'COMPLETED'
                ? paymentNotice ??
                    'Chuyến đã hoàn thành; cần xác minh thanh toán.'
                : 'Đã xác minh chuyến đang được giao từ máy chủ.'));
        if (state.foreground && tracking.status != 'COMPLETED') {
          _startBusyLocation();
          await _uploadLocation(revision);
        }
      } else if (tracking.bookingPublicId == saved.offer.bookingPublicId &&
          tracking.driverPublicId == saved.driverPublicId &&
          tracking.status == 'CANCELLED') {
        await _acceptedStore.clear(userPublicId);
        if (!await _current(revision)) return;
        emit(state.copy(
            notice: 'Máy chủ xác nhận chuyến đã lưu bị hủy. '
                'Bật trực tuyến lại để nhận đề nghị mới.'));
      } else {
        emit(state.copy(
            notice:
                'Không thể xác minh chuyến đã lưu. Kiểm tra lại với máy chủ.'));
      }
    } catch (error) {
      if (await _current(revision)) {
        emit(state.copy(loading: false, error: _message(error)));
      }
    }
  }

  Future<void> reloadVehicles() async {
    final revision = _revision;
    final request = ++_vehicleLoadRevision;
    final errorOwner = _vehicleLoadErrorOwner;
    final errorAtStart = state._errorWrite;
    if (_generation == null || !await _current(revision)) return;
    try {
      final vehicles = await _useCases.vehicles(_sessionId);
      if (await _current(revision) && request == _vehicleLoadRevision) {
        emit(state.copy(
            vehicles: vehicles,
            loading: false,
            error: _clearError(errorOwner)));
      }
    } catch (error) {
      if (await _current(revision) && request == _vehicleLoadRevision) {
        final writesError = identical(state._errorWrite, errorAtStart);
        emit(state.copy(
            loading: false,
            error: writesError ? _message(error) : DriverState._unchanged));
        if (writesError) _vehicleLoadErrorOwner = state._errorWrite;
      }
    }
  }

  Future<void> addVehicle(VehicleDraft draft) async {
    if (state.actionBusy || _generation == null) return;
    final revision = _revision;
    final errorOwner = _vehicleActionErrorOwner;
    final errorAtStart = state._errorWrite;
    final action = Completer<void>();
    _vehicleAction = action;
    emit(state.copy(actionBusy: true));
    try {
      await _useCases.addVehicle(draft, _sessionId);
      if (!await _current(revision)) return;
      final vehicles = await _useCases.vehicles(_sessionId);
      if (await _current(revision)) {
        emit(state.copy(
            vehicles: vehicles,
            actionBusy: false,
            error: _clearError(errorOwner),
            notice: 'Đã thêm xe. Hãy kích hoạt xe trước khi trực tuyến.'));
      }
    } catch (error) {
      if (await _current(revision)) {
        final writesError = identical(state._errorWrite, errorAtStart);
        emit(state.copy(
            actionBusy: false,
            error: writesError ? _message(error) : DriverState._unchanged));
        if (writesError) _vehicleActionErrorOwner = state._errorWrite;
      }
    } finally {
      if (identical(_vehicleAction, action)) _vehicleAction = null;
      action.complete();
    }
  }

  Future<void> activateVehicle(String publicId) async {
    if (state.actionBusy || _generation == null) return;
    final revision = _revision;
    final errorOwner = _vehicleActionErrorOwner;
    final errorAtStart = state._errorWrite;
    final action = Completer<void>();
    _vehicleAction = action;
    emit(state.copy(actionBusy: true));
    try {
      await _useCases.activateVehicle(publicId, _sessionId);
      if (!await _current(revision)) return;
      final vehicles = await _useCases.vehicles(_sessionId);
      if (await _current(revision)) {
        emit(state.copy(
            vehicles: vehicles,
            actionBusy: false,
            error: _clearError(errorOwner),
            notice: 'Xe đã được kích hoạt.'));
      }
    } catch (error) {
      if (await _current(revision)) {
        final writesError = identical(state._errorWrite, errorAtStart);
        emit(state.copy(
            actionBusy: false,
            error: writesError ? _message(error) : DriverState._unchanged));
        if (writesError) _vehicleActionErrorOwner = state._errorWrite;
      }
    } finally {
      if (identical(_vehicleAction, action)) _vehicleAction = null;
      action.complete();
    }
  }

  Future<void> goOnline() async {
    await _changeStatus('ONLINE');
  }

  Future<void> goOffline() async {
    await _changeStatus('OFFLINE');
  }

  Future<bool> _changeStatus(String target, {bool revalidate = false}) async {
    if (state.actionBusy ||
        state.offerActionBusy ||
        state.unresolvedDecision ||
        _generation == null ||
        isMock ||
        state.operatingStatus == 'BUSY' ||
        (target == 'OFFLINE' &&
            !revalidate &&
            state.operatingStatus != 'ONLINE')) {
      return false;
    }
    final revision = _revision;
    final request = ++_statusRevision;
    final errorAtStart = state._errorWrite;
    final errorOwner = _statusErrorOwner;
    final noticeAtStart = state._noticeWrite;
    final offlineNotice = _offlineNoticeOwner;
    final pauseNotice = _pauseNoticeOwner;
    _pendingStatus = target;
    if (target == 'OFFLINE') _stopForeground();
    final activity = _activityRevision;
    emit(state.copy(actionBusy: true));
    try {
      final profile = await _useCases.setStatus(target, _sessionId);
      if (!await _current(revision) ||
          request != _statusRevision ||
          activity != _activityRevision) {
        return false;
      }
      _pendingStatus = null;
      Object? notice = DriverState._unchanged;
      var writesOfflineNotice = false;
      if (profile.operatingStatus == 'ONLINE' &&
          ((offlineNotice != null &&
                  identical(state._noticeWrite, offlineNotice)) ||
              (pauseNotice != null &&
                  identical(state._noticeWrite, pauseNotice)))) {
        notice = null;
      } else if (target == 'OFFLINE' &&
          profile.operatingStatus == 'OFFLINE' &&
          identical(state._noticeWrite, noticeAtStart)) {
        notice = _offlineNotice;
        writesOfflineNotice = true;
      }
      if (target == 'OFFLINE' && profile.operatingStatus == 'OFFLINE') {
        _locationFailure = null;
      }
      emit(state.copy(
          operatingStatus: profile.operatingStatus,
          approvalStatus: target == 'ONLINE'
              ? profile.approvalStatus
              : state.approvalStatus,
          driverPublicId:
              target == 'ONLINE' ? profile.publicId : state.driverPublicId,
          actionBusy: false,
          error: profile.operatingStatus == target
              ? _clearError(errorOwner)
              : DriverState._unchanged,
          notice: notice,
          offer: target == 'OFFLINE' ? null : DriverState._unchanged,
          lastLocationUpload:
              target == 'OFFLINE' ? null : DriverState._unchanged,
          unresolvedDecision:
              target == 'OFFLINE' ? false : state.unresolvedDecision,
          locationMessage:
              target == 'OFFLINE' && profile.operatingStatus == 'OFFLINE'
                  ? _offlineGps
                  : profile.operatingStatus == 'ONLINE' &&
                          state.locationMessage == _offlineGps
                      ? 'Chưa gửi GPS'
                      : state.locationMessage));
      if (profile.operatingStatus == target) _statusErrorOwner = null;
      _resumeStatus = null;
      if (writesOfflineNotice) _offlineNoticeOwner = state._noticeWrite;
      if (profile.operatingStatus == 'ONLINE' && state.foreground) {
        _startForeground();
        await _uploadLocation(revision);
      }
      return profile.operatingStatus == target;
    } catch (error) {
      if (await _current(revision) &&
          request == _statusRevision &&
          activity == _activityRevision) {
        final writesError = identical(state._errorWrite, errorAtStart) &&
            (state.error == null || identical(errorAtStart, errorOwner));
        emit(state.copy(
            actionBusy: false,
            error: writesError ? _message(error) : DriverState._unchanged));
        if (writesError) _statusErrorOwner = state._errorWrite;
        if (target == 'OFFLINE' &&
            state.operatingStatus == 'ONLINE' &&
            state.foreground) {
          _startForeground();
        }
      }
      return false;
    } finally {
      if (request == _statusRevision) {
        _pendingStatus = null;
        if (state.actionBusy &&
            await _current(revision) &&
            request == _statusRevision) {
          emit(state.copy(actionBusy: false));
        }
      }
    }
  }

  void _startForeground() {
    _stopForeground();
    _locationTimer =
        Timer.periodic(heartbeatInterval, (_) => _uploadLocation(_revision));
    _pollTimer = Timer.periodic(pollInterval, (_) => pollOnce());
  }

  void _startBusyLocation() {
    _stopForeground();
    if (_tripChannelActive || state.completedAwaitingSettlement) return;
    _locationTimer =
        Timer.periodic(heartbeatInterval, (_) => _uploadLocation(_revision));
  }

  /// The trip screen publishes ride GPS when connected. Keep the M2 profile
  /// heartbeat only as a disconnected/closed-screen fallback.
  void setTripChannelActive(bool active) {
    if (_tripChannelActive == active || isClosed) return;
    _tripChannelActive = active;
    if (kDebugMode) {
      debugPrint('GoMoveGPS source=channel-handoff '
          'tripConnected=$active operating=${state.operatingStatus} '
          'foreground=${state.foreground}');
    }
    if (state.operatingStatus != 'BUSY' ||
        !state.foreground ||
        state.completedAwaitingSettlement) {
      return;
    }
    if (active) {
      _stopForeground();
      unawaited(_startActiveResumeCheck());
    } else {
      _startBusyLocation();
    }
  }

  void markTripCompleted(String bookingPublicId) {
    if (state.acceptedOffer?.bookingPublicId != bookingPublicId || isClosed) {
      return;
    }
    _stopForeground();
    emit(state.copy(completedAwaitingSettlement: true));
  }

  /// Called only after a durable PAID receipt with server release timestamp.
  Future<void> finishSettledBooking(CashReceipt receipt) async {
    if (receipt.paymentStatus != 'PAID' || receipt.paymentMethod != 'CASH') {
      return;
    }
    final bookingPublicId = receipt.bookingPublicId;
    final revision = _revision;
    if (state.acceptedOffer?.bookingPublicId != bookingPublicId ||
        _generation == null ||
        !await _current(revision)) {
      return;
    }
    var localStoreWarning = false;
    try {
      final saved = await _acceptedStore.read(userPublicId);
      if (!await _current(revision)) return;
      // Never clear a newer or different account-scoped handoff.
      if (saved != null && saved.offer.bookingPublicId != bookingPublicId) {
        return;
      }
      if (saved == null) {
        localStoreWarning = true;
      } else {
        await _acceptedStore.clear(userPublicId);
      }
    } catch (_) {
      // The Backend receipt still proves release. Keep this session aligned
      // with the server, but report that restart recovery may need attention.
      localStoreWarning = true;
    }
    if (!await _current(revision)) return;
    _tripChannelActive = false;
    _stopForeground();
    emit(state.copy(
        acceptedOffer: null,
        operatingStatus: 'ONLINE',
        completedAwaitingSettlement: false,
        notice: localStoreWarning
            ? 'Máy chủ đã giải phóng tài xế, nhưng chưa cập nhật được '
                'bàn giao lưu trên thiết bị. Kiểm tra lại khi mở ứng dụng.'
            : 'Máy chủ đã xác nhận PAID và giải phóng tài xế.'));
    if (state.foreground) {
      _startForeground();
      await _uploadLocation(revision);
    }
  }

  /// Called only after authorized REST tracking confirms terminal cancellation.
  Future<void> finishCancelledBooking(String bookingPublicId) async {
    final revision = _revision;
    if (state.acceptedOffer?.bookingPublicId != bookingPublicId ||
        _generation == null ||
        !await _current(revision)) {
      return;
    }
    var localStoreWarning = false;
    try {
      final saved = await _acceptedStore.read(userPublicId);
      if (!await _current(revision)) return;
      if (saved != null && saved.offer.bookingPublicId != bookingPublicId) {
        return;
      }
      if (saved == null) {
        localStoreWarning = true;
      } else {
        await _acceptedStore.clear(userPublicId);
      }
    } catch (_) {
      localStoreWarning = true;
    }
    if (!await _current(revision)) return;
    _tripChannelActive = false;
    _stopForeground();
    emit(state.copy(
        acceptedOffer: null,
        operatingStatus: null,
        completedAwaitingSettlement: false,
        notice: localStoreWarning
            ? 'Máy chủ đã hủy chuyến, nhưng chưa cập nhật được bàn giao lưu trên thiết bị.'
            : 'Máy chủ đã xác nhận hủy chuyến. Đang kiểm tra trạng thái nhận cuốc.'));
    if (state.foreground) {
      // The former approval value may be unknown after a restart or stale after
      // an admin change. The existing idempotent endpoint returns server truth.
      await goOnline();
      if (!await _current(revision)) return;
      emit(state.copy(
          notice: localStoreWarning
              ? 'Chuyến đã hủy; chưa cập nhật được bàn giao lưu trên thiết bị.'
              : state.operatingStatus == 'ONLINE'
                  ? 'Máy chủ đã hủy chuyến; tài xế đã trực tuyến trở lại.'
                  : 'Máy chủ đã hủy chuyến. Bật trực tuyến lại khi có kết nối.'));
    }
  }

  void _stopForeground() {
    _stopActiveResumeCheck();
    _activityRevision++;
    _pollTimer?.cancel();
    _locationTimer?.cancel();
    _pollTimer = null;
    _locationTimer = null;
  }

  bool get _needsActiveResumeCheck =>
      !isClosed &&
      state.foreground &&
      state.operatingStatus == 'BUSY' &&
      _tripChannelActive &&
      !state.completedAwaitingSettlement &&
      state.acceptedOffer != null &&
      state.driverPublicId != null &&
      _pauseNoticeOwner != null &&
      identical(state._noticeWrite, _pauseNoticeOwner);

  void _stopActiveResumeCheck([Object? run]) {
    if (run != null && !identical(run, _activeResumeRun)) return;
    _activeResumeTimer?.cancel();
    _activeResumeTimer = null;
    _activeResumeRun = null;
  }

  Future<void> _startActiveResumeCheck() async {
    _stopActiveResumeCheck();
    if (!_needsActiveResumeCheck || _tripRepository == null) return;
    final run = Object();
    _activeResumeRun = run;
    // Only while an owned pause notice awaits recovery. Never publish a
    // second GPS stream; one REST read at a time checks server-confirmed GPS.
    _activeResumeTimer = Timer.periodic(
        heartbeatInterval, (_) => unawaited(_checkActiveResume(run)));
    await _checkActiveResume(run);
  }

  Future<void> _checkActiveResume(Object run) async {
    if (!identical(run, _activeResumeRun) || _checkingActiveResume) return;
    if (!_needsActiveResumeCheck) {
      _stopActiveResumeCheck(run);
      return;
    }
    final revision = _revision;
    final attempt = _resumeRevision;
    final activity = _activityRevision;
    final booking = state.acceptedOffer!.bookingPublicId;
    final driver = state.driverPublicId;
    final notice = _pauseNoticeOwner;
    _checkingActiveResume = true;
    try {
      if (!await _current(revision)) {
        _stopActiveResumeCheck(run);
        return;
      }
      if (!identical(run, _activeResumeRun) || !_needsActiveResumeCheck) return;
      final tracking = await _tripRepository!.tracking(booking, _sessionId);
      if (!await _current(revision)) {
        _stopActiveResumeCheck(run);
        return;
      }
      if (!identical(run, _activeResumeRun) ||
          attempt != _resumeRevision ||
          activity != _activityRevision ||
          !_needsActiveResumeCheck ||
          state.acceptedOffer?.bookingPublicId != booking ||
          state.driverPublicId != driver) {
        return;
      }
      final latitude = tracking.latitude;
      final longitude = tracking.longitude;
      final sampled = tracking.locationUpdatedAt;
      final age =
          sampled == null ? null : _now().toUtc().difference(sampled.toUtc());
      if (tracking.bookingPublicId == booking &&
          tracking.driverPublicId == driver &&
          tracking.allowsLiveLocation &&
          latitude != null &&
          latitude.isFinite &&
          latitude >= -90 &&
          latitude <= 90 &&
          longitude != null &&
          longitude.isFinite &&
          longitude >= -180 &&
          longitude <= 180 &&
          sampled != null &&
          sampled.millisecondsSinceEpoch > 0 &&
          !age!.isNegative &&
          age < locationFreshness) {
        emit(state.copy(notice: _clearNotice(notice)));
        _stopActiveResumeCheck(run);
      }
    } catch (error) {
      // Failed reconciliation never turns a connected socket into GPS proof.
      if (_authError(error) ||
          error is ServerException && error.statusCode == 404) {
        _stopActiveResumeCheck(run);
      }
    } finally {
      _checkingActiveResume = false;
    }
  }

  Future<void> _uploadLocation(int revision) async {
    final activityRevision = _activityRevision;
    final pauseNotice = _pauseNoticeOwner;
    if (_uploading ||
        !state.foreground ||
        state.completedAwaitingSettlement ||
        !const {'ONLINE', 'BUSY'}.contains(state.operatingStatus) ||
        !await _current(revision)) {
      return;
    }
    _uploading = true;
    var uploadStarted = false;
    try {
      final point = await _location.current();
      if (!await _current(revision) ||
          !state.foreground ||
          activityRevision != _activityRevision) {
        return;
      }
      final sampledAt = point.sampledAt?.toUtc();
      final age =
          sampledAt == null ? null : _now().toUtc().difference(sampledAt);
      final rejection = sampledAt == null
          ? 'missing_sample_time'
          : age!.isNegative
              ? 'future_sample'
              : age > locationFreshness
                  ? 'expired_sample'
                  : _lastUploadedSampleAt != null &&
                          !sampledAt.isAfter(_lastUploadedSampleAt!)
                      ? 'duplicate_or_older_sample'
                      : null;
      if (rejection != null) {
        if (kDebugMode) {
          debugPrint('GoMoveGPS source=profile-REST result=skipped '
              'reason=$rejection '
              'ageMs=${age?.inMilliseconds} '
              'operating=${state.operatingStatus} tripChannel=$_tripChannelActive');
        }
        if (!_hasFreshLocationUpload && _locationFailure == null) {
          emit(state.copy(
              offer: null,
              locationMessage: state.lastLocationUpload != null ||
                      rejection == 'expired_sample'
                  ? _staleGps
                  : rejection == 'future_sample'
                      ? 'Thời gian mẫu GPS không hợp lệ; đang chờ vị trí mới.'
                      : 'GPS chưa có mẫu vị trí mới; đang chờ cập nhật.'));
        }
        if (state.operatingStatus == 'ONLINE') await pollOnce();
        return;
      }
      uploadStarted = true;
      await _useCases.uploadLocation(point, _sessionId);
      if (!await _current(revision) || activityRevision != _activityRevision) {
        return;
      }
      _lastUploadedSampleAt = sampledAt;
      _locationFailure = null;
      if (kDebugMode) {
        debugPrint('GoMoveGPS source=profile-REST result=sent '
            'ageMs=${age!.inMilliseconds} '
            'operating=${state.operatingStatus} tripChannel=$_tripChannelActive');
      }
      emit(state.copy(
          lastLocationUpload: _now(),
          locationProblem: null,
          notice: _clearNotice(pauseNotice),
          locationMessage: point.approximate
              ? 'Đã gửi GPS gần đúng; có thể giảm khả năng nhận chuyến.'
              : 'GPS mới đã gửi đến máy chủ.'));
      if (state.operatingStatus == 'ONLINE') await pollOnce();
    } on DriverLocationException catch (error) {
      if (kDebugMode) {
        debugPrint('GoMoveGPS source=profile-REST result=skipped '
            'reason=location_${error.problem.name}');
      }
      if (await _current(revision) &&
          state.foreground &&
          activityRevision == _activityRevision) {
        _locationFailure = _locationMessage(error.problem);
        emit(state.copy(
            locationProblem: error.problem,
            locationMessage: _locationFailure,
            lastLocationUpload: null,
            offer: null));
      }
    } catch (error) {
      if (kDebugMode) {
        debugPrint('GoMoveGPS source=profile-REST result=failed '
            'errorType=${error.runtimeType}');
      }
      if (await _current(revision) &&
          state.foreground &&
          activityRevision == _activityRevision) {
        _locationFailure = uploadStarted
            ? 'Chưa gửi được GPS đến máy chủ. ${_message(error)}'
            : error is TimeoutException
                ? 'Chưa nhận được mẫu GPS từ thiết bị. Đang chờ cập nhật.'
                : 'Không lấy được GPS từ thiết bị. ${_message(error)}';
        emit(state.copy(
            locationMessage: _locationFailure,
            lastLocationUpload: null,
            offer: null));
        if (_authError(error)) _stopForeground();
      }
    } finally {
      _uploading = false;
    }
  }

  bool get _hasFreshLocationUpload {
    final uploaded = state.lastLocationUpload;
    if (uploaded == null) return false;
    // Preserve the existing eligibility deadline from the last confirmed PUT.
    final age = _now().toUtc().difference(uploaded.toUtc());
    return !age.isNegative && age < locationFreshness;
  }

  Future<void> pollOnce() async {
    final revision = _revision;
    final offerRevision = _offerRevision;
    final activityRevision = _activityRevision;
    final errorOwner = _pollErrorOwner;
    final errorAtStart = state._errorWrite;
    if (_polling ||
        _generation == null ||
        !state.foreground ||
        state.operatingStatus != 'ONLINE' ||
        state.unresolvedDecision ||
        state.offerActionBusy ||
        !await _current(revision)) {
      return;
    }
    if (!_hasFreshLocationUpload) {
      emit(state.copy(
          offer: null,
          locationMessage: state.lastLocationUpload == null
              ? state.locationMessage
              : _staleGps));
      return;
    }
    _polling = true;
    try {
      final offers = await _useCases.activeOffers(_sessionId);
      if (!await _current(revision) ||
          !state.foreground ||
          state.operatingStatus != 'ONLINE' ||
          activityRevision != _activityRevision ||
          offerRevision != _offerRevision ||
          state.unresolvedDecision ||
          state.offerActionBusy) {
        return;
      }
      final fresh = offers.where((offer) => _now().isBefore(offer.expiresAt));
      emit(state.copy(
          offer: fresh.isEmpty ? null : fresh.first,
          error: _clearError(errorOwner),
          notice: fresh.isEmpty && state.offer != null
              ? 'Đề nghị không còn khả dụng hoặc đã hết hạn.'
              : DriverState._unchanged));
      _pollErrorOwner = null;
    } catch (error) {
      if (await _current(revision) &&
          state.foreground &&
          state.operatingStatus == 'ONLINE' &&
          activityRevision == _activityRevision &&
          offerRevision == _offerRevision) {
        final writesError = identical(state._errorWrite, errorAtStart);
        emit(state.copy(
            error: writesError ? _message(error) : DriverState._unchanged,
            offer: _authError(error) ? null : state.offer));
        if (writesError) _pollErrorOwner = state._errorWrite;
        if (_authError(error)) _stopForeground();
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> decide(bool accept) async {
    final offer = state.offer;
    if (offer == null ||
        state.offerActionBusy ||
        state.actionBusy ||
        state.unresolvedDecision ||
        _generation == null ||
        !_now().isBefore(offer.expiresAt)) {
      return;
    }
    final revision = _revision;
    _offerRevision++;
    emit(state.copy(
        offerActionBusy: true, error: _clearError(_bookingErrorOwner)));
    if (accept) {
      final driverId = state.driverPublicId;
      if (driverId == null || !await _current(revision)) {
        if (await _current(revision)) {
          _emitBookingError(state.copy(
              offerActionBusy: false, error: 'Chưa xác minh ID tài xế.'));
        }
        return;
      }
      _stopForeground();
      try {
        // One account-scoped key is written before HTTP and later promoted in
        // place. A lost response or process death leaves a recoverable hint.
        await _acceptedStore.write(userPublicId,
            AcceptedBookingRecord(driverId, offer, pendingAcceptance: true));
      } catch (_) {
        if (await _current(revision)) {
          _emitBookingError(state.copy(
              offerActionBusy: false,
              error: 'Không lưu được ý định nhận chuyến; chưa gửi yêu cầu.'));
          if (state.foreground && state.operatingStatus == 'ONLINE') {
            _startForeground();
          }
        }
        return;
      }
      if (!await _current(revision)) return;
      if (!_now().isBefore(offer.expiresAt)) {
        // This process knows no request was sent. A restarted process cannot
        // infer that from the clock or a masked tracking 404.
        await _resolveIntent(
            offer, revision, 'Đề nghị đã hết hạn trước khi gửi.');
        return;
      }
    }
    try {
      final decision = accept
          ? await _useCases.accept(offer.offerPublicId, _sessionId)
          : await _useCases.reject(offer.offerPublicId, _sessionId);
      if (!await _current(revision)) return;
      if (decision.offerPublicId != offer.offerPublicId ||
          decision.status != (accept ? 'ACCEPTED' : 'REJECTED')) {
        throw const FormatException('Phản hồi quyết định không khớp đề nghị');
      }
      if (accept) {
        await _confirmAccepted(offer, revision);
      } else {
        emit(state.copy(
            offer: null,
            offerActionBusy: false,
            notice: 'Đã từ chối đề nghị.'));
        await pollOnce();
      }
    } catch (error) {
      if (!await _current(revision)) return;
      if (accept) {
        _emitBookingError(state.copy(
            offerActionBusy: false,
            unresolvedDecision: true,
            error:
                'Chưa xác minh kết quả nhận chuyến. Không gửi lại quyết định.'));
        if (_authError(error)) {
          _stopForeground();
        } else {
          await _reconcile(
              rejected: error is ServerException && error.statusCode == 409);
        }
      } else if (error is ServerException && error.statusCode == 409) {
        emit(state.copy(
            offer: null,
            offerActionBusy: false,
            notice: 'Đề nghị đã hết hạn hoặc không còn khả dụng.'));
        await pollOnce();
      } else if (error is NetworkException ||
          error is ServerException && error.statusCode == 503) {
        _emitBookingError(state.copy(
            offerActionBusy: false,
            unresolvedDecision: true,
            error:
                'Chưa xác định kết quả do lỗi mạng/máy chủ. Không gửi lại quyết định.'));
        await reconcile();
      } else {
        _emitBookingError(
            state.copy(offerActionBusy: false, error: _message(error)));
        if (_authError(error)) _stopForeground();
      }
    }
  }

  Future<void> _confirmAccepted(DriverOffer offer, int revision,
      {bool completed = false}) async {
    final driverId = state.driverPublicId;
    if (driverId == null) {
      _emitBookingError(state.copy(
          offerActionBusy: false,
          unresolvedDecision: true,
          error:
              'Máy chủ đã nhận đề nghị nhưng thiếu ID tài xế để lưu bàn giao.'));
      return;
    }
    _stopForeground();
    emit(state.copy(
        offer: null,
        acceptedOffer: offer,
        operatingStatus: 'BUSY',
        completedAwaitingSettlement: completed,
        offerActionBusy: false,
        unresolvedDecision: false,
        notice: 'Máy chủ đã xác nhận nhận chuyến.'));
    if (state.foreground && !completed) _startBusyLocation();
    try {
      await _acceptedStore.write(
          userPublicId, AcceptedBookingRecord(driverId, offer));
      if (!await _current(revision)) return;
    } catch (_) {
      if (await _current(revision)) {
        _emitBookingError(state.copy(
            error: 'Đã nhận chuyến nhưng không lưu được thông tin '
                'bàn giao trên thiết bị. Ghi lại Booking UUID trước khi thoát.'));
      }
    }
  }

  Future<void> reconcile() => _reconcile();

  Future<void> _reconcile({bool rejected = false}) async {
    if (_generation == null || _reconciling) return;
    final revision = _revision;
    _reconciling = true;
    DriverOffer? offer;
    try {
      final saved = await _acceptedStore.read(userPublicId);
      if (!await _current(revision)) return;
      offer = state.offer ?? saved?.offer;
      if (offer == null) return;
      final driverId = saved?.driverPublicId ?? state.driverPublicId;
      if (driverId == null ||
          saved != null &&
              (saved.offer.offerPublicId != offer.offerPublicId ||
                  saved.offer.bookingPublicId != offer.bookingPublicId)) {
        throw const FormatException(
            'Bàn giao không khớp quyết định đang kiểm tra');
      }
      final tracking =
          await _useCases.tracking(offer.bookingPublicId, _sessionId);
      if (!await _current(revision)) return;
      if (tracking.bookingPublicId == offer.bookingPublicId &&
          tracking.driverPublicId != null &&
          tracking.driverPublicId == driverId &&
          const {
            'DRIVER_ACCEPTED',
            'DRIVER_ARRIVED',
            'PASSENGER_ONBOARD',
            'IN_PROGRESS',
            'COMPLETED'
          }.contains(tracking.status)) {
        emit(state.copy(driverPublicId: driverId));
        await _confirmAccepted(offer, revision,
            completed: tracking.status == 'COMPLETED');
        return;
      }
      if (tracking.bookingPublicId == offer.bookingPublicId &&
          tracking.driverPublicId == driverId &&
          tracking.status == 'CANCELLED') {
        await _resolveIntent(
            offer, revision, 'Máy chủ xác nhận chuyến đã bị hủy.');
        return;
      }
      if (rejected && tracking.bookingPublicId == offer.bookingPublicId) {
        await _resolveIntent(
            offer, revision, 'Đề nghị đã hết hạn hoặc không còn khả dụng.');
        return;
      }
      // A missing active offer alone cannot prove whether a decision committed.
      if (await _current(revision)) {
        _emitBookingError(state.copy(
            error:
                'Chưa xác minh được kết quả. Kiểm tra lại sau; không gửi lại quyết định.'));
      }
    } catch (error) {
      if (rejected &&
          offer != null &&
          error is ServerException &&
          error.statusCode == 404 &&
          await _current(revision)) {
        await _resolveIntent(
            offer, revision, 'Đề nghị đã hết hạn hoặc không còn khả dụng.');
        return;
      }
      if (await _current(revision)) {
        _emitBookingError(state.copy(
            error: 'Không thể xác minh kết quả. Không gửi lại quyết định.'));
        if (_authError(error)) _stopForeground();
      }
    } finally {
      _reconciling = false;
    }
  }

  Future<void> _resolveIntent(
      DriverOffer offer, int revision, String notice) async {
    final errorOwner = _bookingErrorOwner;
    try {
      final saved = await _acceptedStore.read(userPublicId);
      if (!await _current(revision)) return;
      if (saved != null &&
          (saved.offer.offerPublicId != offer.offerPublicId ||
              saved.offer.bookingPublicId != offer.bookingPublicId)) {
        return;
      }
      await _acceptedStore.clear(userPublicId);
      if (!await _current(revision)) return;
      emit(state.copy(
          offer: null,
          offerActionBusy: false,
          unresolvedDecision: false,
          error: _clearError(errorOwner),
          notice: notice));
      if (state.foreground && state.operatingStatus == 'ONLINE') {
        _startForeground();
        await pollOnce();
      }
    } catch (_) {
      if (await _current(revision)) {
        _stopForeground();
        _emitBookingError(state.copy(
            offerActionBusy: false,
            unresolvedDecision: true,
            error:
                'Chưa cập nhật được bàn giao trên thiết bị. Kiểm tra lại kết quả.'));
      }
    }
  }

  void pause() {
    final pending = _pendingStatus;
    _resumeStatus = pending ?? state.operatingStatus ?? _resumeStatus;
    _pendingStatus = null;
    _statusRevision++;
    _resumeRevision++;
    _stopForeground();
    if (!isClosed) {
      emit(state.copy(
          foreground: false,
          actionBusy: pending == null ? state.actionBusy : false,
          operatingStatus: pending == null ? DriverState._unchanged : null,
          offer: state.unresolvedDecision || state.offerActionBusy
              ? state.offer
              : null,
          notice:
              'Ứng dụng tạm dừng: GPS có thể hết hạn, không nhận đề nghị mới.'));
      _pauseNoticeOwner = state._noticeWrite;
    }
  }

  Future<void> resume() async {
    if (isClosed) return;
    final revision = _revision;
    final attempt = ++_resumeRevision;
    if (!await _current(revision) || attempt != _resumeRevision) return;
    final target = _resumeStatus ?? state.operatingStatus;
    emit(state.copy(
        foreground: true,
        operatingStatus: target == 'ONLINE' || target == 'OFFLINE'
            ? null
            : DriverState._unchanged));
    while (_vehicleAction != null) {
      await _vehicleAction!.future;
      if (!await _current(revision) ||
          attempt != _resumeRevision ||
          !state.foreground) {
        return;
      }
    }
    if (state.unresolvedDecision) {
      await reconcile();
    } else if (target == 'ONLINE' || target == 'OFFLINE') {
      await _changeStatus(target!, revalidate: true);
      if (await _current(revision) &&
          attempt == _resumeRevision &&
          state.unresolvedDecision) {
        await reconcile();
      }
    } else if (target == 'BUSY') {
      _resumeStatus = null;
      if (_tripChannelActive) {
        await _startActiveResumeCheck();
      } else {
        _startBusyLocation();
        await _uploadLocation(revision);
      }
    }
  }

  Future<void> openLocationSettings() =>
      _location.openSettings(state.locationProblem);

  @override
  Future<void> close() async {
    _revision++;
    _statusRevision++;
    _resumeRevision++;
    _stopForeground();
    await super.close();
  }

  bool _authError(Object error) =>
      error is UnauthorizedException ||
      error is ServerException &&
          (error.statusCode == 401 || error.statusCode == 403);

  String _locationMessage(DriverLocationProblem problem) => switch (problem) {
        DriverLocationProblem.disabled =>
          'Dịch vụ vị trí đang tắt. Hãy bật GPS.',
        DriverLocationProblem.denied =>
          'Chưa cấp quyền vị trí. Hãy cho phép để nhận cuốc.',
        DriverLocationProblem.deniedForever =>
          'Quyền vị trí bị từ chối vĩnh viễn. Mở Cài đặt để cấp quyền.',
      };

  String _message(Object error) {
    if (error is ServerException) {
      return switch (error.errorCode) {
        'DRIVER_NOT_APPROVED' => 'Tài xế chưa được Admin phê duyệt.',
        'ACTIVE_VEHICLE_REQUIRED' =>
          'Cần kích hoạt một xe trước khi trực tuyến.',
        'DRIVER_HAS_UNRELEASED_BOOKING' =>
          'Đang có chuyến chưa kết thúc; không thể đổi trạng thái.',
        _ => error.message,
      };
    }
    if (error is NetworkException) return error.message;
    if (error is DriverLocationException) {
      return _locationMessage(error.problem);
    }
    if (error is FormatException) return error.message;
    return 'Không thể hoàn tất thao tác. Vui lòng thử lại.';
  }
}
