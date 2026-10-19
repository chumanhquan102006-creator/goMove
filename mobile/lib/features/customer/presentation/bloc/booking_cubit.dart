import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../../core/storage/secure_storage_service.dart';
import '../../domain/models/booking.dart';
import '../../domain/models/booking_intent.dart';
import '../../domain/usecases/customer_usecases.dart';
import 'quote_cubit.dart';

class BookingState {
  final bool loading;
  final Booking? booking;
  final BookingIntent? pending;
  final String? error;
  const BookingState(
      {this.loading = false, this.booking, this.pending, this.error});
}

class BookingCubit extends Cubit<BookingState> {
  final CreateBookingUseCase createBooking;
  final String customerPublicId;
  final SecureStorageService? session;
  int _revision = 0;
  BookingCubit(this.createBooking, this.customerPublicId, {this.session})
      : super(const BookingState());

  Future<int?> _origin() async {
    if (session == null) return null;
    final snapshot = await session!.getSession();
    final owner = await session!.getUserPublicId();
    return snapshot.accessToken != null && owner == customerPublicId
        ? snapshot.generation
        : null;
  }

  Future<bool> _current(int revision, int? origin) async {
    if (isClosed || revision != _revision) return false;
    if (session == null) return true;
    if (origin == null || !await session!.isCurrentSession(origin)) {
      return false;
    }
    return !isClosed &&
        revision == _revision &&
        await session!.getUserPublicId() == customerPublicId &&
        await session!.isCurrentSession(origin);
  }

  Future<void> restore() async {
    final revision = ++_revision;
    int? origin;
    try {
      origin = await _origin();
      if (session != null && origin == null) return;
      final pending = await createBooking.pendingFor(customerPublicId);
      if (await _current(revision, origin)) {
        emit(BookingState(pending: pending));
      }
    } catch (_) {
      if (await _current(revision, origin)) {
        emit(const BookingState(
            error:
                'Không đọc được yêu cầu Booking đang chờ. Không tạo yêu cầu mới.'));
      }
    }
  }

  Future<void> submit(String quotePublicId) async {
    if (isClosed || state.loading) return;
    final revision = ++_revision;
    emit(BookingState(loading: true, pending: state.pending));
    int? origin;
    try {
      origin = await _origin();
      if (!await _current(revision, origin)) return;
      final booking = await createBooking(
          customerPublicId: customerPublicId,
          quotePublicId: quotePublicId,
          sessionGeneration: origin);
      if (await _current(revision, origin)) {
        emit(BookingState(booking: booking));
      }
    } catch (error) {
      if (isClosed || revision != _revision) return;
      if (!await _current(revision, origin)) return;
      BookingIntent? pending;
      try {
        pending = await createBooking.pendingFor(customerPublicId);
      } catch (_) {}
      if (await _current(revision, origin)) {
        emit(BookingState(
            pending: pending,
            error: error is PendingIntentConflict
                ? 'Có Booking chưa rõ kết quả. Hãy thử lại yêu cầu cũ hoặc chủ động bỏ nó.'
                : customerError(error)));
      }
    }
  }

  Future<void> abandon() async {
    final revision = ++_revision;
    int? origin;
    try {
      origin = await _origin();
      if (!await _current(revision, origin)) return;
      await createBooking.abandon(customerPublicId);
      if (await _current(revision, origin)) emit(const BookingState());
    } catch (_) {
      if (await _current(revision, origin)) {
        emit(BookingState(
            pending: state.pending,
            error:
                'Không thể bỏ yêu cầu đang xử lý. Hãy chờ kết quả rồi thử lại.'));
      }
    }
  }
}
