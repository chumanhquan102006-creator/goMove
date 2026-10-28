import 'package:flutter_test/flutter_test.dart';
import 'package:gomove_mobile/features/customer/domain/models/quote.dart';
import 'package:gomove_mobile/features/trip/domain/models/road_route.dart';

const pickup = Coordinates(21.0287, 105.8524);
const dropoff = Coordinates(21.0245, 105.8576);

Map<String, dynamic> availableRoute({Object? geometry}) => {
      'sourceQuotePublicId': 'quote-1',
      'bookingPublicId': null,
      'availability': 'AVAILABLE',
      'geometryFormat': 'GEOJSON_LINESTRING',
      'geometry': geometry ??
          {
            'type': 'LineString',
            'coordinates': [
              [105.8524, 21.0287],
              [105.8550, 21.0260],
              [105.8576, 21.0245]
            ],
          },
      'routingProvider': 'OSRM',
      'capturedAt': '2026-10-27T03:00:00Z',
    };

void main() {
  test('GeoJSON longitude/latitude becomes app latitude/longitude in order',
      () {
    final route = RoadRoute.fromJson(availableRoute());
    expect(route.available, isTrue);
    expect(route.points, hasLength(3));
    expect(route.points.first.latitude, 21.0287);
    expect(route.points.first.longitude, 105.8524);
    expect(route.points[1].latitude, 21.0260);
    expect(route.points[1].longitude, 105.8550);
    expect(route.matchesEndpoints(pickup, dropoff), isTrue);
    expect(route.matchesEndpoints(dropoff, pickup), isFalse);
    expect(() => route.points.add(pickup), throwsUnsupportedError);
  });

  test(
      'legacy UNAVAILABLE has no drawable points and rejects contradictory geometry',
      () {
    final unavailable = RoadRoute.fromJson({
      ...availableRoute(),
      'availability': 'UNAVAILABLE',
      'geometry': null,
    });
    expect(unavailable.available, isFalse);
    expect(unavailable.points, isEmpty);
    expect(unavailable.matchesEndpoints(pickup, dropoff), isFalse);
    expect(
        () => RoadRoute.fromJson({
              ...availableRoute(),
              'availability': 'UNAVAILABLE',
            }),
        throwsFormatException);
  });

  test('malformed, reversed, out-of-range and oversized routes are never valid',
      () {
    expect(
        () => RoadRoute.fromJson({
              ...availableRoute(),
              'geometryFormat': 'ENCODED_POLYLINE',
            }),
        throwsFormatException);
    expect(
        () => RoadRoute.fromJson(availableRoute(geometry: {
              'type': 'Point',
              'coordinates': [105.8524, 21.0287]
            })),
        throwsFormatException);
    expect(
        () => RoadRoute.fromJson(availableRoute(geometry: {
              'type': 'LineString',
              'coordinates': [
                [105.8524, 21.0287]
              ]
            })),
        throwsFormatException);
    expect(
        () => RoadRoute.fromJson(availableRoute(geometry: {
              'type': 'LineString',
              'coordinates': [
                [105.8524, 21.0287],
                [181, 21.0245]
              ]
            })),
        throwsFormatException);
    expect(
        () => RoadRoute.fromJson(availableRoute(geometry: {
              'type': 'LineString',
              'coordinates': List.generate(
                  RoadRoute.maxVertices + 1, (_) => [105.8524, 21.0287])
            })),
        throwsFormatException);
    expect(
        () => RoadRoute.fromJson(availableRoute(geometry: {
              'type': 'LineString',
              'coordinates': [
                [105.8524, 21.0287],
                [105.8576, 21.0245]
              ],
              'unexpected': 'x' * RoadRoute.maxGeometryBytes,
            })),
        throwsFormatException);

    // Both values here are technically in coordinate range. The endpoint
    // check must still reject the wrong pair order before MapLibre draws it.
    final swapped = RoadRoute.fromJson(availableRoute(geometry: {
      'type': 'LineString',
      'coordinates': [
        [21.0287, 80.8524],
        [21.0245, 80.8576]
      ],
    }));
    expect(swapped.available, isTrue);
    expect(swapped.matchesEndpoints(pickup, dropoff), isFalse);
  });
}
