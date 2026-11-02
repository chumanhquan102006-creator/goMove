import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/error/exceptions.dart';
import '../../../../core/storage/secure_storage_service.dart';
import '../../domain/models/driver_earnings_summary.dart';
import '../../domain/repositories/driver_earnings_repository.dart';

class DriverEarningsState {
  final DriverEarningsSummary? summary;
  final bool loading;
  final bool sessionEnded;
  final String? error;

  const DriverEarningsState({
    this.summary,
    this.loading = false,
    this.sessionEnded = false,
    this.error,
  });
}

class DriverEarningsCubit extends Cubit<DriverEarningsState> {
  final DriverEarningsRepository repository;
  final SecureStorageService session;
  final String driverPublicId;
  int _revision = 0;
  int? _generation;
  bool _foreground = true;

  DriverEarningsCubit(this.repository, this.session, this.driverPublicId)
      : super(const DriverEarningsState());

  void hideForBackground() {
    if (isClosed || state.sessionEnded) return;
    _foreground = false;
    _revision++;
    emit(const DriverEarningsState());
  }

  void invalidateSession() {
    if (isClosed) return;
    _revision++;
    emit(const DriverEarningsState(sessionEnded: true));
  }

  Future<bool> _current(int revision, int generation) async {
    if (isClosed || !_foreground || revision != _revision) return false;
    if (!await session.isCurrentSession(generation) ||
        await session.getUserPublicId() != driverPublicId ||
        !await session.isCurrentSession(generation)) {
      if (!isClosed && revision == _revision) invalidateSession();
      return false;
    }
    return !isClosed && _foreground && revision == _revision;
  }

  Future<void> load() async {
    if (isClosed || state.sessionEnded) return;
    _foreground = true;
    final revision = ++_revision;
    emit(const DriverEarningsState(loading: true));
    try {
      final snapshot = await session.getSession();
      if (isClosed || revision != _revision) return;
      if (snapshot.accessToken == null ||
          snapshot.accessToken!.isEmpty ||
          (_generation != null && _generation != snapshot.generation) ||
          !await _current(revision, snapshot.generation)) {
        if (!isClosed && revision == _revision) invalidateSession();
        return;
      }
      _generation ??= snapshot.generation;
      final summary = await repository.summary(snapshot.generation);
      if (!await _current(revision, snapshot.generation)) return;
      emit(DriverEarningsState(summary: summary));
    } catch (error) {
      if (isClosed || revision != _revision) return;
      if (error is UnauthorizedException ||
          error is ServerException &&
              (error.statusCode == 401 || error.statusCode == 403)) {
        invalidateSession();
        return;
      }
      final generation = _generation;
      if (generation != null && !await _current(revision, generation)) return;
      emit(
          const DriverEarningsState(error: 'Chưa tải được tổng kết tiền mặt.'));
    }
  }

  @override
  Future<void> close() {
    _revision++;
    return super.close();
  }
}
