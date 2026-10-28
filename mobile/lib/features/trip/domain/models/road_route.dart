import 'dart:convert';
import 'dart:math' as math;

import '../../../customer/domain/models/quote.dart';

/// A stored, authorized road route. Coordinates on the wire are GeoJSON
/// [longitude, latitude]; [Coordinates] keeps the app's latitude-first API.
class RoadRoute {
  static const maxVertices = 8192;
  static const maxGeometryBytes = 512 * 1024;
  static const endpointToleranceMeters = 500.0;

  final String sourceQuotePublicId;
  final String? bookingPublicId;
  final List<Coordinates> points;

  const RoadRoute._(
      this.sourceQuotePublicId, this.bookingPublicId, this.points);

  bool get available => points.isNotEmpty;

  static RoadRoute fromJson(Map<String, dynamic> json) {
    final sourceId = json['sourceQuotePublicId'];
    final bookingId = json['bookingPublicId'];
    final availability = json['availability'];
    if (sourceId is! String ||
        sourceId.isEmpty ||
        (bookingId != null && bookingId is! String)) {
      throw const FormatException('Định danh tuyến đường không hợp lệ');
    }
    if (availability == 'UNAVAILABLE') {
      if (json['geometry'] != null) {
        throw const FormatException('Trạng thái tuyến đường không nhất quán');
      }
      return RoadRoute._(sourceId, bookingId as String?, const []);
    }
    if (availability != 'AVAILABLE' ||
        json['geometryFormat'] != 'GEOJSON_LINESTRING') {
      throw const FormatException('Định dạng tuyến đường không hợp lệ');
    }
    final geometry = json['geometry'];
    if (geometry is! Map || geometry['type'] != 'LineString') {
      throw const FormatException('Hình học tuyến đường không hợp lệ');
    }
    final positions = geometry['coordinates'];
    if (positions is! List ||
        positions.length < 2 ||
        positions.length > maxVertices) {
      throw const FormatException('Số điểm tuyến đường không hợp lệ');
    }
    final points = <Coordinates>[];
    for (final position in positions) {
      if (position is! List ||
          position.length != 2 ||
          position[0] is! num ||
          position[1] is! num) {
        throw const FormatException('Tọa độ tuyến đường không hợp lệ');
      }
      final point = Coordinates(
          (position[1] as num).toDouble(), (position[0] as num).toDouble());
      if (!point.isValid) {
        throw const FormatException('Tọa độ tuyến đường ngoài phạm vi');
      }
      points.add(point);
    }
    if (utf8.encode(jsonEncode(geometry)).length > maxGeometryBytes) {
      throw const FormatException('Tuyến đường quá lớn');
    }
    return RoadRoute._(
        sourceId, bookingId as String?, List.unmodifiable(points));
  }

  /// Local defense if a malformed response slips past backend validation.
  bool matchesEndpoints(Coordinates pickup, Coordinates dropoff) =>
      available &&
      pickup.isValid &&
      dropoff.isValid &&
      _distanceMeters(points.first, pickup) <= endpointToleranceMeters &&
      _distanceMeters(points.last, dropoff) <= endpointToleranceMeters;

  static double _distanceMeters(Coordinates a, Coordinates b) {
    const radians = 0.017453292519943295;
    const earthMeters = 6371000.0;
    final lat1 = a.latitude * radians;
    final lat2 = b.latitude * radians;
    final lonDelta = (b.longitude - a.longitude) * radians;
    final haversine = _sinSquared((lat2 - lat1) / 2) +
        math.cos(lat1) * math.cos(lat2) * _sinSquared(lonDelta / 2);
    return 2 * earthMeters * math.asin(math.sqrt(haversine.clamp(0.0, 1.0)));
  }

  static double _sinSquared(double angle) {
    final value = math.sin(angle);
    return value * value;
  }
}
