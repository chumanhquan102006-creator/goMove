import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/auth_bloc.dart';
import '../bloc/auth_event.dart';
import '../bloc/auth_state.dart';
import '../registration_validation.dart';

/// Màn hình Đăng ký tài khoản khách hàng mới (CUSTOMER ONLY - Mục A.4 & C.11)
/// Tuyệt đối KHÔNG có Role Selector, mặc định 100% vai trò là Customer.
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _phoneController = TextEditingController();
  final _fullNameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  bool _submitting = false;
  Map<String, String> _serverFieldErrors = {};

  void _clearServerError(String field) {
    if (_serverFieldErrors.containsKey(field)) {
      setState(() => _serverFieldErrors.remove(field));
    }
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _fullNameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  void _onRegisterPressed() {
    if (_submitting || context.read<AuthBloc>().state is AuthLoadingState) {
      return;
    }
    if (_formKey.currentState?.validate() ?? false) {
      setState(() => _submitting = true);
      context.read<AuthBloc>().add(
            AuthRegisterSubmitted(
              phone: _phoneController.text.trim(),
              email: _emailController.text.trim().isEmpty
                  ? null
                  : _emailController.text.trim(),
              password: _passwordController.text,
              fullName: _fullNameController.text.trim(),
            ),
          );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Đăng ký tài khoản'),
        centerTitle: true,
      ),
      body: BlocConsumer<AuthBloc, AuthState>(
        listener: (context, state) {
          if (state is AuthErrorState) {
            setState(() {
              _submitting = false;
              _serverFieldErrors = {
                ...state.fieldErrors,
                if (state.code == 'PHONE_ALREADY_EXISTS')
                  'phone': state.message,
                if (state.code == 'EMAIL_ALREADY_EXISTS')
                  'email': state.message,
              };
            });
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _formKey.currentState?.validate();
            });
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(state.message),
                backgroundColor: colors.error,
                behavior: SnackBarBehavior.floating,
              ),
            );
          } else if (state is AuthRegistrationSuccessState) {
            _submitting = false;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text(
                    'Đăng ký tài khoản thành công! Vui lòng đăng nhập.'),
                backgroundColor: colors.tertiary,
                behavior: SnackBarBehavior.floating,
              ),
            );
            Navigator.of(context).pop(_phoneController.text.trim());
          }
        },
        builder: (context, state) {
          final isLoading = state is AuthLoadingState || _submitting;

          return SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.all(24.0),
            child: Form(
              key: _formKey,
              autovalidateMode: AutovalidateMode.onUserInteraction,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Tạo tài khoản GoMove',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Dành cho sinh viên đặt xe nhanh chóng, tiết kiệm',
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: colors.onSurfaceVariant),
                  ),
                  const SizedBox(height: 24),
                  TextFormField(
                    controller: _fullNameController,
                    keyboardType: TextInputType.name,
                    textCapitalization: TextCapitalization.words,
                    autocorrect: true,
                    onChanged: (_) => _clearServerError('fullName'),
                    decoration: const InputDecoration(
                      labelText: 'Họ và tên *',
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                    validator: (value) =>
                        RegistrationValidation.fullName(value) ??
                        _serverFieldErrors['fullName'],
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _phoneController,
                    keyboardType: TextInputType.phone,
                    onChanged: (_) => _clearServerError('phone'),
                    decoration: const InputDecoration(
                      labelText: 'Số điện thoại *',
                      prefixIcon: Icon(Icons.phone_android),
                    ),
                    validator: (value) =>
                        RegistrationValidation.phone(value) ??
                        _serverFieldErrors['phone'],
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    onChanged: (_) => _clearServerError('email'),
                    decoration: const InputDecoration(
                      labelText: 'Email (Tùy chọn)',
                      prefixIcon: Icon(Icons.email_outlined),
                    ),
                    validator: (value) =>
                        RegistrationValidation.email(value) ??
                        _serverFieldErrors['email'],
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _passwordController,
                    obscureText: _obscurePassword,
                    onChanged: (_) => _clearServerError('password'),
                    decoration: InputDecoration(
                      labelText: 'Mật khẩu *',
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        icon: Icon(_obscurePassword
                            ? Icons.visibility_off
                            : Icons.visibility),
                        onPressed: () => setState(
                            () => _obscurePassword = !_obscurePassword),
                      ),
                    ),
                    validator: (value) =>
                        RegistrationValidation.password(value) ??
                        _serverFieldErrors['password'],
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _confirmPasswordController,
                    obscureText: _obscureConfirmPassword,
                    decoration: InputDecoration(
                      labelText: 'Xác nhận mật khẩu *',
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        icon: Icon(_obscureConfirmPassword
                            ? Icons.visibility_off
                            : Icons.visibility),
                        onPressed: () => setState(() =>
                            _obscureConfirmPassword = !_obscureConfirmPassword),
                      ),
                    ),
                    validator: (value) => RegistrationValidation.confirmation(
                        value, _passwordController.text),
                  ),
                  const SizedBox(height: 28),
                  ElevatedButton(
                    onPressed: isLoading ? null : _onRegisterPressed,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: colors.primary,
                      foregroundColor: colors.onPrimary,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    child: isLoading
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text(
                            'ĐĂNG KÝ NGAY',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    alignment: WrapAlignment.center,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      const Text('Đã có tài khoản?'),
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: Text(
                          'Đăng nhập',
                          style: TextStyle(
                            color: colors.primary,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
