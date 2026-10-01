import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;

enum AppEnvironment {
  dev,
  staging,
  prod,
  mock,
}

/// [AppConfig] quản lý tập trung cấu hình runtime, biến môi trường và
/// cờ chuyển đổi linh hoạt giữa Mock-First và Real Backend API (Điều 161, 162).
class AppConfig {
  final AppEnvironment environment;
  final String appTitle;
  final String apiBaseUrl;
  final String wsBaseUrl;
  final Duration connectTimeout;
  final Duration receiveTimeout;
  final Duration sendTimeout;

  /// Cờ định danh kích hoạt chế độ Mock toàn hệ thống (Mock-First Strategy)
  final bool isMock;

  const AppConfig({
    required this.environment,
    required this.appTitle,
    required this.apiBaseUrl,
    required this.wsBaseUrl,
    required this.connectTimeout,
    required this.receiveTimeout,
    required this.sendTimeout,
    required this.isMock,
  });

  /// Singleton instance có thể truy cập toàn ứng dụng
  static AppConfig? _instance;
  static AppConfig get instance => _instance!;

  /// Tự động xác định default host theo từng nền tảng:
  /// - Android Emulator: http://10.0.2.2:8080
  /// - iOS Simulator / macOS / Windows / Linux: http://localhost:8080
  static String resolveDefaultHost() {
    if (kIsWeb) return 'http://localhost:8080';
    try {
      if (Platform.isAndroid) {
        return 'http://10.0.2.2:8080';
      }
    } catch (_) {}
    return 'http://localhost:8080';
  }

  /// Chuẩn hóa URL để luôn có tiền tố `/api/v1`
  static String normalizeBaseUrl(String url) {
    var trimmed = url.trim();
    if (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    if (!trimmed.endsWith('/api/v1')) {
      trimmed = '$trimmed/api/v1';
    }
    return trimmed;
  }

  /// Khởi tạo cấu hình ứng dụng
  static AppConfig initialize({
    AppEnvironment env = AppEnvironment.mock,
    bool? forceMock,
    String? customBaseUrl,
  }) {
    final bool enableMock = forceMock ?? const bool.fromEnvironment('MOCK_ENABLED', defaultValue: true);

    final String defaultHost = resolveDefaultHost();
    const String envBaseUrl = String.fromEnvironment('API_BASE_URL');
    final String rawBaseUrl = customBaseUrl ?? (envBaseUrl.isNotEmpty ? envBaseUrl : defaultHost);
    final String finalBaseUrl = normalizeBaseUrl(rawBaseUrl);

    const String wsUrl = String.fromEnvironment(
      'WS_BASE_URL',
      defaultValue: 'ws://10.0.2.2:8080/ws',
    );

    _instance = AppConfig(
      environment: env,
      appTitle: 'GoMove - Ride Hailing',
      apiBaseUrl: finalBaseUrl,
      wsBaseUrl: wsUrl,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 15),
      sendTimeout: const Duration(seconds: 15),
      isMock: enableMock,
    );

    return _instance!;
  }

  /// Reset cấu hình singleton để cô lập trạng thái giữa các unit test.
  static void reset() {
    _instance = null;
  }
}
