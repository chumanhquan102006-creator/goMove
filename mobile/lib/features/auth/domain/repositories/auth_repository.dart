import '../../../../core/utils/result.dart';
import '../entities/user.dart';

/// Hợp đồng trừu tượng (Interface) của AuthRepository thuộc tầng Domain.
/// Tầng Presentation / BLoC chỉ phụ thuộc vào Interface này, hoàn toàn không phụ thuộc
/// vào nguồn dữ liệu thực tế (Mock hay Real API) - Thực hiện nguyên lý Dependency Inversion.
abstract class AuthRepository {
  /// Đăng nhập bằng số điện thoại hoặc email (identifier) và mật khẩu
  Future<Result<User>> login({
    required String identifier,
    required String password,
  });

  /// Đăng ký tài khoản khách hàng mới (CUSTOMER ONLY - Mục A.4)
  Future<Result<User>> register({
    required String phone,
    String? email,
    required String password,
    required String fullName,
  });

  /// Lấy thông tin tài khoản hiện tại từ phiên đăng nhập
  Future<Result<User>> getCurrentUser();

  /// Đăng xuất khỏi hệ thống và vô hiệu hóa token trên server
  Future<Result<void>> logout();

  /// Kiểm tra xem client đã có token lưu trữ hay chưa
  Future<Result<bool>> isAuthenticated();

  /// Khôi phục và thẩm định phiên làm việc khi mở ứng dụng (Mục G)
  Future<Result<User>> checkAuthStatus();
}
