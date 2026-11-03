import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/error/exceptions.dart';
import '../../../core/storage/secure_storage_service.dart';
import '../domain/review_models.dart';
import '../domain/review_repository.dart';

class AdminQualityState {
  final String? filter;
  final List<QualityCase> cases;
  final int casesPage;
  final bool hasMoreCases;
  final bool loadingMoreCases;
  final QualityDetail? detail;
  final bool loading;
  final bool working;
  final bool uncertain;
  final bool sessionEnded;
  final String? error;
  const AdminQualityState(
      {this.filter,
      this.cases = const [],
      this.casesPage = 0,
      this.hasMoreCases = false,
      this.loadingMoreCases = false,
      this.detail,
      this.loading = false,
      this.working = false,
      this.uncertain = false,
      this.sessionEnded = false,
      this.error});
}

class AdminQualityCubit extends Cubit<AdminQualityState> {
  final ReviewRepository repository;
  final SecureStorageService session;
  final String adminPublicId;
  int _revision = 0;
  int? _generation;
  bool _foreground = true;
  bool _actionPending = false;
  String? _caseToVerify;

  AdminQualityCubit(this.repository, this.session, this.adminPublicId)
      : super(const AdminQualityState());

  Future<int?> _origin(int revision) async {
    final snapshot = await session.getSession();
    if (isClosed || revision != _revision) return null;
    if (snapshot.accessToken == null ||
        snapshot.accessToken!.isEmpty ||
        await session.getUserPublicId() != adminPublicId ||
        (_generation != null && _generation != snapshot.generation) ||
        !await session.isCurrentSession(snapshot.generation)) {
      invalidateSession();
      return null;
    }
    if (isClosed || revision != _revision) return null;
    _generation ??= snapshot.generation;
    return snapshot.generation;
  }

  Future<bool> _current(int revision, int generation) async {
    if (isClosed || revision != _revision || !_foreground) return false;
    if (!await session.isCurrentSession(generation) ||
        await session.getUserPublicId() != adminPublicId ||
        !await session.isCurrentSession(generation)) {
      if (!isClosed && revision == _revision) invalidateSession();
      return false;
    }
    return !isClosed && revision == _revision && _foreground;
  }

  void invalidateSession() {
    if (isClosed) return;
    _revision++;
    _actionPending = false;
    _caseToVerify = null;
    emit(const AdminQualityState(sessionEnded: true));
  }

  void hideForBackground() {
    if (isClosed || state.sessionEnded) return;
    _foreground = false;
    _revision++;
    emit(AdminQualityState(
        filter: state.filter,
        working: _actionPending,
        uncertain: _caseToVerify != null));
  }

  Future<void> setFilter(String? filter) async {
    if (isClosed ||
        !_foreground ||
        state.sessionEnded ||
        _actionPending ||
        _caseToVerify != null ||
        state.working ||
        state.uncertain ||
        state.filter == filter) {
      return;
    }
    if (filter != null &&
        !const {'OPEN', 'WARNED', 'DISPUTED', 'SUSPENDED', 'DISMISSED'}
            .contains(filter)) {
      return;
    }
    _revision++;
    emit(AdminQualityState(filter: filter));
    await load();
  }

  Future<void> load() async {
    if (isClosed || state.sessionEnded) return;
    _foreground = true;
    if (_actionPending) return;
    if (_caseToVerify != null) {
      await reconcile(_caseToVerify!);
      return;
    }
    if (state.working) return;
    if (state.uncertain && state.detail != null) {
      await reconcile(state.detail!.qualityCase.publicId);
      return;
    }
    final filter = state.filter;
    final revision = ++_revision;
    emit(AdminQualityState(filter: filter, loading: true));
    try {
      final generation = await _origin(revision);
      if (generation == null) return;
      final page = await repository.adminCases(0, filter, generation);
      if (!await _current(revision, generation)) return;
      emit(AdminQualityState(
          filter: filter,
          cases: page.items,
          casesPage: page.page,
          hasMoreCases: page.hasNext));
    } catch (error) {
      if (isClosed || revision != _revision) return;
      if (_accessError(error)) {
        invalidateSession();
        return;
      }
      emit(AdminQualityState(
          filter: filter, error: 'Chưa tải được danh sách rà soát.'));
    }
  }

  Future<void> loadMoreCases() async {
    if (isClosed ||
        state.sessionEnded ||
        !_foreground ||
        state.loading ||
        state.loadingMoreCases ||
        _actionPending ||
        _caseToVerify != null ||
        state.working ||
        state.uncertain ||
        !state.hasMoreCases) {
      return;
    }
    final previous = state;
    final revision = ++_revision;
    emit(AdminQualityState(
      filter: previous.filter,
      cases: previous.cases,
      casesPage: previous.casesPage,
      hasMoreCases: previous.hasMoreCases,
      detail: previous.detail,
      uncertain: previous.uncertain,
      loadingMoreCases: true,
    ));
    try {
      final generation = await _origin(revision);
      if (generation == null) return;
      final page = await repository.adminCases(
          previous.casesPage + 1, previous.filter, generation);
      if (!await _current(revision, generation)) return;
      final seen = previous.cases.map((item) => item.publicId).toSet();
      emit(AdminQualityState(
        filter: previous.filter,
        cases: [
          ...previous.cases,
          ...page.items.where((item) => seen.add(item.publicId)),
        ],
        casesPage: page.page,
        hasMoreCases: page.hasNext,
        detail: previous.detail,
        uncertain: previous.uncertain,
      ));
    } catch (error) {
      if (isClosed || revision != _revision) return;
      if (_accessError(error)) {
        invalidateSession();
        return;
      }
      final generation = _generation;
      if (generation != null && !await _current(revision, generation)) return;
      emit(AdminQualityState(
        filter: previous.filter,
        cases: previous.cases,
        casesPage: previous.casesPage,
        hasMoreCases: previous.hasMoreCases,
        detail: previous.detail,
        uncertain: previous.uncertain,
        error: 'Chưa tải thêm được hồ sơ. Hãy thử lại.',
      ));
    }
  }

  Future<void> open(String publicId) async {
    if (isClosed ||
        state.sessionEnded ||
        _actionPending ||
        _caseToVerify != null ||
        state.working ||
        state.uncertain) {
      return;
    }
    final revision = ++_revision;
    emit(AdminQualityState(
        filter: state.filter,
        cases: state.cases,
        casesPage: state.casesPage,
        hasMoreCases: state.hasMoreCases,
        loading: true,
        uncertain: state.uncertain));
    try {
      final generation = await _origin(revision);
      if (generation == null) return;
      final detail = await repository.adminDetail(publicId, generation);
      if (!await _current(revision, generation)) return;
      emit(AdminQualityState(
          filter: state.filter,
          cases: state.cases,
          casesPage: state.casesPage,
          hasMoreCases: state.hasMoreCases,
          detail: detail));
    } catch (error) {
      if (isClosed || revision != _revision) return;
      if (_accessError(error)) {
        invalidateSession();
        return;
      }
      emit(AdminQualityState(
          filter: state.filter,
          cases: state.cases,
          casesPage: state.casesPage,
          hasMoreCases: state.hasMoreCases,
          error: 'Chưa tải được hồ sơ rà soát.'));
    }
  }

  Future<void> act(String action, String note) async {
    final detail = state.detail;
    if (detail == null ||
        isClosed ||
        _actionPending ||
        _caseToVerify != null ||
        state.working ||
        state.uncertain ||
        state.sessionEnded ||
        !_foreground ||
        note.trim().isEmpty ||
        note.length > 500) {
      return;
    }
    final publicId = detail.qualityCase.publicId;
    final revision = ++_revision;
    emit(AdminQualityState(
        filter: state.filter,
        cases: state.cases,
        casesPage: state.casesPage,
        hasMoreCases: state.hasMoreCases,
        detail: detail,
        working: true));
    try {
      final generation = await _origin(revision);
      if (generation == null) return;
      _actionPending = true;
      _caseToVerify = publicId;
      final updated = await repository.adminAction(
          publicId, action, note.trim(), generation);
      _actionPending = false;
      if (!await _current(revision, generation)) {
        await _settleInterruptedAction();
        return;
      }
      emit(AdminQualityState(
          filter: state.filter,
          cases: state.cases,
          casesPage: state.casesPage,
          hasMoreCases: state.hasMoreCases,
          detail: updated,
          uncertain: true));
      // An authoritative list/read clears the mutation gate.
      await reconcile(publicId);
    } catch (error) {
      _actionPending = false;
      if (isClosed || state.sessionEnded) return;
      if (revision != _revision) {
        await _settleInterruptedAction();
        return;
      }
      if (_accessError(error)) {
        invalidateSession();
        return;
      }
      emit(AdminQualityState(
          filter: state.filter,
          cases: state.cases,
          casesPage: state.casesPage,
          hasMoreCases: state.hasMoreCases,
          detail: detail,
          uncertain: true,
          error:
              'Chưa xác minh được kết quả. Hãy kiểm tra lại trước khi thao tác tiếp.'));
      await reconcile(publicId);
    }
  }

  Future<void> _settleInterruptedAction() async {
    if (isClosed || state.sessionEnded || _caseToVerify == null) return;
    final publicId = _caseToVerify!;
    emit(AdminQualityState(filter: state.filter, uncertain: true));
    if (_foreground) {
      await reconcile(publicId);
    }
  }

  Future<void> reconcile(String publicId) async {
    if (isClosed ||
        state.sessionEnded ||
        _actionPending ||
        (_caseToVerify != null && _caseToVerify != publicId)) {
      return;
    }
    final revision = ++_revision;
    emit(AdminQualityState(
        filter: state.filter,
        cases: state.cases,
        casesPage: state.casesPage,
        hasMoreCases: state.hasMoreCases,
        detail: state.detail,
        loading: true,
        uncertain: true));
    try {
      final generation = await _origin(revision);
      if (generation == null) return;
      final detail = await repository.adminDetail(publicId, generation);
      final page = await repository.adminCases(0, state.filter, generation);
      if (!await _current(revision, generation)) return;
      if (_caseToVerify == publicId) _caseToVerify = null;
      emit(AdminQualityState(
          filter: state.filter,
          cases: page.items,
          casesPage: page.page,
          hasMoreCases: page.hasNext,
          detail: detail));
    } catch (error) {
      if (isClosed || revision != _revision) return;
      if (_accessError(error)) {
        invalidateSession();
        return;
      }
      emit(AdminQualityState(
          filter: state.filter,
          cases: state.cases,
          casesPage: state.casesPage,
          hasMoreCases: state.hasMoreCases,
          detail: state.detail,
          uncertain: true,
          error: 'Chưa xác minh được kết quả. Vui lòng tải lại.'));
    }
  }

  bool _accessError(Object error) =>
      error is UnauthorizedException ||
      error is ServerException &&
          (error.statusCode == 401 || error.statusCode == 403);

  @override
  Future<void> close() {
    _revision++;
    return super.close();
  }
}
