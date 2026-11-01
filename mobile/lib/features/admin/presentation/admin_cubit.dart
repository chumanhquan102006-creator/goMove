import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/error/exceptions.dart';
import '../../../core/storage/secure_storage_service.dart';
import '../domain/admin_models.dart';
import '../domain/admin_repository.dart';

enum AdminTab { dashboard, drivers, accounts, bookings }

class AdminState {
  final AdminTab tab;
  final int page;
  final String? filter;
  final String? search;
  final bool loading;
  final bool working;
  final bool sessionEnded;
  final String? error;
  final String? notice;
  final bool approvalUncertain;
  final bool approvalNeedsRefresh;
  final AdminDashboard? dashboard;
  final AdminPage<AdminDriver>? drivers;
  final AdminPage<AdminAccount>? accounts;
  final AdminPage<AdminBooking>? bookings;
  final AdminDriver? driverDetail;
  final AdminAccount? accountDetail;

  const AdminState({
    this.tab = AdminTab.dashboard,
    this.page = 0,
    this.filter,
    this.search,
    this.loading = false,
    this.working = false,
    this.sessionEnded = false,
    this.error,
    this.notice,
    this.approvalUncertain = false,
    this.approvalNeedsRefresh = false,
    this.dashboard,
    this.drivers,
    this.accounts,
    this.bookings,
    this.driverDetail,
    this.accountDetail,
  });

  AdminState copyWith({
    AdminTab? tab,
    int? page,
    String? filter,
    String? search,
    bool? loading,
    bool? working,
    bool? sessionEnded,
    String? error,
    String? notice,
    bool? approvalUncertain,
    bool? approvalNeedsRefresh,
    AdminDashboard? dashboard,
    AdminPage<AdminDriver>? drivers,
    AdminPage<AdminAccount>? accounts,
    AdminPage<AdminBooking>? bookings,
    AdminDriver? driverDetail,
    AdminAccount? accountDetail,
    bool clearDetail = false,
    bool clearData = false,
    bool clearNotice = false,
  }) =>
      AdminState(
        tab: tab ?? this.tab,
        page: page ?? this.page,
        filter: filter ?? this.filter,
        search: search ?? this.search,
        loading: loading ?? this.loading,
        working: working ?? this.working,
        sessionEnded: sessionEnded ?? this.sessionEnded,
        error: error,
        notice: clearNotice ? null : notice ?? this.notice,
        approvalUncertain: approvalUncertain ?? this.approvalUncertain,
        approvalNeedsRefresh: approvalNeedsRefresh ?? this.approvalNeedsRefresh,
        dashboard: clearData ? null : dashboard ?? this.dashboard,
        drivers: clearData ? null : drivers ?? this.drivers,
        accounts: clearData ? null : accounts ?? this.accounts,
        bookings: clearData ? null : bookings ?? this.bookings,
        driverDetail: clearDetail ? null : driverDetail ?? this.driverDetail,
        accountDetail: clearDetail ? null : accountDetail ?? this.accountDetail,
      );
}

class AdminCubit extends Cubit<AdminState> {
  final AdminRepository repository;
  final SecureStorageService session;
  final String adminPublicId;
  int _revision = 0;
  int? _generation;
  int _approvalSerial = 0;
  bool _approvalPending = false;
  String? _approvalDriverToVerify;

  AdminCubit(this.repository, this.session, this.adminPublicId)
      : super(const AdminState());

  Future<int?> _origin(int revision) async {
    final snapshot = await session.getSession();
    if (isClosed || revision != _revision) return null;
    final owner = await session.getUserPublicId();
    if (isClosed || revision != _revision) return null;
    if (snapshot.accessToken == null ||
        snapshot.accessToken!.isEmpty ||
        owner != adminPublicId ||
        (_generation != null && _generation != snapshot.generation) ||
        !await session.isCurrentSession(snapshot.generation)) {
      _endSession();
      return null;
    }
    _generation ??= snapshot.generation;
    return snapshot.generation;
  }

  Future<bool> _current(int revision, int generation) async {
    if (isClosed || revision != _revision || state.sessionEnded) return false;
    if (!await session.isCurrentSession(generation) ||
        await session.getUserPublicId() != adminPublicId ||
        !await session.isCurrentSession(generation)) {
      if (!isClosed && revision == _revision) _endSession();
      return false;
    }
    return !isClosed && revision == _revision && !state.sessionEnded;
  }

  void _endSession() {
    if (isClosed) return;
    _revision++;
    _approvalSerial++;
    _approvalPending = false;
    _approvalDriverToVerify = null;
    emit(const AdminState(sessionEnded: true));
  }

  void invalidateSession() => _endSession();

  void hideForBackground() {
    if (isClosed || state.sessionEnded) return;
    _revision++;
    emit(AdminState(
        tab: state.tab,
        working: _approvalPending,
        approvalNeedsRefresh: _approvalDriverToVerify != null,
        approvalUncertain: state.approvalUncertain));
  }

  void selectTab(AdminTab tab) {
    if (isClosed || state.sessionEnded) return;
    _revision++;
    emit(AdminState(
        tab: tab,
        working: _approvalPending,
        approvalNeedsRefresh: _approvalDriverToVerify != null,
        approvalUncertain: state.approvalUncertain));
    load();
  }

  void setQuery({String? filter, String? search}) {
    if (isClosed || state.sessionEnded) return;
    _revision++;
    emit(AdminState(
        tab: state.tab,
        filter: filter,
        search: search?.trim().isEmpty == true ? null : search?.trim(),
        working: _approvalPending,
        approvalNeedsRefresh: _approvalDriverToVerify != null,
        approvalUncertain: state.approvalUncertain));
    load();
  }

  void goToPage(int page) {
    if (isClosed || state.sessionEnded || page < 0) return;
    _revision++;
    emit(AdminState(
        tab: state.tab,
        filter: state.filter,
        search: state.search,
        page: page,
        working: _approvalPending,
        approvalNeedsRefresh: _approvalDriverToVerify != null,
        approvalUncertain: state.approvalUncertain));
    load();
  }

  Future<void> load() async {
    if (isClosed || state.sessionEnded) return;
    final startedWhileApprovalPending = _approvalPending;
    final revision = ++_revision;
    final request = state;
    emit(request.copyWith(
        loading: true,
        clearDetail: true,
        clearData: true,
        clearNotice: true,
        working: _approvalPending,
        approvalNeedsRefresh: _approvalDriverToVerify != null));
    try {
      final generation = await _origin(revision);
      if (generation == null) return;
      switch (request.tab) {
        case AdminTab.dashboard:
          final data = await repository.dashboard(generation);
          if (await _current(revision, generation)) {
            emit(state.copyWith(loading: false, dashboard: data));
          }
          break;
        case AdminTab.drivers:
          final data = await repository.drivers(
              request.page, request.filter, request.search, generation);
          if (await _current(revision, generation)) {
            if (!startedWhileApprovalPending &&
                !_approvalPending &&
                _approvalDriverToVerify != null) {
              final serial = _approvalSerial;
              final verifyId = _approvalDriverToVerify!;
              final verified = await repository.driver(verifyId, generation);
              if (!await _current(revision, generation)) return;
              if (verified.publicId != verifyId) {
                throw const FormatException('Driver reconciliation mismatch');
              }
              if (serial == _approvalSerial &&
                  _approvalDriverToVerify == verifyId &&
                  !_approvalPending) {
                _approvalDriverToVerify = null;
              }
            }
            emit(state.copyWith(
                loading: false,
                drivers: data,
                working: _approvalPending,
                approvalNeedsRefresh: _approvalDriverToVerify != null,
                approvalUncertain: _approvalDriverToVerify != null &&
                    state.approvalUncertain));
          }
          break;
        case AdminTab.accounts:
          final data = await repository.accounts(
              request.page, request.filter, request.search, generation);
          if (await _current(revision, generation)) {
            emit(state.copyWith(loading: false, accounts: data));
          }
          break;
        case AdminTab.bookings:
          final data = await repository.bookings(
              request.page, request.filter, generation);
          if (await _current(revision, generation)) {
            emit(state.copyWith(loading: false, bookings: data));
          }
          break;
      }
    } catch (error) {
      await _failure(error, revision);
    }
  }

  Future<void> openDriver(String publicId) async {
    final startedWhileApprovalPending = _approvalPending;
    final revision = ++_revision;
    emit(state.copyWith(
        loading: true,
        clearDetail: true,
        working: _approvalPending,
        approvalNeedsRefresh: _approvalDriverToVerify != null));
    try {
      final generation = await _origin(revision);
      if (generation == null) return;
      final detail = await repository.driver(publicId, generation);
      if (await _current(revision, generation)) {
        if (detail.publicId != publicId) {
          throw const FormatException('Driver detail mismatch');
        }
        if (!startedWhileApprovalPending &&
            !_approvalPending &&
            _approvalDriverToVerify == publicId) {
          _approvalDriverToVerify = null;
        }
        // A read started before PATCH settled may contain the old status.
        final staleOriginal =
            startedWhileApprovalPending && _approvalDriverToVerify == publicId;
        emit(state.copyWith(
            loading: false,
            clearDetail: staleOriginal,
            driverDetail: staleOriginal ? null : detail,
            working: _approvalPending,
            approvalNeedsRefresh: _approvalDriverToVerify != null,
            approvalUncertain:
                _approvalDriverToVerify != null && state.approvalUncertain));
      }
    } catch (error) {
      await _failure(error, revision);
    }
  }

  Future<void> openAccount(String publicId) async {
    final revision = ++_revision;
    emit(state.copyWith(loading: true, clearDetail: true));
    try {
      final generation = await _origin(revision);
      if (generation == null) return;
      final detail = await repository.account(publicId, generation);
      if (await _current(revision, generation)) {
        emit(state.copyWith(loading: false, accountDetail: detail));
      }
    } catch (error) {
      await _failure(error, revision);
    }
  }

  Future<void> setApproval(String publicId, String status) async {
    if (isClosed ||
        _approvalPending ||
        _approvalDriverToVerify != null ||
        state.working ||
        state.approvalUncertain ||
        state.approvalNeedsRefresh ||
        state.sessionEnded ||
        state.tab != AdminTab.drivers ||
        state.driverDetail?.publicId != publicId) {
      return;
    }
    final initiatingTab = state.tab;
    final revision = ++_revision;
    emit(state.copyWith(working: true, clearNotice: true));
    try {
      final generation = await _origin(revision);
      if (generation == null || !_approvalActive(revision, initiatingTab)) {
        return;
      }
      final serial = ++_approvalSerial;
      _approvalPending = true;
      _approvalDriverToVerify = publicId;
      AdminApprovalResult result;
      try {
        result = await repository.setApproval(publicId, status, generation);
      } catch (error) {
        _approvalPending = false;
        final conflict = error is ServerException && error.statusCode == 409;
        if (conflict) _approvalDriverToVerify = null;
        if (!await _current(revision, generation) ||
            !_approvalActive(revision, initiatingTab)) {
          _settleSupersededApproval(serial, confirmed: false);
          return;
        }
        if (conflict ||
            error is UnauthorizedException ||
            error is ServerException &&
                (error.statusCode == 401 || error.statusCode == 403)) {
          await _failure(error, revision);
        } else {
          _showUncertainApproval(initiatingTab);
        }
        return;
      }
      _approvalPending = false;
      if (!await _current(revision, generation) ||
          !_approvalActive(revision, initiatingTab)) {
        _settleSupersededApproval(serial, confirmed: result.confirmed);
        return;
      }
      if (!result.confirmed) {
        _showUncertainApproval(initiatingTab, result.reconciledDriver);
        return;
      }
      final page = state.page;
      final filter = state.filter;
      final search = state.search;
      emit(AdminState(
        tab: initiatingTab,
        page: page,
        filter: filter,
        search: search,
        loading: true,
        approvalNeedsRefresh: true,
        driverDetail: result.reconciledDriver,
        notice: 'Máy chủ đã xác nhận trạng thái duyệt $status.',
      ));
      try {
        final drivers =
            await repository.drivers(page, filter, search, generation);
        if (!await _current(revision, generation) ||
            !_approvalActive(revision, initiatingTab)) {
          _settleSupersededApproval(serial, confirmed: true);
          return;
        }
        emit(state.copyWith(loading: false, drivers: drivers));
        final detail = result.reconciledDriver ??
            await repository.driver(publicId, generation);
        if (!await _current(revision, generation) ||
            !_approvalActive(revision, initiatingTab)) {
          _settleSupersededApproval(serial, confirmed: true);
          return;
        }
        if (serial == _approvalSerial && _approvalDriverToVerify == publicId) {
          _approvalDriverToVerify = null;
        }
        emit(state.copyWith(
            driverDetail: detail,
            working: false,
            approvalNeedsRefresh: _approvalDriverToVerify != null,
            approvalUncertain: false));
      } catch (error) {
        if (!_approvalActive(revision, initiatingTab)) {
          _settleSupersededApproval(serial, confirmed: true);
          return;
        }
        await _failure(error, revision,
            readFailureMessage: 'Trạng thái duyệt đã được máy chủ xác nhận, '
                'nhưng chưa tải lại được dữ liệu. Hãy làm mới.');
      }
    } catch (error) {
      await _failure(error, revision);
    }
  }

  void _showUncertainApproval(AdminTab tab, [AdminDriver? observedDriver]) {
    final observed = observedDriver?.approvalStatus;
    emit(AdminState(
      tab: tab,
      page: state.page,
      filter: state.filter,
      search: state.search,
      approvalUncertain: true,
      approvalNeedsRefresh: true,
      driverDetail: observedDriver,
      notice: observed == null
          ? 'Chưa xác định kết quả duyệt và chưa kiểm tra được trạng thái máy chủ. '
              'Không gửi lại tự động; hãy làm mới để xác minh.'
          : 'Chưa xác định kết quả duyệt. Trạng thái máy chủ hiện là $observed. '
              'Không gửi lại tự động; hãy làm mới trước khi quyết định.',
    ));
  }

  void _settleSupersededApproval(int serial, {required bool confirmed}) {
    if (isClosed || state.sessionEnded || serial != _approvalSerial) return;
    final needsRefresh = _approvalDriverToVerify != null;
    emit(state.copyWith(
      working: _approvalPending,
      approvalNeedsRefresh: needsRefresh,
      approvalUncertain: needsRefresh && !confirmed,
      notice: state.tab == AdminTab.drivers && needsRefresh
          ? confirmed
              ? 'Máy chủ đã xác nhận thay đổi duyệt trước đó. '
                  'Làm mới để đối chiếu dữ liệu trước khi duyệt tiếp.'
              : 'Chưa xác định kết quả duyệt. '
                  'Làm mới để xác minh trước khi duyệt tiếp.'
          : null,
    ));
  }

  bool _approvalActive(int revision, AdminTab tab) =>
      !isClosed &&
      revision == _revision &&
      !state.sessionEnded &&
      state.tab == tab;

  Future<void> _failure(Object error, int revision,
      {String? readFailureMessage}) async {
    if (isClosed || revision != _revision) return;
    final generation = _generation;
    if (generation != null && !await _current(revision, generation)) return;
    if (error is UnauthorizedException ||
        error is ServerException &&
            (error.statusCode == 401 || error.statusCode == 403)) {
      if (generation != null) {
        try {
          await session.clearIfCurrent(generation);
        } catch (_) {/* Still hide all Admin data if secure storage fails. */}
      }
      if (isClosed || revision != _revision) return;
      _endSession();
    } else {
      final message = error is ServerException &&
              error.errorCode == 'DRIVER_HAS_UNRELEASED_BOOKING'
          ? 'Tài xế đang được gán cho chuyến chưa giải phóng. Hãy làm mới trước khi đổi trạng thái.'
          : readFailureMessage ??
              'Không tải được dữ liệu quản trị. Vui lòng thử lại.';
      emit(state.copyWith(
          loading: false, working: _approvalPending, error: message));
    }
  }

  @override
  Future<void> close() {
    _revision++;
    return super.close();
  }
}
