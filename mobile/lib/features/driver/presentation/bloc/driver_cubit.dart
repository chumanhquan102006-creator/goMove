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
      this.completedAwaitingSettlement = false});

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
          bool? completedAwaitingSettlement}) =>
      DriverState(
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
          notice:
              identical(notice, _unchanged) ? this.notice : notice as String?,
          unresolvedDecision: unresolvedDecision ?? this.unresolvedDecision,
          completedAwaitingSettlement:
              completedAwaitingSettlement ?? this.completedAwaitingSettlement);
}

class DriverCubit extends Cubit<DriverState> {
  static const offerPollInterval = Duration(seconds: 2);
  static const locationHeartbeatInterval = Duration(seconds: 9);
  static const locationFreshness = Duration(seconds: 30);

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

  Future<void> initialize() async {
    if (isMock) {
      emit(state.copy(
          notice:
              'Chế độ mock không gọi API tài xế. Hãy chạy MOCK_ENABLED=false.'));
      return;
    }
    final revision = ++_revision;
    _generation = (await _session.getSession()).generation;
    emit(state.copy(loading: true, error: null));
    try {
      try {
        final vehicles = await _useCases.vehicles(_sessionId);
        if (!await _current(revision)) return;
        emit(state.copy(vehicles: vehicles, loading: false));
      } catch (error) {
        if (!await _current(revision)) return;
        // Vehicle listing is not a prerequisite for recovering an accepted
        // Booking; tracking/payment are independently authorized endpoints.
        emit(state.copy(loading: false, error: _message(error)));
      }
      if (!await _current(revision)) return;
      final saved = await _acceptedStore.read(userPublicId);
      if (saved == null || !await _current(revision)) return;
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
      } else if (tracking.status == 'CANCELLED') {
        await _acceptedStore.clear(userPublicId);
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
    if (_generation == null || !await _current(revision)) return;
    try {
      final vehicles = await _useCases.vehicles(_sessionId);
      if (await _current(revision)) {
        emit(state.copy(vehicles: vehicles, error: null));
      }
    } catch (error) {
      if (await _current(revision)) {
        emit(state.copy(error: _message(error)));
      }
    }
  }

  Future<void> addVehicle(VehicleDraft draft) async {
    if (state.actionBusy || _generation == null) return;
    final revision = _revision;
    emit(state.copy(actionBusy: true, error: null));
    try {
      await _useCases.addVehicle(draft, _sessionId);
      if (!await _current(revision)) return;
      final vehicles = await _useCases.vehicles(_sessionId);
      if (await _current(revision)) {
        emit(state.copy(
            vehicles: vehicles,
            actionBusy: false,
            notice: 'Đã thêm xe. Hãy kích hoạt xe trước khi trực tuyến.'));
      }
    } catch (error) {
      if (await _current(revision)) {
        emit(state.copy(actionBusy: false, error: _message(error)));
      }
    }
  }

  Future<void> activateVehicle(String publicId) async {
    if (state.actionBusy || _generation == null) return;
    final revision = _revision;
    emit(state.copy(actionBusy: true, error: null));
    try {
      await _useCases.activateVehicle(publicId, _sessionId);
      if (!await _current(revision)) return;
      final vehicles = await _useCases.vehicles(_sessionId);
      if (await _current(revision)) {
        emit(state.copy(
            vehicles: vehicles,
            actionBusy: false,
            notice: 'Xe đã được kích hoạt.'));
      }
    } catch (error) {
      if (await _current(revision)) {
        emit(state.copy(actionBusy: false, error: _message(error)));
      }
    }
  }

  Future<void> goOnline() async {
    if (state.actionBusy ||
        state.offerActionBusy ||
        state.operatingStatus == 'BUSY' ||
        _generation == null ||
        isMock) {
      return;
    }
    final revision = _revision;
    emit(state.copy(actionBusy: true, error: null));
    try {
      final profile = await _useCases.setStatus('ONLINE', _sessionId);
      if (!await _current(revision)) return;
      emit(state.copy(
          operatingStatus: profile.operatingStatus,
          approvalStatus: profile.approvalStatus,
          driverPublicId: profile.publicId,
          actionBusy: false));
      if (profile.operatingStatus == 'ONLINE' && state.foreground) {
        _startForeground();
        await _uploadLocation(revision);
      }
    } catch (error) {
      if (await _current(revision)) {
        emit(state.copy(actionBusy: false, error: _message(error)));
      }
    }
  }

  Future<void> goOffline() async {
    if (state.actionBusy ||
        state.offerActionBusy ||
        state.operatingStatus != 'ONLINE' ||
        _generation == null) {
      return;
    }
    _stopForeground();
    final revision = _revision;
    emit(state.copy(actionBusy: true, error: null));
    try {
      final profile = await _useCases.setStatus('OFFLINE', _sessionId);
      if (!await _current(revision)) return;
      emit(state.copy(
          operatingStatus: profile.operatingStatus,
          actionBusy: false,
          offer: null,
          lastLocationUpload: null,
          unresolvedDecision: false,
          notice: 'Máy chủ đã xác nhận OFFLINE.'));
    } catch (error) {
      if (!await _current(revision)) return;
      emit(state.copy(actionBusy: false, error: _message(error)));
      if (state.operatingStatus == 'ONLINE' && state.foreground) {
        _startForeground();
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

  void _stopForeground() {
    _activityRevision++;
    _pollTimer?.cancel();
    _locationTimer?.cancel();
    _pollTimer = null;
    _locationTimer = null;
  }

  Future<void> _uploadLocation(int revision) async {
    final activityRevision = _activityRevision;
    if (_uploading ||
        !state.foreground ||
        state.completedAwaitingSettlement ||
        !const {'ONLINE', 'BUSY'}.contains(state.operatingStatus) ||
        !await _current(revision)) {
      return;
    }
    _uploading = true;
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
              'reason=$rejection lat=${point.latitude} lon=${point.longitude} '
              'sampledAt=${sampledAt?.toIso8601String()} '
              'ageMs=${age?.inMilliseconds} '
              'operating=${state.operatingStatus} tripChannel=$_tripChannelActive');
        }
        emit(state.copy(
            locationMessage: 'GPS chưa có mẫu vị trí mới; đang chờ cập nhật.'));
        if (state.operatingStatus == 'ONLINE') await pollOnce();
        return;
      }
      await _useCases.uploadLocation(point, _sessionId);
      if (!await _current(revision) || activityRevision != _activityRevision) {
        return;
      }
      _lastUploadedSampleAt = sampledAt;
      if (kDebugMode) {
        debugPrint('GoMoveGPS source=profile-REST result=sent '
            'lat=${point.latitude} lon=${point.longitude} '
            'sampledAt=${sampledAt!.toIso8601String()} '
            'ageMs=${age!.inMilliseconds} '
            'operating=${state.operatingStatus} tripChannel=$_tripChannelActive');
      }
      emit(state.copy(
          lastLocationUpload: _now(),
          locationProblem: null,
          locationMessage: point.approximate
              ? 'Đã gửi GPS gần đúng; có thể giảm khả năng nhận chuyến.'
              : 'GPS mới đã gửi đến máy chủ.',
          error: null));
      if (state.operatingStatus == 'ONLINE') await pollOnce();
    } on DriverLocationException catch (error) {
      if (kDebugMode) {
        debugPrint('GoMoveGPS source=profile-REST result=skipped '
            'reason=location_${error.problem.name}');
      }
      if (await _current(revision)) {
        emit(state.copy(
            locationProblem: error.problem,
            locationMessage: _locationMessage(error.problem),
            lastLocationUpload: null,
            offer: null));
      }
    } catch (error) {
      if (kDebugMode) {
        debugPrint('GoMoveGPS source=profile-REST result=failed '
            'errorType=${error.runtimeType}');
      }
      if (await _current(revision)) {
        emit(state.copy(
            locationMessage: _message(error),
            lastLocationUpload: null,
            offer: null));
        if (_authError(error)) _stopForeground();
      }
    } finally {
      _uploading = false;
    }
  }

  Future<void> pollOnce() async {
    final revision = _revision;
    final offerRevision = _offerRevision;
    if (_polling ||
        _generation == null ||
        !state.foreground ||
        state.operatingStatus != 'ONLINE' ||
        state.unresolvedDecision ||
        state.offerActionBusy ||
        !await _current(revision)) {
      return;
    }
    final last = state.lastLocationUpload;
    if (last == null || _now().difference(last) >= locationFreshness) {
      emit(state.copy(
          offer: null,
          locationMessage: 'GPS quá 30 giây; đang chờ vị trí mới.'));
      return;
    }
    _polling = true;
    try {
      final offers = await _useCases.activeOffers(_sessionId);
      if (!await _current(revision) ||
          !state.foreground ||
          state.operatingStatus != 'ONLINE' ||
          offerRevision != _offerRevision ||
          state.unresolvedDecision ||
          state.offerActionBusy) {
        return;
      }
      final fresh = offers.where((offer) => _now().isBefore(offer.expiresAt));
      emit(state.copy(offer: fresh.isEmpty ? null : fresh.first, error: null));
    } catch (error) {
      if (await _current(revision)) {
        emit(state.copy(
            error: _message(error),
            offer: _authError(error) ? null : state.offer));
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
    emit(state.copy(offerActionBusy: true, error: null));
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
      if (error is ServerException && error.statusCode == 409) {
        emit(state.copy(
            offer: null,
            offerActionBusy: false,
            notice: 'Đề nghị đã hết hạn hoặc không còn khả dụng.'));
        await pollOnce();
      } else if (error is NetworkException ||
          error is ServerException && error.statusCode == 503) {
        emit(state.copy(
            offerActionBusy: false,
            unresolvedDecision: true,
            error:
                'Chưa xác định kết quả do lỗi mạng/máy chủ. Không gửi lại quyết định.'));
        await reconcile();
      } else {
        emit(state.copy(offerActionBusy: false, error: _message(error)));
        if (_authError(error)) _stopForeground();
      }
    }
  }

  Future<void> _confirmAccepted(DriverOffer offer, int revision,
      {bool completed = false}) async {
    final driverId = state.driverPublicId;
    if (driverId == null) {
      emit(state.copy(
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
        emit(state.copy(
            error: 'Đã nhận chuyến nhưng không lưu được thông tin '
                'bàn giao trên thiết bị. Ghi lại Booking UUID trước khi thoát.'));
      }
    }
  }

  Future<void> reconcile() async {
    final offer = state.offer;
    if (offer == null || _generation == null || _reconciling) return;
    final revision = _revision;
    _reconciling = true;
    try {
      final tracking =
          await _useCases.tracking(offer.bookingPublicId, _sessionId);
      if (!await _current(revision)) return;
      if (tracking.bookingPublicId == offer.bookingPublicId &&
          tracking.driverPublicId != null &&
          tracking.driverPublicId == state.driverPublicId &&
          const {
            'DRIVER_ACCEPTED',
            'DRIVER_ARRIVED',
            'PASSENGER_ONBOARD',
            'IN_PROGRESS',
            'COMPLETED'
          }.contains(tracking.status)) {
        await _confirmAccepted(offer, revision,
            completed: tracking.status == 'COMPLETED');
        return;
      }
      // A missing active offer alone cannot prove whether a decision committed.
      await _useCases.activeOffers(_sessionId);
      if (await _current(revision)) {
        emit(state.copy(
            error:
                'Chưa xác minh được kết quả. Kiểm tra lại sau; không gửi lại quyết định.'));
      }
    } catch (error) {
      if (await _current(revision)) {
        emit(state.copy(
            error: 'Không thể xác minh kết quả. Không gửi lại quyết định.'));
        if (_authError(error)) _stopForeground();
      }
    } finally {
      _reconciling = false;
    }
  }

  void pause() {
    _stopForeground();
    if (!isClosed) {
      emit(state.copy(
          foreground: false,
          offer: state.unresolvedDecision || state.offerActionBusy
              ? state.offer
              : null,
          notice:
              'Ứng dụng tạm dừng: GPS có thể hết hạn, không nhận đề nghị mới.'));
    }
  }

  Future<void> resume() async {
    if (isClosed) return;
    final revision = _revision;
    if (!await _current(revision)) return;
    emit(state.copy(foreground: true));
    if (state.operatingStatus == 'ONLINE') {
      // No GET /drivers/me: revalidate ONLINE by asking the server again.
      await goOnline();
      if (state.unresolvedDecision) await reconcile();
    } else if (state.operatingStatus == 'BUSY') {
      if (!_tripChannelActive) {
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
