import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gomove_mobile/core/config/app_config.dart';
import 'package:gomove_mobile/core/error/failures.dart';
import 'package:gomove_mobile/core/theme/app_motion.dart';
import 'package:gomove_mobile/core/utils/result.dart';
import 'package:gomove_mobile/features/auth/domain/entities/user.dart';
import 'package:gomove_mobile/features/auth/domain/repositories/auth_repository.dart';
import 'package:gomove_mobile/features/auth/domain/usecases/check_auth_status_usecase.dart';
import 'package:gomove_mobile/features/auth/domain/usecases/login_usecase.dart';
import 'package:gomove_mobile/features/auth/domain/usecases/logout_usecase.dart';
import 'package:gomove_mobile/features/auth/domain/usecases/register_usecase.dart';
import 'package:gomove_mobile/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:gomove_mobile/features/auth/presentation/screens/login_screen.dart';
import 'package:gomove_mobile/features/auth/presentation/screens/register_screen.dart';
import 'package:gomove_mobile/features/auth/presentation/screens/role_home.dart';
import 'package:gomove_mobile/features/auth/presentation/screens/splash_screen.dart';

class _AuthRepository implements AuthRepository {
  final check = Completer<Result<User>>();
  final loginResult = Completer<Result<User>>();
  int loginCalls = 0;

  @override
  Future<Result<User>> checkAuthStatus() => check.future;

  @override
  Future<Result<User>> login({
    required String identifier,
    required String password,
  }) {
    loginCalls++;
    return loginResult.future;
  }

  @override
  Future<Result<User>> register({
    required String phone,
    String? email,
    required String password,
    required String fullName,
  }) async =>
      const Error(UnauthorizedFailure());

  @override
  Future<Result<void>> logout() async => const Success(null);

  @override
  Future<Result<User>> getCurrentUser() => check.future;

  @override
  Future<Result<bool>> isAuthenticated() async => const Success(false);
}

AuthBloc _bloc(_AuthRepository repository) => AuthBloc(
      loginUseCase: LoginUseCase(repository),
      registerUseCase: RegisterUseCase(repository),
      logoutUseCase: LogoutUseCase(repository),
      checkAuthStatusUseCase: CheckAuthStatusUseCase(repository),
    );

void main() {
  setUp(() => AppConfig.initialize(forceMock: true));
  tearDown(AppConfig.reset);

  test('home and logout navigation never animates a native map route', () {
    final route = AppMotion.immediateRoute<void>(const SizedBox.shrink());
    expect(route.transitionDuration, Duration.zero);
    expect(route.reverseTransitionDuration, Duration.zero);
  });

  testWidgets('motion tokens honor Android reduce-motion preference',
      (tester) async {
    Duration? observed;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        observed = AppMotion.duration(context, AppMotion.card);
        return AppMotion.entrance(context, const Text('GoMove'));
      }),
    ));
    expect(observed, AppMotion.card);
    expect(find.byType(TweenAnimationBuilder<double>), findsOneWidget);

    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child!,
      ),
      home: Builder(builder: (context) {
        observed = AppMotion.duration(context, AppMotion.card);
        return AppMotion.entrance(context, const Text('GoMove'));
      }),
    ));
    expect(observed, Duration.zero);
    expect(find.byType(TweenAnimationBuilder<double>), findsNothing);
    expect(find.text('GoMove'), findsOneWidget);
  });

  testWidgets('splash waits for auth before transitioning to login',
      (tester) async {
    final repository = _AuthRepository();
    final bloc = _bloc(repository);
    addTearDown(bloc.close);
    await tester.pumpWidget(BlocProvider.value(
      value: bloc,
      child: const MaterialApp(home: SplashScreen()),
    ));
    await tester.pump();
    expect(find.byType(SplashScreen), findsOneWidget);
    expect(find.byType(LoginScreen), findsNothing);

    repository.check.complete(const Error(UnauthorizedFailure()));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.byType(SplashScreen), findsNothing);
  });

  testWidgets('login loading feedback follows request, with no early success',
      (tester) async {
    final repository = _AuthRepository();
    final bloc = _bloc(repository);
    addTearDown(bloc.close);
    await tester.pumpWidget(BlocProvider.value(
      value: bloc,
      child: const MaterialApp(home: LoginScreen()),
    ));
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), '0901234567');
    await tester.enterText(fields.at(1), 'password');
    await tester.tap(find.text('ĐĂNG NHẬP'));
    await tester.pump();

    expect(repository.loginCalls, 1);
    expect(tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
        isNull);
    expect(find.byKey(const ValueKey('login-loading')), findsOneWidget);
    expect(find.byType(LoginScreen), findsOneWidget);

    repository.loginResult.complete(const Error(InvalidCredentialsFailure()));
    await tester.pump();
    await tester.pump(AppMotion.feedback);
    expect(find.text('Số điện thoại hoặc mật khẩu không chính xác.'),
        findsOneWidget);
    expect(repository.loginCalls, 1);
  });

  testWidgets('logout removes the previous route and its account details',
      (tester) async {
    final bloc = _bloc(_AuthRepository());
    addTearDown(bloc.close);
    const user = User(
      publicId: 'account-a',
      phoneNumber: '0901234567',
      fullName: 'Customer A',
      role: UserRole.unknown,
    );
    await tester.pumpWidget(BlocProvider.value(
      value: bloc,
      child: const MaterialApp(home: RoleHome(user: user)),
    ));
    expect(find.text('Customer A'), findsOneWidget);

    await tester.tap(find.byTooltip('Đăng xuất'));
    await tester.pumpAndSettle();
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.text('Customer A'), findsNothing);
    expect(Navigator.of(tester.element(find.byType(LoginScreen))).canPop(),
        isFalse);
  });

  testWidgets(
      'register remains reachable at 320px with keyboard and reduced motion',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bloc = _bloc(_AuthRepository());
    addTearDown(bloc.close);
    await tester.pumpWidget(BlocProvider.value(
      value: bloc,
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: true,
            viewInsets: const EdgeInsets.only(bottom: 240),
          ),
          child: child!,
        ),
        home: const RegisterScreen(),
      ),
    ));

    expect(find.byType(TweenAnimationBuilder<double>), findsNothing);
    await tester.ensureVisible(find.text('ĐĂNG KÝ NGAY'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('ĐĂNG KÝ NGAY'), findsOneWidget);
  });
}
