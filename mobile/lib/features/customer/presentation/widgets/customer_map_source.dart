import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:maplibre_gl/maplibre_gl.dart';

/// Shared public basemap configuration for Customer maps. No session data is
/// ever attached to requests made to the external tile provider.
class CustomerMapSource {
  CustomerMapSource._();

  static const _configuredStyle = String.fromEnvironment(
    'MAP_STYLE_URL',
    defaultValue: MapLibreStyles.openfreemapLiberty,
  );
  static const _configuredAttribution =
      String.fromEnvironment('MAP_ATTRIBUTION');

  static String get styleUrl => _configuredStyle.trim().isEmpty
      ? MapLibreStyles.openfreemapLiberty
      : _configuredStyle;

  static String get visibleAttribution {
    if (_configuredAttribution.trim().isNotEmpty) {
      return _configuredAttribution;
    }
    if (_configuredStyle.trim().isEmpty ||
        _configuredStyle == MapLibreStyles.openfreemapLiberty) {
      return 'Nền bản đồ: OpenFreeMap · © OpenMapTiles · dữ liệu © OpenStreetMap contributors';
    }
    return 'Nguồn bản đồ tùy chỉnh: xem nút ghi công trên bản đồ; đặt MAP_ATTRIBUTION khi build.';
  }

  static Future<void> configureRequests() async {
    if (!kIsWeb) {
      await setHttpHeaders({
        'User-Agent': 'GoMoveAcademicDemo/1.0 (MapLibre Flutter)',
      });
    }
  }
}
