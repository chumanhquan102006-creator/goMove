import '../models/road_route.dart';

abstract class RoadRouteRepository {
  Future<RoadRoute> quote(String quotePublicId, int sessionGeneration);
  Future<RoadRoute> booking(String bookingPublicId, int sessionGeneration);
}
