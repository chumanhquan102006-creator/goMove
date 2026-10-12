import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../../core/error/exceptions.dart';
import '../../domain/models/quote.dart';
import '../../domain/usecases/customer_usecases.dart';

class QuoteState {
  final bool loading;
  final Quote? quote;
  final String? error;
  const QuoteState({this.loading = false, this.quote, this.error});
}

class QuoteCubit extends Cubit<QuoteState> {
  final RequestQuoteUseCase requestQuote;
  QuoteCubit(this.requestQuote) : super(const QuoteState());

  Future<void> request(QuoteRequest request) async {
    if (state.loading) {
      return;
    }
    emit(const QuoteState(loading: true));
    try {
      emit(QuoteState(quote: await requestQuote(request)));
    } catch (error) {
      emit(QuoteState(error: customerError(error)));
    }
  }
}

String customerError(Object error) {
  if (error is FormatException) {
    return error.message;
  }
  if (error is NetworkException) {
    return 'Không xác định được kết quả do lỗi mạng. Hãy thử lại với cùng mã yêu cầu.';
  }
  if (error is UnauthorizedException) {
    return 'Phiên đăng nhập đã hết hạn. Vui lòng đăng nhập lại.';
  }
  if (error is ServerException) {
    return switch (error.statusCode) {
      400 => 'Dữ liệu gửi lên không hợp lệ. Hãy kiểm tra tọa độ và loại xe.',
      401 => 'Phiên đăng nhập đã hết hạn. Vui lòng đăng nhập lại.',
      403 => 'Tài khoản không có quyền Customer.',
      404 => 'Không tìm thấy Quote hoặc Booking được phép xem.',
      409 => 'Quote đã hết hạn, đã dùng hoặc khóa idempotency xung đột.',
      503 => 'Máy chủ đang bận. Có thể thử lại an toàn.',
      _ => 'Máy chủ chưa xử lý được yêu cầu. Vui lòng thử lại.',
    };
  }
  return 'Không thể hoàn tất yêu cầu. Vui lòng kiểm tra kết nối và thử lại.';
}
