import '../models/place_search_result.dart';
import '../models/quote.dart';

abstract class GeocodingRepository {
  Future<List<PlaceSearchResult>> search(String query,
      {int? sessionGeneration});

  Future<PlaceSearchResult?> reverse(Coordinates point,
      {int? sessionGeneration});
}
