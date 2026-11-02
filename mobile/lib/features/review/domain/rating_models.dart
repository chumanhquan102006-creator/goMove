class TripRating {
  final String publicId;
  final String bookingPublicId;
  final int stars;
  final String? comment;
  final DateTime createdAt;

  const TripRating(this.publicId, this.bookingPublicId, this.stars,
      this.comment, this.createdAt);

  factory TripRating.fromJson(Map<String, dynamic> json) => TripRating(
        json['publicId'] as String,
        json['bookingPublicId'] as String,
        (json['stars'] as num).toInt(),
        json['comment'] as String?,
        DateTime.parse(json['createdAt'] as String).toUtc(),
      );
}

class RatingLookup {
  final TripRating? rating;
  const RatingLookup(this.rating);

  factory RatingLookup.fromJson(Map<String, dynamic> json) => RatingLookup(
        json['rated'] == true && json['rating'] is Map
            ? TripRating.fromJson(
                Map<String, dynamic>.from(json['rating'] as Map))
            : null,
      );
}
