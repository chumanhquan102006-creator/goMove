import 'rating_models.dart';

abstract class RatingRepository {
  Future<RatingLookup> lookup(String bookingPublicId, int generation);
  Future<TripRating> submit(
      String bookingPublicId, int stars, String? comment, int generation);
}
