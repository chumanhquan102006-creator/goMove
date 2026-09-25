import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/auth_bloc.dart';
import '../bloc/auth_event.dart';
import '../bloc/auth_state.dart';
import 'customer_home_stub_screen.dart';
import 'login_screen.dart';

/// Màn hình Splash: Kiểm tra và phục hồi phiên đăng nhập khi khởi động (Mục G)
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    // Kích hoạt thẩm định phiên làm việc
    context.read<AuthBloc>().add(const AuthCheckRequested());
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<AuthBloc, AuthState>(
      listener: (context, state) {
        if (state is AuthenticatedState) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute<void>(
              builder: (_) => CustomerHomeStubScreen(user: state.user),
            ),
          );
        } else if (state is UnauthenticatedState) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute<void>(
              builder: (_) => const LoginScreen(),
            ),
          );
        }
      },
      child: const Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.electric_moped_rounded,
                size: 96,
                color: Color(0xFF0066FF),
              ),
              SizedBox(height: 20),
              Text(
                'GoMove',
                style: TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                  color: Color(0xFF1E293B),
                ),
              ),
              SizedBox(height: 8),
              Text(
                'Di chuyển thông minh & an toàn cho sinh viên',
                style: TextStyle(
                  fontSize: 14,
                  color: Color(0xFF64748B),
                ),
              ),
              SizedBox(height: 48),
              SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF0066FF)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
