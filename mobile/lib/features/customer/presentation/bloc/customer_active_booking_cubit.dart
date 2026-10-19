import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/error/exceptions.dart';
import '../../../../core/storage/secure_storage_service.dart';
import '../../../trip/domain/models/trip_models.dart';
import '../../../trip/domain/repositories/trip_repository.dart';
import '../../data/active_booking_store.dart';
import '../../domain/models/booking.dart';
import '../../domain/usecases/customer_usecases.dart';

class CustomerActiveBookingState {
  final Booking? booking;
  final CashPayment? payment;
  final bool loading;
  final bool sessionEnded;
  final String? error;

  const CustomerActiveBookingState(
      {this.booking,
      this.payment,
      this.loading = false,
      this.sessionEnded = false,
      this.error});

  /// A completed trip still needs recovery while CASH is not verified PAID.
  bool get isActive =>
      booking != null &&
      !(booking!.status == 'COMPLETED' && payment?.isPaid == true);
}

/// The saved UUID is only a hint. Every restoration is authorized by the
/// server's owned-Booking GET before any Booking detail is shown.
class CustomerActiveBookingCubit extends Cubit<CustomerActiveBookingState> {
  static final _uuid = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

  final GetBookingUseCase getBooking;
  final TripRepository tripRepository;
  final ActiveBookingStore store;
  final SecureStorageService session;
  final String customerPublicId;
  int _revision = 0;

  CustomerActiveBookingCubit(this.getBooking, this.tripRepository, this.store,
      this.session, this.customerPublicId)
      : super(const CustomerActiveBookingState());

  Future<int?> _origin(int revision) async {
    final snapshot = await session.getSession();
    if (isClosed || revision != _revision) return null;
    final owner = await session.getUserPublicId();
    if (isClosed || revision != _revision) return null;
    if (snapshot.accessToken == null ||
        snapshot.accessToken!.isEmpty ||
        owner != customerPublicId ||
        !await session.isCurrentSession(snapshot.generation)) {
      _endSession();
      return null;
    }
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
    emit(const CustomerActiveBookingState(
        sessionEnded: true,
        error:
            'Phiên đăng nhập đã thay đổi. Hãy đăng nhập lại để xem chuyến.'));
  }

  Future<void> restore() async {
    if (isClosed || state.sessionEnded) return;
    final revision = ++_revision;
    int? generation;
    // A resume never displays cached details until the owned GET succeeds.
    emit(const CustomerActiveBookingState(loading: true));
    try {
      generation = await _origin(revision);
      if (generation == null) return;
      final record = await store.read(customerPublicId);
      if (!await _current(revision, generation)) return;
      if (record == null) {
        emit(const CustomerActiveBookingState());
        return;
      }
      await _verify(record.bookingPublicId, revision, generation,
          persist: false);
    } catch (error) {
      if (isClosed || revision != _revision || state.sessionEnded) return;
      if (generation != null && !await _current(revision, generation)) return;
      if (_accessError(error)) {
        _endSession();
        return;
      }
      if (error is ServerException &&
          (error.statusCode == 403 || error.statusCode == 404)) {
        try {
          await store.clear(customerPublicId);
        } catch (_) {
          // A failed local delete must not strand Home in its loading state.
          if (generation != null && !await _current(revision, generation)) {
            return;
          }
          emit(CustomerActiveBookingState(
              error: '${_message(error)} Không xóa được tham chiếu cũ; '
                  'bạn vẫn có thể nhập UUID khác.'));
          return;
        }
        if (generation != null && !await _current(revision, generation)) return;
      }
      emit(CustomerActiveBookingState(error: _message(error)));
    }
  }

  Future<void> refresh() => restore();

  Future<void> recoverByPublicId(String rawPublicId) async {
    if (isClosed || state.sessionEnded || state.loading) return;
    final requested = rawPublicId.trim().toLowerCase();
    if (!_uuid.hasMatch(requested)) {
      emit(CustomerActiveBookingState(
          booking: state.booking,
          payment: state.payment,
          error: 'UUID Booking không hợp lệ. Hãy kiểm tra và nhập lại.'));
      return;
    }
    final revision = ++_revision;
    int? generation;
    final previousBooking = state.booking;
    final previousPayment = state.payment;
    emit(CustomerActiveBookingState(
        booking: previousBooking, payment: previousPayment, loading: true));
    try {
      generation = await _origin(revision);
      if (generation == null) return;
      await _verify(requested, revision, generation, persist: true);
    } catch (error) {
      if (isClosed || revision != _revision || state.sessionEnded) return;
      if (generation != null && !await _current(revision, generation)) return;
      if (_accessError(error)) {
        _endSession();
        return;
      }
      emit(CustomerActiveBookingState(
          booking: previousBooking,
          payment: previousPayment,
          error: _message(error)));
    }
  }

  Future<void> _verify(String publicId, int revision, int generation,
      {required bool persist}) async {
    final booking = await getBooking(publicId, sessionGeneration: generation);
    if (!await _current(revision, generation)) return;
    if (booking.publicId.toLowerCase() != publicId.toLowerCase()) {
      throw const FormatException('Phản hồi Booking không khớp UUID yêu cầu');
    }
    CashPayment? payment;
    String? paymentError;
    if (booking.status == 'COMPLETED') {
      try {
        payment = await tripRepository.payment(booking.publicId, generation);
        if (!await _current(revision, generation)) return;
        if (payment.bookingPublicId != booking.publicId) {
          throw const FormatException('Thanh toán không khớp Booking');
        }
      } catch (error) {
        if (!await _current(revision, generation)) return;
        if (_accessError(error)) {
          _endSession();
          return;
        }
        paymentError = 'Đã xác thực Booking nhưng chưa kiểm tra được '
            'thanh toán. Hãy mở chuyến hoặc thử cập nhật lại.';
      }
    }
    // A PAID historical lookup may be displayed but cannot replace the
    // durable hint for an ongoing (or still-unpaid) Booking.
    if (persist && !(booking.status == 'COMPLETED' && payment?.isPaid == true)) {
      await store.write(
          customerPublicId,
          ActiveBookingRecord(
              customerPublicId: customerPublicId,
              bookingPublicId: booking.publicId));
      if (!await _current(revision, generation)) return;
    }
    if (!await _current(revision, generation)) return;
    emit(CustomerActiveBookingState(
        booking: booking, payment: payment, error: paymentError));
  }

  bool _accessError(Object error) =>
      error is UnauthorizedException ||
      error is ServerException && error.statusCode == 401;

  String _message(Object error) {
    if (error is UnauthorizedException ||
        error is ServerException && error.statusCode == 401) {
      return 'Phiên đăng nhập đã hết hạn. Hãy đăng nhập lại.';
    }
    if (error is ServerException) {
      return switch (error.statusCode) {
        403 => 'Tài khoản không được phép xem Booking này.',
        404 => 'Không tìm thấy Booking thuộc tài khoản này.',
        503 => 'Máy chủ đang bận. Hãy thử lại sau.',
        _ => 'Không thể xác minh Booking. Hãy thử lại sau.',
      };
    }
    if (error is NetworkException) {
      return 'Không kết nối được Backend. Chưa thể xác minh Booking.';
    }
    if (error is FormatException) return error.message;
    return 'Không thể khôi phục Booking. Hãy thử lại.';
  }
}
