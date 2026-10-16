import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../../core/error/exceptions.dart';
import '../../../../core/storage/secure_storage_service.dart';
import '../../domain/usecases/driver_usecases.dart';

class OnboardingState {
  final bool loading;
  final bool submitted;
  final bool uncertain;
  final String? error;
  const OnboardingState(
      {this.loading = false,
      this.submitted = false,
      this.uncertain = false,
      this.error});
}

class OnboardingCubit extends Cubit<OnboardingState> {
  final DriverUseCases _useCases;
  final SecureStorageService _storage;
  OnboardingCubit(this._useCases, this._storage)
      : super(const OnboardingState());

  Future<void> submit(String licenseNumber) async {
    if (state.loading || state.submitted || state.uncertain) return;
    emit(const OnboardingState(loading: true));
    final generation = (await _storage.getSession()).generation;
    try {
      final profile = await _useCases.onboard(licenseNumber.trim(), generation);
      final current = await _storage.isCurrentSession(generation);
      if (isClosed || !current) return;
      if (profile.approvalStatus != 'PENDING') {
        emit(const OnboardingState(error: 'Trạng thái phê duyệt bất thường.'));
        return;
      }
      emit(const OnboardingState(submitted: true));
    } catch (error) {
      final current = await _storage.isCurrentSession(generation);
      if (isClosed || !current) return;
      final uncertain = error is NetworkException ||
          error is ServerException && error.statusCode == 503;
      emit(OnboardingState(
          uncertain: uncertain,
          error: uncertain
              ? 'Chưa xác định máy chủ đã nhận yêu cầu hay chưa. Đăng xuất, '
                  'đăng nhập lại để kiểm tra vai trò; không gửi lặp.'
              : error is ServerException
                  ? error.message
                  : 'Không thể gửi yêu cầu. Kiểm tra trạng thái tài khoản.'));
    }
  }
}
