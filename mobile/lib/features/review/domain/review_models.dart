class DriverReputation {
  final double? average;
  final int ratingCount;
  final int earnedPoints;
  final int deductedPoints;
  final int availablePoints;
  final List<String> badges;

  const DriverReputation(this.average, this.ratingCount, this.earnedPoints,
      this.deductedPoints, this.availablePoints, this.badges);

  factory DriverReputation.fromJson(Map<String, dynamic> json) =>
      DriverReputation(
        json['ratingAverage'] == null
            ? null
            : double.parse(json['ratingAverage'].toString()),
        (json['ratingCount'] as num).toInt(),
        (json['earnedPoints'] as num).toInt(),
        (json['deductedPoints'] as num).toInt(),
        (json['availablePoints'] as num).toInt(),
        (json['badges'] as List).cast<String>(),
      );
}

class RewardEvent {
  final String publicId;
  final int stars;
  final int pointsDelta;
  final DateTime createdAt;

  const RewardEvent(
      this.publicId, this.stars, this.pointsDelta, this.createdAt);
  factory RewardEvent.fromJson(Map<String, dynamic> json) => RewardEvent(
      json['publicId'] as String,
      (json['stars'] as num).toInt(),
      (json['pointsDelta'] as num).toInt(),
      DateTime.parse(json['createdAt'] as String).toLocal());
}

class QualityCase {
  final String publicId;
  final String driverPublicId;
  final String? driverDisplayName;
  final String status;
  final int ratingCount;
  final double recentAverage;
  final String reason;
  final DateTime createdAt;

  const QualityCase(this.publicId, this.driverPublicId, this.status,
      this.ratingCount, this.recentAverage, this.reason, this.createdAt,
      {this.driverDisplayName});
  factory QualityCase.fromJson(Map<String, dynamic> json) => QualityCase(
      json['publicId'] as String,
      json['driverPublicId'] as String,
      json['status'] as String,
      (json['ratingCount'] as num).toInt(),
      double.parse(json['recentAverage'].toString()),
      json['reason'] as String,
      DateTime.parse(json['createdAt'] as String).toLocal(),
      driverDisplayName: json['driverDisplayName'] as String?);
}

class RatingEvidence {
  final int stars;
  final String? comment;
  final DateTime createdAt;
  const RatingEvidence(this.stars, this.comment, this.createdAt);
  factory RatingEvidence.fromJson(Map<String, dynamic> json) => RatingEvidence(
      (json['stars'] as num).toInt(),
      json['comment'] as String?,
      DateTime.parse(json['createdAt'] as String).toLocal());
}

class QualityAction {
  final String action;
  final String? note;
  final DateTime createdAt;
  const QualityAction(this.action, this.note, this.createdAt);
  factory QualityAction.fromJson(Map<String, dynamic> json) => QualityAction(
      json['action'] as String,
      json['note'] as String?,
      DateTime.parse(json['createdAt'] as String).toLocal());
}

class QualityDetail {
  final QualityCase qualityCase;
  final List<RatingEvidence> evidence;
  final List<QualityAction> actions;
  const QualityDetail(this.qualityCase, this.evidence, this.actions);
  factory QualityDetail.fromJson(Map<String, dynamic> json) => QualityDetail(
      QualityCase.fromJson(
          Map<String, dynamic>.from(json['qualityCase'] as Map)),
      (json['recentRatings'] as List)
          .map((e) =>
              RatingEvidence.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      (json['actions'] as List)
          .map((e) =>
              QualityAction.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList());
}

class ReviewPage<T> {
  final List<T> items;
  final int page;
  final bool hasNext;
  const ReviewPage(this.items, this.page, this.hasNext);
  factory ReviewPage.fromJson(
          Map<String, dynamic> json, T Function(Map<String, dynamic>) parse) =>
      ReviewPage(
          (json['items'] as List)
              .map((e) => parse(Map<String, dynamic>.from(e as Map)))
              .toList(),
          (json['page'] as num).toInt(),
          json['hasNext'] as bool);
}
