import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gomove_mobile/core/error/failures.dart';
import 'package:gomove_mobile/core/utils/result.dart';
import 'package:gomove_mobile/features/auth/data/models/register_request_model.dart';
import 'package:gomove_mobile/features/auth/data/models/user_model.dart';
import 'package:gomove_mobile/features/auth/domain/entities/user.dart';
import 'package:gomove_mobile/features/auth/domain/repositories/auth_repository.dart';
import 'package:gomove_mobile/features/auth/domain/usecases/check_auth_status_usecase.dart';
import 'package:gomove_mobile/features/auth/domain/usecases/login_usecase.dart';
import 'package:gomove_mobile/features/auth/domain/usecases/logout_usecase.dart';
import 'package:gomove_mobile/features/auth/domain/usecases/register_usecase.dart';
import 'package:gomove_mobile/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:gomove_mobile/features/auth/presentation/registration_validation.dart';
import 'package:gomove_mobile/features/auth/presentation/screens/register_screen.dart';

class RegistrationRepository implements AuthRepository {
  int calls = 0;
  String? submittedName;
  Result<User> response = const Error(ValidationFailure(
      message: 'Thông tin đăng ký chưa hợp lệ. Vui lòng kiểm tra các trường.',
      fieldErrors: {'password': 'Mật khẩu phải có từ 8 đến 128 ký tự.'}));
  Completer<Result<User>>? pending;

  @override
  Future<Result<User>> register(
      {required String phone,
      String? email,
      required String password,
      required String fullName}) async {
    calls++;
    submittedName = fullName;
    if (pending != null) return pending!.future;
    return response;
  }

  @override
  Future<Result<User>> login(
          {required String identifier, required String password}) =>
      throw UnimplementedError();
  @override
  Future<Result<User>> checkAuthStatus() => throw UnimplementedError();
  @override
  Future<Result<User>> getCurrentUser() => throw UnimplementedError();
  @override
  Future<Result<bool>> isAuthenticated() => throw UnimplementedError();
  @override
  Future<Result<void>> logout() => throw UnimplementedError();
}

void main() {
  test('Registration contract accepts Unicode and enforces exact lengths', () {
    const composed = 'Nguyễn Văn An';
    const decomposed = 'Nguyễn Văn An';
    for (final name in [composed, decomposed]) {
      expect(RegistrationValidation.fullName(name), isNull);
      final encoded = jsonEncode(RegisterRequestModel(
              phone: '0901234567', password: '12345678', fullName: name)
          .toJson());
      expect(jsonDecode(encoded)['fullName'], name);
      final model = UserModel.fromJson({
        'publicId': 'uuid',
        'phone': '0901234567',
        'fullName': name,
        'role': 'CUSTOMER'
      });
      expect(model.fullName, name);
      expect(UserModel.fromJson(jsonDecode(jsonEncode(model.toJson()))
              as Map<String, dynamic>)
          .fullName, name);
    }
    expect(RegistrationValidation.password('1234567'),
        'Mật khẩu phải có ít nhất 8 ký tự.');
    expect(RegistrationValidation.password('a' * 128), isNull);
    expect(RegistrationValidation.password('a' * 129),
        'Mật khẩu tối đa 128 ký tự.');
    expect(RegistrationValidation.phone('1'), isNull);
    expect(RegistrationValidation.phone('1' * 21), isNotNull);
    expect(RegistrationValidation.fullName('a' * 101), isNotNull);
    expect(RegistrationValidation.email('bad-email'), isNotNull);
    expect(RegistrationValidation.email(''), isNull);
    expect(RegistrationValidation.confirmation('different', '12345678'),
        isNotNull);
  });

  testWidgets('Registration blocks short password and displays backend field error',
      (tester) async {
    final repository = RegistrationRepository();
    final bloc = AuthBloc(
        loginUseCase: LoginUseCase(repository),
        registerUseCase: RegisterUseCase(repository),
        logoutUseCase: LogoutUseCase(repository),
        checkAuthStatusUseCase: CheckAuthStatusUseCase(repository));
    addTearDown(bloc.close);
    await tester.pumpWidget(BlocProvider.value(
        value: bloc,
        child: const MaterialApp(home: RegisterScreen())));
    final fields = find.byType(TextFormField);
    const name = 'Nguyễn Văn An';
    await tester.enterText(fields.at(0), name);
    await tester.enterText(fields.at(1), '0901234567');
    await tester.enterText(fields.at(3), '1234567');
    await tester.enterText(fields.at(4), '1234567');
    await tester.ensureVisible(find.text('ĐĂNG KÝ NGAY'));
    await tester.tap(find.text('ĐĂNG KÝ NGAY'));
    await tester.pumpAndSettle();
    expect(repository.calls, 0);
    expect(find.text('Mật khẩu phải có ít nhất 8 ký tự.'), findsOneWidget);

    await tester.enterText(fields.at(3), '12345678');
    await tester.enterText(fields.at(4), '12345678');
    await tester.ensureVisible(find.text('ĐĂNG KÝ NGAY'));
    await tester.tap(find.text('ĐĂNG KÝ NGAY'));
    await tester.pumpAndSettle();
    expect(repository.calls, 1);
    expect(repository.submittedName, name);
    expect(find.text('Mật khẩu phải có từ 8 đến 128 ký tự.'), findsOneWidget);
    expect(find.textContaining('Request validation failed'), findsNothing);
  });

  testWidgets('Name field preserves a Vietnamese IME composing sequence',
      (tester) async {
    final repository = RegistrationRepository();
    final bloc = AuthBloc(
        loginUseCase: LoginUseCase(repository),
        registerUseCase: RegisterUseCase(repository),
        logoutUseCase: LogoutUseCase(repository),
        checkAuthStatusUseCase: CheckAuthStatusUseCase(repository));
    addTearDown(bloc.close);
    await tester.pumpWidget(BlocProvider.value(
        value: bloc,
        child: const MaterialApp(home: RegisterScreen())));
    final nameField = find.byType(TextFormField).first;
    final widget = tester.widget<TextFormField>(nameField);
    final textField = tester.widget<TextField>(
        find.descendant(of: nameField, matching: find.byType(TextField)));
    expect(textField.keyboardType, TextInputType.name);
    expect(textField.inputFormatters, isNull);
    await tester.showKeyboard(nameField);
    const composed = 'Nguyễn Văn An';
    tester.testTextInput.updateEditingValue(const TextEditingValue(
      text: composed,
      selection: TextSelection.collapsed(offset: composed.length),
      composing: TextRange(start: 0, end: composed.length),
    ));
    await tester.pump();
    expect(widget.controller?.text, composed);
    expect(widget.controller?.value.composing,
        const TextRange(start: 0, end: composed.length));
  });

  testWidgets('Duplicate phone is shown beside the registration field',
      (tester) async {
    final repository = RegistrationRepository()
      ..response = const Error(PhoneAlreadyExistsFailure());
    final bloc = AuthBloc(
        loginUseCase: LoginUseCase(repository),
        registerUseCase: RegisterUseCase(repository),
        logoutUseCase: LogoutUseCase(repository),
        checkAuthStatusUseCase: CheckAuthStatusUseCase(repository));
    addTearDown(bloc.close);
    await tester.pumpWidget(BlocProvider.value(
        value: bloc,
        child: const MaterialApp(home: RegisterScreen())));
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'Nguyễn Văn An');
    await tester.enterText(fields.at(1), '0901234567');
    await tester.enterText(fields.at(3), '12345678');
    await tester.enterText(fields.at(4), '12345678');
    await tester.ensureVisible(find.text('ĐĂNG KÝ NGAY'));
    await tester.tap(find.text('ĐĂNG KÝ NGAY'));
    await tester.pumpAndSettle();
    expect(repository.calls, 1);
    expect(find.text('Số điện thoại này đã được đăng ký tài khoản.'),
        findsWidgets);
  });

  testWidgets('Registration cannot be submitted twice while waiting',
      (tester) async {
    final repository = RegistrationRepository()
      ..pending = Completer<Result<User>>();
    final bloc = AuthBloc(
        loginUseCase: LoginUseCase(repository),
        registerUseCase: RegisterUseCase(repository),
        logoutUseCase: LogoutUseCase(repository),
        checkAuthStatusUseCase: CheckAuthStatusUseCase(repository));
    addTearDown(bloc.close);
    await tester.pumpWidget(BlocProvider.value(
        value: bloc,
        child: const MaterialApp(home: RegisterScreen())));
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'Nguyễn Văn An');
    await tester.enterText(fields.at(1), '0901234567');
    await tester.enterText(fields.at(3), '12345678');
    await tester.enterText(fields.at(4), '12345678');
    await tester.ensureVisible(find.text('ĐĂNG KÝ NGAY'));
    await tester.tap(find.text('ĐĂNG KÝ NGAY'));
    await tester.pump();
    expect(repository.calls, 1);
    expect(tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
        isNull);
    repository.pending!.complete(repository.response);
    await tester.pumpAndSettle();
    expect(repository.calls, 1);
  });
}
