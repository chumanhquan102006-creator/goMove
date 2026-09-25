import 'package:flutter/material.dart';
import 'core/config/app_config.dart';
import 'core/di/injection.dart';
import 'app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Khởi tạo cấu hình ứng dụng (Mặc định: Mock Mode = true phục vụ Frontend-First)
  final config = AppConfig.initialize();

  // Thiết lập Service Locator & Dependency Injection (chuyển đổi Mock / Real tự động)
  await setupServiceLocator(config: config);

  runApp(const GoMoveApp());
}
