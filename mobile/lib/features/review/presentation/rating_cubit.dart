import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/error/exceptions.dart';
import '../../../core/storage/secure_storage_service.dart';
import '../domain/rating_models.dart';
import '../domain/rating_repository.dart';

class RatingState {
  final TripRating? rating;
  final bool loading;
  final bool submitting;
  final bool uncertain;
  final bool skipped;
  final bool sessionEnded;
  final String? error;

  const RatingState(
      {this.rating,
      this.loading = false,
      this.submitting = false,
      this.uncertain = false,
      this.skipped = false,
      this.sessionEnded = false,
      this.error});
}

class RatingCubit extends Cubit<RatingState> {
  final RatingRepository repository;
  final SecureStorageService session;
  final String customerPublicId;
  final String bookingPublicId;
  int _revision = 0;
  int? _generation;

  RatingCubit(this.repository, this.session, this.customerPublicId,
      this.bookingPublicId)
      : super(const RatingState());

  Future<int?> _origin(int revision) async {
    final snapshot = await session.getSession();
    if (isClosed || revision != _revision) return null;
    final owner = await session.getUserPublicId();
    if (isClosed || revision != _revision) return null;
    if (snapshot.accessToken == null ||
        snapshot.accessToken!.isEmpty ||
        owner != customerPublicId ||
        (_generation != null && _generation != snapshot.generation) ||
        !await session.isCurrentSession(snapshot.generation)) {
      invalidateSession();
      return null;
    }
    _generation ??= snapshot.generation;
    return snapshot.generation;
  }

  Future<bool> _current(int revision, int generation) async {
    if (isClosed || revision != _revision || state.sessionEnded) return false;
    if (!await session.isCurrentSession(generation) ||
        await session.getUserPublicId() != customerPublicId ||
        !await session.isCurrentSession(generation)) {
      if (!isClosed && revision == _revision) invalidateSession();
      return false;
    }
    return !isClosed && revision == _revision && !state.sessionEnded;
  }

  void invalidateSession() {
    if (isClosed) return;
    _revision++;
    emit(const RatingState(sessionEnded: true));
  }

  void hideForBackground() {
    if (isClosed || state.sessionEnded) return;
    _revision++;
    emit(RatingState(skipped: state.skipped));
  }

  void skip() {
    if (isClosed || state.sessionEnded || state.submitting) return;
    emit(RatingState(
        rating: state.rating,
        skipped: true,
        uncertain: state.uncertain,
        error: state.error));
  }

  Future<void> load() async {
    if (isClosed || state.sessionEnded) return;
    final revision = ++_revision;
    final skipped = state.skipped;
    emit(RatingState(
        loading: true, uncertain: state.uncertain, skipped: skipped));
    try {
      final generation = await _origin(revision);
      if (generation == null) return;
      final lookup = await repository.lookup(bookingPublicId, generation);
      if (!await _current(revision, generation)) return;
      if (lookup.rating != null &&
          lookup.rating!.bookingPublicId != bookingPublicId) {
        throw const FormatException('Đánh giá không thuộc chuyến này');
      }
      emit(RatingState(rating: lookup.rating, skipped: skipped));
    } catch (error) {
      if (!await _allowedAfterError(revision, error)) return;
      emit(RatingState(
          skipped: skipped,
          uncertain: state.uncertain,
          error: 'Chưa tải được đánh giá. Hãy thử lại.'));
    }
  }

  Future<void> submit(int stars, String? comment) async {
    if (isClosed ||
        state.sessionEnded ||
        state.loading ||
        state.submitting ||
        state.uncertain ||
        state.rating != null) {
      return;
    }
    if (stars < 1 || stars > 5 || (comment?.length ?? 0) > 500) {
      emit(RatingState(
          skipped: state.skipped,
          error: 'Chọn 1–5 sao và viết tối đa 500 ký tự.'));
      return;
    }
    final normalized = comment?.trim().isEmpty == true ? null : comment?.trim();
    final revision = ++_revision;
    emit(const RatingState(submitting: true));
    try {
      final generation = await _origin(revision);
      if (generation == null) return;
      try {
        final rating = await repository.submit(
            bookingPublicId, stars, normalized, generation);
        if (!await _current(revision, generation)) return;
        if (rating.bookingPublicId != bookingPublicId ||
            rating.stars != stars) {
          throw const FormatException('Đánh giá không khớp chuyến đã gửi');
        }
        emit(RatingState(rating: rating));
      } catch (error) {
        if (!await _current(revision, generation)) return;
        if (_accessError(error)) {
          invalidateSession();
          return;
        }
        if (error is NetworkException ||
            error is FormatException ||
            error is ServerException &&
                (error.statusCode == 409 || (error.statusCode ?? 0) >= 500)) {
          try {
            final lookup = await repository.lookup(bookingPublicId, generation);
            if (!await _current(revision, generation)) return;
            final found = lookup.rating;
            if (found != null && found.bookingPublicId == bookingPublicId) {
              emit(RatingState(
                  rating: found,
                  error: found.stars == stars && found.comment == normalized
                      ? null
                      : 'Chuyến này đã có đánh giá trước đó.'));
              return;
            }
          } catch (readError) {
            if (!await _current(revision, generation)) return;
            if (_accessError(readError)) {
              invalidateSession();
              return;
            }
          }
          emit(const RatingState(
              uncertain: true,
              error:
                  'Chưa xác minh được kết quả gửi. Hãy tải lại trước khi thử tiếp.'));
          return;
        }
        emit(const RatingState(error: 'Chưa gửi được đánh giá. Hãy thử lại.'));
      }
    } catch (error) {
      if (!await _allowedAfterError(revision, error)) return;
      emit(const RatingState(error: 'Chưa gửi được đánh giá. Hãy thử lại.'));
    }
  }

  Future<bool> _allowedAfterError(int revision, Object error) async {
    if (isClosed || revision != _revision) return false;
    final generation = _generation;
    if (generation != null && !await _current(revision, generation)) {
      return false;
    }
    if (_accessError(error)) {
      invalidateSession();
      return false;
    }
    return !isClosed && revision == _revision;
  }

  bool _accessError(Object error) =>
      error is UnauthorizedException ||
      error is ServerException &&
          (error.statusCode == 401 ||
              error.statusCode == 403 ||
              error.statusCode == 404);

  @override
  Future<void> close() {
    _revision++;
    return super.close();
  }
}
