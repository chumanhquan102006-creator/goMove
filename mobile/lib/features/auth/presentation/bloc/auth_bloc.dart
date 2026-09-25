import 'package:flutter_bloc/flutter_bloc.dart';
import '../../domain/usecases/check_auth_status_usecase.dart';
import '../../domain/usecases/login_usecase.dart';
import '../../domain/usecases/logout_usecase.dart';
import '../../domain/usecases/register_usecase.dart';
import 'auth_event.dart';
import 'auth_state.dart';

/// [AuthBloc] điều phối toàn bộ State Machine của Authentication:
/// Tuân thủ Điều 136: BLoC làm tầng trung gian tiếp nhận Event từ UI,
/// gọi Domain UseCase tương ứng và phát State. Tuyệt đối không gọi API trực tiếp trong UI (Mục A.1).
class AuthBloc extends Bloc<AuthEvent, AuthState> {
  final LoginUseCase _loginUseCase;
  final RegisterUseCase _registerUseCase;
  final LogoutUseCase _logoutUseCase;
  final CheckAuthStatusUseCase _checkAuthStatusUseCase;

  AuthBloc({
    required LoginUseCase loginUseCase,
    required RegisterUseCase registerUseCase,
    required LogoutUseCase logoutUseCase,
    required CheckAuthStatusUseCase checkAuthStatusUseCase,
  })  : _loginUseCase = loginUseCase,
        _registerUseCase = registerUseCase,
        _logoutUseCase = logoutUseCase,
        _checkAuthStatusUseCase = checkAuthStatusUseCase,
        super(const AuthInitialState()) {
    on<AuthCheckRequested>(_onAuthCheckRequested);
    on<AuthLoginSubmitted>(_onAuthLoginSubmitted);
    on<AuthRegisterSubmitted>(_onAuthRegisterSubmitted);
    on<AuthLogoutRequested>(_onAuthLogoutRequested);
    on<AuthForceUnauthenticated>(_onAuthForceUnauthenticated);
  }

  Future<void> _onAuthCheckRequested(
    AuthCheckRequested event,
    Emitter<AuthState> emit,
  ) async {
    emit(const AuthLoadingState());

    final result = await _checkAuthStatusUseCase();

    result.fold(
      onSuccess: (user) => emit(AuthenticatedState(user)),
      onFailure: (_) => emit(const UnauthenticatedState()),
    );
  }

  Future<void> _onAuthLoginSubmitted(
    AuthLoginSubmitted event,
    Emitter<AuthState> emit,
  ) async {
    emit(const AuthLoadingState());

    final result = await _loginUseCase(
      identifier: event.identifier,
      password: event.password,
    );

    result.fold(
      onSuccess: (user) => emit(AuthenticatedState(user)),
      onFailure: (failure) => emit(AuthErrorState(
        message: failure.message,
        code: failure.code,
      )),
    );
  }

  Future<void> _onAuthRegisterSubmitted(
    AuthRegisterSubmitted event,
    Emitter<AuthState> emit,
  ) async {
    emit(const AuthLoadingState());

    final result = await _registerUseCase(
      phone: event.phone,
      email: event.email,
      password: event.password,
      fullName: event.fullName,
    );

    result.fold(
      onSuccess: (user) => emit(AuthRegistrationSuccessState(user)),
      onFailure: (failure) => emit(AuthErrorState(
        message: failure.message,
        code: failure.code,
      )),
    );
  }

  Future<void> _onAuthLogoutRequested(
    AuthLogoutRequested event,
    Emitter<AuthState> emit,
  ) async {
    emit(const AuthLoadingState());
    await _logoutUseCase();
    emit(const UnauthenticatedState());
  }

  void _onAuthForceUnauthenticated(
    AuthForceUnauthenticated event,
    Emitter<AuthState> emit,
  ) {
    emit(const UnauthenticatedState());
  }
}
