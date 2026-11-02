import 'review_models.dart';

abstract class ReviewRepository {
  Future<DriverReputation> reputation(int generation);
  Future<ReviewPage<RewardEvent>> rewards(int page, int generation);
  Future<ReviewPage<QualityCase>> myCases(int page, int generation);
  Future<QualityCase> dispute(String publicId, String reason, int generation);
  Future<ReviewPage<QualityCase>> adminCases(
      int page, String? status, int generation);
  Future<QualityDetail> adminDetail(String publicId, int generation);
  Future<QualityDetail> adminAction(
      String publicId, String action, String note, int generation);
}
