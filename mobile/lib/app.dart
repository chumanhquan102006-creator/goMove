import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'core/config/app_config.dart';
import 'core/di/injection.dart';
import 'features/auth/presentation/bloc/auth_bloc.dart';
import 'features/auth/presentation/screens/splash_screen.dart';

class GoMoveApp extends StatelessWidget {
  const GoMoveApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider<AuthBloc>(
          create: (_) => sl<AuthBloc>(),
        ),
      ],
      child: MaterialApp(
        title: AppConfig.instance.appTitle,
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF0066FF),
            brightness: Brightness.light,
          ),
          appBarTheme: const AppBarTheme(
            elevation: 0,
            centerTitle: true,
          ),
        ),
        home: const SplashScreen(),
      ),
    );
  }
}
