import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../../core/config/app_config.dart';
import '../bloc/auth_bloc.dart';
import '../bloc/auth_event.dart';
import '../bloc/auth_state.dart';
import 'customer_home_stub_screen.dart';
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
  final _identifierController = TextEditingController(text: '0901234567');
  final _passwordController = TextEditingController(text: '123456');
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

  void _fillMockAccount({required String phone, required String password, required String roleTitle}) {
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

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('GoMove'),
        centerTitle: true,
        backgroundColor: Colors.white,
        elevation: 0,
      ),
      body: BlocConsumer<AuthBloc, AuthState>(
        listener: (context, state) {
          if (state is AuthErrorState) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(state.message),
                backgroundColor: const Color(0xFFEF4444),
                behavior: SnackBarBehavior.floating,
              ),
            );
          } else if (state is AuthenticatedState) {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute<void>(
                builder: (_) => CustomerHomeStubScreen(user: state.user),
              ),
            );
          }
        },
        builder: (context, state) {
          final isLoading = state is AuthLoadingState;

          return SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 12.0),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 10),
                  const Center(
                    child: Icon(
                      Icons.electric_moped_rounded,
                      size: 72,
                      color: Color(0xFF0066FF),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Đăng nhập GoMove',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1E293B),
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Ứng dụng di chuyển thông minh cho sinh viên',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Color(0xFF64748B), fontSize: 13),
                  ),
                  const SizedBox(height: 32),
                  TextFormField(
                    controller: _identifierController,
                    keyboardType: TextInputType.text,
                    decoration: const InputDecoration(
                      labelText: 'Số điện thoại hoặc Email',
                      prefixIcon: Icon(Icons.person_outline),
                      border: OutlineInputBorder(),
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
                        icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility),
                        onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                      ),
                      border: const OutlineInputBorder(),
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
                      backgroundColor: const Color(0xFF0066FF),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: isLoading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text(
                            'ĐĂNG NHẬP',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('Chưa có tài khoản?'),
                      TextButton(
                        onPressed: () async {
                          final registeredPhone = await Navigator.of(context).push<String>(
                            MaterialPageRoute(builder: (_) => const RegisterScreen()),
                          );
                          if (registeredPhone != null) {
                            setState(() {
                              _identifierController.text = registeredPhone;
                              _passwordController.clear();
                            });
                          }
                        },
                        child: const Text(
                          'Đăng ký ngay',
                          style: TextStyle(
                            color: Color(0xFF0066FF),
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
                        border: BorderSide(color: Colors.amber.shade300),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.bolt, color: Colors.amber.shade800, size: 18),
                              const SizedBox(width: 6),
                              Text(
                                'MOCK MODE ĐANG BẬT (AppConfig.isMock = true)',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 11,
                                  color: Colors.amber.shade900,
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
