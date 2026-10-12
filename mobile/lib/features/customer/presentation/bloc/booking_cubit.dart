import 'package:flutter_bloc/flutter_bloc.dart';
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
  int _revision = 0;
  BookingCubit(this.createBooking, this.customerPublicId)
      : super(const BookingState());

  Future<void> restore() async {
    final revision = ++_revision;
    try {
      final pending = await createBooking.pendingFor(customerPublicId);
      if (!isClosed && revision == _revision) {
        emit(BookingState(pending: pending));
      }
    } catch (_) {
      if (!isClosed && revision == _revision) {
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
    try {
      final booking = await createBooking(
          customerPublicId: customerPublicId, quotePublicId: quotePublicId);
      if (!isClosed && revision == _revision) {
        emit(BookingState(booking: booking));
      }
    } catch (error) {
      if (isClosed || revision != _revision) return;
      BookingIntent? pending;
      try {
        pending = await createBooking.pendingFor(customerPublicId);
      } catch (_) {}
      if (!isClosed && revision == _revision) {
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
    try {
      await createBooking.abandon(customerPublicId);
      if (!isClosed && revision == _revision) emit(const BookingState());
    } catch (_) {
      if (!isClosed && revision == _revision) {
        emit(BookingState(pending: state.pending,
            error: 'Không thể bỏ yêu cầu đang xử lý. Hãy chờ kết quả rồi thử lại.'));
      }
    }
  }
}
