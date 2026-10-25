import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../../core/config/app_config.dart';
import '../../../../core/theme/app_motion.dart';
import '../bloc/auth_bloc.dart';
import '../bloc/auth_event.dart';
import '../bloc/auth_state.dart';
import 'role_home.dart';
import 'register_screen.dart';

/// Màn hình Đăng nhập (Mục D.7):
/// Kết nối trực tiếp BLoC, xác thực form, điều hướng sang RegisterScreen và CustomerHomeStubScreen.
/// Tuyệt đối KHÔNG có API call trực tiếp trong Widget.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _identifierController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;

  @override
  void dispose() {
    _identifierController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _onLoginPressed() {
    if (_formKey.currentState?.validate() ?? false) {
      context.read<AuthBloc>().add(
            AuthLoginSubmitted(
              identifier: _identifierController.text.trim(),
              password: _passwordController.text,
            ),
          );
    }
  }

  void _fillMockAccount(
      {required String phone,
      required String password,
      required String roleTitle}) {
    setState(() {
      _identifierController.text = phone;
      _passwordController.text = password;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Đã nạp tài khoản test: $roleTitle ($phone)'),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isMockMode = AppConfig.instance.isMock;
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('GoMove'),
        centerTitle: true,
      ),
      body: BlocConsumer<AuthBloc, AuthState>(
        listener: (context, state) {
          if (state is AuthErrorState) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(state.message),
                backgroundColor: colors.error,
                behavior: SnackBarBehavior.floating,
              ),
            );
          } else if (state is AuthenticatedState) {
            Navigator.of(context).pushReplacement(
              AppMotion.immediateRoute<void>(RoleHome(user: state.user)),
            );
          }
        },
        builder: (context, state) {
          final isLoading = state is AuthLoadingState;

          return SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding:
                const EdgeInsets.symmetric(horizontal: 24.0, vertical: 12.0),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 10),
                  AppMotion.entrance(
                    context,
                    Column(
                      children: [
                        Icon(
                          Icons.electric_moped_rounded,
                          size: 72,
                          color: colors.primary,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Đăng nhập GoMove',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Ứng dụng di chuyển thông minh cho sinh viên',
                          textAlign: TextAlign.center,
                          style: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),
                  TextFormField(
                    controller: _identifierController,
                    keyboardType: TextInputType.text,
                    decoration: const InputDecoration(
                      labelText: 'Số điện thoại hoặc Email',
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'Vui lòng nhập số điện thoại hoặc email';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _passwordController,
                    obscureText: _obscurePassword,
                    decoration: InputDecoration(
                      labelText: 'Mật khẩu',
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        icon: Icon(_obscurePassword
                            ? Icons.visibility_off
                            : Icons.visibility),
                        onPressed: () => setState(
                            () => _obscurePassword = !_obscurePassword),
                      ),
                    ),
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'Vui lòng nhập mật khẩu';
                      }
                      if (value.length < 6) {
                        return 'Mật khẩu tối thiểu 6 ký tự';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: isLoading ? null : _onLoginPressed,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      backgroundColor: colors.primary,
                      foregroundColor: colors.onPrimary,
                    ),
                    child: AnimatedSwitcher(
                      duration: AppMotion.duration(context, AppMotion.feedback),
                      child: isLoading
                          ? const SizedBox(
                              key: ValueKey('login-loading'),
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text(
                              'ĐĂNG NHẬP',
                              key: ValueKey('login-ready'),
                              style: TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    alignment: WrapAlignment.center,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      const Text('Chưa có tài khoản?'),
                      TextButton(
                        onPressed: () async {
                          final registeredPhone =
                              await Navigator.of(context).push<String>(
                            AppMotion.authRoute<String>(
                                context, const RegisterScreen()),
                          );
                          if (registeredPhone != null) {
                            setState(() {
                              _identifierController.text = registeredPhone;
                              _passwordController.clear();
                            });
                          }
                        },
                        child: Text(
                          'Đăng ký ngay',
                          style: TextStyle(
                            color: colors.primary,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (isMockMode) ...[
                    const SizedBox(height: 20),
                    const Divider(),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.amber.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.amber.shade300),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.bolt,
                                  color: Colors.amber.shade800, size: 18),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  'MOCK MODE ĐANG BẬT (AppConfig.isMock = true)',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 11,
                                    color: Colors.amber.shade900,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton(
                                  onPressed: () => _fillMockAccount(
                                    phone: '0901234567',
                                    password: '123456',
                                    roleTitle: 'SV Khách',
                                  ),
                                  child: const Text('SV Khách'),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: OutlinedButton(
                                  onPressed: () => _fillMockAccount(
                                    phone: '0909876543',
                                    password: '123456',
                                    roleTitle: 'SV Tài xế',
                                  ),
                                  child: const Text('SV Tài xế'),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
