class RegistrationValidation {
  RegistrationValidation._();

  static String? fullName(String? value) {
    final name = (value ?? '').trim();
    if (name.isEmpty) return 'Vui lòng nhập họ và tên.';
    if (name.length > 100) return 'Họ và tên tối đa 100 ký tự.';
    return null;
  }

  static String? phone(String? value) {
    final phone = (value ?? '').trim();
    if (phone.isEmpty) return 'Vui lòng nhập số điện thoại.';
    if (phone.length > 20) return 'Số điện thoại tối đa 20 ký tự.';
    return null;
  }

  static String? email(String? value) {
    final email = (value ?? '').trim();
    if (email.isEmpty) return null;
    if (email.length > 100) return 'Email tối đa 100 ký tự.';
    if (!RegExp(r'^[^\s@]+@[^\s@]+$').hasMatch(email)) {
      return 'Email không hợp lệ.';
    }
    return null;
  }

  static String? password(String? value) {
    final length = value?.length ?? 0;
    if (length < 8) return 'Mật khẩu phải có ít nhất 8 ký tự.';
    if (length > 128) return 'Mật khẩu tối đa 128 ký tự.';
    return null;
  }

  static String? confirmation(String? value, String password) =>
      value == password ? null : 'Mật khẩu xác nhận không khớp.';
}
