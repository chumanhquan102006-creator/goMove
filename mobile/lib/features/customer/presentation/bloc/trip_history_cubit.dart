import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/error/exceptions.dart';
import '../../../../core/storage/secure_storage_service.dart';
import '../../domain/models/place_search_result.dart';
import '../../domain/models/quote.dart';
import '../../domain/models/trip_history.dart';
import '../../domain/repositories/geocoding_repository.dart';
import '../../domain/repositories/trip_history_repository.dart';

class TripHistoryState {
  final List<HistoryTrip> items;
  final Map<String, PlaceSearchResult> addresses;
  final int page;
  final bool hasNext;
  final bool loading;
  final bool loadingMore;
  final bool sessionEnded;
  final String? error;

  const TripHistoryState({
    this.items = const [],
    this.addresses = const {},
    this.page = -1,
    this.hasNext = false,
    this.loading = false,
    this.loadingMore = false,
    this.sessionEnded = false,
    this.error,
  });

  TripHistoryState copyWith({
    List<HistoryTrip>? items,
    Map<String, PlaceSearchResult>? addresses,
    int? page,
    bool? hasNext,
    bool? loading,
    bool? loadingMore,
    String? error,
  }) =>
      TripHistoryState(
        items: items ?? this.items,
        addresses: addresses ?? this.addresses,
        page: page ?? this.page,
        hasNext: hasNext ?? this.hasNext,
        loading: loading ?? this.loading,
        loadingMore: loadingMore ?? this.loadingMore,
        error: error,
      );
}

class TripHistoryCubit extends Cubit<TripHistoryState> {
  static const pageSize = 10;
  static const maxAddressLookups = 20;

  final TripHistoryRepository repository;
  final GeocodingRepository geocoding;
  final SecureStorageService session;
  final String customerPublicId;
  final Map<String, PlaceSearchResult?> _addressCache = {};
  int _revision = 0;
  int? _generation;
  int _addressLookups = 0;

  TripHistoryCubit(
      this.repository, this.geocoding, this.session, this.customerPublicId)
      : super(const TripHistoryState());

  static String pointKey(Coordinates point) =>
      '${point.latitude},${point.longitude}';

  Future<int?> _origin(int revision) async {
    final snapshot = await session.getSession();
    if (isClosed || revision != _revision) return null;
    final owner = await session.getUserPublicId();
    if (isClosed || revision != _revision) return null;
    if (snapshot.accessToken == null ||
        snapshot.accessToken!.isEmpty ||
        owner != customerPublicId ||
        (_generation != null && snapshot.generation != _generation) ||
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
        await session.getUserPublicId() != customerPublicId ||
        !await session.isCurrentSession(generation)) {
      if (!isClosed && revision == _revision) _endSession();
      return false;
    }
    return !isClosed && revision == _revision && !state.sessionEnded;
  }

  void _endSession() {
    if (isClosed) return;
    _revision++;
    _addressCache.clear();
    emit(const TripHistoryState(sessionEnded: true));
  }

  void invalidateSession() => _endSession();

  void hideForBackground() {
    if (isClosed) return;
    _revision++;
    _addressCache.clear();
    _addressLookups = 0;
    emit(const TripHistoryState());
  }

  Future<void> load() async {
    if (isClosed || state.sessionEnded) return;
    final revision = ++_revision;
    emit(const TripHistoryState(loading: true));
    try {
      final generation = await _origin(revision);
      if (generation == null) return;
      final result = await repository.page(0, pageSize, generation);
      if (!await _current(revision, generation)) return;
      emit(TripHistoryState(
          items: result.items, page: 0, hasNext: result.hasNext));
      unawaited(_resolve(result.items, revision, generation));
    } catch (error) {
      if (isClosed || revision != _revision) return;
      final generation = _generation;
      if (generation != null && !await _current(revision, generation)) return;
      if (_accessError(error)) {
        _endSession();
      } else {
        emit(TripHistoryState(error: _message(error)));
      }
    }
  }

  Future<void> more() async {
    if (isClosed ||
        state.sessionEnded ||
        state.loading ||
        state.loadingMore ||
        !state.hasNext) {
      return;
    }
    final revision = _revision;
    final nextPage = state.page + 1;
    emit(state.copyWith(loadingMore: true));
    try {
      final generation = await _origin(revision);
      if (generation == null) return;
      final result = await repository.page(nextPage, pageSize, generation);
      if (!await _current(revision, generation)) return;
      final seen = state.items.map((item) => item.bookingPublicId).toSet();
      final added = result.items
          .where((item) => seen.add(item.bookingPublicId))
          .toList(growable: false);
      emit(state.copyWith(
          items: [...state.items, ...added],
          page: nextPage,
          hasNext: result.hasNext,
          loadingMore: false));
      unawaited(_resolve(added, revision, generation));
    } catch (error) {
      if (isClosed || revision != _revision) return;
      final generation = _generation;
      if (generation != null && !await _current(revision, generation)) return;
      if (_accessError(error)) {
        _endSession();
      } else {
        emit(state.copyWith(loadingMore: false, error: _message(error)));
      }
    }
  }

  Future<void> _resolve(
      List<HistoryTrip> items, int revision, int generation) async {
    for (final item in items) {
      for (final point in [item.pickup, item.dropoff]) {
        if (!await _current(revision, generation)) return;
        final key = pointKey(point);
        if (_addressCache.containsKey(key)) continue;
        if (_addressLookups >= maxAddressLookups) return;
        _addressLookups++;
        try {
          final place =
              await geocoding.reverse(point, sessionGeneration: generation);
          if (!await _current(revision, generation)) return;
          if (place != null &&
              pointKey(place.coordinates) == key &&
              place.label.trim().isNotEmpty) {
            _addressCache[key] = place;
            emit(state.copyWith(
                addresses: {...state.addresses, key: place},
                error: state.error));
          } else {
            _addressCache[key] = null;
          }
        } catch (error) {
          if (!await _current(revision, generation)) return;
          if (_accessError(error)) _endSession();
          // A provider outage or 429 leaves coordinates visible and avoids a burst.
          return;
        }
      }
    }
  }

  bool _accessError(Object error) =>
      error is UnauthorizedException ||
      error is ServerException &&
          (error.statusCode == 401 || error.statusCode == 403);

  String _message(Object error) => error is NetworkException
      ? 'Không kết nối được máy chủ. Hãy thử lại.'
      : 'Không tải được lịch sử chuyến đi. Hãy thử lại.';

  @override
  Future<void> close() {
    _revision++;
    _addressCache.clear();
    return super.close();
  }
}
