import 'dart:async';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gomove_mobile/core/error/failures.dart';
import 'package:gomove_mobile/core/utils/result.dart';
import 'package:gomove_mobile/features/auth/domain/entities/user.dart';
import 'package:gomove_mobile/features/auth/domain/repositories/auth_repository.dart';
import 'package:gomove_mobile/features/auth/domain/usecases/check_auth_status_usecase.dart';
import 'package:gomove_mobile/features/auth/domain/usecases/login_usecase.dart';
import 'package:gomove_mobile/features/auth/domain/usecases/logout_usecase.dart';
import 'package:gomove_mobile/features/auth/domain/usecases/register_usecase.dart';
import 'package:gomove_mobile/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:gomove_mobile/features/auth/presentation/bloc/auth_event.dart';
import 'package:gomove_mobile/features/auth/presentation/bloc/auth_state.dart';

class FakeAuthRepository implements AuthRepository {
  Result<User>? loginResult;
  Result<User>? registerResult;
  Result<User>? checkAuthStatusResult;
  Result<void>? logoutResult;
  Completer<Result<void>>? logoutPending;

  @override
  Future<Result<User>> login({required String identifier, required String password}) async {
    return loginResult!;
  }

  @override
  Future<Result<User>> register({
    required String phone,
    String? email,
    required String password,
    required String fullName,
  }) async {
    return registerResult!;
  }

  @override
  Future<Result<User>> checkAuthStatus() async {
    return checkAuthStatusResult!;
  }

  @override
  Future<Result<void>> logout() async {
    if (logoutPending != null) return logoutPending!.future;
    return logoutResult ?? const Success(null);
  }

  @override
  Future<Result<User>> getCurrentUser() async {
    return checkAuthStatusResult!;
  }

  @override
  Future<Result<bool>> isAuthenticated() async {
    return const Success(true);
  }
}

void main() {
  late FakeAuthRepository fakeRepository;
  late LoginUseCase loginUseCase;
  late RegisterUseCase registerUseCase;
  late LogoutUseCase logoutUseCase;
  late CheckAuthStatusUseCase checkAuthStatusUseCase;

  const tUser = User(
    publicId: '550e8400-e29b-41d4-a716-446655440000',
    phoneNumber: '0987654321',
    fullName: 'Nguyen Van A',
    email: 'user@example.com',
    role: UserRole.customer,
    status: 'ACTIVE',
    isStudentVerified: true,
  );

  setUp(() {
    fakeRepository = FakeAuthRepository();
    loginUseCase = LoginUseCase(fakeRepository);
    registerUseCase = RegisterUseCase(fakeRepository);
    logoutUseCase = LogoutUseCase(fakeRepository);
    checkAuthStatusUseCase = CheckAuthStatusUseCase(fakeRepository);
  });

  AuthBloc buildBloc() {
    return AuthBloc(
      loginUseCase: loginUseCase,
      registerUseCase: registerUseCase,
      logoutUseCase: logoutUseCase,
      checkAuthStatusUseCase: checkAuthStatusUseCase,
    );
  }

  group('AuthBloc Tests', () {
    test('State ban đầu là AuthInitialState', () {
      expect(buildBloc().state, equals(const AuthInitialState()));
    });

    blocTest<AuthBloc, AuthState>(
      'Đăng nhập thành công phát ra [AuthLoadingState, AuthenticatedState]',
      build: () {
        fakeRepository.loginResult = const Success(tUser);
        return buildBloc();
      },
      act: (bloc) => bloc.add(const AuthLoginSubmitted(
        identifier: '0987654321',
        password: 'Password123!',
      )),
      expect: () => [
        const AuthLoadingState(),
        const AuthenticatedState(tUser),
      ],
    );

    blocTest<AuthBloc, AuthState>(
      'Đăng nhập thất bại phát ra [AuthLoadingState, AuthErrorState]',
      build: () {
        fakeRepository.loginResult = const Error(InvalidCredentialsFailure());
        return buildBloc();
      },
      act: (bloc) => bloc.add(const AuthLoginSubmitted(
        identifier: '0987654321',
        password: 'wrong_password',
      )),
      expect: () => [
        const AuthLoadingState(),
        const AuthErrorState(
          message: 'Số điện thoại hoặc mật khẩu không chính xác.',
          code: 'INVALID_CREDENTIALS',
        ),
      ],
    );

    blocTest<AuthBloc, AuthState>(
      'Registration field errors reach the presentation state',
      build: () {
        fakeRepository.registerResult = const Error(ValidationFailure(
          message: 'Thông tin đăng ký chưa hợp lệ. Vui lòng kiểm tra các trường.',
          fieldErrors: {'password': 'Mật khẩu phải có từ 8 đến 128 ký tự.'},
        ));
        return buildBloc();
      },
      act: (bloc) => bloc.add(const AuthRegisterSubmitted(
        phone: '0901234567',
        password: 'Password123',
        fullName: 'Nguyễn Văn An',
      )),
      expect: () => [
        const AuthLoadingState(),
        const AuthErrorState(
          message: 'Thông tin đăng ký chưa hợp lệ. Vui lòng kiểm tra các trường.',
          code: 'VALIDATION_ERROR',
          fieldErrors: {'password': 'Mật khẩu phải có từ 8 đến 128 ký tự.'},
        ),
      ],
    );

    blocTest<AuthBloc, AuthState>(
      'Khôi phục phiên thành công tại Splash (AuthCheckRequested) phát ra [AuthLoadingState, AuthenticatedState]',
      build: () {
        fakeRepository.checkAuthStatusResult = const Success(tUser);
        return buildBloc();
      },
      act: (bloc) => bloc.add(const AuthCheckRequested()),
      expect: () => [
        const AuthLoadingState(),
        const AuthenticatedState(tUser),
      ],
    );

    blocTest<AuthBloc, AuthState>(
      'Khôi phục phiên thất bại tại Splash phát ra [AuthLoadingState, UnauthenticatedState]',
      build: () {
        fakeRepository.checkAuthStatusResult = const Error(UnauthorizedFailure());
        return buildBloc();
      },
      act: (bloc) => bloc.add(const AuthCheckRequested()),
      expect: () => [
        const AuthLoadingState(),
        const UnauthenticatedState(),
      ],
    );

    blocTest<AuthBloc, AuthState>(
      'Lỗi mạng khi khôi phục phiên giữ ở Splash để thử lại',
      build: () {
        fakeRepository.checkAuthStatusResult = const Error(NetworkFailure());
        return buildBloc();
      },
      act: (bloc) => bloc.add(const AuthCheckRequested()),
      expect: () => [
        const AuthLoadingState(),
        const AuthErrorState(
          message: 'Không thể kết nối đến máy chủ GoMove. Vui lòng kiểm tra lại mạng.',
          code: 'NETWORK_UNAVAILABLE',
        ),
      ],
    );

    blocTest<AuthBloc, AuthState>(
      'Đăng xuất thành công phát ra [AuthLoadingState, UnauthenticatedState]',
      build: () {
        fakeRepository.logoutResult = const Success(null);
        return buildBloc();
      },
      act: (bloc) => bloc.add(const AuthLogoutRequested()),
      expect: () => [
        const AuthLoadingState(),
        const UnauthenticatedState(),
      ],
    );

    test('Late A logout cannot replace a newer B authenticated UI state',
        () async {
      fakeRepository.logoutPending = Completer<Result<void>>();
      fakeRepository.loginResult = const Success(tUser);
      final bloc = buildBloc();
      addTearDown(bloc.close);
      bloc.add(const AuthLogoutRequested());
      await Future<void>.delayed(Duration.zero);
      bloc.add(const AuthLoginSubmitted(
          identifier: 'B', password: 'Password123'));
      await bloc.stream.firstWhere((state) => state is AuthenticatedState);
      fakeRepository.logoutPending!.complete(const Success(null));
      await Future<void>.delayed(Duration.zero);
      expect(bloc.state, const AuthenticatedState(tUser));
    });
  });
}
