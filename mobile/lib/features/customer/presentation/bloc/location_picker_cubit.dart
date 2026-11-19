import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/error/exceptions.dart';
import '../../../../core/storage/secure_storage_service.dart';
import '../../domain/models/place_search_result.dart';
import '../../domain/models/quote.dart';
import '../../domain/repositories/geocoding_repository.dart';

enum LocationPickerTarget { pickup, dropoff }

enum LocationPickerPhase {
  closed,
  authorizing,
  locating,
  moving,
  stable,
  confirming,
  suspended,
  unavailable,
}

class LocationPickerState {
  final int epoch;
  final LocationPickerTarget target;
  final LocationPickerPhase phase;
  final int? generation;
  final int cameraRevision;
  final Coordinates? point;
  final PlaceSearchResult? address;
  final bool lookingUp;
  final String? message;

  const LocationPickerState({
    this.epoch = 0,
    this.target = LocationPickerTarget.pickup,
    this.phase = LocationPickerPhase.closed,
    this.generation,
    this.cameraRevision = -1,
    this.point,
    this.address,
    this.lookingUp = false,
    this.message,
  });

  bool get isOpen => phase != LocationPickerPhase.closed;
  bool get cameraEnabled =>
      isOpen && generation != null && phase != LocationPickerPhase.suspended;
  bool get canConfirm =>
      phase == LocationPickerPhase.stable && point?.isValid == true;
}

class ConfirmedMapLocation {
  final LocationPickerTarget target;
  final Coordinates point;
  final PlaceSearchResult? address;
  const ConfirmedMapLocation(this.target, this.point, this.address);
}

/// Ephemeral, account-scoped draft. Only Home may apply a confirmed result to
/// its committed controllers. Timers never own Quote or Booking operations.
class LocationPickerCubit extends Cubit<LocationPickerState> {
  final SecureStorageService? session;
  final GeocodingRepository? geocoding;
  final String customerPublicId;
  final bool Function() isCurrentAccount;
  Timer? _idleTimer;
  Timer? _cooldown;
  bool _foreground = true;
  bool _inFlight = false;
  bool _rateLimited = false;
  int _epoch = 0;
  int _lookupRevision = 0;
  Coordinates? _pending;

  LocationPickerCubit({
    required this.session,
    required this.geocoding,
    required this.customerPublicId,
    required this.isCurrentAccount,
  }) : super(const LocationPickerState());

  bool _current(int epoch) =>
      !isClosed &&
      _foreground &&
      state.isOpen &&
      epoch == _epoch &&
      isCurrentAccount();

  Future<bool> _authorized(int epoch, int generation) async {
    try {
      if (!_current(epoch) || session == null) return false;
      final owner = await session!.getUserPublicId();
      if (!_current(epoch) || owner != customerPublicId) return false;
      final current = await session!.isCurrentSession(generation);
      return _current(epoch) && current;
    } catch (_) {
      return false;
    }
  }

  Future<void> enter(LocationPickerTarget target, Coordinates? initial) async {
    if (!_foreground || !isCurrentAccount() || isClosed) return;
    _invalidateLookups();
    _rateLimited = false;
    final epoch = ++_epoch;
    emit(LocationPickerState(
        epoch: epoch,
        target: target,
        phase: LocationPickerPhase.authorizing,
        point: initial?.isValid == true ? initial : null));
    try {
      final snapshot = await session?.getSession();
      if (!_current(epoch)) return;
      if (snapshot == null ||
          snapshot.accessToken?.isNotEmpty != true ||
          !await _authorized(epoch, snapshot.generation)) {
        if (_current(epoch)) cancel();
        return;
      }
      if (!_current(epoch)) return;
      emit(LocationPickerState(
          epoch: epoch,
          target: target,
          generation: snapshot.generation,
          point: state.point,
          phase: LocationPickerPhase.locating));
    } catch (_) {
      if (_current(epoch)) cancel();
    }
  }

  void cameraMoving(int epoch, int revision) {
    if (!_current(epoch) ||
        !state.cameraEnabled ||
        revision <= state.cameraRevision) {
      return;
    }
    _invalidateLookups();
    emit(LocationPickerState(
        epoch: epoch,
        target: state.target,
        generation: state.generation,
        cameraRevision: revision,
        point: state.point,
        phase: LocationPickerPhase.moving));
  }

  void cameraIdle(int epoch, int revision, Coordinates point) {
    if (!_current(epoch) ||
        !state.cameraEnabled ||
        revision < state.cameraRevision) {
      return;
    }
    if ((state.canConfirm || state.phase == LocationPickerPhase.confirming) &&
        revision == state.cameraRevision &&
        point.latitude == state.point?.latitude &&
        point.longitude == state.point?.longitude) {
      return;
    }
    if (!point.isValid) {
      unavailable(epoch);
      return;
    }
    _invalidateLookups();
    emit(LocationPickerState(
        epoch: epoch,
        target: state.target,
        generation: state.generation,
        cameraRevision: revision,
        point: point,
        phase: LocationPickerPhase.stable));
    _idleTimer = Timer(const Duration(milliseconds: 600), () {
      if (!_current(epoch) || !state.canConfirm) return;
      _pending = point;
      unawaited(_drain());
    });
  }

  Future<void> _drain() async {
    if (isClosed ||
        !_foreground ||
        !state.canConfirm ||
        _pending == null ||
        _inFlight ||
        _cooldown != null ||
        _rateLimited) {
      return;
    }
    final point = _pending!;
    _pending = null;
    final epoch = _epoch;
    final revision = _lookupRevision;
    final generation = state.generation!;
    _inFlight = true;
    try {
      if (!await _authorized(epoch, generation)) {
        if (_current(epoch)) cancel();
        return;
      }
      if (!_current(epoch) || revision != _lookupRevision) return;
      if (geocoding == null) {
        _lookupResult(epoch, revision, null,
            'Chưa xác minh được địa chỉ. Bạn vẫn có thể dùng tọa độ này.');
        return;
      }
      _cooldown = Timer(const Duration(seconds: 1), () {
        _cooldown = null;
        unawaited(_drain());
      });
      emit(LocationPickerState(
          epoch: epoch,
          target: state.target,
          generation: generation,
          cameraRevision: state.cameraRevision,
          point: point,
          phase: LocationPickerPhase.stable,
          lookingUp: true));
      final result =
          await geocoding!.reverse(point, sessionGeneration: generation);
      if (!_current(epoch) || revision != _lookupRevision) return;
      if (!await _authorized(epoch, generation)) {
        if (_current(epoch)) cancel();
        return;
      }
      final exact = result != null &&
          result.coordinates.latitude == point.latitude &&
          result.coordinates.longitude == point.longitude;
      _lookupResult(
          epoch,
          revision,
          exact ? result : null,
          exact
              ? null
              : 'Chưa tìm được địa chỉ. Tọa độ đã chọn vẫn dùng được.');
    } catch (error) {
      if (!_current(epoch)) return;
      if (!await _authorized(epoch, generation)) {
        if (_current(epoch)) cancel();
        return;
      }
      if (!_current(epoch)) return;
      _rateLimited = error is ServerException && error.statusCode == 429;
      if (_rateLimited) _pending = null;
      if (revision != _lookupRevision) return;
      _lookupResult(
          epoch,
          revision,
          null,
          _rateLimited
              ? 'Tìm địa chỉ đang quá tải. Bạn vẫn có thể xác nhận tọa độ.'
              : 'Không thể tìm địa chỉ lúc này. Bạn vẫn có thể xác nhận tọa độ.');
    } finally {
      _inFlight = false;
      if (!isClosed) unawaited(_drain());
    }
  }

  void _lookupResult(
      int epoch, int revision, PlaceSearchResult? address, String? message) {
    if (!_current(epoch) || revision != _lookupRevision || !state.canConfirm) {
      return;
    }
    emit(LocationPickerState(
        epoch: epoch,
        target: state.target,
        generation: state.generation,
        cameraRevision: state.cameraRevision,
        point: state.point,
        address: address,
        message: message,
        phase: LocationPickerPhase.stable));
  }

  Future<ConfirmedMapLocation?> confirm() async {
    if (!state.canConfirm || !_current(_epoch)) return null;
    final selected = state;
    _invalidateLookups();
    emit(LocationPickerState(
        epoch: selected.epoch,
        target: selected.target,
        generation: selected.generation,
        cameraRevision: selected.cameraRevision,
        point: selected.point,
        address: selected.address,
        phase: LocationPickerPhase.confirming));
    final authorized = await _authorized(selected.epoch, selected.generation!);
    if (!_current(selected.epoch)) return null;
    if (!authorized) {
      cancel();
      return null;
    }
    if (state.phase != LocationPickerPhase.confirming ||
        state.cameraRevision != selected.cameraRevision) {
      return null;
    }
    final result = ConfirmedMapLocation(
        selected.target, selected.point!, selected.address);
    cancel();
    return result;
  }

  void unavailable(int epoch) {
    if (!_current(epoch)) return;
    _invalidateLookups();
    emit(LocationPickerState(
        epoch: epoch,
        target: state.target,
        generation: state.generation,
        cameraRevision: state.cameraRevision,
        point: state.point,
        phase: LocationPickerPhase.unavailable,
        message:
            'Chưa xác định được điểm trên bản đồ. Hãy thử kéo lại hoặc hủy để nhập thủ công.'));
  }

  void suspend() {
    _foreground = false;
    _invalidateLookups();
    if (!state.isOpen || isClosed) return;
    emit(LocationPickerState(
        epoch: ++_epoch,
        target: state.target,
        point: state.point,
        generation: state.generation,
        phase: LocationPickerPhase.suspended));
  }

  Future<void> resume() async {
    _foreground = true;
    if (!state.isOpen || isClosed) return;
    final previous = state;
    if (previous.generation == null ||
        !await _authorized(previous.epoch, previous.generation!)) {
      if (!isClosed && state.epoch == previous.epoch) cancel();
      return;
    }
    if (!_current(previous.epoch)) return;
    emit(LocationPickerState(
        epoch: ++_epoch,
        target: previous.target,
        generation: previous.generation,
        point: previous.point,
        phase: LocationPickerPhase.locating));
  }

  void _invalidateLookups() {
    _idleTimer?.cancel();
    _idleTimer = null;
    _pending = null;
    _lookupRevision++;
  }

  void cancel() {
    if (isClosed) return;
    _invalidateLookups();
    emit(LocationPickerState(epoch: ++_epoch));
  }

  @override
  Future<void> close() {
    _epoch++;
    _invalidateLookups();
    _cooldown?.cancel();
    return super.close();
  }
}
