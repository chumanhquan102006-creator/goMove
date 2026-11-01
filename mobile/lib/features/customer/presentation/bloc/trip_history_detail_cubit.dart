import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/error/exceptions.dart';
import '../../../../core/storage/secure_storage_service.dart';
import '../../../trip/domain/models/trip_models.dart';
import '../../../trip/domain/repositories/trip_repository.dart';
import '../../domain/models/booking.dart';
import '../../domain/models/place_search_result.dart';
import '../../domain/models/quote.dart';
import '../../domain/repositories/geocoding_repository.dart';
import '../../domain/repositories/trip_history_repository.dart';

class TripHistoryDetailState {
  final Booking? booking;
  final CashPayment? payment;
  final PlaceSearchResult? pickupAddress;
  final PlaceSearchResult? dropoffAddress;
  final bool loading;
  final bool sessionEnded;
  final String? error;
  final String? paymentError;

  const TripHistoryDetailState({
    this.booking,
    this.payment,
    this.pickupAddress,
    this.dropoffAddress,
    this.loading = false,
    this.sessionEnded = false,
    this.error,
    this.paymentError,
  });
}

class TripHistoryDetailCubit extends Cubit<TripHistoryDetailState> {
  final TripHistoryRepository repository;
  final TripRepository tripRepository;
  final GeocodingRepository geocoding;
  final SecureStorageService session;
  final String customerPublicId;
  final String bookingPublicId;
  int _revision = 0;
  int? _generation;

  TripHistoryDetailCubit(this.repository, this.tripRepository, this.geocoding,
      this.session, this.customerPublicId, this.bookingPublicId)
      : super(const TripHistoryDetailState());

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
    emit(const TripHistoryDetailState(sessionEnded: true));
  }

  void invalidateSession() => _endSession();

  void hideForBackground() {
    if (isClosed) return;
    _revision++;
    emit(const TripHistoryDetailState());
  }

  Future<void> load() async {
    if (isClosed || state.sessionEnded) return;
    final revision = ++_revision;
    emit(const TripHistoryDetailState(loading: true));
    try {
      final generation = await _origin(revision);
      if (generation == null) return;
      final booking = await repository.detail(bookingPublicId, generation);
      if (!await _current(revision, generation)) return;
      if (booking.publicId != bookingPublicId ||
          !booking.isCompleted ||
          booking.pickup == null ||
          booking.dropoff == null) {
        throw const FormatException('Chi tiết chuyến không khớp yêu cầu');
      }
      CashPayment? payment;
      String? paymentError;
      try {
        payment = await tripRepository.payment(bookingPublicId, generation);
        if (!await _current(revision, generation)) return;
        if (payment.bookingPublicId != bookingPublicId ||
            payment.method != 'CASH' ||
            (payment.status != 'PAID' && payment.status != 'PENDING') ||
            (payment.isPaid && payment.paidAt == null)) {
          throw const FormatException('Thanh toán chuyến không hợp lệ');
        }
      } catch (error) {
        if (!await _current(revision, generation)) return;
        if (_accessError(error)) {
          _endSession();
          return;
        }
        paymentError = 'Chưa xác minh được thanh toán. Hãy thử tải lại.';
      }
      emit(TripHistoryDetailState(
          booking: booking, payment: payment, paymentError: paymentError));
      final pickup = await _reverse(booking.pickup!, revision, generation);
      if (!await _current(revision, generation)) return;
      final dropoff = await _reverse(booking.dropoff!, revision, generation);
      if (!await _current(revision, generation)) return;
      emit(TripHistoryDetailState(
          booking: booking,
          payment: payment,
          pickupAddress: pickup,
          dropoffAddress: dropoff,
          paymentError: paymentError));
    } catch (error) {
      if (isClosed || revision != _revision) return;
      final generation = _generation;
      if (generation != null && !await _current(revision, generation)) return;
      if (_accessError(error)) {
        _endSession();
      } else {
        emit(TripHistoryDetailState(
            error: error is NetworkException
                ? 'Không kết nối được máy chủ. Hãy thử lại.'
                : 'Không tải được chi tiết chuyến. Hãy thử lại.'));
      }
    }
  }

  Future<PlaceSearchResult?> _reverse(
      Coordinates point, int revision, int generation) async {
    try {
      final place =
          await geocoding.reverse(point, sessionGeneration: generation);
      if (!await _current(revision, generation)) return null;
      if (place?.coordinates.latitude != point.latitude ||
          place?.coordinates.longitude != point.longitude) {
        return null;
      }
      return place;
    } catch (error) {
      if (await _current(revision, generation) && _accessError(error)) {
        _endSession();
      }
      return null;
    }
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
