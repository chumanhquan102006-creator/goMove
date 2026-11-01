import 'admin_models.dart';

abstract class AdminRepository {
  Future<AdminDashboard> dashboard(int generation);
  Future<AdminPage<AdminDriver>> drivers(
      int page, String? approval, String? search, int generation);
  Future<AdminDriver> driver(String publicId, int generation);
  Future<AdminApprovalResult> setApproval(
      String publicId, String status, int generation);
  Future<AdminPage<AdminAccount>> accounts(
      int page, String? role, String? search, int generation);
  Future<AdminAccount> account(String publicId, int generation);
  Future<AdminPage<AdminBooking>> bookings(
      int page, String? status, int generation);
}
