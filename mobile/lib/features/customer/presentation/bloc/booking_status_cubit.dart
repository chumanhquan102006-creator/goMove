import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../domain/models/booking.dart';
import '../../domain/usecases/customer_usecases.dart';
import 'quote_cubit.dart';

class BookingStatusState {
  final Booking booking;
  final String? error;
  const BookingStatusState(this.booking, {this.error});
}

class BookingStatusCubit extends Cubit<BookingStatusState> {
  final GetBookingUseCase getBooking;
  Timer? _timer;
  bool _busy = false;
  BookingStatusCubit(this.getBooking, Booking initial)
      : super(BookingStatusState(initial));

  void start() {
    if (_timer != null || state.booking.isCompleted) return;
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => refresh());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> refresh() async {
    if (_busy || isClosed || state.booking.isCompleted) return;
    _busy = true;
    try {
      final booking = await getBooking(state.booking.publicId);
      if (!isClosed) {
        emit(BookingStatusState(booking));
        if (booking.isCompleted) {
          stop();
        }
      }
    } catch (error) {
      if (!isClosed) {
        emit(BookingStatusState(state.booking, error: customerError(error)));
      }
    } finally {
      _busy = false;
    }
  }

  @override
  Future<void> close() {
    stop();
    return super.close();
  }
}
