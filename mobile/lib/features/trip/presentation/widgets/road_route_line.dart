import 'package:maplibre_gl/maplibre_gl.dart';

import '../../domain/models/road_route.dart';

class RoadRouteLine {
  RoadRouteLine._();

  static LineOptions? options(RoadRoute? route) {
    if (route == null || !route.available) return null;
    return LineOptions(
      geometry: route.points
          .map((point) => LatLng(point.latitude, point.longitude))
          .toList(growable: false),
      lineColor: '#0066FF',
      lineWidth: 5,
      lineOpacity: .88,
      lineJoin: 'round',
    );
  }
}
