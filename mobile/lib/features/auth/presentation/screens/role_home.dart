import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../../core/theme/app_motion.dart';
import '../../../../features/customer/presentation/screens/customer_home_screen.dart';
import '../../../../features/driver/presentation/screens/driver_home_screen.dart';
import '../../domain/entities/user.dart';
import '../bloc/auth_bloc.dart';
import '../bloc/auth_event.dart';
import '../bloc/auth_state.dart';
import 'login_screen.dart';

class RoleHome extends StatelessWidget {
  final User user;
  const RoleHome({super.key, required this.user});

  @override
  Widget build(BuildContext context) => BlocListener<AuthBloc, AuthState>(
        listener: (context, state) {
          if (state is UnauthenticatedState) {
            Navigator.of(context).pushAndRemoveUntil(
                AppMotion.immediateRoute<void>(const LoginScreen()),
                (_) => false);
          }
        },
        child: homeForRole(user),
      );
}

Widget homeForRole(User user) => switch (user.role) {
      UserRole.customer => CustomerHomeScreen(user: user),
      UserRole.driver => DriverHomeScreen(user: user),
      _ => _PlaceholderHome(
          user: user,
          title: 'Không hỗ trợ vai trò',
          message: 'Vai trò này không được phép truy cập ứng dụng Customer.'),
    };

class _PlaceholderHome extends StatelessWidget {
  final User user;
  final String title;
  final String message;
  const _PlaceholderHome(
      {required this.user, required this.title, required this.message});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(title), actions: [
          IconButton(
            tooltip: 'Đăng xuất',
            icon: const Icon(Icons.logout),
            onPressed: () =>
                context.read<AuthBloc>().add(const AuthLogoutRequested()),
          )
        ]),
        body: Center(
            child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(user.fullName,
                        style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 12),
                    Text(message, textAlign: TextAlign.center),
                  ],
                ))),
      );
}
