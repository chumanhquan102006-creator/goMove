import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../../core/error/failures.dart';
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
  int _authRevision = 0;

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
    final revision = ++_authRevision;
    emit(const AuthLoadingState());

    final result = await _checkAuthStatusUseCase();
    if (revision != _authRevision) return;

    result.fold(
      onSuccess: (user) => emit(AuthenticatedState(user)),
      onFailure: (failure) => emit(failure is UnauthorizedFailure ||
              failure is RefreshTokenExpiredFailure
          ? const UnauthenticatedState()
          : AuthErrorState(message: failure.message, code: failure.code)),
    );
  }

  Future<void> _onAuthLoginSubmitted(
    AuthLoginSubmitted event,
    Emitter<AuthState> emit,
  ) async {
    final revision = ++_authRevision;
    emit(const AuthLoadingState());

    final result = await _loginUseCase(
      identifier: event.identifier,
      password: event.password,
    );
    if (revision != _authRevision) return;

    result.fold(
      onSuccess: (user) => emit(AuthenticatedState(user)),
      onFailure: (failure) => emit(AuthErrorState(
        message: failure.message,
        code: failure.code,
        fieldErrors: failure is ValidationFailure ? failure.fieldErrors : const {},
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
        fieldErrors: failure is ValidationFailure ? failure.fieldErrors : const {},
      )),
    );
  }

  Future<void> _onAuthLogoutRequested(
    AuthLogoutRequested event,
    Emitter<AuthState> emit,
  ) async {
    final revision = ++_authRevision;
    emit(const AuthLoadingState());
    await _logoutUseCase();
    if (revision != _authRevision) return;
    emit(const UnauthenticatedState());
  }

  void _onAuthForceUnauthenticated(
    AuthForceUnauthenticated event,
    Emitter<AuthState> emit,
  ) {
    _authRevision++;
    emit(const UnauthenticatedState());
  }
}
