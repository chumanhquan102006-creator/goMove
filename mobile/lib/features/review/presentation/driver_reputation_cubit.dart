import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/error/exceptions.dart';
import '../../../core/storage/secure_storage_service.dart';
import '../domain/review_models.dart';
import '../domain/review_repository.dart';

class DriverReputationState {
  final DriverReputation? reputation;
  final List<RewardEvent> rewards;
  final List<QualityCase> cases;
  final bool loading;
  final bool loadingMoreRewards;
  final bool hasMoreRewards;
  final int rewardsPage;
  final bool loadingMoreCases;
  final bool hasMoreCases;
  final int casesPage;
  final bool working;
  final bool sessionEnded;
  final String? error;
  final String? notice;
  const DriverReputationState(
      {this.reputation,
      this.rewards = const [],
      this.cases = const [],
      this.loading = false,
      this.loadingMoreRewards = false,
      this.hasMoreRewards = false,
      this.rewardsPage = 0,
      this.loadingMoreCases = false,
      this.hasMoreCases = false,
      this.casesPage = 0,
      this.working = false,
      this.sessionEnded = false,
      this.error,
      this.notice});
}

class DriverReputationCubit extends Cubit<DriverReputationState> {
  final ReviewRepository repository;
  final SecureStorageService session;
  final String driverPublicId;
  int _revision = 0;
  int? _generation;
  bool _foreground = true;

  DriverReputationCubit(this.repository, this.session, this.driverPublicId)
      : super(const DriverReputationState());

  Future<int?> _origin(int revision) async {
    final snapshot = await session.getSession();
    if (isClosed || revision != _revision) return null;
    if (snapshot.accessToken == null ||
        snapshot.accessToken!.isEmpty ||
        await session.getUserPublicId() != driverPublicId ||
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
        await session.getUserPublicId() != driverPublicId ||
        !await session.isCurrentSession(generation)) {
      if (!isClosed && revision == _revision) invalidateSession();
      return false;
    }
    return !isClosed && revision == _revision && _foreground;
  }

  void invalidateSession() {
    if (isClosed) return;
    _revision++;
    emit(const DriverReputationState(sessionEnded: true));
  }

  void hideForBackground() {
    if (isClosed || state.sessionEnded) return;
    _foreground = false;
    _revision++;
    emit(const DriverReputationState());
  }

  Future<void> load() async {
    if (isClosed || state.sessionEnded) return;
    _foreground = true;
    final revision = ++_revision;
    emit(const DriverReputationState(loading: true));
    try {
      final generation = await _origin(revision);
      if (generation == null) return;
      final reputation = await repository.reputation(generation);
      final rewards = await repository.rewards(0, generation);
      final cases = await repository.myCases(0, generation);
      if (!await _current(revision, generation)) return;
      emit(DriverReputationState(
          reputation: reputation,
          rewards: rewards.items,
          cases: cases.items,
          rewardsPage: rewards.page,
          hasMoreRewards: rewards.hasNext,
          casesPage: cases.page,
          hasMoreCases: cases.hasNext));
    } catch (error) {
      if (isClosed || revision != _revision) return;
      if (_accessError(error)) {
        invalidateSession();
        return;
      }
      final generation = _generation;
      if (generation != null && !await _current(revision, generation)) return;
      emit(const DriverReputationState(
          error: 'Chưa tải được đánh giá và điểm thưởng. Hãy thử lại.'));
    }
  }

  Future<void> loadMoreRewards() async {
    if (isClosed ||
        state.sessionEnded ||
        !_foreground ||
        state.working ||
        state.loading ||
        state.loadingMoreRewards ||
        state.loadingMoreCases ||
        !state.hasMoreRewards) {
      return;
    }
    final previous = state;
    final revision = ++_revision;
    emit(DriverReputationState(
      reputation: previous.reputation,
      rewards: previous.rewards,
      cases: previous.cases,
      rewardsPage: previous.rewardsPage,
      hasMoreRewards: previous.hasMoreRewards,
      casesPage: previous.casesPage,
      hasMoreCases: previous.hasMoreCases,
      loadingMoreRewards: true,
    ));
    try {
      final generation = await _origin(revision);
      if (generation == null) return;
      final page =
          await repository.rewards(previous.rewardsPage + 1, generation);
      if (!await _current(revision, generation)) return;
      final seen = previous.rewards.map((item) => item.publicId).toSet();
      emit(DriverReputationState(
        reputation: previous.reputation,
        rewards: [
          ...previous.rewards,
          ...page.items.where((item) => seen.add(item.publicId)),
        ],
        cases: previous.cases,
        rewardsPage: page.page,
        hasMoreRewards: page.hasNext,
        casesPage: previous.casesPage,
        hasMoreCases: previous.hasMoreCases,
      ));
    } catch (error) {
      if (isClosed || revision != _revision) return;
      if (_accessError(error)) {
        invalidateSession();
        return;
      }
      final generation = _generation;
      if (generation != null && !await _current(revision, generation)) return;
      emit(DriverReputationState(
        reputation: previous.reputation,
        rewards: previous.rewards,
        cases: previous.cases,
        rewardsPage: previous.rewardsPage,
        hasMoreRewards: previous.hasMoreRewards,
        casesPage: previous.casesPage,
        hasMoreCases: previous.hasMoreCases,
        error: 'Chưa tải thêm được lịch sử. Hãy thử lại.',
      ));
    }
  }

  Future<void> loadMoreCases() async {
    if (isClosed ||
        state.sessionEnded ||
        !_foreground ||
        state.working ||
        state.loading ||
        state.loadingMoreRewards ||
        state.loadingMoreCases ||
        !state.hasMoreCases) {
      return;
    }
    final previous = state;
    final revision = ++_revision;
    emit(DriverReputationState(
      reputation: previous.reputation,
      rewards: previous.rewards,
      cases: previous.cases,
      rewardsPage: previous.rewardsPage,
      hasMoreRewards: previous.hasMoreRewards,
      casesPage: previous.casesPage,
      hasMoreCases: previous.hasMoreCases,
      loadingMoreCases: true,
    ));
    try {
      final generation = await _origin(revision);
      if (generation == null) return;
      final page = await repository.myCases(previous.casesPage + 1, generation);
      if (!await _current(revision, generation)) return;
      final seen = previous.cases.map((item) => item.publicId).toSet();
      emit(DriverReputationState(
        reputation: previous.reputation,
        rewards: previous.rewards,
        cases: [
          ...previous.cases,
          ...page.items.where((item) => seen.add(item.publicId)),
        ],
        rewardsPage: previous.rewardsPage,
        hasMoreRewards: previous.hasMoreRewards,
        casesPage: page.page,
        hasMoreCases: page.hasNext,
      ));
    } catch (error) {
      if (isClosed || revision != _revision) return;
      if (_accessError(error)) {
        invalidateSession();
        return;
      }
      final generation = _generation;
      if (generation != null && !await _current(revision, generation)) return;
      emit(DriverReputationState(
        reputation: previous.reputation,
        rewards: previous.rewards,
        cases: previous.cases,
        rewardsPage: previous.rewardsPage,
        hasMoreRewards: previous.hasMoreRewards,
        casesPage: previous.casesPage,
        hasMoreCases: previous.hasMoreCases,
        error: 'Chưa tải thêm được hồ sơ. Hãy thử lại.',
      ));
    }
  }

  Future<void> dispute(String casePublicId, String reason) async {
    if (isClosed ||
        state.sessionEnded ||
        !_foreground ||
        state.working ||
        reason.trim().isEmpty ||
        reason.length > 500) {
      return;
    }
    final revision = ++_revision;
    emit(DriverReputationState(
        reputation: state.reputation,
        rewards: state.rewards,
        cases: state.cases,
        rewardsPage: state.rewardsPage,
        hasMoreRewards: state.hasMoreRewards,
        casesPage: state.casesPage,
        hasMoreCases: state.hasMoreCases,
        working: true));
    try {
      final generation = await _origin(revision);
      if (generation == null) return;
      await repository.dispute(casePublicId, reason.trim(), generation);
      if (!await _current(revision, generation)) return;
      await load(); // The server remains authoritative after a mutation.
    } catch (error) {
      if (isClosed || revision != _revision) return;
      if (_accessError(error)) {
        invalidateSession();
        return;
      }
      // A timeout can happen after a committed dispute. Read before retry.
      await load();
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
